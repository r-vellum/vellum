//! Render backends.
//!
//! The scene walk (`scene.rs`) resolves each node to a primitive path, an
//! absolute transform, a colour, and a clip region, then emits it through the
//! [`RenderBackend`] trait. tiny-skia raster is one implementation; SVG (and PDF,
//! later) are others. Geometry is carried as `tiny_skia::Path` + `Transform`.

use std::borrow::Cow;
use std::collections::HashMap;
use std::rc::Rc;

use tiny_skia::{FilterQuality, FillRule, Mask, Paint, Path, PathBuilder, Pixmap, Stroke, StrokeDash, Transform};

use crate::color::{Extend, LineCap, LineJoin, Rgba, Stop};
use crate::font::{glyph_outline_cached, glyph_sprite_cached, PHASE_X, PHASE_Y};
use crate::units::rotation_about;

/// Resolved stroke style handed to `stroke_path`: width + dash (device px, on/off,
/// empty = solid) + cap/join/mitre.
#[derive(Clone, Debug)]
pub struct StrokeStyle {
    pub width: f32,
    pub dash: Vec<f32>,
    pub cap: LineCap,
    pub join: LineJoin,
    pub miter: f32,
}

fn skia_cap(c: LineCap) -> tiny_skia::LineCap {
    match c {
        LineCap::Round => tiny_skia::LineCap::Round,
        LineCap::Butt => tiny_skia::LineCap::Butt,
        LineCap::Square => tiny_skia::LineCap::Square,
    }
}

fn skia_join(j: LineJoin) -> tiny_skia::LineJoin {
    match j {
        LineJoin::Round => tiny_skia::LineJoin::Round,
        LineJoin::Mitre => tiny_skia::LineJoin::Miter,
        LineJoin::Bevel => tiny_skia::LineJoin::Bevel,
    }
}

fn skia_stroke(s: &StrokeStyle) -> Stroke {
    Stroke {
        width: s.width,
        miter_limit: s.miter,
        line_cap: skia_cap(s.cap),
        line_join: skia_join(s.join),
        dash: if s.dash.is_empty() { None } else { StrokeDash::new(s.dash.clone(), 0.0) },
        ..Stroke::default()
    }
}

/// A fill paint with geometry resolved to viewport-local pixels (the backend's
/// own draw transform then maps it to device space, exactly like the path).
pub enum ResolvedPaint {
    Solid(Rgba),
    Linear { x1: f64, y1: f64, x2: f64, y2: f64, stops: Vec<Stop>, extend: Extend },
    /// Two circles in local px: the focal/start circle `(fx, fy, fr)` at stop
    /// offset 0 and the outer/end circle `(cx, cy, r)` at offset 1 (concentric
    /// when `fr == 0` and `(fx, fy) == (cx, cy)`).
    Radial { cx: f64, cy: f64, r: f64, fx: f64, fy: f64, fr: f64, stops: Vec<Stop>, extend: Extend },
    /// A tiled image: `tile` is straight RGBA (`tw` x `th`, top-left); it fills a
    /// `w` x `h` (px) cell centred at `(x, y)` and repeats per `extend`. `opacity`
    /// is the folded gpar alpha (applied without touching the shared tile).
    Pattern { tile: Rc<Vec<u8>>, tw: u32, th: u32, x: f64, y: f64, w: f64, h: f64, extend: Extend, opacity: f32 },
}

/// One clip region contributing to a clip chain, in viewport-local pixels placed
/// by `transform`: either a `w` x `h` rectangle or an arbitrary path.
#[derive(Clone, Debug)]
pub enum ClipShape {
    Rect { w: f64, h: f64, transform: Transform },
    Path { path: Path, evenodd: bool, transform: Transform },
}

/// The clip applying to a draw: the intersection of `shapes` (empty = no clip).
/// `id` identifies the originating viewport so backends can cache per-viewport
/// clip artifacts (a raster `Mask`, an SVG `<clipPath>`).
pub struct Clip<'a> {
    pub id: usize,
    pub shapes: &'a [ClipShape],
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
    /// Per-glyph fill colour. **Empty** ⇒ every glyph uses `color` (the plain path).
    /// Non-empty ⇒ one entry per glyph (a rich multi-run label).
    pub gcolor: &'a [Rgba],
    pub label: &'a str,
    pub family: &'a str,
    pub face: &'a str,
    pub size: f64,
    pub dpi: f64,
}

/// How a mask's pixels modulate the group they cover.
#[derive(Clone, Copy, Debug)]
pub enum MaskKind {
    /// Use the mask's alpha channel as coverage.
    Alpha,
    /// Use the mask's luminance (`0.2126R + 0.7152G + 0.0722B`) as coverage.
    Luminance,
}

impl MaskKind {
    pub fn from_code(c: i32) -> MaskKind {
        match c {
            1 => MaskKind::Luminance,
            _ => MaskKind::Alpha,
        }
    }
}

/// A rendered mask handed to `begin_group`: a page-sized RGBA raster plus how to
/// read coverage from it. The mask is always rasterized (uniform across output
/// formats); only how each backend *applies* it differs.
pub struct MaskLayer {
    pub pixmap: Pixmap,
    pub kind: MaskKind,
}

/// How a group composites onto the backdrop below it (the CSS `mix-blend-mode` /
/// PDF separable+non-separable set, supported by all three backends). `Normal` is
/// ordinary source-over and is the no-op default.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum BlendKind {
    Normal, Multiply, Screen, Overlay, Darken, Lighten, ColorDodge, ColorBurn,
    HardLight, SoftLight, Difference, Exclusion, Hue, Saturation, Color, Luminosity,
}

impl BlendKind {
    /// Codes match `.blend_codes` in R (the R<->Rust ABI).
    pub fn from_code(c: i32) -> BlendKind {
        use BlendKind::*;
        match c {
            1 => Multiply, 2 => Screen, 3 => Overlay, 4 => Darken, 5 => Lighten,
            6 => ColorDodge, 7 => ColorBurn, 8 => HardLight, 9 => SoftLight,
            10 => Difference, 11 => Exclusion, 12 => Hue, 13 => Saturation,
            14 => Color, 15 => Luminosity, _ => Normal,
        }
    }

    fn to_skia(self) -> tiny_skia::BlendMode {
        use tiny_skia::BlendMode as B;
        use BlendKind::*;
        match self {
            Normal => B::SourceOver, Multiply => B::Multiply, Screen => B::Screen,
            Overlay => B::Overlay, Darken => B::Darken, Lighten => B::Lighten,
            ColorDodge => B::ColorDodge, ColorBurn => B::ColorBurn, HardLight => B::HardLight,
            SoftLight => B::SoftLight, Difference => B::Difference, Exclusion => B::Exclusion,
            Hue => B::Hue, Saturation => B::Saturation, Color => B::Color, Luminosity => B::Luminosity,
        }
    }

    /// CSS `mix-blend-mode` keyword, or `None` for `Normal` (omit the attribute).
    fn svg(self) -> Option<&'static str> {
        use BlendKind::*;
        Some(match self {
            Normal => return None,
            Multiply => "multiply", Screen => "screen", Overlay => "overlay",
            Darken => "darken", Lighten => "lighten", ColorDodge => "color-dodge",
            ColorBurn => "color-burn", HardLight => "hard-light", SoftLight => "soft-light",
            Difference => "difference", Exclusion => "exclusion", Hue => "hue",
            Saturation => "saturation", Color => "color", Luminosity => "luminosity",
        })
    }
}

/// A drawing target. The walk calls these in paint order. `begin_group` /
/// `end_group` bracket an isolated compositing layer; the optional `mask` (handed
/// to `begin_group`, since PDF must install its soft mask *before* the content)
/// modulates the group when it closes.
pub trait RenderBackend {
    fn fill_path(&mut self, path: &Path, transform: Transform, paint: &ResolvedPaint, rule: FillRule, clip: &Clip);
    fn stroke_path(&mut self, path: &Path, transform: Transform, color: Rgba, stroke: &StrokeStyle, clip: &Clip);
    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip);
    fn begin_group(&mut self, mask: Option<MaskLayer>, alpha: f32, blend: BlendKind);
    fn end_group(&mut self);

    /// Repaint boundaries (FW4c). `caches_subrasters` is `true` only for the
    /// raster backend; vector backends leave it `false` and render a
    /// `cache = TRUE` viewport's subtree inline (so SVG/PDF stay vector). When
    /// `true`, the walk brackets a boundary's subtree with `subraster_begin`
    /// (push a fresh isolated layer) … `subraster_end` (pop and return it, so the
    /// walk can memoise it), and composites a cached/captured layer with
    /// `composite_subraster` (page-sized, at identity — position is baked in).
    fn caches_subrasters(&self) -> bool {
        false
    }
    fn subraster_begin(&mut self) {}
    fn subraster_end(&mut self) -> Option<Pixmap> {
        None
    }
    fn composite_subraster(&mut self, _pm: &Pixmap) {}

    /// Draw a straight-RGBA image (`iw` x `ih`, top-left origin) into a `w` x `h`
    /// (local px) cell centred at `(x, y)`, mapped to device by `transform`.
    #[allow(clippy::too_many_arguments)]
    fn draw_image(
        &mut self,
        rgba: &[u8],
        iw: u32,
        ih: u32,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        interpolate: bool,
        transform: Transform,
        clip: &Clip,
    );

    /// Draw a batch of circles: centres `(cx, cy)` + radii `r` in local px,
    /// mapped to device by `transform`. The default places one unit circle per
    /// element; the raster backend overrides this to stamp a cached sprite for
    /// large uniform solid-fill point clouds. `stroke` is `(colour, style)`.
    fn draw_circles(
        &mut self,
        cx: &[f64],
        cy: &[f64],
        r: &[f64],
        fill: Option<&ResolvedPaint>,
        stroke: Option<(Rgba, StrokeStyle)>,
        transform: Transform,
        clip: &Clip,
    ) where
        Self: Sized,
    {
        circles_by_path(self, cx, cy, r, fill, stroke.as_ref(), transform, clip);
    }

    /// Stroke a polyline / batch of disjoint segments (one `Path` whose subpaths
    /// are the lines). The default emits the single combined stroke; the raster
    /// backend overrides this with a per-segment fast path that avoids the
    /// superlinear winding-fill of a self-overlapping or many-subpath stroke
    /// outline. Vector backends keep the compact single-path form.
    fn stroke_lines(&mut self, path: &Path, transform: Transform, color: Rgba, stroke: &StrokeStyle, clip: &Clip)
    where
        Self: Sized,
    {
        self.stroke_path(path, transform, color, stroke, clip);
    }

    /// Collect and clear any degradation warnings accumulated during the walk —
    /// features this backend could not fully honour (e.g. a PDF tiling pattern it
    /// had to drop). The render path surfaces these to the user as one R warning.
    /// Default: none (the backend rendered everything it was asked to).
    fn take_warnings(&mut self) -> Vec<String> {
        Vec::new()
    }

    /// Bracket the next primitive's output with semantic metadata (a pre-formatted
    /// attribute string, e.g. SVG `data-*`/`role`; empty = none). The SVG backend
    /// wraps the node in a `<g …>`; raster/PDF ignore it. Always paired with
    /// `end_node`.
    fn begin_node(&mut self, _attrs: &str) {}
    fn end_node(&mut self) {}

    /// Set the per-element data key for the *next* primitive emitted (a batched
    /// node calls this before each element). The SVG backend splices it in as a
    /// `data-key="…"` attribute; raster/PDF ignore it. `None` clears it.
    fn set_element_key(&mut self, _key: Option<&str>) {}

    /// Open a named panel group around the following primitives (paired with
    /// `end_panel`). The SVG backend wraps them in `<g data-vellum-panel="name">`;
    /// raster/PDF ignore it.
    fn begin_panel(&mut self, _name: &str) {}
    fn end_panel(&mut self) {}

    /// Whether this backend emits per-element `data-key` attributes (only the SVG
    /// backend does). When false, the batched fast paths (solid circles, combined
    /// segments) stay on their fast path even for a keyed node — the keys would be
    /// ignored anyway — so raster/PDF output is pixel-identical whether or not a
    /// scene carries interactivity keys.
    fn wants_element_keys(&self) -> bool {
        false
    }
}

/// One unit circle (origin, radius 1) reused with a per-element affine transform.
/// The stroke width and dash are pre-divided by the radius so they land at their
/// device sizes after the uniform scale.
fn circles_by_path<B: RenderBackend>(
    b: &mut B,
    cx: &[f64],
    cy: &[f64],
    r: &[f64],
    fill: Option<&ResolvedPaint>,
    stroke: Option<&(Rgba, StrokeStyle)>,
    transform: Transform,
    clip: &Clip,
) {
    let n = cx.len().min(cy.len()).min(r.len());
    let unit = unit_circle_path();
    for i in 0..n {
        let rr = r[i];
        if rr <= 0.0 {
            continue;
        }
        let tr = transform.pre_concat(Transform::from_row(rr as f32, 0.0, 0.0, rr as f32, cx[i] as f32, cy[i] as f32));
        if let Some(f) = fill {
            b.fill_path(&unit, tr, f, FillRule::Winding, clip);
        }
        if let Some((c, st)) = stroke {
            let scaled = StrokeStyle {
                width: st.width / rr as f32,
                dash: st.dash.iter().map(|d| d / rr as f32).collect(),
                cap: st.cap,
                join: st.join,
                miter: st.miter,
            };
            b.stroke_path(&unit, tr, *c, &scaled, clip);
        }
    }
}

fn unit_circle_path() -> Path {
    let mut pb = PathBuilder::new();
    pb.push_circle(0.0, 0.0, 1.0);
    pb.finish().expect("unit circle path")
}

fn skia_masktype(k: MaskKind) -> tiny_skia::MaskType {
    match k {
        MaskKind::Alpha => tiny_skia::MaskType::Alpha,
        MaskKind::Luminance => tiny_skia::MaskType::Luminance,
    }
}

// --- shared geometry helpers ------------------------------------------------

pub fn rect_path(x: f64, y: f64, w: f64, h: f64) -> Option<Path> {
    tiny_skia::Rect::from_xywh(x as f32, y as f32, w as f32, h as f32).map(PathBuilder::from_rect)
}

/// A rounded rectangle (top-left `(x, y)`, size `w`×`h`, corner radius `r` in the
/// same px units). `r` is clamped to half the shorter side; `r == 0` degrades to
/// a plain rect. Corners are cubic-Bézier quarter-circle approximations.
pub fn roundrect_path(x: f64, y: f64, w: f64, h: f64, r: f64) -> Option<Path> {
    if w <= 0.0 || h <= 0.0 {
        return None;
    }
    let r = r.max(0.0).min(w / 2.0).min(h / 2.0);
    if r <= 0.0 {
        return rect_path(x, y, w, h);
    }
    let kr = (r * 0.552_284_749_830_793_6) as f32; // control-point offset for a 90° arc
    let r = r as f32;
    let (x0, y0, x1, y1) = (x as f32, y as f32, (x + w) as f32, (y + h) as f32);
    let mut pb = PathBuilder::new();
    pb.move_to(x0 + r, y0);
    pb.line_to(x1 - r, y0);
    pb.cubic_to(x1 - r + kr, y0, x1, y0 + r - kr, x1, y0 + r);
    pb.line_to(x1, y1 - r);
    pb.cubic_to(x1, y1 - r + kr, x1 - r + kr, y1, x1 - r, y1);
    pb.line_to(x0 + r, y1);
    pb.cubic_to(x0 + r - kr, y1, x0, y1 - r + kr, x0, y1 - r);
    pb.line_to(x0, y0 + r);
    pb.cubic_to(x0, y0 + r - kr, x0 + r - kr, y0, x0 + r, y0);
    pb.close();
    pb.finish()
}

/// A regular hexagon centred at `(cx, cy)` with circumradius `r` (centre→vertex).
/// `flat` selects orientation: flat-top (a horizontal top/bottom edge) when true,
/// pointy-top (a vertex up/down) when false. `r <= 0` → `None`. A thin wrapper over
/// [`hexagon_path_xy`] with the regular relation between the two half-extents.
pub fn hexagon_path(cx: f64, cy: f64, r: f64, flat: bool) -> Option<Path> {
    if r <= 0.0 {
        return None;
    }
    let s = r * (3.0_f64).sqrt() * 0.5; // the short half-extent of a regular hex
    if flat {
        hexagon_path_xy(cx, cy, r, s, true)
    } else {
        hexagon_path_xy(cx, cy, s, r, false)
    }
}

/// A hexagon centred at `(cx, cy)` with independent horizontal half-extent `hx`
/// and vertical half-extent `hy` (each measured centre→edge along its own axis,
/// so the full width is `2*hx` and the full height is `2*hy`). `flat` selects
/// flat-top — vertices left/right at `(±hx, 0)`, horizontal edges at `±hy` — vs
/// pointy-top — vertices top/bottom at `(0, ±hy)`, vertical edges at `±hx`. A
/// regular hexagon is the special case `hy == hx*sqrt(3)/2` (flat) resp.
/// `hx == hy*sqrt(3)/2` (pointy). Non-positive or non-finite extents → `None`.
pub fn hexagon_path_xy(cx: f64, cy: f64, hx: f64, hy: f64, flat: bool) -> Option<Path> {
    if hx <= 0.0 || hy <= 0.0 || !cx.is_finite() || !cy.is_finite() {
        return None;
    }
    let corners: [(f64, f64); 6] = if flat {
        [
            (hx, 0.0),
            (hx * 0.5, hy),
            (-hx * 0.5, hy),
            (-hx, 0.0),
            (-hx * 0.5, -hy),
            (hx * 0.5, -hy),
        ]
    } else {
        [
            (0.0, hy),
            (hx, hy * 0.5),
            (hx, -hy * 0.5),
            (0.0, -hy),
            (-hx, -hy * 0.5),
            (-hx, hy * 0.5),
        ]
    };
    let mut pb = PathBuilder::new();
    for (k, (dx, dy)) in corners.iter().enumerate() {
        let (px, py) = ((cx + dx) as f32, (cy + dy) as f32);
        if k == 0 {
            pb.move_to(px, py);
        } else {
            pb.line_to(px, py);
        }
    }
    pb.close();
    pb.finish()
}

/// An annular sector centred at `(cx, cy)` spanning `theta0..theta1` (radians, CCW,
/// 0 at 3 o'clock) between inner radius `r0` and outer radius `r1`. The arc is
/// densified into line segments (~4° each). `r0 <= 0` collapses the inner edge to
/// the centre (a pie slice); `r0 == r1` yields a zero-area path (an arc outline when
/// stroked). Returns `None` for a zero angular span or non-positive outer radius.
pub fn sector_path(cx: f64, cy: f64, r0: f64, r1: f64, theta0: f64, theta1: f64) -> Option<Path> {
    let r_out = r1.max(0.0);
    let r_in = r0.max(0.0);
    let dtheta = theta1 - theta0;
    if r_out <= 0.0 || dtheta == 0.0 || !dtheta.is_finite() || !cx.is_finite() || !cy.is_finite() {
        return None;
    }
    // ~4 degrees per segment, at least 2 segments across the span. Cap the count so
    // an extreme span (should already be rejected R-side as non-finite/huge, but be
    // defensive) can't blow up the allocation / loop.
    const MAX_SECTOR_SEGS: usize = 4096;
    let segs = ((dtheta.abs() / (std::f64::consts::PI / 45.0)).ceil().max(2.0) as usize)
        .min(MAX_SECTOR_SEGS);
    let pt = |r: f64, a: f64| ((cx + r * a.cos()) as f32, (cy + r * a.sin()) as f32);
    let mut pb = PathBuilder::new();
    // Outer arc, theta0 -> theta1.
    let (sx, sy) = pt(r_out, theta0);
    pb.move_to(sx, sy);
    for k in 1..=segs {
        let a = theta0 + dtheta * (k as f64) / (segs as f64);
        let (px, py) = pt(r_out, a);
        pb.line_to(px, py);
    }
    // Inner arc back, theta1 -> theta0 (collapses to the centre when r_in == 0).
    for k in 0..=segs {
        let a = theta1 - dtheta * (k as f64) / (segs as f64);
        let (px, py) = pt(r_in, a);
        pb.line_to(px, py);
    }
    pb.close();
    pb.finish()
}

/// Render a solid AA circle of radius `r` (device px) into a tight square sprite,
/// centred. Used to stamp large uniform point clouds instead of filling each.
fn circle_sprite(r: f64, color: Rgba) -> Option<Pixmap> {
    let dim = ((r + 1.0) * 2.0).ceil() as u32; // +1px AA padding
    let mut pm = Pixmap::new(dim, dim)?;
    let c = dim as f32 / 2.0;
    let mut pb = PathBuilder::new();
    pb.push_circle(c, c, r as f32);
    let path = pb.finish()?;
    let mut paint = Paint::default();
    paint.set_color(color.to_skia());
    paint.anti_alias = true;
    pm.fill_path(&path, &paint, FillRule::Winding, Transform::identity(), None);
    Some(pm)
}

/// Build a `Pixmap` from straight (non-premultiplied) RGBA bytes, top-left origin.
fn pixmap_from_straight(tile: &[u8], tw: u32, th: u32) -> Option<Pixmap> {
    let n = (tw as usize).checked_mul(th as usize)?;
    if tile.len() < n * 4 {
        return None;
    }
    let mut pm = Pixmap::new(tw, th)?;
    let px = pm.pixels_mut();
    for (i, p) in px.iter_mut().enumerate() {
        *p = tiny_skia::ColorU8::from_rgba(tile[4 * i], tile[4 * i + 1], tile[4 * i + 2], tile[4 * i + 3])
            .premultiply();
    }
    Some(pm)
}

/// Encode straight (un-premultiplied) RGBA to PNG. Unlike round-tripping through a
/// premultiplied `Pixmap` (which zeroes RGB wherever alpha is 0), this preserves
/// the colour under fully-transparent texels — so the SVG `<image>` shows no
/// fringing when a pattern/raster with transparent edges is scaled/interpolated.
fn straight_png(rgba: &[u8], w: u32, h: u32) -> Option<Vec<u8>> {
    let n = (w as usize).checked_mul(h as usize)?;
    if w == 0 || h == 0 || rgba.len() < n * 4 {
        return None;
    }
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, w, h);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut writer = enc.write_header().ok()?;
        writer.write_image_data(&rgba[..n * 4]).ok()?;
    }
    Some(out)
}

/// The tile -> local-px transform: scale the `tw` x `th` tile into a `w` x `h`
/// cell centred at `(x, y)`. The backend's draw transform then maps local->device.
fn pattern_transform(tw: u32, th: u32, x: f64, y: f64, w: f64, h: f64) -> Transform {
    Transform::from_row(
        (w / tw as f64) as f32,
        0.0,
        0.0,
        (h / th as f64) as f32,
        (x - w / 2.0) as f32,
        (y - h / 2.0) as f32,
    )
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
    /// A stack of draw targets: `targets[0]` is the page; `begin_group` pushes an
    /// isolated layer that drawing then targets until `end_group` composites it.
    targets: Vec<Pixmap>,
    /// Per-open-group mask, opacity, and blend mode (parallel to the layer stack
    /// above the page); applied when the group closes.
    group_masks: Vec<Option<MaskLayer>>,
    group_alpha: Vec<f32>,
    group_blend: Vec<BlendKind>,
    /// Bounded LRU of compiled clip masks (most-recent first). tiny-skia requires
    /// a clip `Mask` to match the target pixmap size, so each entry is page-sized
    /// and cannot be shrunk to a bounding box; instead we cap how many stay
    /// resident. Primitives sharing a clip are drawn contiguously, so a small
    /// cache captures essentially all reuse while keeping memory bounded on pages
    /// with very many distinct clips or deep clip trees.
    clip_cache: Vec<(usize, Option<Rc<Mask>>)>,
    w: u32,
    h: u32,
    /// Glyph-bitmap fast path enabled? Set only on the page backend (never on
    /// mask/measurement backends — a colour-baked sprite would corrupt what a
    /// luminance mask reads). See `draw_text`.
    bitmap_text: bool,
}

/// Max page-sized clip masks kept resident at once (see `clip_cache`).
const CLIP_CACHE_CAP: usize = 8;

impl RasterBackend {
    pub fn new(w: u32, h: u32, bg: Rgba) -> Self {
        // Clamp to >=1 so a 0-sized target can't panic here (page dimensions are
        // already validated to >=1 by px_dim; this guards the constructor directly
        // and keeps the stored w/h — reused for every group/subraster layer and
        // clip mask below — non-zero). A valid render is unaffected.
        let (w, h) = (w.max(1), h.max(1));
        let mut pm = Pixmap::new(w, h).expect("non-zero pixmap dimensions");
        // `Pixmap::new` is already zeroed (transparent); only paint a non-empty
        // background. This skips a full-page write for every rasterized mask,
        // whose backdrop is always transparent.
        if bg.a != 0 {
            pm.fill(bg.to_skia());
        }
        RasterBackend {
            targets: vec![pm],
            group_masks: Vec::new(),
            group_alpha: Vec::new(),
            group_blend: Vec::new(),
            clip_cache: Vec::new(),
            w,
            h,
            bitmap_text: false,
        }
    }

    /// Enable the glyph-bitmap fast path for this backend (page backend only).
    pub fn set_bitmap_text(&mut self, on: bool) {
        self.bitmap_text = on;
    }

    pub fn into_pixmap(mut self) -> Pixmap {
        // Balanced groups leave only the page; if not, the base is still first.
        self.targets.swap_remove(0)
    }

    fn target(&mut self) -> &mut Pixmap {
        self.targets.last_mut().expect("at least the page target")
    }

    fn mask_for(&mut self, clip: &Clip) -> Option<Rc<Mask>> {
        if clip.shapes.is_empty() {
            return None;
        }
        if let Some(pos) = self.clip_cache.iter().position(|(id, _)| *id == clip.id) {
            // Cache hit: promote to most-recent and return.
            let entry = self.clip_cache.remove(pos);
            let val = entry.1.clone();
            self.clip_cache.insert(0, entry);
            return val;
        }
        let mut m = page_mask(self.w, self.h);
        for shape in clip.shapes {
            match shape {
                ClipShape::Rect { w, h, transform } => match rect_path(0.0, 0.0, *w, *h) {
                    Some(rect) => m.intersect_path(&rect, FillRule::Winding, true, *transform),
                    None => m.clear(),
                },
                ClipShape::Path { path, evenodd, transform } => {
                    let rule = if *evenodd { FillRule::EvenOdd } else { FillRule::Winding };
                    m.intersect_path(path, rule, true, *transform);
                }
            }
        }
        let m = Some(Rc::new(m));
        // Insert most-recent-first; evicting the oldest keeps memory bounded. An
        // evicted mask still in use survives via the Rc the caller already holds.
        self.clip_cache.insert(0, (clip.id, m.clone()));
        self.clip_cache.truncate(CLIP_CACHE_CAP);
        m
    }
}

fn solid_paint(color: Rgba) -> Paint<'static> {
    let mut paint = Paint::default();
    paint.set_color(color.to_skia());
    paint.anti_alias = true;
    paint
}

fn skia_spread(extend: Extend) -> tiny_skia::SpreadMode {
    match extend {
        Extend::Pad => tiny_skia::SpreadMode::Pad,
        Extend::Repeat => tiny_skia::SpreadMode::Repeat,
        Extend::Reflect => tiny_skia::SpreadMode::Reflect,
    }
}

fn skia_stops(stops: &[Stop]) -> Vec<tiny_skia::GradientStop> {
    stops.iter().map(|s| tiny_skia::GradientStop::new(s.offset, s.color.to_skia())).collect()
}

/// Build a tiny-skia paint for a resolved fill. Gradient geometry is in local px
/// with an identity gradient transform; `fill_path`'s ctm maps it like the path.
fn paint_for(paint: &ResolvedPaint) -> Option<Paint<'static>> {
    let shader = match paint {
        ResolvedPaint::Solid(c) => return Some(solid_paint(*c)),
        ResolvedPaint::Linear { x1, y1, x2, y2, stops, extend } => tiny_skia::LinearGradient::new(
            tiny_skia::Point::from_xy(*x1 as f32, *y1 as f32),
            tiny_skia::Point::from_xy(*x2 as f32, *y2 as f32),
            skia_stops(stops),
            skia_spread(*extend),
            Transform::identity(),
        ),
        ResolvedPaint::Radial { cx, cy, r, fx, fy, fr, stops, extend } => tiny_skia::RadialGradient::new(
            // tiny-skia 0.12: new(start_point, start_radius, end_point, end_radius, …).
            // The focal circle `(fx, fy, fr)` is the start (stop offset 0); the outer
            // circle `(cx, cy, r)` is the end (offset 1). A concentric gradient has
            // `fr = 0` and `(fx, fy) == (cx, cy)`.
            tiny_skia::Point::from_xy(*fx as f32, *fy as f32),
            *fr as f32,
            tiny_skia::Point::from_xy(*cx as f32, *cy as f32),
            *r as f32,
            skia_stops(stops),
            skia_spread(*extend),
            Transform::identity(),
        ),
        // Patterns borrow a Pixmap and are handled inline in RasterBackend::fill_path.
        ResolvedPaint::Pattern { .. } => return None,
    }?;
    let mut p = Paint::default();
    p.shader = shader;
    p.anti_alias = true;
    Some(p)
}

impl RenderBackend for RasterBackend {
    fn fill_path(&mut self, path: &Path, transform: Transform, paint: &ResolvedPaint, rule: FillRule, clip: &Clip) {
        let mask = self.mask_for(clip);
        if let ResolvedPaint::Pattern { tile, tw, th, x, y, w, h, extend, opacity } = paint {
            // The tile Pixmap must outlive the Pattern shader (it borrows it), so
            // build both here rather than via paint_for's `'static` return.
            let pm = match pixmap_from_straight(tile, *tw, *th) {
                Some(pm) => pm,
                None => return,
            };
            let t = pattern_transform(*tw, *th, *x, *y, *w, *h);
            let mut p = Paint::default();
            p.shader = tiny_skia::Pattern::new(pm.as_ref(), skia_spread(*extend), FilterQuality::Bilinear, *opacity, t);
            p.anti_alias = true;
            self.target().fill_path(path, &p, rule, transform, mask.as_deref());
            return;
        }
        if let Some(p) = paint_for(paint) {
            self.target().fill_path(path, &p, rule, transform, mask.as_deref());
        }
    }

    fn stroke_path(&mut self, path: &Path, transform: Transform, color: Rgba, stroke: &StrokeStyle, clip: &Clip) {
        if stroke.width <= 0.0 {
            return;
        }
        let mask = self.mask_for(clip);
        let sk = skia_stroke(stroke);
        self.target().stroke_path(path, &solid_paint(color), &sk, transform, mask.as_deref());
    }

    fn stroke_lines(&mut self, path: &Path, transform: Transform, color: Rgba, stroke: &StrokeStyle, clip: &Clip) {
        if stroke.width <= 0.0 {
            return;
        }
        // Fast path for grid's default line style: opaque, solid (no dash), round
        // cap + round join. Stroke each segment independently. When opaque, drawing
        // overlaps twice is idempotent, and a round cap covers the same disc as a
        // round join — so the result matches the combined stroke pixel-for-pixel,
        // but each tiny fill touches only its own few scanlines. The combined
        // winding-fill instead pays O(active_edges x height): for a self-
        // intersecting polyline (many outline edges crossing every scanline) or a
        // page-spanning batch of disjoint segments that is the dominant cost.
        let fast = color.a == 255
            && stroke.dash.is_empty()
            && matches!(stroke.cap, LineCap::Round)
            && matches!(stroke.join, LineJoin::Round);
        if !fast {
            self.stroke_path(path, transform, color, stroke, clip);
            return;
        }
        let mask = self.mask_for(clip);
        let sk = skia_stroke(stroke);
        let paint = solid_paint(color);
        let target = self.targets.last_mut().expect("at least the page target");
        use tiny_skia::PathSegment;
        let mut prev: Option<(f32, f32)> = None;
        for seg in path.segments() {
            match seg {
                PathSegment::MoveTo(p) => prev = Some((p.x, p.y)),
                PathSegment::LineTo(p) => {
                    if let Some((ax, ay)) = prev {
                        let mut pb = PathBuilder::new();
                        pb.move_to(ax, ay);
                        pb.line_to(p.x, p.y);
                        if let Some(sp) = pb.finish() {
                            target.stroke_path(&sp, &paint, &sk, transform, mask.as_deref());
                        }
                    }
                    prev = Some((p.x, p.y));
                }
                // Lines/segments are polylines only; curves/closes shouldn't occur,
                // but track the endpoint so any stragglers connect sensibly.
                PathSegment::QuadTo(_, p) | PathSegment::CubicTo(_, _, p) => prev = Some((p.x, p.y)),
                PathSegment::Close => {}
            }
        }
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        let mask = self.mask_for(clip);
        let paint = solid_paint(run.color);
        let base = if run.rot != 0.0 {
            transform.pre_concat(rotation_about(run.rot, run.ax, run.ay))
        } else {
            transform
        };
        // Glyph-bitmap fast path (FW: high-distinct-label text). Legal only when
        // `base` is a pure translation — rotated text OR a rotated/scaled viewport
        // both make it non-translation, and must fall back to the exact outline
        // fill (which also keeps SVG/PDF and small renders byte-identical). Large
        // glyphs stay exact (quantisation is visible there; per-blit cost grows).
        const GLYPH_SPRITE_MAX_PX: f64 = 40.0;
        let sprite_ok = self.bitmap_text
            && base.sx == 1.0 && base.sy == 1.0 && base.kx == 0.0 && base.ky == 0.0;
        let n = run.gid.len()
            .min(run.gx.len())
            .min(run.gy.len())
            .min(run.gsize.len())
            .min(run.gpath.len())
            .min(run.gface.len());
        for i in 0..n {
            let ox = run.ax + run.gx[i] - run.hjust * run.w;
            let oy = run.ay - (run.gy[i] - run.vjust * run.h);
            if sprite_ok && run.gsize[i] <= GLYPH_SPRITE_MAX_PX {
                // Device pen; quantise the fraction to a sub-pixel phase, carrying
                // a round-up into the integer cell (round(f*N)==N means f≈1.0).
                let px = base.tx as f64 + ox;
                let py = base.ty as f64 + oy;
                let mut ix = px.floor() as i32;
                let mut iy = py.floor() as i32;
                let mut qx = ((px - ix as f64) * PHASE_X as f64).round() as i32;
                if qx >= PHASE_X as i32 { ix += 1; qx = 0; }
                let mut qy = ((py - iy as f64) * PHASE_Y as f64).round() as i32;
                if qy >= PHASE_Y as i32 { iy += 1; qy = 0; }
                let c = run.gcolor.get(i).copied().unwrap_or(run.color);
                let cc = [c.r, c.g, c.b, c.a];
                if let Some(sprite) = glyph_sprite_cached(
                    &run.gpath[i], run.gface[i], run.gid[i], run.gsize[i] as f32, cc, qx as u8, qy as u8,
                ) {
                    let pmp = tiny_skia::PixmapPaint::default();
                    self.targets.last_mut().expect("at least the page target").draw_pixmap(
                        ix + sprite.dx, iy + sprite.dy, sprite.pixmap.as_ref(), &pmp,
                        Transform::identity(), mask.as_deref(),
                    );
                    continue;
                }
                // sprite None (whitespace / oversize) -> fall through to exact fill.
            }
            let outline = match glyph_outline_cached(&run.gpath[i], run.gface[i], run.gid[i], run.gsize[i] as f32) {
                Some(p) => p,
                None => continue,
            };
            let place = Transform::from_row(1.0, 0.0, 0.0, -1.0, ox as f32, oy as f32);
            // Per-glyph colour for rich labels; otherwise the one shared paint.
            let glyph_paint = match run.gcolor.get(i) {
                Some(&c) => solid_paint(c),
                None => paint.clone(),
            };
            self.targets.last_mut().expect("at least the page target").fill_path(
                outline.as_ref(),
                &glyph_paint,
                FillRule::Winding,
                base.pre_concat(place),
                mask.as_deref(),
            );
        }
    }

    fn begin_group(&mut self, mask: Option<MaskLayer>, alpha: f32, blend: BlendKind) {
        // A transparent isolated layer; subsequent drawing targets it. The mask,
        // opacity, and blend mode are held until the group closes.
        self.targets.push(Pixmap::new(self.w, self.h).expect("non-zero layer dimensions"));
        self.group_masks.push(mask);
        self.group_alpha.push(alpha);
        self.group_blend.push(blend);
    }

    fn end_group(&mut self) {
        let mask = self.group_masks.pop().flatten();
        let alpha = self.group_alpha.pop().unwrap_or(1.0);
        let blend = self.group_blend.pop().unwrap_or(BlendKind::Normal);
        let layer = match self.targets.pop() {
            Some(l) if !self.targets.is_empty() => l,
            other => {
                // Unbalanced end_group: nothing to composite onto. Restore and bail.
                if let Some(l) = other {
                    self.targets.push(l);
                }
                return;
            }
        };
        let m = mask.map(|ml| Mask::from_pixmap(ml.pixmap.as_ref(), skia_masktype(ml.kind)));
        // Compositing the layer as a whole at `alpha` (and through `blend`) is what
        // makes group opacity/blend differ from per-element: overlaps inside the
        // layer don't compound, and the blend is against the backdrop below.
        let paint = tiny_skia::PixmapPaint {
            opacity: alpha.clamp(0.0, 1.0),
            blend_mode: blend.to_skia(),
            ..Default::default()
        };
        self.target().draw_pixmap(0, 0, layer.as_ref(), &paint, Transform::identity(), m.as_ref());
    }

    // Repaint boundaries: like begin/end_group but without mask/opacity/blend, and
    // the layer is returned (not composited) so the walk can memoise it and then
    // composite it here at identity. Source-over compositing is associative, so a
    // captured-then-composited layer is byte-identical to drawing the subtree inline.
    fn caches_subrasters(&self) -> bool {
        true
    }

    fn subraster_begin(&mut self) {
        self.targets.push(Pixmap::new(self.w, self.h).expect("non-zero layer dimensions"));
    }

    fn subraster_end(&mut self) -> Option<Pixmap> {
        if self.targets.len() <= 1 {
            return None; // never pop the base page target (unbalanced)
        }
        self.targets.pop()
    }

    fn composite_subraster(&mut self, pm: &Pixmap) {
        let paint = tiny_skia::PixmapPaint::default();
        self.target().draw_pixmap(0, 0, pm.as_ref(), &paint, Transform::identity(), None);
    }

    fn draw_circles(
        &mut self,
        cx: &[f64],
        cy: &[f64],
        r: &[f64],
        fill: Option<&ResolvedPaint>,
        stroke: Option<(Rgba, StrokeStyle)>,
        transform: Transform,
        clip: &Clip,
    ) {
        // Sprite fast path: a large cloud of equal-radius, solid-fill, unstroked
        // markers. Rasterize the marker once and blit it per point (pixel-snapped,
        // imperceptible at the densities where it triggers). Anything else falls
        // back to per-element path fills.
        //
        // PERF-4 (measured): the sprite blit beats both alternatives across the
        // whole tested radius range — per-element circle fills (~1.2x slower at
        // r=24px) and a single combined-path fill of all discs (much slower:
        // 3e5 discs in one rasterizer sweep is ~2.7x slower than the sprite).
        // So the sprite is kept for all uniform small-to-large markers; SPRITE_MAX_R
        // only guards against absurd per-blit areas. The residual ~0.6x vs grid for
        // big markers is raster throughput (grid's device circle fill is hard to
        // beat); for huge overplotted clouds use datashade() (PERF-5) instead.
        const SPRITE_MIN: usize = 10_000;
        const SPRITE_MAX_R: f64 = 64.0;
        // The fixed-radius sprite is placed at the mapped centre, so it is exact
        // only when the CTM's linear part preserves length — a rotation/reflection
        // at unit scale keeps a circle the same-radius circle (viewport transforms
        // are isometries by invariant, enforced by a debug_assert in resolve_one).
        // A non-unit scale would need a resized sprite, so verify at runtime and
        // fall back to per-element fills (which apply the full CTM) otherwise —
        // keeping raster identical to SVG/PDF even if the invariant is ever broken.
        let m = &transform;
        let unit_scale = (m.sx * m.sx + m.ky * m.ky - 1.0).abs() < 1e-6
            && (m.kx * m.kx + m.sy * m.sy - 1.0).abs() < 1e-6
            && (m.sx * m.kx + m.ky * m.sy).abs() < 1e-6;
        let n = cx.len().min(cy.len()).min(r.len());
        let uniform_small = n >= SPRITE_MIN
            && unit_scale
            && stroke.is_none()
            && r[0] > 0.0
            && r[0] <= SPRITE_MAX_R
            && r[..n].iter().all(|&v| (v - r[0]).abs() < 1e-9);
        if uniform_small {
            if let Some(ResolvedPaint::Solid(color)) = fill {
                if let Some(sprite) = circle_sprite(r[0], *color) {
                    let mask = self.mask_for(clip);
                    let off = sprite.width() as f64 / 2.0;
                    let paint = tiny_skia::PixmapPaint::default();
                    let target = self.targets.last_mut().expect("at least the page target");
                    for i in 0..n {
                        // transform is a rigid isometry, so map the centre directly.
                        let dx = transform.sx as f64 * cx[i] + transform.kx as f64 * cy[i] + transform.tx as f64;
                        let dy = transform.ky as f64 * cx[i] + transform.sy as f64 * cy[i] + transform.ty as f64;
                        target.draw_pixmap(
                            (dx - off).round() as i32,
                            (dy - off).round() as i32,
                            sprite.as_ref(),
                            &paint,
                            Transform::identity(),
                            mask.as_deref(),
                        );
                    }
                    return;
                }
            }
        }
        circles_by_path(self, cx, cy, r, fill, stroke.as_ref(), transform, clip);
    }

    fn draw_image(&mut self, rgba: &[u8], iw: u32, ih: u32, x: f64, y: f64, w: f64, h: f64, interpolate: bool, transform: Transform, clip: &Clip) {
        let pm = match pixmap_from_straight(rgba, iw, ih) {
            Some(p) => p,
            None => return,
        };
        let mask = self.mask_for(clip);
        // Map the iw x ih pixmap into the w x h cell at (x-w/2, y-h/2); `transform` then to device.
        let place = transform.pre_concat(Transform::from_row(
            (w / iw as f64) as f32, 0.0, 0.0, (h / ih as f64) as f32,
            (x - w / 2.0) as f32, (y - h / 2.0) as f32,
        ));
        let mut paint = tiny_skia::PixmapPaint::default();
        paint.quality = if interpolate { FilterQuality::Bilinear } else { FilterQuality::Nearest };
        self.targets.last_mut().expect("at least the page target")
            .draw_pixmap(0, 0, pm.as_ref(), &paint, place, mask.as_deref());
    }
}

// --- SVG backend ------------------------------------------------------------

pub struct SvgBackend {
    w: u32,
    h: u32,
    defs: String,
    body: String,
    /// A stack of open group buffers; drawing appends to the top (or `body` when
    /// empty). `end_group` pops one and wraps it in a `<g>` (with its mask).
    groups: Vec<String>,
    group_masks: Vec<Option<MaskLayer>>,
    group_alpha: Vec<f32>,
    group_blend: Vec<BlendKind>,
    clip_attrs: HashMap<usize, String>,
    /// Deduplicates gradient/pattern `<defs>` by content signature so repeated
    /// identical fills reference one def instead of emitting N copies.
    def_ids: HashMap<String, String>,
    next_clip: u32,
    next_grad: u32,
    /// When true, text is emitted as filled glyph `<path>` outlines (pixel-faithful,
    /// matching raster/PDF) instead of selectable `<text>` (renderer-shaped).
    outline_text: bool,
    /// Per-node metadata buffers (`begin_node`/`end_node`): a stack of partial
    /// buffers that drawing appends to, and a parallel stack of the wrapping `<g>`
    /// attributes (`None` = this node carried no metadata, so no buffer was pushed).
    node_stack: Vec<String>,
    node_open: Vec<Option<String>>,
    /// Per-element data key for the next primitive (`set_element_key`); spliced
    /// into the emitted element as `data-key="…"`. `None` = no attribute. Held as
    /// `Rc<str>` so `emit` (called once per fill and once per stroke of an element)
    /// can take a cheap refcount-bump clone rather than copying the key each time.
    cur_element_key: Option<Rc<str>>,
    /// Memoised `fill="…" fill-opacity="…"` for the last solid paint. A batched
    /// primitive resolves one paint for the whole run, so this hits on every
    /// element after the first — skipping a per-element `rgb_hex` + `format!`.
    last_solid_fill: Option<(Rgba, String)>,
    /// Scene-level accessible name / long description (a11y). When either is set,
    /// the root `<svg>` gains `role="img"` + `aria-labelledby` and emits
    /// `<title>`/`<desc>` children. `a11y_prefix` uniquifies their ids so several
    /// SVGs on one page don't collide. Empty prefix + both None = unchanged output.
    a11y_title: Option<String>,
    a11y_desc: Option<String>,
    a11y_prefix: String,
}

impl SvgBackend {
    pub fn new(w: u32, h: u32, bg: Rgba, outline_text: bool) -> Self {
        let mut body = String::new();
        if bg.a > 0 {
            body.push_str(&format!(
                "<rect width=\"{w}\" height=\"{h}\" fill=\"{}\" fill-opacity=\"{}\"/>",
                rgb_hex(bg),
                opacity(bg)
            ));
        }
        SvgBackend {
            w,
            h,
            defs: String::new(),
            body,
            groups: Vec::new(),
            group_masks: Vec::new(),
            group_alpha: Vec::new(),
            group_blend: Vec::new(),
            clip_attrs: HashMap::new(),
            def_ids: HashMap::new(),
            next_clip: 0,
            next_grad: 0,
            outline_text,
            node_stack: Vec::new(),
            node_open: Vec::new(),
            cur_element_key: None,
            last_solid_fill: None,
            a11y_title: None,
            a11y_desc: None,
            a11y_prefix: String::new(),
        }
    }

    /// Set the scene-level accessible name (`title`) and long description
    /// (`desc`), with an id `prefix` to uniquify their element ids. Empty strings
    /// are treated as absent.
    pub fn set_a11y(&mut self, title: &str, desc: &str, prefix: &str) {
        self.a11y_title = if title.is_empty() { None } else { Some(title.to_string()) };
        self.a11y_desc = if desc.is_empty() { None } else { Some(desc.to_string()) };
        self.a11y_prefix = prefix.to_string();
    }

    /// Return the id of a `<defs>` entry with signature `key`, emitting it via
    /// `make(id)` the first time and reusing it afterwards.
    ///
    /// The `key` is a `format!` string (callers include the serialized stops /
    /// tile-`Rc` pointer + geometry). A struct/`Rc`-keyed map would avoid the string
    /// alloc, but the key cost is dwarfed by the surrounding SVG serialization, so it
    /// is intentionally left as-is.
    fn intern_def(&mut self, key: String, make: impl FnOnce(&str) -> String) -> String {
        if let Some(id) = self.def_ids.get(&key) {
            return id.clone();
        }
        let id = format!("g{}", self.next_grad);
        self.next_grad += 1;
        let def = make(&id);
        self.defs.push_str(&def);
        self.def_ids.insert(key, id.clone());
        id
    }

    /// The buffer currently receiving output: an open per-node metadata buffer
    /// (innermost), else the innermost open compositing group, else the body.
    fn out(&mut self) -> &mut String {
        if !self.node_stack.is_empty() {
            self.node_stack.last_mut().unwrap()
        } else if !self.groups.is_empty() {
            self.groups.last_mut().unwrap()
        } else {
            &mut self.body
        }
    }

    /// The `fill="..."` attributes for a resolved paint (registers a gradient def
    /// when needed). Gradient coords are local px (`userSpaceOnUse`); the element's
    /// own `transform` maps them to device, exactly like the path geometry.
    fn svg_fill(&mut self, paint: &ResolvedPaint) -> String {
        match paint {
            ResolvedPaint::Solid(c) => {
                if let Some((pc, s)) = &self.last_solid_fill {
                    if pc == c {
                        return s.clone();
                    }
                }
                let s = format!("fill=\"{}\" fill-opacity=\"{}\"", rgb_hex(*c), opacity(*c));
                self.last_solid_fill = Some((*c, s.clone()));
                s
            }
            ResolvedPaint::Linear { x1, y1, x2, y2, stops, extend } => {
                let stops_xml = svg_stops(stops);
                let s = svg_spread(*extend);
                let key = format!("L|{x1}|{y1}|{x2}|{y2}|{s}|{stops_xml}");
                let id = self.intern_def(key, |id| {
                    format!(
                        "<linearGradient id=\"{id}\" gradientUnits=\"userSpaceOnUse\" \
                         x1=\"{x1}\" y1=\"{y1}\" x2=\"{x2}\" y2=\"{y2}\" spreadMethod=\"{s}\">{stops_xml}</linearGradient>"
                    )
                });
                format!("fill=\"url(#{id})\"")
            }
            ResolvedPaint::Radial { cx, cy, r, fx, fy, fr, stops, extend } => {
                let stops_xml = svg_stops(stops);
                let s = svg_spread(*extend);
                // SVG's `fx`/`fy` default to `cx`/`cy` and `fr` to 0, so a concentric
                // gradient omits them — keeping its output byte-identical to before.
                let focal = if *fr != 0.0 || *fx != *cx || *fy != *cy {
                    format!(" fx=\"{fx}\" fy=\"{fy}\" fr=\"{fr}\"")
                } else {
                    String::new()
                };
                let key = format!("R|{cx}|{cy}|{r}|{focal}|{s}|{stops_xml}");
                let id = self.intern_def(key, |id| {
                    format!(
                        "<radialGradient id=\"{id}\" gradientUnits=\"userSpaceOnUse\" \
                         cx=\"{cx}\" cy=\"{cy}\" r=\"{r}\"{focal} spreadMethod=\"{s}\">{stops_xml}</radialGradient>"
                    )
                });
                format!("fill=\"url(#{id})\"")
            }
            ResolvedPaint::Pattern { tile, tw, th, x, y, w, h, opacity, .. } => {
                // The tile is embedded as a PNG data URI and stretched over a
                // userSpaceOnUse cell; the element's own transform maps it to
                // device, like the path. (SVG patterns tile by repeat; the
                // reflect/pad extend modes degrade to repeat here.) Dedup by the
                // tile's `Rc` identity + geometry so we don't re-encode the PNG.
                let (px, py) = (x - w / 2.0, y - h / 2.0);
                let key = format!("P|{:p}|{px}|{py}|{w}|{h}", Rc::as_ptr(tile));
                let id = match self.def_ids.get(&key) {
                    Some(id) => id.clone(),
                    None => {
                        let png = straight_png(tile, *tw, *th);
                        let href = match png {
                            Some(bytes) => format!("data:image/png;base64,{}", b64(&bytes)),
                            None => return String::from("fill=\"none\""),
                        };
                        let id = format!("g{}", self.next_grad);
                        self.next_grad += 1;
                        self.defs.push_str(&format!(
                            "<pattern id=\"{id}\" patternUnits=\"userSpaceOnUse\" \
                             x=\"{px}\" y=\"{py}\" width=\"{w}\" height=\"{h}\">\
                             <image href=\"{href}\" x=\"0\" y=\"0\" width=\"{w}\" height=\"{h}\" \
                             preserveAspectRatio=\"none\"/></pattern>"
                        ));
                        self.def_ids.insert(key, id.clone());
                        id
                    }
                };
                let op = if *opacity < 1.0 { format!(" fill-opacity=\"{opacity}\"") } else { String::new() };
                format!("fill=\"url(#{id})\"{op}")
            }
        }
    }

    pub fn into_string(self) -> String {
        // Accessibility: when a scene name/description is set, mark the root as an
        // image with an accessible name+description via `role="img"` +
        // `aria-labelledby`, and emit `<title>`/`<desc>` as the first children
        // (the placement AT expects). Absent => byte-identical to before.
        let mut svg_attrs = String::new();
        let mut a11y_head = String::new();
        if self.a11y_title.is_some() || self.a11y_desc.is_some() {
            // Escape the prefix: it is interpolated into `id`/`aria-labelledby`
            // attribute values, so a `"`/`<`/`&` would otherwise break the markup.
            let p = xml_escape(&self.a11y_prefix);
            let p = &p;
            let mut ids: Vec<String> = Vec::new();
            if let Some(t) = &self.a11y_title {
                ids.push(format!("{p}-t"));
                a11y_head.push_str(&format!("<title id=\"{p}-t\">{}</title>", xml_escape(t)));
            }
            if let Some(d) = &self.a11y_desc {
                ids.push(format!("{p}-d"));
                a11y_head.push_str(&format!("<desc id=\"{p}-d\">{}</desc>", xml_escape(d)));
            }
            svg_attrs = format!(" role=\"img\" aria-labelledby=\"{}\"", ids.join(" "));
        }
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{w}\" height=\"{h}\" \
             viewBox=\"0 0 {w} {h}\"{a}>{head}<defs>{defs}</defs>{body}</svg>\n",
            w = self.w,
            h = self.h,
            a = svg_attrs,
            head = a11y_head,
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
        let has_clip = !attr.is_empty();
        // A per-element `data-key` is spliced into the shape's opening tag when set
        // (kept, not cleared, so a fill+stroke pair for one element both carry it;
        // the batched render loop clears it when the node ends). Writing straight
        // into the output buffer avoids copying the whole `element` string (and, when
        // keyed, the extra splice buffer) that the previous formatting approach did.
        let key = self.cur_element_key.clone(); // cheap Rc refcount bump when set
        let out = self.out();
        if has_clip {
            out.push_str("<g");
            out.push_str(&attr);
            out.push('>');
        }
        match &key {
            Some(k) => push_data_keyed(out, element, k),
            None => out.push_str(element),
        }
        if has_clip {
            out.push_str("</g>");
        }
    }

    /// A ` clip-path="url(#…)"` attribute for this clip (empty string = none).
    /// Nested `<clipPath>` elements (each referencing the previous) intersect.
    fn clip_attr(&mut self, clip: &Clip) -> String {
        if clip.shapes.is_empty() {
            return String::new();
        }
        if let Some(a) = self.clip_attrs.get(&clip.id) {
            return a.clone();
        }
        let mut parent_ref = String::new();
        let mut last = String::new();
        for shape in clip.shapes {
            let id = format!("c{}", self.next_clip);
            self.next_clip += 1;
            // Clip geometry is baked to device coords (userSpaceOnUse) so the
            // wrapping `<g>` carries no transform.
            let rule = matches!(shape, ClipShape::Path { evenodd: true, .. });
            let rule_attr = if rule { " clip-rule=\"evenodd\"" } else { "" };
            self.defs.push_str(&format!(
                "<clipPath id=\"{id}\" clipPathUnits=\"userSpaceOnUse\"{parent_ref}><path d=\"{d}\"{rule_attr}/></clipPath>",
                d = clip_shape_d(shape),
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
    fn fill_path(&mut self, path: &Path, transform: Transform, paint: &ResolvedPaint, rule: FillRule, clip: &Clip) {
        let fill = self.svg_fill(paint);
        let rule_attr = match rule {
            FillRule::EvenOdd => " fill-rule=\"evenodd\"",
            FillRule::Winding => "",
        };
        let element = format!(
            "<path d=\"{}\" {fill}{rule_attr}{}/>",
            path_to_d(path),
            transform_attr(transform),
        );
        self.emit(&element, clip);
    }

    fn stroke_path(&mut self, path: &Path, transform: Transform, color: Rgba, stroke: &StrokeStyle, clip: &Clip) {
        if stroke.width <= 0.0 {
            return;
        }
        let dash = if stroke.dash.is_empty() {
            String::new()
        } else {
            let arr: Vec<String> = stroke.dash.iter().map(|d| d.to_string()).collect();
            format!(" stroke-dasharray=\"{}\"", arr.join(","))
        };
        let element = format!(
            "<path d=\"{}\" fill=\"none\" stroke=\"{}\" stroke-opacity=\"{}\" stroke-width=\"{}\" \
             stroke-linecap=\"{}\" stroke-linejoin=\"{}\" stroke-miterlimit=\"{}\"{}{}/>",
            path_to_d(path),
            rgb_hex(color),
            opacity(color),
            stroke.width,
            svg_cap(stroke.cap),
            svg_join(stroke.join),
            stroke.miter,
            dash,
            transform_attr(transform),
        );
        self.emit(&element, clip);
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        if run.label.is_empty() {
            return;
        }
        // A rich (per-glyph colour) label can't be a single `<text>` element, so it
        // always takes the outline path even when native text is otherwise preferred.
        let rich = !run.gcolor.is_empty();
        if self.outline_text || rich {
            // Glyph-faithful: fill the same skrifa outlines the raster backend uses,
            // each placed by the shared glyph transform — so SVG matches raster/PDF
            // exactly (no dependence on the viewer's fonts).
            let base = if run.rot != 0.0 {
                transform.pre_concat(rotation_about(run.rot, run.ax, run.ay))
            } else {
                transform
            };
            let n = run.gid.len().min(run.gx.len()).min(run.gy.len())
                .min(run.gsize.len()).min(run.gpath.len()).min(run.gface.len());
            let mut paths = String::new();
            for i in 0..n {
                let outline = match glyph_outline_cached(&run.gpath[i], run.gface[i], run.gid[i], run.gsize[i] as f32) {
                    Some(p) => p,
                    None => continue,
                };
                let ox = run.ax + run.gx[i] - run.hjust * run.w;
                let oy = run.ay - (run.gy[i] - run.vjust * run.h);
                let place = base.pre_concat(Transform::from_row(1.0, 0.0, 0.0, -1.0, ox as f32, oy as f32));
                // Per-glyph fill for rich labels; otherwise inherit the group's fill.
                let fill_attr = match run.gcolor.get(i) {
                    Some(&c) => format!(" fill=\"{}\" fill-opacity=\"{}\"", rgb_hex(c), opacity(c)),
                    None => String::new(),
                };
                paths.push_str(&format!("<path d=\"{}\"{}{}/>", path_to_d(outline.as_ref()), fill_attr, transform_attr(place)));
            }
            if !paths.is_empty() {
                let element = format!(
                    "<g fill=\"{col}\" fill-opacity=\"{op}\">{paths}</g>",
                    col = rgb_hex(run.color),
                    op = opacity(run.color),
                );
                self.emit(&element, clip);
            }
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

    fn begin_group(&mut self, mask: Option<MaskLayer>, alpha: f32, blend: BlendKind) {
        self.groups.push(String::new());
        self.group_masks.push(mask);
        self.group_alpha.push(alpha);
        self.group_blend.push(blend);
    }

    fn end_group(&mut self) {
        let mask = self.group_masks.pop().flatten();
        let alpha = self.group_alpha.pop().unwrap_or(1.0);
        let blend = self.group_blend.pop().unwrap_or(BlendKind::Normal);
        let inner = self.groups.pop().unwrap_or_default();
        // SVG masks are luminance-based; bake the chosen coverage into a grayscale
        // image (gray == coverage) so a single luminance mask serves both kinds.
        // Group opacity is a `<g opacity>` (applies to the composited layer).
        let mask_attr = match mask.and_then(|ml| mask_png(&ml.pixmap, ml.kind)) {
            Some(png) => {
                let id = format!("g{}", self.next_grad);
                self.next_grad += 1;
                self.defs.push_str(&format!(
                    "<mask id=\"{id}\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" \
                     width=\"{w}\" height=\"{h}\"><image href=\"data:image/png;base64,{b}\" \
                     x=\"0\" y=\"0\" width=\"{w}\" height=\"{h}\" preserveAspectRatio=\"none\"/></mask>",
                    w = self.w,
                    h = self.h,
                    b = b64(&png),
                ));
                format!(" mask=\"url(#{id})\"")
            }
            None => String::new(),
        };
        let opacity_attr = if alpha < 1.0 {
            format!(" opacity=\"{alpha}\"")
        } else {
            String::new()
        };
        // Group blend is CSS `mix-blend-mode` (blends the group against the backdrop).
        let blend_attr = match blend.svg() {
            Some(mode) => format!(" style=\"mix-blend-mode:{mode}\""),
            None => String::new(),
        };
        self.out().push_str(&format!("<g{mask_attr}{opacity_attr}{blend_attr}>{inner}</g>"));
    }

    fn draw_image(&mut self, rgba: &[u8], iw: u32, ih: u32, x: f64, y: f64, w: f64, h: f64, interpolate: bool, transform: Transform, clip: &Clip) {
        let png = match straight_png(rgba, iw, ih) {
            Some(b) => b,
            None => return,
        };
        let rendering = if interpolate { "" } else { " image-rendering=\"pixelated\"" };
        let element = format!(
            "<image href=\"data:image/png;base64,{b}\" x=\"{px}\" y=\"{py}\" width=\"{w}\" height=\"{h}\" \
             preserveAspectRatio=\"none\"{rendering}{tr}/>",
            b = b64(&png),
            px = x - w / 2.0,
            py = y - h / 2.0,
            tr = transform_attr(transform),
        );
        self.emit(&element, clip);
    }

    // Per-node semantic metadata: route this node's elements into a fresh buffer,
    // then wrap them in a `<g …>` carrying the attributes. A node with no metadata
    // pushes `None` (no buffer) so the common case is free of an extra group.
    fn begin_node(&mut self, attrs: &str) {
        if attrs.is_empty() {
            self.node_open.push(None);
        } else {
            self.node_stack.push(String::new());
            self.node_open.push(Some(attrs.to_string()));
        }
    }

    fn end_node(&mut self) {
        if let Some(Some(attrs)) = self.node_open.pop() {
            let inner = self.node_stack.pop().unwrap_or_default();
            self.out().push_str(&format!("<g {attrs}>{inner}</g>"));
        }
    }

    fn set_element_key(&mut self, key: Option<&str>) {
        self.cur_element_key = key.map(Rc::from);
    }

    fn wants_element_keys(&self) -> bool {
        true
    }

    // A named panel group: route the enclosed nodes into a fresh buffer, then wrap
    // them in `<g data-vellum-panel="…">`. Reuses the node-metadata buffer stack
    // (identical mechanism), so panels and per-node `<g>`s nest correctly. The
    // wrapper carries no transform — elements keep their baked device-space
    // transforms, matching the clip-`<g>` invariant.
    fn begin_panel(&mut self, name: &str) {
        self.node_stack.push(String::new());
        self.node_open.push(Some(format!("data-vellum-panel=\"{}\"", xml_escape(name))));
    }

    fn end_panel(&mut self) {
        if let Some(Some(attrs)) = self.node_open.pop() {
            let inner = self.node_stack.pop().unwrap_or_default();
            self.out().push_str(&format!("<g {attrs}>{inner}</g>"));
        }
    }
}

/// Append `element` to `out` with a `data-key="…"` attribute spliced into its
/// opening tag, right after the tag name (so it lands inside `<tag …>`). Writes
/// directly into the output buffer — no intermediate element/attribute Strings.
/// Used by `SvgBackend::emit` to tag individual elements of a batched primitive.
fn push_data_keyed(out: &mut String, element: &str, key: &str) {
    // The opening tag name runs from the leading `<` to the first space, `/`, or
    // `>`; splice the attribute there.
    let at = element.find([' ', '/', '>']).unwrap_or(element.len());
    out.push_str(&element[..at]);
    out.push_str(" data-key=\"");
    out.push_str(xml_escape(key).as_ref());
    out.push('"');
    out.push_str(&element[at..]);
}

/// Coverage byte a mask contributes for one (demultiplied) pixel: its alpha, or
/// its Rec.709 luminance. Shared by the SVG (`mask_png`) and PDF (`mask_gray_rgba`)
/// mask encoders so the two backends can't drift in how they read coverage.
fn mask_coverage(c: tiny_skia::ColorU8, kind: MaskKind) -> u8 {
    match kind {
        MaskKind::Alpha => c.alpha(),
        MaskKind::Luminance => {
            (0.2126 * c.red() as f32 + 0.7152 * c.green() as f32 + 0.0722 * c.blue() as f32).round() as u8
        }
    }
}

/// Encode a mask raster as an opaque grayscale PNG where each pixel's gray level
/// is its coverage (alpha or luminance), for use as an SVG luminance `<mask>`.
fn mask_png(pm: &Pixmap, kind: MaskKind) -> Option<Vec<u8>> {
    let mut out = Pixmap::new(pm.width(), pm.height())?;
    let src = pm.pixels();
    let dst = out.pixels_mut();
    for (s, d) in src.iter().zip(dst.iter_mut()) {
        let cov = mask_coverage(s.demultiply(), kind);
        *d = tiny_skia::ColorU8::from_rgba(cov, cov, cov, 255).premultiply();
    }
    out.encode_png().ok()
}

// Straight (un-premultiplied) RGBA where each texel's coverage (alpha for an
// alpha mask, luminance for a luminance mask) is baked into an opaque gray. Read
// back as a Luminosity mask this reproduces either mask kind. Used by the PDF
// backend, which has no premultiplied-image path.
fn mask_gray_rgba(pm: &Pixmap, kind: MaskKind) -> Vec<u8> {
    let src = pm.pixels();
    let mut out = Vec::with_capacity(src.len() * 4);
    for s in src {
        let cov = mask_coverage(s.demultiply(), kind);
        out.extend_from_slice(&[cov, cov, cov, 255]);
    }
    out
}

// --- SVG serialization helpers ----------------------------------------------

fn rgb_hex(c: Rgba) -> String {
    format!("#{:02x}{:02x}{:02x}", c.r, c.g, c.b)
}

fn b64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn svg_spread(extend: Extend) -> &'static str {
    match extend {
        Extend::Pad => "pad",
        Extend::Repeat => "repeat",
        Extend::Reflect => "reflect",
    }
}

fn svg_cap(c: LineCap) -> &'static str {
    match c {
        LineCap::Round => "round",
        LineCap::Butt => "butt",
        LineCap::Square => "square",
    }
}

fn svg_join(j: LineJoin) -> &'static str {
    match j {
        LineJoin::Round => "round",
        LineJoin::Mitre => "miter",
        LineJoin::Bevel => "bevel",
    }
}

fn svg_stops(stops: &[Stop]) -> String {
    stops
        .iter()
        .map(|s| {
            format!(
                "<stop offset=\"{}\" stop-color=\"{}\" stop-opacity=\"{}\"/>",
                s.offset,
                rgb_hex(s.color),
                opacity(s.color)
            )
        })
        .collect()
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
    use std::fmt::Write;
    use tiny_skia::PathSegment;
    let mut d = String::new();
    // Write directly into the buffer (no throwaway String per segment). Writing to
    // a String is infallible, so the Result is discarded.
    for seg in path.segments() {
        match seg {
            PathSegment::MoveTo(p) => { let _ = write!(d, "M{} {} ", p.x, p.y); }
            PathSegment::LineTo(p) => { let _ = write!(d, "L{} {} ", p.x, p.y); }
            PathSegment::QuadTo(c, p) => { let _ = write!(d, "Q{} {} {} {} ", c.x, c.y, p.x, p.y); }
            PathSegment::CubicTo(c1, c2, p) => {
                let _ = write!(d, "C{} {} {} {} {} {} ", c1.x, c1.y, c2.x, c2.y, p.x, p.y);
            }
            PathSegment::Close => d.push('Z'),
        }
    }
    // Each non-close segment leaves exactly one trailing space; drop it (a `Z`
    // leaves none). Equivalent to the previous trim_end without a second alloc.
    if d.ends_with(' ') {
        d.pop();
    }
    d
}

/// The four device-space corners of a `w`x`h` rect placed by `t`, ordered
/// TL, TR, BR, BL. Shared by the SVG (`clip_shape_d`) and PDF (`clip_rect_kpath`)
/// rect-clip emitters so their corner math can't drift.
fn rect_corners(w: f64, h: f64, t: Transform) -> [(f64, f64); 4] {
    let pt = |x: f64, y: f64| {
        (
            t.sx as f64 * x + t.kx as f64 * y + t.tx as f64,
            t.ky as f64 * x + t.sy as f64 * y + t.ty as f64,
        )
    };
    [pt(0.0, 0.0), pt(w, 0.0), pt(w, h), pt(0.0, h)]
}

/// A clip shape as a closed SVG path `d` in device coords (transform baked in).
fn clip_shape_d(shape: &ClipShape) -> String {
    match shape {
        ClipShape::Rect { w, h, transform } => {
            let [(x0, y0), (x1, y1), (x2, y2), (x3, y3)] = rect_corners(*w, *h, *transform);
            format!("M{x0} {y0} L{x1} {y1} L{x2} {y2} L{x3} {y3} Z")
        }
        ClipShape::Path { path, transform, .. } => match path.clone().transform(*transform) {
            Some(p) => path_to_d(&p),
            None => String::new(),
        },
    }
}

// Escape a string for XML text or a double-quoted attribute value. Shared with
// scene.rs (the SVG identity attributes) so the two backends can't drift.
pub(crate) fn xml_escape(s: &str) -> Cow<'_, str> {
    // Fast path: the overwhelming majority of keys / ids / labels contain none of
    // the XML metacharacters, so return the input untouched (no allocation).
    if !s.bytes().any(|b| matches!(b, b'&' | b'<' | b'>' | b'"')) {
        return Cow::Borrowed(s);
    }
    let mut out = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(c),
        }
    }
    Cow::Owned(out)
}

// --- PDF backend (krilla) ---------------------------------------------------

use krilla::color::rgb;
use krilla::geom::{Path as KPath, PathBuilder as KPathBuilder, Point as KPoint, Size as KSize, Transform as KTransform};
use krilla::image::Image as KImage;
use krilla::blend::BlendMode as KBlend;
use krilla::mask::{Mask as KMask, MaskType as KMaskType};
use krilla::num::NormalizedF32;
use krilla::paint::{
    Fill, FillRule as KFillRule, LineCap as KLineCap, LineJoin as KLineJoin, LinearGradient as KLinear,
    Paint as KPaint, Pattern as KPattern, RadialGradient as KRadial, SpreadMethod as KSpread, Stop as KStop,
    Stroke as KStroke, StrokeDash as KStrokeDash,
};
use krilla::surface::Surface;
use krilla::text::{Font, GlyphId, KrillaGlyph};

/// Map a blend mode to krilla's, or `None` for `Normal` (skip the state push).
fn krilla_blend(b: BlendKind) -> Option<KBlend> {
    use BlendKind::*;
    Some(match b {
        Normal => return None,
        Multiply => KBlend::Multiply, Screen => KBlend::Screen, Overlay => KBlend::Overlay,
        Darken => KBlend::Darken, Lighten => KBlend::Lighten, ColorDodge => KBlend::ColorDodge,
        ColorBurn => KBlend::ColorBurn, HardLight => KBlend::HardLight, SoftLight => KBlend::SoftLight,
        Difference => KBlend::Difference, Exclusion => KBlend::Exclusion, Hue => KBlend::Hue,
        Saturation => KBlend::Saturation, Color => KBlend::Color, Luminosity => KBlend::Luminosity,
    })
}

/// Draws onto a krilla PDF surface. Geometry is converted from `tiny_skia`
/// types; everything is drawn in device pixels and a single root scale
/// (`72/dpi`) maps to PDF points.
pub struct PdfBackend<'a, 'b> {
    surface: &'a mut Surface<'b>,
    fonts: HashMap<(String, u32), Option<Font>>,
    /// For each open group, how many `surface.pop()`s `end_group` must issue
    /// (1 if it installed a soft mask, 0 otherwise).
    group_pushes: Vec<usize>,
    /// Degradation messages: features this PDF walk could not honour (a dropped
    /// tiling pattern, a skipped mask). Surfaced to the user as one R warning.
    warnings: Vec<String>,
}

impl<'a, 'b> PdfBackend<'a, 'b> {
    pub fn new(surface: &'a mut Surface<'b>) -> Self {
        PdfBackend { surface, fonts: HashMap::new(), group_pushes: Vec::new(), warnings: Vec::new() }
    }

    /// Record a degradation, de-duplicated (the same gap usually recurs across
    /// many primitives; the user needs to hear it once).
    fn warn(&mut self, msg: impl Into<String>) {
        let msg = msg.into();
        if !self.warnings.contains(&msg) {
            self.warnings.push(msg);
        }
    }

    /// Fill the page with the background colour (device-px page rect).
    pub fn fill_background(&mut self, w: u32, h: u32, bg: Rgba) {
        if bg.a == 0 {
            return;
        }
        if let Some(path) = rect_path(0.0, 0.0, w as f64, h as f64) {
            let empty = Clip { id: usize::MAX, shapes: &[] };
            self.fill_path(&path, Transform::identity(), &ResolvedPaint::Solid(bg), FillRule::Winding, &empty);
        }
    }

    /// Push clip paths (under the root scale) then the primitive transform;
    /// returns the number of `pop()`s needed to unwind.
    fn push_state(&mut self, transform: Transform, clip: &Clip) -> usize {
        let mut n = 0;
        for shape in clip.shapes {
            let (kpath, rule) = match shape {
                ClipShape::Rect { w, h, transform } => {
                    (clip_rect_kpath(*w, *h, *transform), KFillRule::NonZero)
                }
                ClipShape::Path { path, evenodd, transform } => {
                    let dev = path.clone().transform(*transform).and_then(|p| to_kpath(&p));
                    (dev, if *evenodd { KFillRule::EvenOdd } else { KFillRule::NonZero })
                }
            };
            if let Some(p) = kpath {
                self.surface.push_clip_path(&p, &rule);
                n += 1;
            }
        }
        self.surface.push_transform(&to_ktransform(transform));
        n + 1
    }

    fn pop_state(&mut self, n: usize) {
        for _ in 0..n {
            self.surface.pop();
        }
    }

    fn font_for(&mut self, path: &str, index: u32) -> Option<Font> {
        let key = (path.to_string(), index);
        if let Some(f) = self.fonts.get(&key) {
            return f.clone();
        }
        let font = std::fs::read(path)
            .ok()
            .and_then(|bytes| Font::new(krilla::Data::from(bytes), index));
        self.fonts.insert(key, font.clone());
        font
    }
}

impl RenderBackend for PdfBackend<'_, '_> {
    fn fill_path(&mut self, path: &Path, transform: Transform, paint: &ResolvedPaint, rule: FillRule, clip: &Clip) {
        let kp = match to_kpath(path) {
            Some(p) => p,
            None => return,
        };
        // Gradient geometry is local px (identity gradient transform); the
        // primitive `transform` pushed below maps it to device, like the path.
        let (kpaint, opacity) = match paint {
            ResolvedPaint::Solid(c) => (rgb::Color::new(c.r, c.g, c.b).into(), norm(c.a)),
            ResolvedPaint::Linear { x1, y1, x2, y2, stops, extend } => (
                KPaint::from(KLinear {
                    x1: *x1 as f32,
                    y1: *y1 as f32,
                    x2: *x2 as f32,
                    y2: *y2 as f32,
                    transform: KTransform::identity(),
                    spread_method: krilla_spread(*extend),
                    stops: krilla_stops(stops),
                    anti_alias: true,
                }),
                NormalizedF32::ONE,
            ),
            ResolvedPaint::Radial { cx, cy, r, fx, fy, fr, stops, extend } => (
                KPaint::from(KRadial {
                    fx: *fx as f32,
                    fy: *fy as f32,
                    fr: *fr as f32,
                    cx: *cx as f32,
                    cy: *cy as f32,
                    cr: *r as f32,
                    transform: KTransform::identity(),
                    spread_method: krilla_spread(*extend),
                    stops: krilla_stops(stops),
                    anti_alias: true,
                }),
                NormalizedF32::ONE,
            ),
            // A real tiling pattern: draw the tile image into a stream sized to the
            // cell, anchored at the cell's top-left (matching raster/SVG).
            ResolvedPaint::Pattern { tile, tw, th, x, y, w, h, opacity, .. } => {
                // Overflow-checked tile byte count (parity with pixmap_from_straight).
                let need = (*tw as usize)
                    .checked_mul(*th as usize)
                    .and_then(|p| p.checked_mul(4));
                match (KSize::from_wh(*w as f32, *h as f32), need) {
                    // `>=` for parity with the raster/SVG tile checks (which accept a
                    // buffer at least the required size, not exactly it).
                    (Some(cell), Some(n)) if tile.len() >= n => {
                        let img = KImage::from_rgba8(tile[..n].to_vec(), *tw, *th);
                        let stream = {
                            let mut sb = self.surface.stream_builder();
                            let mut surf = sb.surface();
                            surf.draw_image(img, cell);
                            surf.finish();
                            sb.finish()
                        };
                        let pat = KPattern {
                            stream,
                            transform: KTransform::from_translate((x - w / 2.0) as f32, (y - h / 2.0) as f32),
                            width: *w as f32,
                            height: *h as f32,
                        };
                        (KPaint::from(pat), NormalizedF32::new(opacity.clamp(0.0, 1.0)).unwrap_or(NormalizedF32::ONE))
                    }
                    _ => {
                        self.warn("a tiling-pattern fill could not be rendered to PDF (degenerate tile or cell size); the shape was left unfilled");
                        return;
                    }
                }
            }
        };
        let krule = match rule {
            FillRule::EvenOdd => KFillRule::EvenOdd,
            FillRule::Winding => KFillRule::NonZero,
        };
        let n = self.push_state(transform, clip);
        self.surface.set_stroke(None);
        self.surface.set_fill(Some(Fill { paint: kpaint, opacity, rule: krule }));
        self.surface.draw_path(&kp);
        self.pop_state(n);
    }

    fn stroke_path(&mut self, path: &Path, transform: Transform, color: Rgba, stroke: &StrokeStyle, clip: &Clip) {
        if stroke.width <= 0.0 {
            return;
        }
        let kp = match to_kpath(path) {
            Some(p) => p,
            None => return,
        };
        let n = self.push_state(transform, clip);
        self.surface.set_fill(None);
        self.surface.set_stroke(Some(KStroke {
            paint: rgb::Color::new(color.r, color.g, color.b).into(),
            width: stroke.width,
            opacity: norm(color.a),
            miter_limit: stroke.miter,
            line_cap: krilla_cap(stroke.cap),
            line_join: krilla_join(stroke.join),
            dash: if stroke.dash.is_empty() {
                None
            } else {
                Some(KStrokeDash { array: stroke.dash.clone(), offset: 0.0 })
            },
            ..KStroke::default()
        }));
        self.surface.draw_path(&kp);
        self.pop_state(n);
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        let n = run.gid.len()
            .min(run.gx.len())
            .min(run.gy.len())
            .min(run.gsize.len())
            .min(run.gpath.len())
            .min(run.gface.len());
        if n == 0 || run.label.is_empty() {
            return; // n includes gy.len(), so gy[0] below is safe
        }
        let size_px = (run.size * run.dpi / 72.0) as f32;
        if size_px <= 0.0 {
            return;
        }
        // Text origin (local px). Glyph i sits at origin + gx[i]. The baseline y
        // is per-line: glyph runs are split on a change of `gy` (a new line) and
        // each is drawn at its own `start_y`, so multi-line text stacks correctly
        // (avoids guessing krilla's per-glyph y_offset sign). Mirrors raster.
        let start_x = (run.ax - run.hjust * run.w) as f32;
        let base = if run.rot != 0.0 {
            transform.pre_concat(rotation_about(run.rot, run.ax, run.ay))
        } else {
            transform
        };

        // char byte boundaries for ToUnicode (exact when glyphs == chars).
        let bounds: Vec<usize> =
            run.label.char_indices().map(|(b, _)| b).chain(std::iter::once(run.label.len())).collect();
        let exact = n + 1 == bounds.len();
        let range_for = |i: usize| {
            if exact {
                bounds[i]..bounds[i + 1]
            } else if i == 0 {
                0..run.label.len()
            } else {
                0..0
            }
        };

        let pushes = self.push_state(base, clip);
        self.surface.set_stroke(None);
        let rich = !run.gcolor.is_empty();
        // Plain labels set the single fill once; rich labels set it per colour run.
        if !rich {
            self.surface.set_fill(Some(Fill {
                paint: rgb::Color::new(run.color.r, run.color.g, run.color.b).into(),
                opacity: norm(run.color.a),
                rule: KFillRule::NonZero,
            }));
        }

        // Draw in runs of consecutive glyphs sharing a font AND a baseline (so a
        // line break, which changes gy, starts a new run handles font fallback too).
        // Rich labels additionally break on a colour change so each run gets its fill.
        let mut i = 0;
        while i < n {
            let (gpath, gface, gy0) = (&run.gpath[i], run.gface[i], run.gy[i]);
            let col0 = run.gcolor.get(i).copied();
            let mut j = i;
            while j < n
                && &run.gpath[j] == gpath
                && run.gface[j] == gface
                && run.gy[j] == gy0
                && run.gcolor.get(j).copied() == col0
            {
                j += 1;
            }
            if let Some(c) = col0 {
                self.surface.set_fill(Some(Fill {
                    paint: rgb::Color::new(c.r, c.g, c.b).into(),
                    opacity: norm(c.a),
                    rule: KFillRule::NonZero,
                }));
            }
            let start_y = (run.ay - (gy0 - run.vjust * run.h)) as f32;
            if let Some(font) = self.font_for(gpath, gface) {
                let glyphs: Vec<KrillaGlyph> = (i..j)
                    .map(|k| {
                        KrillaGlyph::new(
                            GlyphId::new(run.gid[k]),
                            0.0,                              // x_advance (positions via x_offset)
                            run.gx[k] as f32 / size_px,       // x_offset, normalized
                            0.0,
                            0.0,
                            range_for(k),
                            None,
                        )
                    })
                    .collect();
                self.surface.draw_glyphs(
                    KPoint::from_xy(start_x, start_y),
                    &glyphs,
                    font,
                    run.label,
                    size_px,
                    false,
                );
            }
            i = j;
        }
        self.pop_state(pushes);
    }

    // PDF masks: krilla can only install a soft mask *before* the masked content
    // (`push_mask` + draw live + `pop`), so the walk hands us the mask at
    // group-start. We bake the rasterized mask into a page-sized grayscale image
    // (coverage in RGB, alpha 255) and install it as a Luminosity mask — this
    // unifies alpha/luminance kinds and avoids premultiplied-color pitfalls. The
    // mask stream is drawn in device px, matching the root px->pt scale that is on
    // the surface stack throughout the walk, so it aligns with the content.
    fn begin_group(&mut self, mask: Option<MaskLayer>, alpha: f32, blend: BlendKind) {
        let mut pushes = 0usize;
        if let Some(ml) = mask {
            let (w, h) = (ml.pixmap.width(), ml.pixmap.height());
            if let Some(size) = KSize::from_wh(w as f32, h as f32) {
                let img = KImage::from_rgba8(mask_gray_rgba(&ml.pixmap, ml.kind), w, h);
                let stream = {
                    let mut sb = self.surface.stream_builder();
                    let mut surf = sb.surface();
                    surf.draw_image(img, size);
                    surf.finish();
                    sb.finish()
                };
                self.surface.push_mask(KMask::new(stream, KMaskType::Luminosity));
                pushes += 1;
            } else {
                self.warn("a viewport mask could not be applied to PDF (degenerate mask size); the group was drawn unmasked");
            }
        }
        // Group blend: blends the group's content against the backdrop below it.
        if let Some(kb) = krilla_blend(blend) {
            self.surface.push_blend_mode(kb);
            pushes += 1;
        }
        // Group opacity: an isolated transparency group composited at `alpha`.
        if alpha < 1.0 {
            if let Some(a) = NormalizedF32::new(alpha.clamp(0.0, 1.0)) {
                self.surface.push_opacity(a);
                pushes += 1;
            }
        }
        self.group_pushes.push(pushes);
    }

    fn end_group(&mut self) {
        if let Some(n) = self.group_pushes.pop() {
            for _ in 0..n {
                self.surface.pop();
            }
        }
    }

    fn draw_image(&mut self, rgba: &[u8], iw: u32, ih: u32, x: f64, y: f64, w: f64, h: f64, interpolate: bool, transform: Transform, clip: &Clip) {
        if iw == 0 || ih == 0 || rgba.len() < (iw as usize) * (ih as usize) * 4 {
            return;
        }
        let size = match KSize::from_wh(w as f32, h as f32) {
            Some(s) => s,
            None => return,
        };
        // krilla's `from_rgba8` hard-codes non-interpolated sampling, so honour
        // `interpolate` (as raster/SVG do) by routing an interpolated image through
        // a PNG — `from_png` carries the `/Interpolate` flag. Nearest otherwise, and
        // as a fallback if PNG encoding fails.
        let img = if interpolate {
            match straight_png(rgba, iw, ih)
                .and_then(|png| KImage::from_png(krilla::Data::from(png), true).ok())
            {
                Some(i) => i,
                None => KImage::from_rgba8(rgba.to_vec(), iw, ih),
            }
        } else {
            KImage::from_rgba8(rgba.to_vec(), iw, ih)
        };
        // draw_image places the image at the origin scaled to `size`; translate to
        // the cell's top-left, under the primitive transform + clip.
        let place = transform.pre_concat(Transform::from_row(1.0, 0.0, 0.0, 1.0, (x - w / 2.0) as f32, (y - h / 2.0) as f32));
        let n = self.push_state(place, clip);
        self.surface.draw_image(img, size);
        self.pop_state(n);
    }

    fn take_warnings(&mut self) -> Vec<String> {
        std::mem::take(&mut self.warnings)
    }
}

fn to_kpath(p: &Path) -> Option<KPath> {
    use tiny_skia::PathSegment;
    let mut pb = KPathBuilder::new();
    for seg in p.segments() {
        match seg {
            PathSegment::MoveTo(pt) => pb.move_to(pt.x, pt.y),
            PathSegment::LineTo(pt) => pb.line_to(pt.x, pt.y),
            PathSegment::QuadTo(c, pt) => pb.quad_to(c.x, c.y, pt.x, pt.y),
            PathSegment::CubicTo(c1, c2, pt) => pb.cubic_to(c1.x, c1.y, c2.x, c2.y, pt.x, pt.y),
            PathSegment::Close => pb.close(),
        }
    }
    pb.finish()
}

fn to_ktransform(t: Transform) -> KTransform {
    KTransform::from_row(t.sx, t.ky, t.kx, t.sy, t.tx, t.ty)
}

fn clip_rect_kpath(w: f64, h: f64, transform: Transform) -> Option<KPath> {
    let c = rect_corners(w, h, transform);
    let mut pb = KPathBuilder::new();
    pb.move_to(c[0].0 as f32, c[0].1 as f32);
    pb.line_to(c[1].0 as f32, c[1].1 as f32);
    pb.line_to(c[2].0 as f32, c[2].1 as f32);
    pb.line_to(c[3].0 as f32, c[3].1 as f32);
    pb.close();
    pb.finish()
}

fn norm(a: u8) -> NormalizedF32 {
    NormalizedF32::new(a as f32 / 255.0).unwrap_or(NormalizedF32::ONE)
}

fn krilla_spread(extend: Extend) -> KSpread {
    match extend {
        Extend::Pad => KSpread::Pad,
        Extend::Repeat => KSpread::Repeat,
        Extend::Reflect => KSpread::Reflect,
    }
}

fn krilla_cap(c: LineCap) -> KLineCap {
    match c {
        LineCap::Round => KLineCap::Round,
        LineCap::Butt => KLineCap::Butt,
        LineCap::Square => KLineCap::Square,
    }
}

fn krilla_join(j: LineJoin) -> KLineJoin {
    match j {
        LineJoin::Round => KLineJoin::Round,
        LineJoin::Mitre => KLineJoin::Miter,
        LineJoin::Bevel => KLineJoin::Bevel,
    }
}

fn krilla_stops(stops: &[Stop]) -> Vec<KStop> {
    stops
        .iter()
        .map(|s| KStop {
            offset: NormalizedF32::new(s.offset.clamp(0.0, 1.0)).unwrap_or(NormalizedF32::ZERO),
            color: rgb::Color::new(s.color.r, s.color.g, s.color.b).into(),
            opacity: norm(s.color.a),
        })
        .collect()
}
