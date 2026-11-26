//! Render backends.
//!
//! The scene walk (`scene/draw.rs`) resolves each node to a primitive path, an
//! absolute transform, a colour, and a clip region, then emits it through the
//! [`RenderBackend`] trait. tiny-skia raster is one implementation; SVG (and PDF,
//! later) are others. Geometry is carried as `tiny_skia::Path` + `Transform`.
//!
//! Shared types, the trait and cross-backend helpers live here; each backend has
//! its own module (`raster`, `svg`, `pdf`) and backend-independent path builders
//! live in `paths`.

use crate::scene::NodeMeta;
use std::borrow::Cow;
use std::collections::HashMap;
use std::rc::Rc;
use std::sync::Arc;

use tiny_skia::{
    FillRule, FilterQuality, Mask, Paint, Path, PathBuilder, Pixmap, Stroke, StrokeDash, Transform,
};

use crate::color::{Extend, LineCap, LineJoin, Rgba, Stop};
use crate::font::{glyph_outline_cached, glyph_sprite_cached, PHASE_X, PHASE_Y};
use crate::units::rotation_about;

mod displaylist;
mod dml;
mod paths;
mod pdf;
mod pptx;
mod raster;
mod svg;

pub use displaylist::{DisplayList, DisplayListBackend};
pub use dml::{resolve_media, write_media_files, DmlBackend, EMU_PER_INCH};
pub use pptx::{pptx_package, SlidePart};
pub use paths::*;
pub(crate) use pdf::is_decorative;
pub use pdf::{pdf_tag, PdfBackend};
pub use raster::RasterBackend;
pub use svg::SvgBackend;
pub(crate) use svg::{doc_id_prefix, resolve_ids, xml_escape, ID_TOKEN};

/// Resolved stroke style handed to `stroke_path`: width + dash (device px, on/off,
/// empty = solid) + cap/join/mitre.
#[derive(Clone, Debug)]
pub struct StrokeStyle {
    pub width: f32,
    pub dash: Vec<f32>,
    pub cap: LineCap,
    pub join: LineJoin,
    pub miter: f32,
    /// Snap axis-parallel strokes onto the pixel grid (raster only). A 1-px rule
    /// at a fractional coordinate otherwise straddles two rows and renders as two
    /// grey ones instead of one solid -- the reason screen gridlines look muddy.
    pub crisp: bool,
    /// A gradient/pattern to stroke with, resolved to local px like a fill.
    /// `None` (the overwhelmingly common case) strokes with the plain colour the
    /// backend was handed, and every path stays exactly as it was.
    pub paint: Option<ResolvedPaint>,
    /// Dash phase in device px: how far into the dash pattern the line starts.
    /// Lets adjacent dashed strokes line up, and animates as marching ants.
    pub phase: f32,
}

/// Normalise a dash array (device px) to the one form every backend draws the
/// same way. Returns an empty vector for "solid".
///
/// SVG and PDF repeat an odd-length list to make it even, but tiny-skia rejects
/// it (and the PNG would silently draw solid), so an odd list is doubled here,
/// once, for all three. A list with a negative or non-finite entry, or one that
/// sums to zero, has no dashes to draw and becomes solid on every backend.
pub fn normalize_dash(dash: &[f32]) -> Vec<f32> {
    if dash.is_empty() || dash.iter().any(|d| !d.is_finite() || *d < 0.0) {
        return Vec::new();
    }
    let sum: f32 = dash.iter().sum();
    if !(sum > 0.0 && sum.is_finite()) {
        return Vec::new();
    }
    let mut out = dash.to_vec();
    if out.len() % 2 == 1 {
        out.extend_from_slice(dash);
    }
    out
}

thread_local! {
    /// Anti-aliasing for the primitive currently being drawn, set by the scene
    /// walk from the folded gpar. A thread-local rather than a parameter on every
    /// backend method: `ResolvedPaint` is an enum, so threading a flag through it
    /// would touch every variant and every call site. The walk is single-threaded
    /// per render (rayon parallelises across animation *frames*, each with its own
    /// thread-local), which is the same assumption the glyph-bitmap mode makes.
    static ANTIALIAS: std::cell::Cell<bool> = const { std::cell::Cell::new(true) };
}

/// Set anti-aliasing for subsequent draws on this thread.
pub fn set_antialias(on: bool) {
    ANTIALIAS.with(|c| c.set(on));
}

fn antialias() -> bool {
    ANTIALIAS.with(|c| c.get())
}

/// A fill paint with geometry resolved to viewport-local pixels (the backend's
/// own draw transform then maps it to device space, exactly like the path).
#[derive(Clone, Debug)]
pub enum ResolvedPaint {
    Solid(Rgba),
    Linear {
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
        stops: Vec<Stop>,
        extend: Extend,
    },
    /// Ruled lines filling the shape: geometry, not a tile. `spacing`/`width` are
    /// device px; the walk turns this into stroked spans, so no backend needs a
    /// hatch primitive of its own.
    Hatch {
        angle: f64,
        spacing: f64,
        width: f64,
        col: Rgba,
        bg: Option<Rgba>,
    },
    /// Two circles in local px: the focal/start circle `(fx, fy, fr)` at stop
    /// offset 0 and the outer/end circle `(cx, cy, r)` at offset 1 (concentric
    /// when `fr == 0` and `(fx, fy) == (cx, cy)`).
    Radial {
        cx: f64,
        cy: f64,
        r: f64,
        fx: f64,
        fy: f64,
        fr: f64,
        stops: Vec<Stop>,
        extend: Extend,
    },
    /// A tiled image: `tile` is straight RGBA (`tw` x `th`, top-left); it fills a
    /// `w` x `h` (px) cell centred at `(x, y)` and repeats per `extend`. `opacity`
    /// is the folded gpar alpha (applied without touching the shared tile).
    Pattern {
        tile: Arc<Vec<u8>>,
        tw: u32,
        th: u32,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        extend: Extend,
        opacity: f32,
    },
}

/// One clip region contributing to a clip chain, in viewport-local pixels placed
/// by `transform`: either a `w` x `h` rectangle or an arbitrary path.
#[derive(Clone, Debug)]
pub enum ClipShape {
    Rect {
        w: f64,
        h: f64,
        transform: Transform,
    },
    Path {
        path: Path,
        evenodd: bool,
        transform: Transform,
    },
}

/// The clip applying to a draw: the intersection of `shapes` (empty = no clip).
/// `id` identifies the originating viewport so backends can cache per-viewport
/// clip artifacts (a raster `Mask`, an SVG `<clipPath>`).
/// Split a shaped run into lines as `[lo, hi)` glyph index ranges, breaking on a
/// change of baseline. Glyphs within a line share one `gy`; a new line is a new
/// `gy`. A single-line run yields exactly one range, which keeps every
/// single-line caller on its original code path.
fn line_runs(run: &TextRun) -> Vec<(usize, usize)> {
    let n = run.gid.len().min(run.gx.len()).min(run.gy.len());
    if n == 0 {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut lo = 0usize;
    for i in 1..n {
        if run.gy[i] != run.gy[lo] {
            out.push((lo, i));
            lo = i;
        }
    }
    out.push((lo, n));
    out
}

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
    /// Filled rectangles drawn with the label (fraction bars and radical
    /// overbars of a `tex()` label), in the glyphs' frame. Empty for every
    /// other label, which then renders exactly as before.
    pub rules: &'a [TextRule],
    /// One character per glyph for PDF text extraction when `label` is not
    /// that (a `tex()` label's `label` is its TeX source). Empty: `label`.
    pub gtext: &'a str,
    /// Optional halo: `(colour, width in local px)`. Backends stroke the glyph
    /// outlines in this colour **under** the fill (SVG native text uses
    /// `paint-order`). `None` leaves every text path exactly as it was.
    pub halo: Option<(Rgba, f64)>,
    pub label: &'a str,
    pub family: &'a str,
    pub face: &'a str,
    pub size: f64,
    pub dpi: f64,
}

/// A filled rectangle that belongs to a text label, in label-local px in the
/// same frame as the glyph offsets: `x` from the label's left edge, `y` up
/// from the label box's bottom (`gy`'s origin), `(x, y)` the rule's
/// bottom-left corner. Drawn in the label's own transform, so it rotates,
/// justifies and takes the halo with the glyphs.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TextRule {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub col: Rgba,
}

/// The rule as a path in local px (y down, before the label's rotation),
/// placed by the same anchor/justification as the glyphs.
pub fn text_rule_path(run: &TextRun, r: &TextRule) -> Option<Path> {
    let x0 = run.ax - run.hjust * run.w + r.x;
    let y0 = run.ay - (r.y + r.h - run.vjust * run.h);
    tiny_skia::Rect::from_xywh(x0 as f32, y0 as f32, r.w.max(0.0) as f32, r.h.max(0.0) as f32)
        .map(tiny_skia::PathBuilder::from_rect)
}

/// A drop shadow cast by a group: the group's own coverage, tinted, blurred and
/// offset, painted underneath it.
#[derive(Clone, Copy, Debug)]
pub struct Shadow {
    pub dx: f32,
    pub dy: f32,
    /// Blur radius in device px. `0` gives a hard offset silhouette.
    pub blur: f32,
    pub col: Rgba,
}

/// Render effects applied when an isolated group closes. `None` fields are
/// inactive, so a group without effects composites exactly as it always did.
#[derive(Clone, Copy, Debug, Default)]
pub struct GroupEffect {
    /// Gaussian blur radius in device px applied to the group itself.
    pub blur: Option<f32>,
    pub shadow: Option<Shadow>,
}

impl GroupEffect {
    pub fn is_none(&self) -> bool {
        self.blur.is_none() && self.shadow.is_none()
    }
}

/// Blur a premultiplied pixmap in place: three box-blur passes, which is the
/// standard cheap approximation to a Gaussian (the error is under 3% by the
/// third pass, and it is what SVG's own `feGaussianBlur` is specified to do).
/// Working on premultiplied data is correct here -- it is what compositing
/// consumes, and blurring straight RGBA would bleed colour out of transparent
/// pixels.
pub fn box_blur(pm: &mut Pixmap, radius: f32) {
    if !(radius > 0.0) {
        return;
    }
    let (w, h) = (pm.width() as usize, pm.height() as usize);
    if w == 0 || h == 0 {
        return;
    }
    // Three box passes of this width approximate a Gaussian of `radius` sigma.
    // A window wider than the image only averages the clamped edge pixels, so cap
    // the radius there: an unbounded one (`blur = 1e9`) loops for hours, and
    // `blur = Inf` saturates to usize::MAX and overflows the window arithmetic.
    let r = ((radius * 3.0 * (std::f32::consts::TAU / 4.0).sqrt() / 4.0 + 0.5) as usize)
        .clamp(1, w.max(h));
    let mut buf: Vec<u8> = pm.data().to_vec();
    let mut tmp: Vec<u8> = vec![0; buf.len()];
    for _ in 0..3 {
        blur_pass(&buf, &mut tmp, w, h, r, true);
        blur_pass(&tmp, &mut buf, w, h, r, false);
    }
    pm.data_mut().copy_from_slice(&buf);
}

/// One axis of a box blur. A sliding window over each row (or column) keeps it
/// O(pixels) rather than O(pixels x radius). Edges clamp to the border pixel.
fn blur_pass(src: &[u8], dst: &mut [u8], w: usize, h: usize, r: usize, horizontal: bool) {
    let (outer, inner) = if horizontal { (h, w) } else { (w, h) };
    let idx = |o: usize, i: usize| {
        if horizontal {
            (o * w + i) * 4
        } else {
            (i * w + o) * 4
        }
    };
    let win = (2 * r + 1) as u32;
    for o in 0..outer {
        let mut acc = [0u32; 4];
        // Prime the window at position 0, clamping past the left edge.
        for k in 0..=(r as isize) {
            let i = k.clamp(0, inner as isize - 1) as usize;
            let p = idx(o, i);
            for c in 0..4 {
                acc[c] += src[p + c] as u32;
            }
        }
        // The r pixels before 0 all clamp to pixel 0.
        let p0 = idx(o, 0);
        for c in 0..4 {
            acc[c] += src[p0 + c] as u32 * r as u32;
        }
        for i in 0..inner {
            let p = idx(o, i);
            for c in 0..4 {
                dst[p + c] = (acc[c] / win) as u8;
            }
            let add = idx(o, (i + r + 1).min(inner - 1));
            let sub = idx(o, i.saturating_sub(r));
            for c in 0..4 {
                acc[c] = acc[c] + src[add + c] as u32 - src[sub + c] as u32;
            }
        }
    }
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
    Normal,
    Multiply,
    Screen,
    Overlay,
    Darken,
    Lighten,
    ColorDodge,
    ColorBurn,
    HardLight,
    SoftLight,
    Difference,
    Exclusion,
    Hue,
    Saturation,
    Color,
    Luminosity,
}

impl BlendKind {
    /// Codes match `.blend_codes` in R (the R<->Rust ABI).
    pub fn from_code(c: i32) -> BlendKind {
        use BlendKind::*;
        match c {
            1 => Multiply,
            2 => Screen,
            3 => Overlay,
            4 => Darken,
            5 => Lighten,
            6 => ColorDodge,
            7 => ColorBurn,
            8 => HardLight,
            9 => SoftLight,
            10 => Difference,
            11 => Exclusion,
            12 => Hue,
            13 => Saturation,
            14 => Color,
            15 => Luminosity,
            _ => Normal,
        }
    }

    fn to_skia(self) -> tiny_skia::BlendMode {
        use tiny_skia::BlendMode as B;
        use BlendKind::*;
        match self {
            Normal => B::SourceOver,
            Multiply => B::Multiply,
            Screen => B::Screen,
            Overlay => B::Overlay,
            Darken => B::Darken,
            Lighten => B::Lighten,
            ColorDodge => B::ColorDodge,
            ColorBurn => B::ColorBurn,
            HardLight => B::HardLight,
            SoftLight => B::SoftLight,
            Difference => B::Difference,
            Exclusion => B::Exclusion,
            Hue => B::Hue,
            Saturation => B::Saturation,
            Color => B::Color,
            Luminosity => B::Luminosity,
        }
    }

    /// CSS `mix-blend-mode` keyword, or `None` for `Normal` (omit the attribute).
    pub fn css(self) -> Option<&'static str> {
        self.svg()
    }

    /// CSS `mix-blend-mode` keyword, or `None` for `Normal` (omit the attribute).
    fn svg(self) -> Option<&'static str> {
        use BlendKind::*;
        Some(match self {
            Normal => return None,
            Multiply => "multiply",
            Screen => "screen",
            Overlay => "overlay",
            Darken => "darken",
            Lighten => "lighten",
            ColorDodge => "color-dodge",
            ColorBurn => "color-burn",
            HardLight => "hard-light",
            SoftLight => "soft-light",
            Difference => "difference",
            Exclusion => "exclusion",
            Hue => "hue",
            Saturation => "saturation",
            Color => "color",
            Luminosity => "luminosity",
        })
    }
}

/// A drawing target. The walk calls these in paint order. `begin_group` /
/// `end_group` bracket an isolated compositing layer; the optional `mask` (handed
/// to `begin_group`, since PDF must install its soft mask *before* the content)
/// modulates the group when it closes.
pub trait RenderBackend {
    fn fill_path(
        &mut self,
        path: &Path,
        transform: Transform,
        paint: &ResolvedPaint,
        rule: FillRule,
        clip: &Clip,
    );
    fn stroke_path(
        &mut self,
        path: &Path,
        transform: Transform,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    );
    /// Fill `path` with `paint`, then stroke it with `color` / `stroke` -- the
    /// pair every filled-and-outlined shape draws. The default is exactly the two
    /// calls; the SVG backend overrides it to write one element carrying both
    /// paints when it can (solid fill, undashed solid stroke). Callers pass a
    /// stroke with `width > 0` and a non-hatch fill (a hatch is expanded first).
    #[allow(clippy::too_many_arguments)]
    fn fill_and_stroke_path(
        &mut self,
        path: &Path,
        transform: Transform,
        paint: &ResolvedPaint,
        rule: FillRule,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    ) {
        self.fill_path(path, transform, paint, rule, clip);
        self.stroke_path(path, transform, color, stroke, clip);
    }
    /// A closed shape that paints nothing (no fill, no stroke): an invisible
    /// hover target, such as a `fill = NA` rect. Painting backends ignore it; the
    /// display list records its geometry as a pick-only mark (VR-17).
    fn pick_only_path(
        &mut self,
        _path: &Path,
        _transform: Transform,
        _rule: FillRule,
        _clip: &Clip,
    ) {
    }
    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip);
    fn begin_group(
        &mut self,
        mask: Option<MaskLayer>,
        alpha: f32,
        blend: BlendKind,
        effect: GroupEffect,
    );
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
    /// mapped to device by `transform`. `stroke` is `(colour, style)`. `keys`
    /// are the batch's per-element data keys (empty = unkeyed), handed over
    /// with the batch so a backend that wants them keeps the batch whole.
    ///
    /// The default places one unit circle per element -- or, for a keyed batch
    /// on a backend that emits keys (SVG), builds each circle in place and tags
    /// it with its key. The raster backend overrides this to stamp a sprite
    /// (rasterised per sub-pixel phase) for large uniform point clouds with a
    /// solid fill and/or a solid undashed stroke; the display-list
    /// backend records the batch as one point table.
    #[allow(clippy::too_many_arguments)]
    fn draw_circles(
        &mut self,
        cx: &[f64],
        cy: &[f64],
        r: &[f64],
        fill: Option<&ResolvedPaint>,
        stroke: Option<(Rgba, StrokeStyle)>,
        transform: Transform,
        clip: &Clip,
        keys: &[String],
    ) where
        Self: Sized,
    {
        if !keys.is_empty() && self.wants_element_keys() {
            circles_keyed(
                self,
                cx,
                cy,
                r,
                fill,
                stroke.as_ref(),
                transform,
                clip,
                keys,
            );
        } else {
            circles_by_path(self, cx, cy, r, fill, stroke.as_ref(), transform, clip);
        }
    }

    /// Announce that the primitives that follow, up to the next
    /// `set_element_key` or `begin_marker`, paint one point marker: glyph
    /// `shape` (the `points_grob()` code) of radius `r` centred at `(cx, cy)`,
    /// local px mapped by `transform`. Painting backends ignore it and draw the
    /// paths as usual; the display list records the marker itself.
    #[allow(clippy::too_many_arguments)]
    fn begin_marker(
        &mut self,
        _shape: u32,
        _cx: f64,
        _cy: f64,
        _r: f64,
        _transform: Transform,
        _clip: &Clip,
    ) {
    }

    /// Stroke a polyline / batch of disjoint segments (one `Path` whose subpaths
    /// are the lines). The default emits the single combined stroke; the raster
    /// backend overrides this with a per-segment fast path that avoids the
    /// superlinear winding-fill of a self-overlapping or many-subpath stroke
    /// outline. Vector backends keep the compact single-path form.
    fn stroke_lines(
        &mut self,
        path: &Path,
        transform: Transform,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    ) where
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

    /// Bracket the next primitive's output with semantic metadata. The SVG
    /// backend wraps the node in a `<g …>` carrying `data-*`/`role`; the PDF
    /// backend opens a tagged content span and records a structure-tree entry;
    /// raster ignores it. Always paired with `end_node`.
    ///
    /// The whole `NodeMeta` is passed rather than a pre-formatted attribute
    /// string because the two consumers need different things from it: SVG wants
    /// escaped XML attributes, PDF wants the role and label as separate values
    /// to build a `Tag` from.
    fn begin_node(&mut self, _meta: &NodeMeta) {}
    fn end_node(&mut self) {}

    /// Whether this backend consumes `begin_node`/`end_node` metadata at all.
    /// Default `false`, so the raster path does not pay to carry it.
    fn wants_node_meta(&self) -> bool {
        false
    }

    /// Set the per-element data key for the *next* primitive emitted (a batched
    /// node calls this before each element). The SVG backend splices it in as a
    /// `data-key="…"` attribute; raster/PDF ignore it. `None` clears it.
    fn set_element_key(&mut self, _key: Option<&str>) {}

    /// The top-level node index of the drawing node about to be emitted. Only
    /// the page walk calls it (a mask's content walk does not), so the display
    /// list can map its records back to the nodes a layer filter selects
    /// (VW-30, the flagged-marks layer). No-op for every painting backend.
    fn begin_draw_node(&mut self, _node: usize) {}

    /// Open a named panel group around the following primitives (paired with
    /// `end_panel`). The SVG backend wraps them in `<g data-vellum-panel="name">`
    /// (and, when `pannable`, an inner `<g data-vellum-pan>` with the clip hoisted
    /// to the outer group); raster/PDF ignore it.
    fn begin_panel(&mut self, _name: &str, _pannable: bool) {}
    fn end_panel(&mut self) {}

    /// Whether this backend emits per-element `data-key` attributes (only the SVG
    /// backend does). When false, the batched fast paths (solid circles, combined
    /// segments) stay on their fast path even for a keyed node — the keys would be
    /// ignored anyway — so raster/PDF output is pixel-identical whether or not a
    /// scene carries interactivity keys.
    fn wants_element_keys(&self) -> bool {
        false
    }

    /// Where the walk records each element's resolved geometry for the queries
    /// (`element_geometry()`, picking, hit-testing, boxes). `None` for every
    /// painting backend, so a render pays nothing; `geom::RecordBackend`
    /// returns its sink. See `geom.rs`.
    fn geom_sink(&mut self) -> Option<&mut crate::geom::GeomSink> {
        None
    }
}

/// The message of a caught panic (`&str` or `String` payload).
pub(crate) fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "an internal error in the PDF writer".to_string()
    }
}

/// Can a disc (a circle or a point marker) centred at `(cx, cy)` with radius
/// `r` be drawn? A missing size or position reaches the walk as `NaN` (an R
/// `NA`), and `r <= 0.0` is false for `NaN`, so the radius test must be
/// written this way round. Every backend then drops the same elements: the
/// raster backend skipped them silently, SVG wrote `NaN` paths, and krilla
/// panicked on them (VR-38).
pub(crate) fn drawable_disc(cx: f64, cy: f64, r: f64) -> bool {
    r > 0.0 && r.is_finite() && cx.is_finite() && cy.is_finite()
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
        if !drawable_disc(cx[i], cy[i], rr) {
            continue;
        }
        let tr = transform.pre_concat(Transform::from_row(
            rr as f32,
            0.0,
            0.0,
            rr as f32,
            cx[i] as f32,
            cy[i] as f32,
        ));
        let scaled = stroke.map(|(c, st)| {
            let scaled = StrokeStyle {
                width: st.width / rr as f32,
                dash: st.dash.iter().map(|d| d / rr as f32).collect(),
                cap: st.cap,
                join: st.join,
                miter: st.miter,
                crisp: st.crisp,
                paint: st.paint.clone(),
                phase: st.phase / rr as f32,
            };
            (*c, scaled)
        });
        match (fill, scaled) {
            (Some(f), Some((c, st)))
                if st.width > 0.0 && !matches!(f, ResolvedPaint::Hatch { .. }) =>
            {
                b.fill_and_stroke_path(&unit, tr, f, FillRule::Winding, c, &st, clip);
            }
            (f, st) => {
                if let Some(f) = f {
                    b.fill_path(&unit, tr, f, FillRule::Winding, clip);
                }
                if let Some((c, st)) = st {
                    b.stroke_path(&unit, tr, c, &st, clip);
                }
            }
        }
    }
}

/// A keyed circle batch on a backend that emits keys: each circle built at its
/// own coordinates and tagged with its key. Exactly the per-element build the
/// walk used before keys travelled with the batch, so SVG output is unchanged.
#[allow(clippy::too_many_arguments)]
fn circles_keyed<B: RenderBackend>(
    b: &mut B,
    cx: &[f64],
    cy: &[f64],
    r: &[f64],
    fill: Option<&ResolvedPaint>,
    stroke: Option<&(Rgba, StrokeStyle)>,
    transform: Transform,
    clip: &Clip,
    keys: &[String],
) {
    let n = cx.len().min(cy.len()).min(r.len());
    let pen = stroke.filter(|(_, s)| s.width > 0.0);
    for i in 0..n {
        b.set_element_key(keys.get(i).map(String::as_str).filter(|k| !k.is_empty()));
        let mut pb = PathBuilder::new();
        pb.push_circle(cx[i] as f32, cy[i] as f32, r[i] as f32);
        let Some(path) = pb.finish() else { continue };
        match (fill, pen) {
            (Some(rp), Some((col, style))) if !matches!(rp, ResolvedPaint::Hatch { .. }) => {
                b.fill_and_stroke_path(&path, transform, rp, FillRule::Winding, *col, style, clip);
            }
            (fill, pen) => {
                if let Some(rp) = fill {
                    b.fill_path(&path, transform, rp, FillRule::Winding, clip);
                }
                if let Some((col, style)) = pen {
                    b.stroke_path(&path, transform, *col, style, clip);
                }
            }
        }
    }
}

fn unit_circle_path() -> Path {
    let mut pb = PathBuilder::new();
    pb.push_circle(0.0, 0.0, 1.0);
    pb.finish().expect("unit circle path")
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
        *p = tiny_skia::ColorU8::from_rgba(
            tile[4 * i],
            tile[4 * i + 1],
            tile[4 * i + 2],
            tile[4 * i + 3],
        )
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

/// Coverage byte a mask contributes for one (demultiplied) pixel: its alpha, or
/// its Rec.709 luminance. Shared by the SVG (`mask_png`) and PDF (`mask_gray_rgba`)
/// mask encoders so the two backends can't drift in how they read coverage.
fn mask_coverage(c: tiny_skia::ColorU8, kind: MaskKind) -> u8 {
    match kind {
        MaskKind::Alpha => c.alpha(),
        MaskKind::Luminance => {
            (0.2126 * c.red() as f32 + 0.7152 * c.green() as f32 + 0.0722 * c.blue() as f32).round()
                as u8
        }
    }
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
