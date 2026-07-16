//! Glyph outline rasterization.
//!
//! Shaping and font resolution happen on the R side (via `textshaping` /
//! `systemfonts`), so the backend receives, per glyph: a font file + face
//! index, a glyph id, a pixel size, and a position. This module loads the font
//! with `skrifa` (the FreeType-equivalent), extracts the glyph outline at the
//! requested size, and returns it as a tiny-skia path in glyph-local pixels
//! (y-up, origin at the glyph's baseline pen position).

use std::cell::{Cell, RefCell};
use std::path::Path;
use std::rc::Rc;

use crate::cache::TwoGenCache;

use skrifa::instance::{LocationRef, Size};
use skrifa::outline::{DrawSettings, OutlinePen};
use skrifa::{FontRef, GlyphId, MetadataProvider};
use tiny_skia::{FillRule, Paint, PathBuilder, Pixmap, Transform};

/// Sub-pixel phase counts for the glyph-bitmap (sprite) cache: a sprite is cached
/// per quantised sub-pixel pen offset, so worst-case placement error is
/// `1/(2*PHASE)` px per axis (≈ 1/16 px here → ≈ 16/255 coverage at a glyph
/// edge). MUST match the fast-path phase computation in `render.rs`.
pub const PHASE_X: u32 = 8;
pub const PHASE_Y: u32 = 8;

/// A rasterised glyph coverage bitmap (colour baked in), plus the integer offset
/// `(dx, dy)` from the pen's integer cell to the sprite's top-left pixel.
pub struct GlyphSprite {
    pub pixmap: Pixmap,
    pub dx: i32,
    pub dy: i32,
}

/// Caches font file bytes, extracted glyph outlines, and rasterised glyph
/// sprites. Outlines are keyed by `(path, face, glyph, size-bits)`; sprites also
/// by `(colour, phase_x, phase_y)` (see `GlyphSprite`). A repeated glyph — within
/// a render and, via the persistent cache below, across renders — is extracted
/// and rasterised once. Each cache uses two-generation eviction (see `cache.rs`)
/// so exceeding a cap ages half the entries instead of wiping everything.
pub struct FontCache {
    files: TwoGenCache<String, Option<Rc<Vec<u8>>>>,
    // `Rc<Path>` so a repeated glyph (the outline-fill fallback runs once per glyph
    // *instance*) bumps a refcount instead of deep-copying the path's two Vecs.
    outlines: TwoGenCache<(String, u32, u32, u32), Option<Rc<tiny_skia::Path>>>,
    sprites: TwoGenCache<(String, u32, u32, u32, u32, u8, u8), Option<Rc<GlyphSprite>>>,
    sprite_hits: i64,
    sprite_misses: i64,
}

/// Per-generation caps. Font bytes: few distinct files, but bound it so a
/// long session opening many fonts can't grow it without limit. Outlines are
/// immutable; sprites carry a colour + phase axis on top of the glyph alphabet,
/// so their key space is larger.
const FILES_CAP: usize = 128;
const OUTLINE_CAP: usize = 20_000;
const SPRITE_CAP: usize = 16_384;
/// Never cache an absurdly large sprite (defensive; the R/size gate already keeps
/// sprited glyphs small). A glyph this big falls back to the outline-fill path.
const SPRITE_MAX_DIM: i64 = 512;

impl Default for FontCache {
    fn default() -> Self {
        FontCache {
            files: TwoGenCache::new(FILES_CAP),
            outlines: TwoGenCache::new(OUTLINE_CAP),
            sprites: TwoGenCache::new(SPRITE_CAP),
            sprite_hits: 0,
            sprite_misses: 0,
        }
    }
}

impl FontCache {
    fn bytes(&mut self, path: &str) -> Option<Rc<Vec<u8>>> {
        let key = path.to_string();
        if let Some(cached) = self.files.get(&key) {
            return cached; // cached success, or a cached read failure (`None`)
        }
        // Not cached: read once. A failure is cached too (a comment below notes
        // the staleness trade-off); realistically fonts don't appear mid-session.
        let bytes = std::fs::read(Path::new(path)).ok().map(Rc::new);
        self.files.insert(key, bytes.clone());
        bytes
    }

    /// Outline of `glyph_id` in `font_path`/`face_index`, scaled to `size_px`
    /// (pixels per em). Coordinates are y-up with the origin at the baseline
    /// pen position; the caller places and flips them. Memoised.
    pub fn glyph_outline(
        &mut self,
        font_path: &str,
        face_index: u32,
        glyph_id: u32,
        size_px: f32,
    ) -> Option<Rc<tiny_skia::Path>> {
        let key = (font_path.to_string(), face_index, glyph_id, size_px.to_bits());
        if let Some(o) = self.outlines.get(&key) {
            return o;
        }
        // A negative result (`None`: unreadable font, missing glyph, or a
        // whitespace glyph with no outline) is cached like any other. Whitespace
        // is the common, intended case; a transient read failure staying `None`
        // until `clear_glyph_cache` is an accepted trade-off (fonts don't appear
        // mid-session in practice).
        let out = self.extract(font_path, face_index, glyph_id, size_px).map(Rc::new);
        self.outlines.insert(key, out.clone());
        out
    }

    fn extract(&mut self, font_path: &str, face_index: u32, glyph_id: u32, size_px: f32) -> Option<tiny_skia::Path> {
        let bytes = self.bytes(font_path)?;
        let font = FontRef::from_index(bytes.as_slice(), face_index).ok()?;
        let outlines = font.outline_glyphs();
        let glyph = outlines.get(GlyphId::new(glyph_id))?;

        let mut pen = PathPen::default();
        let settings = DrawSettings::unhinted(Size::new(size_px), LocationRef::default());
        glyph.draw(settings, &mut pen).ok()?;
        pen.builder.finish()
    }

    /// A rasterised sprite for `glyph_id` at `size_px`, colour `color`, and
    /// sub-pixel phase `(phase_x/PHASE_X, phase_y/PHASE_Y)`. Memoised; `None` for
    /// a whitespace glyph (no outline) or an out-of-range sprite size (caller
    /// falls back to filling the outline). See [`GlyphSprite`].
    pub fn glyph_sprite(
        &mut self,
        font_path: &str,
        face_index: u32,
        glyph_id: u32,
        size_px: f32,
        color: [u8; 4],
        phase_x: u8,
        phase_y: u8,
    ) -> Option<Rc<GlyphSprite>> {
        let key = (
            font_path.to_string(), face_index, glyph_id, size_px.to_bits(),
            u32::from_be_bytes(color), phase_x, phase_y,
        );
        if let Some(s) = self.sprites.get(&key) {
            self.sprite_hits += 1;
            return s;
        }
        self.sprite_misses += 1;
        let sprite = self
            .build_sprite(font_path, face_index, glyph_id, size_px, color, phase_x, phase_y)
            .map(Rc::new);
        self.sprites.insert(key, sprite.clone());
        sprite
    }

    fn build_sprite(
        &mut self,
        font_path: &str,
        face_index: u32,
        glyph_id: u32,
        size_px: f32,
        color: [u8; 4],
        phase_x: u8,
        phase_y: u8,
    ) -> Option<GlyphSprite> {
        let outline = self.glyph_outline(font_path, face_index, glyph_id, size_px)?;
        let b = outline.bounds();
        // Sub-pixel pen offset within the integer cell; baked into the sprite.
        let fx = phase_x as f32 / PHASE_X as f32;
        let fy = phase_y as f32 / PHASE_Y as f32;
        // Outline is glyph-local y-up (baseline origin). Device (y-down) mapping,
        // pen at (fx, fy): (lx, ly) -> (fx + lx, fy - ly). tiny-skia `bounds()`
        // has top() = min y (descender) and bottom() = max y (ascender), so the
        // device-top is `fy - bottom()` and device-bottom is `fy - top()`.
        let pad = 1.0f32; // >=1px AA fringe on every side, integer via floor/ceil
        let sminx = (fx + b.left() - pad).floor();
        let sminy = (fy - b.bottom() - pad).floor();
        let smaxx = (fx + b.right() + pad).ceil();
        let smaxy = (fy - b.top() + pad).ceil();
        let w = (smaxx - sminx) as i64;
        let h = (smaxy - sminy) as i64;
        if w <= 0 || h <= 0 || w > SPRITE_MAX_DIM || h > SPRITE_MAX_DIM {
            return None;
        }
        let mut pm = Pixmap::new(w as u32, h as u32)?;
        let mut paint = Paint::default();
        paint.set_color(tiny_skia::Color::from_rgba8(color[0], color[1], color[2], color[3]));
        paint.anti_alias = true;
        // glyph-local (lx, ly) -> sprite pixel (lx + fx - sminx, -ly + fy - sminy).
        let t = Transform::from_row(1.0, 0.0, 0.0, -1.0, fx - sminx, fy - sminy);
        pm.fill_path(outline.as_ref(), &paint, FillRule::Winding, t, None);
        Some(GlyphSprite { pixmap: pm, dx: sminx as i32, dy: sminy as i32 })
    }

    fn sprite_stats(&self) -> (i64, i64, i64) {
        (self.sprite_hits, self.sprite_misses, self.sprites.len() as i64)
    }
}

thread_local! {
    /// Process-persistent glyph cache: font bytes + extracted outlines survive
    /// across renders, so repeated and same-size re-renders reuse the work.
    static GLYPH_CACHE: RefCell<FontCache> = RefCell::new(FontCache::default());
}

/// Glyph outline via the persistent cache. See [`FontCache::glyph_outline`].
pub fn glyph_outline_cached(font_path: &str, face_index: u32, glyph_id: u32, size_px: f32) -> Option<Rc<tiny_skia::Path>> {
    GLYPH_CACHE.with(|c| c.borrow_mut().glyph_outline(font_path, face_index, glyph_id, size_px))
}

/// Glyph sprite via the persistent cache. See [`FontCache::glyph_sprite`].
#[allow(clippy::too_many_arguments)]
pub fn glyph_sprite_cached(
    font_path: &str, face_index: u32, glyph_id: u32, size_px: f32,
    color: [u8; 4], phase_x: u8, phase_y: u8,
) -> Option<Rc<GlyphSprite>> {
    GLYPH_CACHE.with(|c| c.borrow_mut().glyph_sprite(font_path, face_index, glyph_id, size_px, color, phase_x, phase_y))
}

/// `(hits, misses, resident)` for the glyph sprite cache (tests/diagnostics).
pub fn glyph_sprite_stats() -> (i64, i64, i64) {
    GLYPH_CACHE.with(|c| c.borrow().sprite_stats())
}

/// Empty the persistent glyph cache (font bytes + outlines + sprites).
pub fn clear_glyph_cache() {
    GLYPH_CACHE.with(|c| {
        let mut b = c.borrow_mut();
        b.files.clear();
        b.outlines.clear();
        b.sprites.clear();
        b.sprite_hits = 0;
        b.sprite_misses = 0;
    });
}

thread_local! {
    /// Glyph-bitmap mode: 0 = off (always exact outline fill), 1 = auto (sprite
    /// only above the per-render glyph threshold), 2 = on. Set from R per render
    /// from `getOption("vellum.glyph_bitmap")`. Default auto.
    static GLYPH_BITMAP_MODE: Cell<i32> = const { Cell::new(1) };
}

/// Set the glyph-bitmap mode (see `GLYPH_BITMAP_MODE`).
pub fn set_glyph_bitmap_mode(mode: i32) {
    GLYPH_BITMAP_MODE.with(|c| c.set(mode));
}

/// Read the glyph-bitmap mode.
pub fn glyph_bitmap_mode() -> i32 {
    GLYPH_BITMAP_MODE.with(|c| c.get())
}

#[derive(Default)]
struct PathPen {
    builder: PathBuilder,
}

impl OutlinePen for PathPen {
    fn move_to(&mut self, x: f32, y: f32) {
        self.builder.move_to(x, y);
    }
    fn line_to(&mut self, x: f32, y: f32) {
        self.builder.line_to(x, y);
    }
    fn quad_to(&mut self, cx: f32, cy: f32, x: f32, y: f32) {
        self.builder.quad_to(cx, cy, x, y);
    }
    fn curve_to(&mut self, c0x: f32, c0y: f32, c1x: f32, c1y: f32, x: f32, y: f32) {
        self.builder.cubic_to(c0x, c0y, c1x, c1y, x, y);
    }
    fn close(&mut self) {
        self.builder.close();
    }
}
