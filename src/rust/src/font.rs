//! Glyph outline rasterization.
//!
//! Shaping and font resolution happen on the R side (via `textshaping` /
//! `systemfonts`), so the backend receives, per glyph: a font file + face
//! index, a glyph id, a pixel size, and a position. This module loads the font
//! with `skrifa` (the FreeType-equivalent), extracts the glyph outline at the
//! requested size, and returns it as a tiny-skia path in glyph-local pixels
//! (y-up, origin at the glyph's baseline pen position).

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;

use skrifa::instance::{LocationRef, Size};
use skrifa::outline::{DrawSettings, OutlinePen};
use skrifa::{FontRef, GlyphId, MetadataProvider};
use tiny_skia::PathBuilder;

/// Caches font file bytes and extracted glyph outlines. Outlines are keyed by
/// `(path, face, glyph, size-bits)` so a repeated letter — within a render and,
/// via the persistent cache below, across renders — is extracted once.
#[derive(Default)]
pub struct FontCache {
    files: HashMap<String, Option<Vec<u8>>>,
    outlines: HashMap<(String, u32, u32, u32), Option<tiny_skia::Path>>,
}

/// Drop everything once the outline cache gets large (a crude memory backstop;
/// outlines are immutable so there is no correctness need to evict otherwise).
const OUTLINE_CAP: usize = 20_000;

impl FontCache {
    fn bytes(&mut self, path: &str) -> Option<&[u8]> {
        self.files
            .entry(path.to_string())
            .or_insert_with(|| std::fs::read(Path::new(path)).ok())
            .as_deref()
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
    ) -> Option<tiny_skia::Path> {
        let key = (font_path.to_string(), face_index, glyph_id, size_px.to_bits());
        if let Some(o) = self.outlines.get(&key) {
            return o.clone();
        }
        if self.outlines.len() > OUTLINE_CAP {
            self.outlines.clear();
        }
        let out = self.extract(font_path, face_index, glyph_id, size_px);
        self.outlines.insert(key, out.clone());
        out
    }

    fn extract(&mut self, font_path: &str, face_index: u32, glyph_id: u32, size_px: f32) -> Option<tiny_skia::Path> {
        let bytes = self.bytes(font_path)?;
        let font = FontRef::from_index(bytes, face_index).ok()?;
        let outlines = font.outline_glyphs();
        let glyph = outlines.get(GlyphId::new(glyph_id))?;

        let mut pen = PathPen::default();
        let settings = DrawSettings::unhinted(Size::new(size_px), LocationRef::default());
        glyph.draw(settings, &mut pen).ok()?;
        pen.builder.finish()
    }
}

thread_local! {
    /// Process-persistent glyph cache: font bytes + extracted outlines survive
    /// across renders, so repeated and same-size re-renders reuse the work.
    static GLYPH_CACHE: RefCell<FontCache> = RefCell::new(FontCache::default());
}

/// Glyph outline via the persistent cache. See [`FontCache::glyph_outline`].
pub fn glyph_outline_cached(font_path: &str, face_index: u32, glyph_id: u32, size_px: f32) -> Option<tiny_skia::Path> {
    GLYPH_CACHE.with(|c| c.borrow_mut().glyph_outline(font_path, face_index, glyph_id, size_px))
}

/// Empty the persistent glyph cache (font bytes + outlines).
pub fn clear_glyph_cache() {
    GLYPH_CACHE.with(|c| {
        let mut b = c.borrow_mut();
        b.files.clear();
        b.outlines.clear();
    });
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
