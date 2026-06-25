//! Render backends.
//!
//! The scene walk (`scene.rs`) resolves each node to a primitive path, an
//! absolute transform, a colour, and a clip region, then emits it through the
//! [`RenderBackend`] trait. tiny-skia raster is one implementation; SVG (and PDF,
//! later) are others. Geometry is carried as `tiny_skia::Path` + `Transform`.

use std::collections::HashMap;
use std::rc::Rc;

use tiny_skia::{FillRule, Mask, Paint, Path, PathBuilder, Pixmap, Stroke, Transform};

use crate::color::Rgba;
use crate::font::FontCache;
use crate::units::rotation_about;

/// One viewport rectangle contributing to a clip, in device space: a `w` x `h`
/// rectangle (viewport-local pixels) placed by `transform`.
#[derive(Clone, Copy, Debug)]
pub struct ClipRect {
    pub w: f64,
    pub h: f64,
    pub transform: Transform,
}

/// The clip applying to a draw: the intersection of `rects` (empty = no clip).
/// `id` identifies the originating viewport so backends can cache per-viewport
/// clip artifacts (a raster `Mask`, an SVG `<clipPath>`).
pub struct Clip<'a> {
    pub id: usize,
    pub rects: &'a [ClipRect],
}

/// Everything a backend needs to render one text node. Glyphs are pre-shaped
/// (raster fills outlines, PDF embeds them); `label`/`family`/`face`/`size` let
/// vector backends emit real `<text>` instead.
pub struct TextRun<'a> {
    pub ax: f64,
    pub ay: f64,
    pub w: f64,
    pub h: f64,
    pub hjust: f64,
    pub vjust: f64,
    pub rot: f64,
    pub color: Rgba,
    pub gid: &'a [u32],
    pub gx: &'a [f64],
    pub gy: &'a [f64],
    pub gsize: &'a [f64],
    pub gpath: &'a [String],
    pub gface: &'a [u32],
    pub label: &'a str,
    pub family: &'a str,
    pub face: &'a str,
    pub size: f64,
    pub dpi: f64,
}

/// A drawing target. The walk calls these in paint order.
pub trait RenderBackend {
    fn fill_path(&mut self, path: &Path, transform: Transform, color: Rgba, clip: &Clip);
    fn stroke_path(&mut self, path: &Path, transform: Transform, color: Rgba, width_px: f32, clip: &Clip);
    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip);
}

// --- shared geometry helpers ------------------------------------------------

pub fn rect_path(x: f64, y: f64, w: f64, h: f64) -> Option<Path> {
    tiny_skia::Rect::from_xywh(x as f32, y as f32, w as f32, h as f32).map(PathBuilder::from_rect)
}

/// A fully-visible (all-255) page-sized mask, the starting point for clipping.
fn page_mask(w: u32, h: u32) -> Mask {
    let mut m = Mask::new(w, h).expect("non-zero mask dimensions");
    if let Some(p) = rect_path(0.0, 0.0, w as f64, h as f64) {
        m.fill_path(&p, FillRule::Winding, true, Transform::identity());
    }
    m
}

// --- raster backend ---------------------------------------------------------

pub struct RasterBackend {
    pm: Pixmap,
    fonts: FontCache,
    masks: HashMap<usize, Option<Rc<Mask>>>,
    w: u32,
    h: u32,
}

impl RasterBackend {
    pub fn new(w: u32, h: u32, bg: Rgba) -> Self {
        let mut pm = Pixmap::new(w, h).expect("non-zero pixmap dimensions");
        pm.fill(bg.to_skia());
        RasterBackend { pm, fonts: FontCache::default(), masks: HashMap::new(), w, h }
    }

    pub fn into_pixmap(self) -> Pixmap {
        self.pm
    }

    fn mask_for(&mut self, clip: &Clip) -> Option<Rc<Mask>> {
        if clip.rects.is_empty() {
            return None;
        }
        if let Some(m) = self.masks.get(&clip.id) {
            return m.clone();
        }
        let mut m = page_mask(self.w, self.h);
        for r in clip.rects {
            match rect_path(0.0, 0.0, r.w, r.h) {
                Some(rect) => m.intersect_path(&rect, FillRule::Winding, true, r.transform),
                None => m.clear(),
            }
        }
        let m = Some(Rc::new(m));
        self.masks.insert(clip.id, m.clone());
        m
    }
}

fn solid_paint(color: Rgba) -> Paint<'static> {
    let mut paint = Paint::default();
    paint.set_color(color.to_skia());
    paint.anti_alias = true;
    paint
}

impl RenderBackend for RasterBackend {
    fn fill_path(&mut self, path: &Path, transform: Transform, color: Rgba, clip: &Clip) {
        let mask = self.mask_for(clip);
        self.pm.fill_path(path, &solid_paint(color), FillRule::Winding, transform, mask.as_deref());
    }

    fn stroke_path(&mut self, path: &Path, transform: Transform, color: Rgba, width_px: f32, clip: &Clip) {
        if width_px <= 0.0 {
            return;
        }
        let mask = self.mask_for(clip);
        let stroke = Stroke { width: width_px, ..Stroke::default() };
        self.pm.stroke_path(path, &solid_paint(color), &stroke, transform, mask.as_deref());
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        let mask = self.mask_for(clip);
        let paint = solid_paint(run.color);
        let base = if run.rot != 0.0 {
            transform.pre_concat(rotation_about(run.rot, run.ax, run.ay))
        } else {
            transform
        };
        let n = run.gid.len()
            .min(run.gx.len())
            .min(run.gy.len())
            .min(run.gsize.len())
            .min(run.gpath.len())
            .min(run.gface.len());
        for i in 0..n {
            let outline = match self.fonts.glyph_outline(&run.gpath[i], run.gface[i], run.gid[i], run.gsize[i] as f32) {
                Some(p) => p,
                None => continue,
            };
            let ox = run.ax + run.gx[i] - run.hjust * run.w;
            let oy = run.ay - (run.gy[i] - run.vjust * run.h);
            let place = Transform::from_row(1.0, 0.0, 0.0, -1.0, ox as f32, oy as f32);
            self.pm.fill_path(&outline, &paint, FillRule::Winding, base.pre_concat(place), mask.as_deref());
        }
    }
}

// --- SVG backend ------------------------------------------------------------

pub struct SvgBackend {
    w: u32,
    h: u32,
    defs: String,
    body: String,
    clip_attrs: HashMap<usize, String>,
    next_clip: u32,
}

impl SvgBackend {
    pub fn new(w: u32, h: u32, bg: Rgba) -> Self {
        let mut body = String::new();
        if bg.a > 0 {
            body.push_str(&format!(
                "<rect width=\"{w}\" height=\"{h}\" fill=\"{}\" fill-opacity=\"{}\"/>",
                rgb_hex(bg),
                opacity(bg)
            ));
        }
        SvgBackend { w, h, defs: String::new(), body, clip_attrs: HashMap::new(), next_clip: 0 }
    }

    pub fn into_string(self) -> String {
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{w}\" height=\"{h}\" \
             viewBox=\"0 0 {w} {h}\"><defs>{defs}</defs>{body}</svg>\n",
            w = self.w,
            h = self.h,
            defs = self.defs,
            body = self.body
        )
    }

    /// Append `element`, wrapped in a clipping `<g>` when a clip applies. The
    /// clip group carries no transform, so its `userSpaceOnUse` clipPath (device
    /// coords) and the element's own `transform` both resolve in device space
    /// and stay aligned — putting `clip-path` directly on a transformed element
    /// would double-transform the clip region.
    fn emit(&mut self, element: &str, clip: &Clip) {
        let attr = self.clip_attr(clip);
        if attr.is_empty() {
            self.body.push_str(element);
        } else {
            self.body.push_str(&format!("<g{attr}>{element}</g>"));
        }
    }

    /// A ` clip-path="url(#…)"` attribute for this clip (empty string = none).
    /// Nested `<clipPath>` elements (each referencing the previous) intersect.
    fn clip_attr(&mut self, clip: &Clip) -> String {
        if clip.rects.is_empty() {
            return String::new();
        }
        if let Some(a) = self.clip_attrs.get(&clip.id) {
            return a.clone();
        }
        let mut parent_ref = String::new();
        let mut last = String::new();
        for r in clip.rects {
            let id = format!("c{}", self.next_clip);
            self.next_clip += 1;
            self.defs.push_str(&format!(
                "<clipPath id=\"{id}\" clipPathUnits=\"userSpaceOnUse\"{parent_ref}><path d=\"{d}\"/></clipPath>",
                d = rect_corners_d(r)
            ));
            parent_ref = format!(" clip-path=\"url(#{id})\"");
            last = id;
        }
        let attr = format!(" clip-path=\"url(#{last})\"");
        self.clip_attrs.insert(clip.id, attr.clone());
        attr
    }
}

impl RenderBackend for SvgBackend {
    fn fill_path(&mut self, path: &Path, transform: Transform, color: Rgba, clip: &Clip) {
        let element = format!(
            "<path d=\"{}\" fill=\"{}\" fill-opacity=\"{}\"{}/>",
            path_to_d(path),
            rgb_hex(color),
            opacity(color),
            transform_attr(transform),
        );
        self.emit(&element, clip);
    }

    fn stroke_path(&mut self, path: &Path, transform: Transform, color: Rgba, width_px: f32, clip: &Clip) {
        if width_px <= 0.0 {
            return;
        }
        let element = format!(
            "<path d=\"{}\" fill=\"none\" stroke=\"{}\" stroke-opacity=\"{}\" stroke-width=\"{}\"{}/>",
            path_to_d(path),
            rgb_hex(color),
            opacity(color),
            width_px,
            transform_attr(transform),
        );
        self.emit(&element, clip);
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        if run.label.is_empty() {
            return;
        }
        let anchor = match run.hjust {
            h if h <= 0.0 => "start",
            h if h >= 1.0 => "end",
            _ => "middle",
        };
        let baseline = match run.vjust {
            v if v <= 0.0 => "text-after-edge",
            v if v >= 1.0 => "text-before-edge",
            _ => "central",
        };
        // Local-px font size (the viewport transform is isometric, so 1 local
        // unit == 1 device px); shape_text size is in points.
        let font_px = run.size * run.dpi / 72.0;
        let weight = if run.face.contains("bold") { " font-weight=\"bold\"" } else { "" };
        let style = if run.face.contains("italic") || run.face.contains("oblique") {
            " font-style=\"italic\""
        } else {
            ""
        };
        let rot = if run.rot != 0.0 {
            // SVG rotate is clockwise in the y-down frame; grid angle is CCW.
            format!(" rotate({} {} {})", -run.rot, run.ax, run.ay)
        } else {
            String::new()
        };
        let family = if run.family.is_empty() { "sans-serif" } else { run.family };
        let element = format!(
            "<text x=\"{x}\" y=\"{y}\" transform=\"{t}{rot}\" fill=\"{col}\" fill-opacity=\"{op}\" \
             font-family=\"{fam}\" font-size=\"{size}\" text-anchor=\"{anchor}\" \
             dominant-baseline=\"{baseline}\"{weight}{style}>{label}</text>",
            x = run.ax,
            y = run.ay,
            t = matrix_str(transform),
            col = rgb_hex(run.color),
            op = opacity(run.color),
            fam = xml_escape(family),
            size = font_px,
            label = xml_escape(run.label),
        );
        self.emit(&element, clip);
    }
}

// --- SVG serialization helpers ----------------------------------------------

fn rgb_hex(c: Rgba) -> String {
    format!("#{:02x}{:02x}{:02x}", c.r, c.g, c.b)
}

fn opacity(c: Rgba) -> f32 {
    c.a as f32 / 255.0
}

fn matrix_str(t: Transform) -> String {
    format!("matrix({} {} {} {} {} {})", t.sx, t.ky, t.kx, t.sy, t.tx, t.ty)
}

fn transform_attr(t: Transform) -> String {
    if t.sx == 1.0 && t.ky == 0.0 && t.kx == 0.0 && t.sy == 1.0 && t.tx == 0.0 && t.ty == 0.0 {
        String::new()
    } else {
        format!(" transform=\"{}\"", matrix_str(t))
    }
}

fn path_to_d(path: &Path) -> String {
    use tiny_skia::PathSegment;
    let mut d = String::new();
    for seg in path.segments() {
        match seg {
            PathSegment::MoveTo(p) => d.push_str(&format!("M{} {} ", p.x, p.y)),
            PathSegment::LineTo(p) => d.push_str(&format!("L{} {} ", p.x, p.y)),
            PathSegment::QuadTo(c, p) => d.push_str(&format!("Q{} {} {} {} ", c.x, c.y, p.x, p.y)),
            PathSegment::CubicTo(c1, c2, p) => {
                d.push_str(&format!("C{} {} {} {} {} {} ", c1.x, c1.y, c2.x, c2.y, p.x, p.y))
            }
            PathSegment::Close => d.push('Z'),
        }
    }
    d.trim_end().to_string()
}

/// The four transformed corners of a `w` x `h` rect as a closed SVG path `d`.
fn rect_corners_d(r: &ClipRect) -> String {
    let pt = |x: f64, y: f64| {
        let dx = r.transform.sx as f64 * x + r.transform.kx as f64 * y + r.transform.tx as f64;
        let dy = r.transform.ky as f64 * x + r.transform.sy as f64 * y + r.transform.ty as f64;
        (dx, dy)
    };
    let (x0, y0) = pt(0.0, 0.0);
    let (x1, y1) = pt(r.w, 0.0);
    let (x2, y2) = pt(r.w, r.h);
    let (x3, y3) = pt(0.0, r.h);
    format!("M{x0} {y0} L{x1} {y1} L{x2} {y2} L{x3} {y3} Z")
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}
