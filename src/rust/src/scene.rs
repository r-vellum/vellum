//! The scene graph and its rasterization to a tiny-skia pixmap.
//!
//! The scene holds a **tree of viewports** (an arena) and a flat list of
//! primitives, each tagged with the viewport it was drawn into. A layout pass
//! ([`Scene::resolve_all`]) walks the tree top-down, computing each viewport's
//! affine transform (placement + rotation), its size, its accumulated graphical
//! parameters, and its clip mask — then rendering draws each primitive in its
//! viewport's local pixels through that transform and clip.
//!
//! The `Scene` is held in Rust and exposed to R as an external-pointer object.

use extendr_api::prelude::*;
use tiny_skia::{FillRule, PathBuilder, Pixmap, Transform};

use crate::render::{
    rect_path, Clip, ClipRect, MaskKind, MaskLayer, PdfBackend, RasterBackend, RenderBackend, ResolvedPaint,
    StrokeStyle, SvgBackend, TextRun,
};

use crate::color::{opt_color, Gpar, GparAcc, Paint, PartialGpar, Rgba};
use crate::units::{rotation_about, Unit, Vp};

// --- layout ----------------------------------------------------------------

/// A layout track size: an absolute extent, or a flexible (`null`) weight.
#[derive(Clone, Copy, Debug)]
enum Track {
    Abs(f64, Unit),
    Null(f64),
}

#[derive(Clone, Debug)]
struct Layout {
    widths: Vec<Track>,  // columns
    heights: Vec<Track>, // rows
}

/// Pixel extent of one absolute track within `total` parent pixels.
fn track_abs_px(value: f64, u: Unit, total: f64, dpi: f64) -> f64 {
    match u {
        Unit::Npc | Unit::Native => value * total,
        Unit::Mm => value / 25.4 * dpi,
        Unit::Inch => value * dpi,
        Unit::Pt => value / 72.0 * dpi,
    }
}

/// Solve a list of tracks against `total` pixels into cumulative edge positions
/// (length `tracks.len() + 1`, starting at 0).
fn solve_tracks(tracks: &[Track], total: f64, dpi: f64) -> Vec<f64> {
    let mut sizes = vec![0.0; tracks.len()];
    let mut abs_sum = 0.0;
    let mut weight_sum = 0.0;
    for (i, t) in tracks.iter().enumerate() {
        match t {
            Track::Abs(v, u) => {
                sizes[i] = track_abs_px(*v, *u, total, dpi);
                abs_sum += sizes[i];
            }
            Track::Null(w) => weight_sum += w.max(0.0),
        }
    }
    let avail = (total - abs_sum).max(0.0);
    for (i, t) in tracks.iter().enumerate() {
        if let Track::Null(w) = t {
            sizes[i] = if weight_sum > 0.0 {
                avail * w.max(0.0) / weight_sum
            } else {
                0.0
            };
        }
    }
    let mut edges = vec![0.0; tracks.len() + 1];
    for i in 0..tracks.len() {
        edges[i + 1] = edges[i] + sizes[i];
    }
    edges
}

// --- viewport tree ----------------------------------------------------------

/// How a viewport is positioned within its parent.
#[derive(Clone, Copy, Debug)]
enum Placement {
    /// Centre `(cx, cy)` and size `(w, h)` in parent coordinates, each with its
    /// own unit.
    Absolute { cx: f64, cy: f64, w: f64, h: f64, cxu: Unit, cyu: Unit, wu: Unit, hu: Unit },
    /// A cell (0-based) of the parent's layout, possibly spanning.
    Cell { row: usize, col: usize, rowspan: usize, colspan: usize },
}

#[derive(Clone, Debug)]
struct ViewportNode {
    parent: Option<usize>,
    children: Vec<usize>,
    placement: Placement,
    xscale: (f64, f64),
    yscale: (f64, f64),
    angle: f64,
    clip: bool,
    gp: PartialGpar,
    layout: Option<Layout>,
}

/// A viewport after the layout pass: its local frame and effective context.
/// `clip_chain` is the list of clipping-ancestor rectangles to intersect
/// (empty = no clip); backends turn it into a mask / `<clipPath>` / PDF clip.
#[derive(Clone)]
struct ResolvedVp {
    vp: Vp,
    gp_acc: GparAcc,
    clip_chain: Vec<ClipRect>,
}

// --- primitives -------------------------------------------------------------

#[derive(Clone, Debug)]
enum Node {
    Rect { x: f64, y: f64, w: f64, h: f64, xu: Unit, yu: Unit, wu: Unit, hu: Unit, gp: PartialGpar },
    Lines { x: Vec<f64>, y: Vec<f64>, xu: Vec<Unit>, yu: Vec<Unit>, gp: PartialGpar },
    Polygon { x: Vec<f64>, y: Vec<f64>, xu: Vec<Unit>, yu: Vec<Unit>, gp: PartialGpar },
    Circle { x: f64, y: f64, r: f64, xu: Unit, yu: Unit, ru: Unit, gp: PartialGpar },
    Text {
        x: f64,
        y: f64,
        xu: Unit,
        yu: Unit,
        rot: f64,
        hjust: f64,
        vjust: f64,
        w: f64,
        h: f64,
        gid: Vec<u32>,
        gx: Vec<f64>,
        gy: Vec<f64>,
        gsize: Vec<f64>,
        gpath: Vec<String>,
        gface: Vec<u32>,
        /// Source string + font descriptor, for vector backends that emit real
        /// `<text>` / embedded glyphs rather than filled outlines.
        label: String,
        family: String,
        face: String,
        size: f64,
        gp: PartialGpar,
    },
    /// A batch of rectangles sharing one gpar (one FFI call, one resolve).
    Rects {
        x: Vec<f64>, y: Vec<f64>, w: Vec<f64>, h: Vec<f64>,
        xu: Vec<Unit>, yu: Vec<Unit>, wu: Vec<Unit>, hu: Vec<Unit>,
        gp: PartialGpar,
    },
    /// A batch of circles sharing one gpar (also serves `points`). Markers with a
    /// solid/no fill take a fast path (one path, per-element transform).
    Circles {
        x: Vec<f64>, y: Vec<f64>, r: Vec<f64>,
        xu: Vec<Unit>, yu: Vec<Unit>, ru: Vec<Unit>,
        gp: PartialGpar,
    },
    /// A batch of disjoint line segments `(x0,y0)->(x1,y1)`, stroked in one pass.
    Segments {
        x0: Vec<f64>, y0: Vec<f64>, x1: Vec<f64>, y1: Vec<f64>,
        x0u: Vec<Unit>, y0u: Vec<Unit>, x1u: Vec<Unit>, y1u: Vec<Unit>,
        gp: PartialGpar,
    },
    /// A general path: `nper` gives the point count of each closed sub-path
    /// (consecutive runs of `x`/`y`), filled by the winding or even-odd rule.
    Path {
        x: Vec<f64>, y: Vec<f64>, xu: Vec<Unit>, yu: Vec<Unit>,
        nper: Vec<usize>,
        evenodd: bool,
        gp: PartialGpar,
    },
    /// A straight-RGBA image (`iw` x `ih`, top-left) filling a `w` x `h` cell
    /// centred at `(x, y)`. Carries no gpar (handled in the walk's pre-pass).
    Image {
        rgba: Vec<u8>, iw: u32, ih: u32,
        x: f64, y: f64, w: f64, h: f64,
        xu: Unit, yu: Unit, wu: Unit, hu: Unit,
        interpolate: bool,
    },
    /// Opens an isolated compositing layer (paired with `GroupEnd`).
    GroupStart,
    /// Closes the layer and composites it, optionally through mask `mask` (an
    /// index into `Scene::masks`).
    GroupEnd { mask: Option<usize> },
}

impl Node {
    fn gp(&self) -> &PartialGpar {
        match self {
            Node::Rect { gp, .. }
            | Node::Lines { gp, .. }
            | Node::Polygon { gp, .. }
            | Node::Circle { gp, .. }
            | Node::Rects { gp, .. }
            | Node::Circles { gp, .. }
            | Node::Segments { gp, .. }
            | Node::Path { gp, .. }
            | Node::Text { gp, .. } => gp,
            Node::Image { .. } | Node::GroupStart | Node::GroupEnd { .. } => {
                unreachable!("handled before gpar resolution")
            }
        }
    }
}

/// A mask attached to a viewport: the grob content to rasterize plus how its
/// pixels modulate coverage. Filled while the mask grob is compiled.
#[derive(Clone, Debug)]
struct MaskDef {
    kind: MaskKind,
    nodes: Vec<(usize, Node)>,
}

/// A drawing scene held in the Rust backend. Internal: the public R API is the
/// S7 layer (`vl_scene()`, grobs, `render()`), which compiles to this object.
#[extendr]
#[derive(Clone, Debug)]
pub struct Scene {
    w_px: u32,
    h_px: u32,
    dpi: f64,
    bg: Rgba,
    viewports: Vec<ViewportNode>,
    current: usize,
    nodes: Vec<(usize, Node)>,
    /// Mask definitions, referenced by index from `Node::GroupEnd`.
    masks: Vec<MaskDef>,
    /// Stack of mask indices currently being filled (nested mask compilation);
    /// while non-empty, new primitives are routed to the top mask's content.
    mask_target: Vec<usize>,
}

#[extendr]
impl Scene {
    /// Create a scene `width` x `height` inches at `dpi`, with background `bg`
    /// (a length-4 integer RGBA vector). A root viewport covering the whole page
    /// (npc == native) is created as viewport 0.
    fn new(width: f64, height: f64, dpi: f64, bg: Robj) -> Self {
        if !(width.is_finite() && height.is_finite() && dpi.is_finite())
            || width <= 0.0
            || height <= 0.0
            || dpi <= 0.0
        {
            throw_r_error("scene width, height, and dpi must be finite and positive");
        }
        let w_px = px_dim(width * dpi);
        let h_px = px_dim(height * dpi);
        let root = ViewportNode {
            parent: None,
            children: Vec::new(),
            placement: Placement::Absolute {
                cx: 0.5,
                cy: 0.5,
                w: 1.0,
                h: 1.0,
                cxu: Unit::Npc,
                cyu: Unit::Npc,
                wu: Unit::Npc,
                hu: Unit::Npc,
            },
            xscale: (0.0, 1.0),
            yscale: (0.0, 1.0),
            angle: 0.0,
            clip: false,
            gp: PartialGpar::from_robj(&rnull(), &rnull(), &rnull(), &rnull(), &rnull()),
            layout: None,
        };
        Scene {
            w_px,
            h_px,
            dpi,
            bg: opt_color(&bg).unwrap_or(Rgba::WHITE),
            viewports: vec![root],
            current: 0,
            nodes: Vec::new(),
            masks: Vec::new(),
            mask_target: Vec::new(),
        }
    }

    /// Push a viewport as a child of the current one and make it current.
    /// Returns the new viewport's id. If `lrow`/`lcol` are >= 0 the viewport is
    /// placed into that (0-based) cell of the parent's layout; otherwise it is
    /// placed by centre/size in parent coordinates.
    #[allow(clippy::too_many_arguments)]
    fn push_viewport(
        &mut self,
        cx: f64,
        cy: f64,
        w: f64,
        h: f64,
        cxu: i32,
        cyu: i32,
        wu: i32,
        hu: i32,
        xscale: &[f64],
        yscale: &[f64],
        angle: f64,
        clip: bool,
        lrow: i32,
        lcol: i32,
        lrowspan: i32,
        lcolspan: i32,
        fill: Robj,
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
    ) -> i32 {
        let placement = if lrow >= 0 && lcol >= 0 {
            Placement::Cell {
                row: lrow as usize,
                col: lcol as usize,
                rowspan: lrowspan.max(1) as usize,
                colspan: lcolspan.max(1) as usize,
            }
        } else {
            Placement::Absolute {
                cx,
                cy,
                w,
                h,
                cxu: Unit::from_code(cxu),
                cyu: Unit::from_code(cyu),
                wu: Unit::from_code(wu),
                hu: Unit::from_code(hu),
            }
        };
        let id = self.viewports.len();
        self.viewports.push(ViewportNode {
            parent: Some(self.current),
            children: Vec::new(),
            placement,
            xscale: pair(xscale, (0.0, 1.0)),
            yscale: pair(yscale, (0.0, 1.0)),
            angle,
            clip,
            gp: PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke),
            layout: None,
        });
        self.viewports[self.current].children.push(id);
        self.current = id;
        id as i32
    }

    /// Move the cursor up `n` levels (towards the root). Stops at the root.
    fn pop_viewport(&mut self, n: i32) {
        for _ in 0..n.max(0) {
            if let Some(p) = self.viewports[self.current].parent {
                self.current = p;
            }
        }
    }

    /// Move the cursor to the root viewport.
    fn to_root(&mut self) {
        self.current = 0;
    }

    /// Attach a row/column layout to the current viewport. Tracks are given as
    /// parallel value + unit-code vectors; the unit `"null"` marks a flexible
    /// track whose value is its weight.
    fn set_layout(&mut self, wvals: &[f64], wunits: Vec<String>, hvals: &[f64], hunits: Vec<String>) {
        let widths = build_tracks(wvals, &wunits);
        let heights = build_tracks(hvals, &hunits);
        self.viewports[self.current].layout = Some(Layout { widths, heights });
    }

    #[allow(clippy::too_many_arguments)]
    fn rect(&mut self, x: f64, y: f64, w: f64, h: f64, xu: i32, yu: i32, wu: i32, hu: i32, fill: Robj, col: Robj, lwd: Robj, alpha: Robj, stroke: Robj) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Rect {
            x,
            y,
            w,
            h,
            xu: Unit::from_code(xu),
            yu: Unit::from_code(yu),
            wu: Unit::from_code(wu),
            hu: Unit::from_code(hu),
            gp,
        });
    }

    fn lines(&mut self, x: &[f64], y: &[f64], xu: &[i32], yu: &[i32], col: Robj, lwd: Robj, alpha: Robj, stroke: Robj) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Lines { x: x.to_vec(), y: y.to_vec(), xu: codes(xu), yu: codes(yu), gp });
    }

    #[allow(clippy::too_many_arguments)]
    fn polygon(&mut self, x: &[f64], y: &[f64], xu: &[i32], yu: &[i32], fill: Robj, col: Robj, lwd: Robj, alpha: Robj, stroke: Robj) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Polygon { x: x.to_vec(), y: y.to_vec(), xu: codes(xu), yu: codes(yu), gp });
    }

    #[allow(clippy::too_many_arguments)]
    fn circle(&mut self, x: f64, y: f64, r: f64, xu: i32, yu: i32, ru: i32, fill: Robj, col: Robj, lwd: Robj, alpha: Robj, stroke: Robj) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Circle { x, y, r, xu: Unit::from_code(xu), yu: Unit::from_code(yu), ru: Unit::from_code(ru), gp });
    }

    /// A whole batch of rectangles in one call, sharing one gpar. Coordinates and
    /// per-coordinate unit codes are parallel slices.
    #[allow(clippy::too_many_arguments)]
    fn rects(
        &mut self, x: &[f64], y: &[f64], w: &[f64], h: &[f64],
        xu: &[i32], yu: &[i32], wu: &[i32], hu: &[i32],
        fill: Robj, col: Robj, lwd: Robj, alpha: Robj, stroke: Robj,
    ) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Rects {
            x: x.to_vec(), y: y.to_vec(), w: w.to_vec(), h: h.to_vec(),
            xu: codes(xu), yu: codes(yu), wu: codes(wu), hu: codes(hu), gp,
        });
    }

    /// A whole batch of circles in one call, sharing one gpar (also used for
    /// `points`, with the radius carrying the marker size).
    #[allow(clippy::too_many_arguments)]
    fn circles(
        &mut self, x: &[f64], y: &[f64], r: &[f64],
        xu: &[i32], yu: &[i32], ru: &[i32],
        fill: Robj, col: Robj, lwd: Robj, alpha: Robj, stroke: Robj,
    ) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Circles {
            x: x.to_vec(), y: y.to_vec(), r: r.to_vec(),
            xu: codes(xu), yu: codes(yu), ru: codes(ru), gp,
        });
    }

    /// A batch of disjoint line segments (stroke only), sharing one gpar.
    #[allow(clippy::too_many_arguments)]
    fn segments(
        &mut self, x0: &[f64], y0: &[f64], x1: &[f64], y1: &[f64],
        x0u: &[i32], y0u: &[i32], x1u: &[i32], y1u: &[i32],
        col: Robj, lwd: Robj, alpha: Robj, stroke: Robj,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Segments {
            x0: x0.to_vec(), y0: y0.to_vec(), x1: x1.to_vec(), y1: y1.to_vec(),
            x0u: codes(x0u), y0u: codes(y0u), x1u: codes(x1u), y1u: codes(y1u), gp,
        });
    }

    /// A general path. `nper` gives the number of points in each closed sub-path
    /// (so holes are sub-paths under the even-odd or winding rule).
    #[allow(clippy::too_many_arguments)]
    fn path(
        &mut self, x: &[f64], y: &[f64], xu: &[i32], yu: &[i32], nper: &[i32],
        evenodd: bool, fill: Robj, col: Robj, lwd: Robj, alpha: Robj, stroke: Robj,
    ) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Path {
            x: x.to_vec(), y: y.to_vec(), xu: codes(xu), yu: codes(yu),
            nper: nper.iter().map(|&v| v.max(0) as usize).collect(),
            evenodd, gp,
        });
    }

    /// A raster image: `rgba` is a flat straight-RGBA integer vector (`iw` x `ih`,
    /// top-left, 4 per pixel), drawn into a `w` x `h` cell centred at `(x, y)`.
    #[allow(clippy::too_many_arguments)]
    fn image(
        &mut self, rgba: &[i32], iw: i32, ih: i32,
        x: f64, y: f64, w: f64, h: f64, xu: i32, yu: i32, wu: i32, hu: i32,
        interpolate: bool,
    ) {
        let bytes: Vec<u8> = rgba.iter().map(|&v| v.clamp(0, 255) as u8).collect();
        self.emit_node(Node::Image {
            rgba: bytes, iw: iw.max(0) as u32, ih: ih.max(0) as u32,
            x, y, w, h,
            xu: Unit::from_code(xu), yu: Unit::from_code(yu), wu: Unit::from_code(wu), hu: Unit::from_code(hu),
            interpolate,
        });
    }

    /// Add pre-shaped text. The R wrapper does shaping (via `textshaping`) and
    /// passes per-glyph ids/positions/fonts plus the block size.
    #[allow(clippy::too_many_arguments)]
    fn text(
        &mut self,
        x: f64,
        y: f64,
        xu: i32,
        yu: i32,
        rot: f64,
        hjust: f64,
        vjust: f64,
        w: f64,
        h: f64,
        gid: &[i32],
        gx: &[f64],
        gy: &[f64],
        gsize: &[f64],
        gpath: Vec<String>,
        gface: &[i32],
        label: &str,
        family: &str,
        face: &str,
        size: f64,
        col: Robj,
        alpha: Robj,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &rnull(), &alpha, &rnull());
        self.emit_node(Node::Text {
            x,
            y,
            xu: Unit::from_code(xu),
            yu: Unit::from_code(yu),
            rot,
            hjust,
            vjust,
            w,
            h,
            gid: gid.iter().map(|&v| v.max(0) as u32).collect(),
            gx: gx.to_vec(),
            gy: gy.to_vec(),
            gsize: gsize.to_vec(),
            gpath,
            gface: gface.iter().map(|&v| v.max(0) as u32).collect(),
            label: label.to_string(),
            family: family.to_string(),
            face: face.to_string(),
            size,
            gp,
        });
    }

    /// Begin collecting a mask's content for the current viewport. Until the
    /// matching `mask_end`, primitives are routed into the mask instead of the
    /// drawn scene. `kind` is 0 (alpha) or 1 (luminance). Returns its index.
    fn mask_begin(&mut self, kind: i32) -> i32 {
        let idx = self.masks.len();
        self.masks.push(MaskDef { kind: MaskKind::from_code(kind), nodes: Vec::new() });
        self.mask_target.push(idx);
        idx as i32
    }

    /// Stop routing primitives into the most recent mask.
    fn mask_end(&mut self) {
        self.mask_target.pop();
    }

    /// Open an isolated compositing group. Routed through `emit_node` so a group
    /// nested inside a mask (a mask grob that itself masks a viewport) lands in
    /// the same node list as its content, keeping markers and content in sync.
    fn group_start(&mut self) {
        self.emit_node(Node::GroupStart);
    }

    /// Close the group, compositing it through mask index `mask` (negative = no
    /// mask, just isolation).
    fn group_end(&mut self, mask: i32) {
        let mask = if mask >= 0 { Some(mask as usize) } else { None };
        self.emit_node(Node::GroupEnd { mask });
    }

    /// Number of primitives currently in the scene.
    fn len(&self) -> i32 {
        self.nodes.len() as i32
    }

    /// Device dimensions in pixels, `c(width, height)`.
    fn dim(&self) -> Vec<i32> {
        vec![self.w_px as i32, self.h_px as i32]
    }

    /// Device resolution in dots per inch.
    fn dpi(&self) -> f64 {
        self.dpi
    }

    /// Render the scene to a PNG file.
    fn render_png(&self, path: &str) {
        let pm = self.rasterize();
        if let Err(e) = pm.save_png(path) {
            throw_r_error(format!("failed to write PNG: {e}"));
        }
    }

    /// Render the scene to an SVG file.
    fn render_svg(&self, path: &str) {
        let mut b = SvgBackend::new(self.w_px, self.h_px, self.bg);
        self.render_to(&mut b);
        if let Err(e) = std::fs::write(path, b.into_string()) {
            throw_r_error(format!("failed to write SVG: {e}"));
        }
    }

    /// Render the scene to a PDF file.
    fn render_pdf(&self, path: &str) {
        let scale = 72.0 / self.dpi as f32;
        let w_pt = self.w_px as f32 * scale;
        let h_pt = self.h_px as f32 * scale;
        let mut doc = krilla::Document::new();
        let settings = match krilla::page::PageSettings::from_wh(w_pt, h_pt) {
            Some(s) => s,
            None => throw_r_error("invalid PDF page size"),
        };
        let mut page = doc.start_page_with(settings);
        let mut surface = page.surface();
        // One root transform maps device pixels -> PDF points.
        surface.push_transform(&krilla::geom::Transform::from_scale(scale, scale));
        {
            let mut b = PdfBackend::new(&mut surface);
            b.fill_background(self.w_px, self.h_px, self.bg);
            self.render_to(&mut b);
        }
        surface.pop();
        surface.finish();
        page.finish();
        match doc.finish() {
            Ok(bytes) => {
                if let Err(e) = std::fs::write(path, bytes) {
                    throw_r_error(format!("failed to write PDF: {e}"));
                }
            }
            Err(e) => throw_r_error(format!("failed to serialize PDF: {e}")),
        }
    }

    /// Render and return the whole image as row-major RGBA bytes
    /// `[r, g, b, a, ...]` (top-left origin, x fastest).
    fn rgba(&self) -> Vec<i32> {
        let pm = self.rasterize();
        let mut out = Vec::with_capacity((self.w_px as usize) * (self.h_px as usize) * 4);
        for p in pm.pixels() {
            let c = p.demultiply();
            out.push(c.red() as i32);
            out.push(c.green() as i32);
            out.push(c.blue() as i32);
            out.push(c.alpha() as i32);
        }
        out
    }

    /// Render and return the RGBA of device pixel `(x, y)` as `c(r, g, b, a)`.
    fn pixel(&self, x: i32, y: i32) -> Vec<i32> {
        let pm = self.rasterize();
        if x < 0 || y < 0 || x as u32 >= self.w_px || y as u32 >= self.h_px {
            throw_r_error("pixel out of bounds");
        }
        match pm.pixel(x as u32, y as u32) {
            Some(p) => {
                let c = p.demultiply();
                vec![c.red() as i32, c.green() as i32, c.blue() as i32, c.alpha() as i32]
            }
            None => throw_r_error("pixel out of bounds"),
        }
    }
}

impl Scene {
    /// Append a primitive to the current draw target: the mask being filled (if
    /// any), else the drawn scene. Tagged with the current viewport.
    fn emit_node(&mut self, node: Node) {
        let vp = self.current;
        match self.mask_target.last() {
            Some(&mi) => self.masks[mi].nodes.push((vp, node)),
            None => self.nodes.push((vp, node)),
        }
    }

    /// Resolve every viewport (transform, size, accumulated gpar, clip mask).
    /// DFS from the root guarantees a parent is resolved before its children.
    fn resolve_all(&self) -> Vec<ResolvedVp> {
        let n = self.viewports.len();
        let mut out: Vec<Option<ResolvedVp>> = vec![None; n];

        // Root: identity transform, whole page.
        let root = &self.viewports[0];
        let root_vp = Vp {
            transform: Transform::identity(),
            w: self.w_px as f64,
            h: self.h_px as f64,
            xscale: root.xscale,
            yscale: root.yscale,
            dpi: self.dpi,
        };
        let root_clip = if root.clip {
            vec![ClipRect { w: self.w_px as f64, h: self.h_px as f64, transform: Transform::identity() }]
        } else {
            Vec::new()
        };
        out[0] = Some(ResolvedVp {
            vp: root_vp,
            gp_acc: GparAcc::root_default().apply(&root.gp),
            clip_chain: root_clip,
        });

        let mut stack: Vec<usize> = root.children.iter().rev().copied().collect();
        while let Some(id) = stack.pop() {
            let node = &self.viewports[id];
            let parent = out[node.parent.unwrap()].clone().unwrap();
            out[id] = Some(self.resolve_one(node, &parent));
            for &c in node.children.iter().rev() {
                stack.push(c);
            }
        }

        out.into_iter().map(|r| r.expect("all viewports resolved")).collect()
    }

    fn resolve_one(&self, node: &ViewportNode, parent: &ResolvedVp) -> ResolvedVp {
        // Child rectangle in PARENT-local pixels.
        let (x0, top, cw, ch) = match node.placement {
            Placement::Absolute { cx, cy, w, h, cxu, cyu, wu, hu } => {
                let cw = parent.vp.x_len(w, wu);
                let ch = parent.vp.y_len(h, hu);
                let center_x = parent.vp.x_pos(cx, cxu);
                let center_y = parent.vp.y_pos(cy, cyu);
                (center_x - cw / 2.0, center_y - ch / 2.0, cw, ch)
            }
            Placement::Cell { row, col, rowspan, colspan } => {
                let empty = Layout { widths: vec![], heights: vec![] };
                let layout = self.viewports[node.parent.unwrap()].layout.as_ref().unwrap_or(&empty);
                let xe = solve_tracks(&layout.widths, parent.vp.w, self.dpi);
                let ye = solve_tracks(&layout.heights, parent.vp.h, self.dpi);
                let cstart = col.min(xe.len().saturating_sub(1));
                let cend = (col + colspan).min(xe.len().saturating_sub(1));
                let rstart = row.min(ye.len().saturating_sub(1));
                let rend = (row + rowspan).min(ye.len().saturating_sub(1));
                let x0 = xe.get(cstart).copied().unwrap_or(0.0);
                let top = ye.get(rstart).copied().unwrap_or(0.0);
                (
                    x0,
                    top,
                    (xe.get(cend).copied().unwrap_or(x0) - x0).max(0.0),
                    (ye.get(rend).copied().unwrap_or(top) - top).max(0.0),
                )
            }
        };

        let transform = parent
            .vp
            .transform
            .pre_concat(Transform::from_translate(x0 as f32, top as f32))
            .pre_concat(rotation_about(node.angle, cw / 2.0, ch / 2.0));

        // Invariant: viewport transforms are isometries (translation + rotation),
        // so stroke widths are preserved. Catch any accidental scaling early.
        #[cfg(debug_assertions)]
        {
            let sxl = (transform.sx * transform.sx + transform.ky * transform.ky).sqrt();
            let syl = (transform.kx * transform.kx + transform.sy * transform.sy).sqrt();
            debug_assert!(
                (sxl - 1.0).abs() < 1e-3 && (syl - 1.0).abs() < 1e-3,
                "viewport transform must be isometric (no scale)"
            );
        }

        let vp = Vp {
            transform,
            w: cw,
            h: ch,
            xscale: node.xscale,
            yscale: node.yscale,
            dpi: self.dpi,
        };

        let mut clip_chain = parent.clip_chain.clone();
        if node.clip {
            clip_chain.push(ClipRect { w: cw, h: ch, transform });
        }

        ResolvedVp {
            vp,
            gp_acc: parent.gp_acc.apply(&node.gp),
            clip_chain,
        }
    }

    fn rasterize(&self) -> Pixmap {
        let mut b = RasterBackend::new(self.w_px, self.h_px, self.bg);
        self.render_to(&mut b);
        b.into_pixmap()
    }

    /// Walk the resolved scene in paint order, emitting each primitive through a
    /// [`RenderBackend`]. Geometry resolution (transform, clip, gpar, path) is
    /// shared; only the per-primitive draw calls are backend-specific.
    fn render_to<B: RenderBackend>(&self, b: &mut B) {
        let resolved = self.resolve_all();
        self.render_nodes(b, &resolved, &self.nodes);
    }

    /// Render an ordered node list (the scene, or a mask's content) onto `b`.
    /// Group markers open/close isolated layers; a closing mask is rasterized
    /// (always to a `RasterBackend`) and handed to `end_group`.
    fn render_nodes<B: RenderBackend>(&self, b: &mut B, resolved: &[ResolvedVp], nodes: &[(usize, Node)]) {
        for (vp_id, node) in nodes {
            match node {
                Node::GroupStart => {
                    b.begin_group();
                    continue;
                }
                Node::GroupEnd { mask } => {
                    match mask.and_then(|m| self.masks.get(m)) {
                        Some(md) => {
                            let mut mb = RasterBackend::new(self.w_px, self.h_px, Rgba { r: 0, g: 0, b: 0, a: 0 });
                            self.render_nodes(&mut mb, resolved, &md.nodes);
                            let mpm = mb.into_pixmap();
                            b.end_group(Some(MaskLayer { pixmap: &mpm, kind: md.kind }));
                        }
                        None => b.end_group(None),
                    }
                    continue;
                }
                // Images carry no gpar; resolve geometry and draw directly.
                Node::Image { rgba, iw, ih, x, y, w, h, xu, yu, wu, hu, interpolate } => {
                    let rv = &resolved[*vp_id];
                    let vp = &rv.vp;
                    let clip = Clip { id: *vp_id, rects: &rv.clip_chain };
                    let cx = vp.x_pos(*x, *xu);
                    let cy = vp.y_pos(*y, *yu);
                    let pw = vp.x_len(*w, *wu);
                    let ph = vp.y_len(*h, *hu);
                    b.draw_image(rgba, *iw, *ih, cx, cy, pw, ph, *interpolate, vp.transform, &clip);
                    continue;
                }
                _ => {}
            }

            let rv = &resolved[*vp_id];
            let vp = &rv.vp;
            let gp = rv.gp_acc.apply(node.gp()).resolve();
            let t = vp.transform;
            let clip = Clip { id: *vp_id, rects: &rv.clip_chain };

            match node {
                Node::Rect { x, y, w, h, xu, yu, wu, hu, .. } => {
                    let cx = vp.x_pos(*x, *xu);
                    let cy = vp.y_pos(*y, *yu);
                    let pw = vp.x_len(*w, *wu);
                    let ph = vp.y_len(*h, *hu);
                    if let Some(path) = rect_path(cx - pw / 2.0, cy - ph / 2.0, pw, ph) {
                        fill_then_stroke(b, &path, &gp, t, &clip, vp, FillRule::Winding);
                    }
                }
                Node::Lines { x, y, xu, yu, .. } => {
                    if let (Some(path), Some(col)) = (build_poly(x, y, xu, yu, vp, false), gp.col) {
                        let style = stroke_style(&gp, vp.dpi);
                        if style.width > 0.0 {
                            b.stroke_path(&path, t, col, &style, &clip);
                        }
                    }
                }
                Node::Polygon { x, y, xu, yu, .. } => {
                    if let Some(path) = build_poly(x, y, xu, yu, vp, true) {
                        fill_then_stroke(b, &path, &gp, t, &clip, vp, FillRule::Winding);
                    }
                }
                Node::Circle { x, y, r, xu, yu, ru, .. } => {
                    let cx = vp.x_pos(*x, *xu);
                    let cy = vp.y_pos(*y, *yu);
                    let rr = vp.r_len(*r, *ru);
                    let mut pb = PathBuilder::new();
                    pb.push_circle(cx as f32, cy as f32, rr as f32);
                    if let Some(path) = pb.finish() {
                        fill_then_stroke(b, &path, &gp, t, &clip, vp, FillRule::Winding);
                    }
                }
                Node::Rects { x, y, w, h, xu, yu, wu, hu, .. } => {
                    let n = [x.len(), y.len(), w.len(), h.len(), xu.len(), yu.len(), wu.len(), hu.len()]
                        .into_iter().min().unwrap_or(0);
                    let lwd = gp.lwd_px(vp.dpi);
                    let stroke = gp.col.filter(|_| lwd > 0.0);
                    let rf = gp.fill.as_ref().map(|p| resolve_paint(p, vp)); // resolve gradient/pattern geom once
                    let solid = matches!(gp.fill, Some(Paint::Solid(_)) | None);
                    if solid && stroke.is_none() {
                        // Fast path: a single unit rect placed per-element by an
                        // affine transform (solid fill is transform-invariant).
                        if let Some(rp) = &rf {
                            let unit = unit_rect();
                            for i in 0..n {
                                let cx = vp.x_pos(x[i], xu[i]);
                                let cy = vp.y_pos(y[i], yu[i]);
                                let pw = vp.x_len(w[i], wu[i]);
                                let ph = vp.y_len(h[i], hu[i]);
                                if pw <= 0.0 || ph <= 0.0 {
                                    continue;
                                }
                                let tr = t.pre_concat(Transform::from_row(pw as f32, 0.0, 0.0, ph as f32, cx as f32, cy as f32));
                                b.fill_path(&unit, tr, rp, FillRule::Winding, &clip);
                            }
                        }
                    } else {
                        // Stroke (non-uniform scale would distort it) or a gradient
                        // that must be resolved in local px: build each rect.
                        let style = stroke_style(&gp, vp.dpi);
                        for i in 0..n {
                            let cx = vp.x_pos(x[i], xu[i]);
                            let cy = vp.y_pos(y[i], yu[i]);
                            let pw = vp.x_len(w[i], wu[i]);
                            let ph = vp.y_len(h[i], hu[i]);
                            if let Some(path) = rect_path(cx - pw / 2.0, cy - ph / 2.0, pw, ph) {
                                if let Some(rp) = &rf {
                                    b.fill_path(&path, t, rp, FillRule::Winding, &clip);
                                }
                                if let Some(c) = stroke {
                                    b.stroke_path(&path, t, c, &style, &clip);
                                }
                            }
                        }
                    }
                }
                Node::Circles { x, y, r, xu, yu, ru, .. } => {
                    let n = [x.len(), y.len(), r.len(), xu.len(), yu.len(), ru.len()]
                        .into_iter().min().unwrap_or(0);
                    let lwd = gp.lwd_px(vp.dpi);
                    let stroke = gp.col.filter(|_| lwd > 0.0);
                    let rf = gp.fill.as_ref().map(|p| resolve_paint(p, vp));
                    if matches!(gp.fill, Some(Paint::Solid(_)) | None) {
                        // Solid/no fill: resolve centres+radii to local px and hand
                        // the batch to the backend (raster may sprite-stamp).
                        let mut cx = Vec::with_capacity(n);
                        let mut cy = Vec::with_capacity(n);
                        let mut rr = Vec::with_capacity(n);
                        for i in 0..n {
                            cx.push(vp.x_pos(x[i], xu[i]));
                            cy.push(vp.y_pos(y[i], yu[i]));
                            rr.push(vp.r_len(r[i], ru[i]));
                        }
                        b.draw_circles(&cx, &cy, &rr, rf.as_ref(), stroke.map(|c| (c, stroke_style(&gp, vp.dpi))), t, &clip);
                    } else {
                        // Gradient/pattern fill: build each circle in local px.
                        let style = stroke_style(&gp, vp.dpi);
                        for i in 0..n {
                            let cx = vp.x_pos(x[i], xu[i]);
                            let cy = vp.y_pos(y[i], yu[i]);
                            let rr = vp.r_len(r[i], ru[i]);
                            let mut pb = PathBuilder::new();
                            pb.push_circle(cx as f32, cy as f32, rr as f32);
                            if let Some(path) = pb.finish() {
                                if let Some(rp) = &rf {
                                    b.fill_path(&path, t, rp, FillRule::Winding, &clip);
                                }
                                if let Some(c) = stroke {
                                    b.stroke_path(&path, t, c, &style, &clip);
                                }
                            }
                        }
                    }
                }
                Node::Text {
                    x, y, xu, yu, rot, hjust, vjust, w, h,
                    gid, gx, gy, gsize, gpath, gface, label, family, face, size, ..
                } => {
                    let color = match gp.col {
                        Some(c) => c,
                        None => continue,
                    };
                    let run = TextRun {
                        ax: vp.x_pos(*x, *xu),
                        ay: vp.y_pos(*y, *yu),
                        w: *w,
                        h: *h,
                        hjust: *hjust,
                        vjust: *vjust,
                        rot: *rot,
                        color,
                        gid,
                        gx,
                        gy,
                        gsize,
                        gpath,
                        gface,
                        label,
                        family,
                        face,
                        size: *size,
                        dpi: vp.dpi,
                    };
                    b.draw_text(&run, t, &clip);
                }
                Node::Segments { x0, y0, x1, y1, x0u, y0u, x1u, y1u, .. } => {
                    if let Some(col) = gp.col {
                        let style = stroke_style(&gp, vp.dpi);
                        if style.width > 0.0 {
                            let n = [x0.len(), y0.len(), x1.len(), y1.len(), x0u.len(), y0u.len(), x1u.len(), y1u.len()]
                                .into_iter().min().unwrap_or(0);
                            let mut pb = PathBuilder::new();
                            for i in 0..n {
                                pb.move_to(vp.x_pos(x0[i], x0u[i]) as f32, vp.y_pos(y0[i], y0u[i]) as f32);
                                pb.line_to(vp.x_pos(x1[i], x1u[i]) as f32, vp.y_pos(y1[i], y1u[i]) as f32);
                            }
                            if let Some(path) = pb.finish() {
                                b.stroke_path(&path, t, col, &style, &clip);
                            }
                        }
                    }
                }
                Node::Path { x, y, xu, yu, nper, evenodd, .. } => {
                    if let Some(path) = build_subpaths(x, y, xu, yu, nper, vp) {
                        let rule = if *evenodd { FillRule::EvenOdd } else { FillRule::Winding };
                        fill_then_stroke(b, &path, &gp, t, &clip, vp, rule);
                    }
                }
                Node::Image { .. } | Node::GroupStart | Node::GroupEnd { .. } => unreachable!("handled above"),
            }
        }
    }
}

/// A unit rect centred at the origin (`-0.5..0.5`), scaled per element in the
/// batched-rect solid fast path.
fn unit_rect() -> tiny_skia::Path {
    rect_path(-0.5, -0.5, 1.0, 1.0).expect("unit rect path")
}

/// Build a multi-subpath device path: `nper[k]` consecutive points form one
/// closed sub-path (so even-odd/winding rules give holes).
fn build_subpaths(x: &[f64], y: &[f64], xu: &[Unit], yu: &[Unit], nper: &[usize], vp: &Vp) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    let mut i = 0usize;
    for &cnt in nper {
        let end = i + cnt;
        if cnt >= 2 && end <= x.len() && end <= y.len() && end <= xu.len() && end <= yu.len() {
            pb.move_to(vp.x_pos(x[i], xu[i]) as f32, vp.y_pos(y[i], yu[i]) as f32);
            for k in (i + 1)..end {
                pb.line_to(vp.x_pos(x[k], xu[k]) as f32, vp.y_pos(y[k], yu[k]) as f32);
            }
            pb.close();
        }
        i = end;
    }
    pb.finish()
}

/// Fill then stroke a shape according to its effective gpar, using `rule` for the
/// fill. Gradient fill geometry is resolved against `vp` into viewport-local px.
fn fill_then_stroke<B: RenderBackend>(b: &mut B, path: &tiny_skia::Path, gp: &Gpar, t: Transform, clip: &Clip, vp: &Vp, rule: FillRule) {
    if let Some(fill) = &gp.fill {
        b.fill_path(path, t, &resolve_paint(fill, vp), rule, clip);
    }
    if let Some(col) = gp.col {
        let style = stroke_style(gp, vp.dpi);
        if style.width > 0.0 {
            b.stroke_path(path, t, col, &style, clip);
        }
    }
}

/// Build a device-space [`StrokeStyle`] from a resolved gpar. The dash nibbles are
/// scaled by the line width (grid's convention, so thicker lines get longer dashes).
fn stroke_style(gp: &Gpar, dpi: f64) -> StrokeStyle {
    let width = gp.lwd_px(dpi);
    let dash = match &gp.lty {
        Some(nibs) => nibs.iter().map(|n| n * width).collect(),
        None => Vec::new(),
    };
    StrokeStyle { width, dash, cap: gp.lineend, join: gp.linejoin, miter: gp.linemitre as f32 }
}

/// Resolve a paint's gradient geometry through the viewport into local px.
fn resolve_paint(paint: &Paint, vp: &Vp) -> ResolvedPaint {
    match paint {
        Paint::Solid(c) => ResolvedPaint::Solid(*c),
        Paint::Linear { x1, y1, x2, y2, unit, stops, extend } => ResolvedPaint::Linear {
            x1: vp.x_pos(*x1, *unit),
            y1: vp.y_pos(*y1, *unit),
            x2: vp.x_pos(*x2, *unit),
            y2: vp.y_pos(*y2, *unit),
            stops: stops.clone(),
            extend: *extend,
        },
        Paint::Radial { cx, cy, r, unit, stops, extend } => ResolvedPaint::Radial {
            cx: vp.x_pos(*cx, *unit),
            cy: vp.y_pos(*cy, *unit),
            r: vp.r_len(*r, *unit),
            stops: stops.clone(),
            extend: *extend,
        },
        Paint::Pattern(p) => ResolvedPaint::Pattern {
            tile: p.tile.clone(),
            tw: p.tw,
            th: p.th,
            x: vp.x_pos(p.x, p.unit),
            y: vp.y_pos(p.y, p.unit),
            w: vp.x_len(p.w, p.unit),
            h: vp.y_len(p.h, p.unit),
            extend: p.extend,
            opacity: p.opacity as f32,
        },
    }
}

fn build_poly(x: &[f64], y: &[f64], xu: &[Unit], yu: &[Unit], vp: &Vp, close: bool) -> Option<tiny_skia::Path> {
    let n = x.len().min(y.len()).min(xu.len()).min(yu.len());
    if n < 2 {
        return None;
    }
    let mut pb = PathBuilder::new();
    pb.move_to(vp.x_pos(x[0], xu[0]) as f32, vp.y_pos(y[0], yu[0]) as f32);
    for i in 1..n {
        pb.line_to(vp.x_pos(x[i], xu[i]) as f32, vp.y_pos(y[i], yu[i]) as f32);
    }
    if close {
        pb.close();
    }
    pb.finish()
}

fn build_tracks(vals: &[f64], units: &[String]) -> Vec<Track> {
    vals.iter()
        .enumerate()
        .map(|(i, &v)| {
            let u = units.get(i).map(String::as_str).unwrap_or("null");
            if u == "null" {
                Track::Null(v)
            } else {
                Track::Abs(v, Unit::parse(u))
            }
        })
        .collect()
}

fn pair(s: &[f64], default: (f64, f64)) -> (f64, f64) {
    if s.len() >= 2 && s[0].is_finite() && s[1].is_finite() && s[0] != s[1] {
        (s[0], s[1])
    } else {
        // A missing, non-finite, or zero-span scale would yield NaN/degenerate
        // native coordinates (which silently vanish); fall back to the default.
        default
    }
}

/// An R `NULL` as an `Robj` (used to mean "inherit" for gpar fields).
fn rnull() -> Robj {
    Robj::from(NULL)
}

/// Decode a slice of integer unit codes from R into `Unit`s (per element).
fn codes(c: &[i32]) -> Vec<Unit> {
    c.iter().map(|&v| Unit::from_code(v)).collect()
}

/// Convert a (finite, positive) dimension in pixels to a `u32`, at least 1 and
/// capped so we never attempt an absurd allocation. Callers validate finiteness.
fn px_dim(v: f64) -> u32 {
    let r = v.round().max(1.0);
    const MAX_DIM: f64 = 30000.0;
    if r > MAX_DIM {
        throw_r_error("scene dimension too large (max 30000 px per side)");
    }
    r as u32
}

extendr_module! {
    mod scene;
    impl Scene;
}
