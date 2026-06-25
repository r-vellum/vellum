//! Glyph outline rasterization.
//!
//! Shaping and font resolution happen on the R side (via `textshaping` /
//! `systemfonts`), so the backend receives, per glyph: a font file + face
//! index, a glyph id, a pixel size, and a position. This module loads the font
//! with `skrifa` (the FreeType-equivalent), extracts the glyph outline at the
//! requested size, and returns it as a tiny-skia path in glyph-local pixels
//! (y-up, origin at the glyph's baseline pen position).

use std::collections::HashMap;
use std::path::Path;

use skrifa::instance::{LocationRef, Size};
use skrifa::outline::{DrawSettings, OutlinePen};
use skrifa::{FontRef, GlyphId, MetadataProvider};
use tiny_skia::PathBuilder;

/// Caches font file bytes by path so repeated glyphs/text don't re-read disk.
#[derive(Default)]
pub struct FontCache {
    files: HashMap<String, Option<Vec<u8>>>,
}

impl FontCache {
    fn bytes(&mut self, path: &str) -> Option<&[u8]> {
        self.files
            .entry(path.to_string())
            .or_insert_with(|| std::fs::read(Path::new(path)).ok())
            .as_deref()
    }

    /// Outline of `glyph_id` in `font_path`/`face_index`, scaled to `size_px`
    /// (pixels per em). Coordinates are y-up with the origin at the baseline
    /// pen position; the caller places and flips them.
    pub fn glyph_outline(
        &mut self,
        font_path: &str,
        face_index: u32,
        glyph_id: u16,
        size_px: f32,
    ) -> Option<tiny_skia::Path> {
        let bytes = self.bytes(font_path)?;
        let font = FontRef::from_index(bytes, face_index).ok()?;
        let outlines = font.outline_glyphs();
        let glyph = outlines.get(GlyphId::new(glyph_id as u32))?;

        let mut pen = PathPen::default();
        let settings = DrawSettings::unhinted(Size::new(size_px), LocationRef::default());
        glyph.draw(settings, &mut pen).ok()?;
        pen.builder.finish()
    }
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
