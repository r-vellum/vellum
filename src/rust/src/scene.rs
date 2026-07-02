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

use std::collections::HashMap;

use extendr_api::prelude::*;
use tiny_skia::{Color, FillRule, Mask, PathBuilder, Pixmap, Stroke, Transform};

use crate::render::{
    hexagon_path, hexagon_path_xy, rect_path, roundrect_path, sector_path, BlendKind, Clip, ClipShape, MaskKind, MaskLayer, PdfBackend, RasterBackend, RenderBackend,
    ResolvedPaint, StrokeStyle, SvgBackend, TextRun,
};

use crate::color::{opt_color, Gpar, GparAcc, Lty, Paint, PartialGpar, Rgba};
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
    /// grid-style `respect`: equalize the physical size of a `null` width unit and
    /// a `null` height unit, centering the grid (see `solve_layout`).
    respect: bool,
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

/// Pixel sizes of a list of tracks within `total` parent pixels: absolute tracks
/// measured directly, `null` tracks sharing the remainder by weight.
fn track_sizes(tracks: &[Track], total: f64, dpi: f64) -> Vec<f64> {
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
    sizes
}

/// Cumulative edges (length `n + 1`, starting at 0) from track sizes.
fn edges_of(sizes: &[f64]) -> Vec<f64> {
    let mut edges = vec![0.0; sizes.len() + 1];
    for i in 0..sizes.len() {
        edges[i + 1] = edges[i] + sizes[i];
    }
    edges
}

/// Total `null` weight and current `null` pixel extent of an axis.
fn null_summary(tracks: &[Track], sizes: &[f64]) -> (f64, f64) {
    let mut weight = 0.0;
    let mut px = 0.0;
    for (i, t) in tracks.iter().enumerate() {
        if let Track::Null(w) = t {
            weight += w.max(0.0);
            px += sizes[i];
        }
    }
    (weight, px)
}

/// Solve both axes of a layout into cell edges plus a centering offset per axis.
///
/// With `layout.respect`, one unit of `null` width is forced to the same physical
/// size as one unit of `null` height (grid's `respect = TRUE`): the axis whose
/// null unit is larger shrinks its `null` tracks to match, and the freed space
/// centers the whole grid via the returned offset. Absolute tracks are untouched,
/// so gutters stay attached to the panel. Without `respect` this is the plain
/// per-axis solve (offsets 0) — byte-for-byte the previous behaviour.
fn solve_layout(layout: &Layout, total_w: f64, total_h: f64, dpi: f64) -> (Vec<f64>, f64, Vec<f64>, f64) {
    let mut xs = track_sizes(&layout.widths, total_w, dpi);
    let mut ys = track_sizes(&layout.heights, total_h, dpi);
    let (mut xoff, mut yoff) = (0.0, 0.0);
    if layout.respect {
        let (wweight, wpx) = null_summary(&layout.widths, &xs);
        let (hweight, hpx) = null_summary(&layout.heights, &ys);
        if wweight > 0.0 && hweight > 0.0 {
            let upw = wpx / wweight; // px per null-weight-unit, x
            let uph = hpx / hweight; // px per null-weight-unit, y
            if upw > uph {
                let scale = uph / upw;
                for (i, t) in layout.widths.iter().enumerate() {
                    if matches!(t, Track::Null(_)) {
                        xs[i] *= scale;
                    }
                }
                xoff = (total_w - xs.iter().sum::<f64>()) / 2.0;
            } else if uph > upw {
                let scale = upw / uph;
                for (i, t) in layout.heights.iter().enumerate() {
                    if matches!(t, Track::Null(_)) {
                        ys[i] *= scale;
                    }
                }
                yoff = (total_h - ys.iter().sum::<f64>()) / 2.0;
            }
        }
    }
    (edges_of(&xs), xoff, edges_of(&ys), yoff)
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

/// An arbitrary clip-path spec attached to a viewport (its own coordinates):
/// `nper` closed sub-paths over `(x, y)`, filled by winding or even-odd.
#[derive(Clone, Debug)]
struct ClipPathSpec {
    x: Vec<f64>, y: Vec<f64>, xu: Vec<Unit>, yu: Vec<Unit>,
    nper: Vec<usize>, evenodd: bool,
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
    /// An arbitrary clip path (overrides the rectangular `clip` when set).
    clip_path: Option<ClipPathSpec>,
    gp: PartialGpar,
    layout: Option<Layout>,
}

/// A viewport after the layout pass: its local frame and effective context.
/// `clip_chain` is the list of clipping-ancestor shapes to intersect
/// (empty = no clip); backends turn it into a mask / `<clipPath>` / PDF clip.
#[derive(Clone)]
struct ResolvedVp {
    vp: Vp,
    gp_acc: GparAcc,
    clip_chain: Vec<ClipShape>,
}

// --- primitives -------------------------------------------------------------

#[derive(Clone, Debug)]
enum Node {
    Rect { x: f64, y: f64, w: f64, h: f64, xu: Unit, yu: Unit, wu: Unit, hu: Unit, gp: PartialGpar },
    RoundRect { x: f64, y: f64, w: f64, h: f64, r: f64, xu: Unit, yu: Unit, wu: Unit, hu: Unit, ru: Unit, gp: PartialGpar },
    Lines {
        x: Vec<f64>, y: Vec<f64>, xu: Vec<Unit>, yu: Vec<Unit>,
        /// Optional whole-path end caps (absolute-length units): trim the first/
        /// last vertex inward by this device length, resolved at render. `None` =
        /// untouched. See `Segments` for the per-element form.
        scap: Option<(f64, Unit)>, ecap: Option<(f64, Unit)>,
        /// Optional signed perpendicular offset (absolute unit): rigidly translate
        /// the whole polyline sideways by this device length along the normal of
        /// its overall (chord) direction. `None` = untouched.
        off: Option<(f64, Unit)>,
        arrow: Option<Arrow>, gp: PartialGpar,
    },
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
        /// Per-glyph fill colour. **Empty** means "use the shared `gp` colour" — the
        /// plain single-style path leaves this empty so its rendering is unchanged.
        /// A rich (multi-run) label fills it with one `Rgba` per glyph.
        gcol: Vec<Rgba>,
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
    /// A batch of point markers with per-element `shape` codes (0 circle, 1 square,
    /// 2 triangle, 3 diamond, 4 plus, 5 cross); `size` is the marker radius.
    Markers {
        x: Vec<f64>, y: Vec<f64>, size: Vec<f64>,
        xu: Vec<Unit>, yu: Vec<Unit>, su: Vec<Unit>,
        shape: Vec<u32>,
        gp: PartialGpar,
    },
    /// A batch of hexagons (for hex-binning): `flat` the orientation, and `fill` a
    /// **per-element** colour (the binned-count colour); `gp` supplies only the
    /// uniform stroke (col/lwd/alpha). Geometry comes from one of two paths: if `w`
    /// (and `h`) are empty, each hex is *regular* with circumradius `size`; if they
    /// are non-empty they give the per-hex **full** width/height (corner-to-corner
    /// along each axis), resolved per-axis so the hex can be non-regular (`size` is
    /// then ignored).
    Hexagons {
        x: Vec<f64>, y: Vec<f64>, size: Vec<f64>, w: Vec<f64>, h: Vec<f64>,
        xu: Vec<Unit>, yu: Vec<Unit>, su: Vec<Unit>, wu: Vec<Unit>, hu: Vec<Unit>,
        fill: Vec<Rgba>,
        flat: bool,
        gp: PartialGpar,
    },
    /// A batch of annular sectors: centre `(x,y)`, inner/outer radius `r0`/`r1`,
    /// angles `theta0`/`theta1` in radians (0 at 3 o'clock, CCW). `fill` is a
    /// **per-element** colour; `gp` supplies the uniform stroke. `r0=0` ⇒ pie slice;
    /// `r0=r1` ⇒ an unfilled arc outline.
    Sectors {
        x: Vec<f64>, y: Vec<f64>, r0: Vec<f64>, r1: Vec<f64>,
        theta0: Vec<f64>, theta1: Vec<f64>,
        xu: Vec<Unit>, yu: Vec<Unit>, r0u: Vec<Unit>, r1u: Vec<Unit>,
        fill: Vec<Rgba>,
        /// Optional arrowhead on the outer arc's end(s) — for directed self-loops
        /// (an open arc, `r0 == r1`, with an absolute mm radius at a native
        /// centre). Placed tangent to the arc. `None` = no head (unchanged).
        arrow: Option<Arrow>,
        gp: PartialGpar,
    },
    /// A batch of disjoint line segments `(x0,y0)->(x1,y1)`, stroked in one pass.
    Segments {
        x0: Vec<f64>, y0: Vec<f64>, x1: Vec<f64>, y1: Vec<f64>,
        x0u: Vec<Unit>, y0u: Vec<Unit>, x1u: Vec<Unit>, y1u: Vec<Unit>,
        /// Optional per-element start/end caps (absolute-length units): shorten
        /// the drawn segment inward from each end by this device length, resolved
        /// at render. Empty = no caps (the batch is unchanged). Recycled on the R
        /// side to the element count, so `scap.len()` is either 0 or `n`.
        scap: Vec<f64>, ecap: Vec<f64>, scapu: Vec<Unit>, ecapu: Vec<Unit>,
        /// Optional per-element signed perpendicular offset (absolute unit): shift
        /// both endpoints sideways by this device length along the segment's left
        /// normal, applied *before* the caps/arrow. Empty = none; else length `n`.
        off: Vec<f64>, offu: Vec<Unit>,
        arrow: Option<Arrow>,
        gp: PartialGpar,
    },
    /// A batch of igraph-style self-loops: a cubic-Bézier teardrop per element,
    /// leaving/re-entering the vertex `(x,y)`, sized by an absolute `size` (and
    /// `foot` = the node radius the feet attach at), bulging along `angle` (rad),
    /// with an optional arrowhead tangent to the returning foot. All lengths are
    /// resolved to device px at render, so the loop tracks an mm node at any size.
    Loop {
        x: Vec<f64>, y: Vec<f64>, xu: Vec<Unit>, yu: Vec<Unit>,
        size: Vec<f64>, su: Vec<Unit>, foot: Vec<f64>, fu: Vec<Unit>,
        angle: Vec<f64>,
        /// Lateral petal scale (dimensionless, per element): multiplies the
        /// teardrop's half-width so a loop can be narrowed without shortening it.
        width: Vec<f64>,
        arrow: Option<Arrow>,
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
    /// Opens an isolated compositing layer (paired with `GroupEnd`), optionally
    /// modulated by mask `mask` (an index into `Scene::masks`), composited at group
    /// opacity `alpha` (1.0 = opaque) and blend mode `blend`. The mask/opacity/blend
    /// are attached at the start because PDF must install them before the content.
    GroupStart { mask: Option<usize>, alpha: f32, blend: BlendKind },
    /// Closes the layer and composites it.
    GroupEnd,
}

impl Node {
    fn gp(&self) -> &PartialGpar {
        match self {
            Node::Rect { gp, .. }
            | Node::RoundRect { gp, .. }
            | Node::Lines { gp, .. }
            | Node::Polygon { gp, .. }
            | Node::Circle { gp, .. }
            | Node::Rects { gp, .. }
            | Node::Circles { gp, .. }
            | Node::Markers { gp, .. }
            | Node::Hexagons { gp, .. }
            | Node::Sectors { gp, .. }
            | Node::Segments { gp, .. }
            | Node::Loop { gp, .. }
            | Node::Path { gp, .. }
            | Node::Text { gp, .. } => gp,
            Node::Image { .. } | Node::GroupStart { .. } | Node::GroupEnd => {
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

/// Per-node semantic metadata (Feature: per-element identity). Carried alongside
/// each drawn node and emitted by vector backends (SVG `data-*`/`role`) for
/// interactivity, accessibility, and testing. Empty fields are omitted.
#[derive(Clone, Default, Debug)]
struct NodeMeta {
    id: String,
    role: String,
    name: String,
}

impl NodeMeta {
    fn is_empty(&self) -> bool {
        self.id.is_empty() && self.role.is_empty() && self.name.is_empty()
    }
    /// Pre-formatted SVG attributes (`data-vellum-*` + ARIA `role`) for this node.
    fn svg_attrs(&self) -> String {
        let mut s = String::new();
        if !self.id.is_empty() {
            s.push_str(&format!("data-vellum-id=\"{}\"", xml_attr_escape(&self.id)));
        }
        if !self.name.is_empty() {
            if !s.is_empty() { s.push(' '); }
            s.push_str(&format!("data-vellum-name=\"{}\"", xml_attr_escape(&self.name)));
        }
        if !self.role.is_empty() {
            if !s.is_empty() { s.push(' '); }
            s.push_str(&format!("role=\"{}\"", xml_attr_escape(&self.role)));
        }
        s
    }
}

/// Minimal escaping for a string placed inside a double-quoted XML attribute.
fn xml_attr_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
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
    /// Hit-test pick id for each entry in `nodes` (parallel). Set by `set_pick`
    /// before compiling each grob; used by `hit_test`'s colour pick-buffer.
    picks: Vec<i32>,
    cur_pick: i32,
    /// Semantic metadata for each entry in `nodes` (parallel). Set by `set_meta`
    /// before compiling each grob; emitted by vector backends as `data-*`/`role`.
    meta: Vec<NodeMeta>,
    cur_meta: NodeMeta,
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
            clip_path: None,
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
            picks: Vec::new(),
            cur_pick: -1,
            meta: Vec::new(),
            cur_meta: NodeMeta::default(),
        }
    }

    /// Set the hit-test pick id applied to subsequently-emitted primitives (one
    /// per grob; the R side assigns ids in paint order). See `hit_test`.
    fn set_pick(&mut self, id: i32) {
        self.cur_pick = id;
    }

    /// Set the semantic metadata applied to subsequently-emitted primitives (one
    /// per grob). Empty strings clear a field. Emitted by vector backends.
    fn set_meta(&mut self, id: &str, role: &str, name: &str) {
        self.cur_meta = NodeMeta {
            id: id.to_string(),
            role: role.to_string(),
            name: name.to_string(),
        };
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
            clip_path: None,
            gp: PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke),
            layout: None,
        });
        self.viewports[self.current].children.push(id);
        self.current = id;
        id as i32
    }

    /// Attach an arbitrary clip path (in the current viewport's coordinates) to
    /// the current viewport; `nper` gives the point count of each closed sub-path.
    fn set_clip_path(&mut self, x: &[f64], y: &[f64], xu: &[i32], yu: &[i32], nper: &[i32], evenodd: bool) {
        let spec = ClipPathSpec {
            x: x.to_vec(), y: y.to_vec(), xu: codes(xu), yu: codes(yu),
            nper: nper.iter().map(|&v| v.max(0) as usize).collect(),
            evenodd,
        };
        self.viewports[self.current].clip_path = Some(spec);
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
    /// track whose value is its weight. `respect` enables grid-style aspect
    /// locking (equal physical size for a `null` width unit and a `null` height
    /// unit; see `solve_layout`).
    fn set_layout(&mut self, wvals: &[f64], wunits: Vec<String>, hvals: &[f64], hunits: Vec<String>, respect: bool) {
        let widths = build_tracks(wvals, &wunits);
        let heights = build_tracks(hvals, &hunits);
        self.viewports[self.current].layout = Some(Layout { widths, heights, respect });
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

    #[allow(clippy::too_many_arguments)]
    fn roundrect(&mut self, x: f64, y: f64, w: f64, h: f64, r: f64, xu: i32, yu: i32, wu: i32, hu: i32, ru: i32, fill: Robj, col: Robj, lwd: Robj, alpha: Robj, stroke: Robj) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::RoundRect {
            x,
            y,
            w,
            h,
            r,
            xu: Unit::from_code(xu),
            yu: Unit::from_code(yu),
            wu: Unit::from_code(wu),
            hu: Unit::from_code(hu),
            ru: Unit::from_code(ru),
            gp,
        });
    }

    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_arguments)]
    fn lines(
        &mut self, x: &[f64], y: &[f64], xu: &[i32], yu: &[i32],
        scap: &[f64], ecap: &[f64], scapu: &[i32], ecapu: &[i32],
        off: &[f64], offu: &[i32],
        col: Robj, lwd: Robj, alpha: Robj, stroke: Robj,
        aangle: f64, alen: f64, aends: i32, aclosed: bool,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Lines {
            x: x.to_vec(), y: y.to_vec(), xu: codes(xu), yu: codes(yu),
            scap: cap_scalar(scap, scapu), ecap: cap_scalar(ecap, ecapu),
            off: cap_scalar(off, offu),
            arrow: arrow_from(aangle, alen, aends, aclosed), gp,
        });
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

    /// A batch of markers (point glyphs) sharing one gpar. Like `circles` but each
    /// element carries a `shape` code (0 circle, 1 square, 2 triangle, 3 diamond,
    /// 4 plus, 5 cross); `size` is the marker radius. Filled shapes fill+stroke per
    /// gpar; plus/cross are stroke-only. (circle_grob / default points use the
    /// faster `circles` path; this is for shape variety.)
    #[allow(clippy::too_many_arguments)]
    fn markers(
        &mut self, x: &[f64], y: &[f64], size: &[f64],
        xu: &[i32], yu: &[i32], su: &[i32], shape: &[i32],
        fill: Robj, col: Robj, lwd: Robj, alpha: Robj, stroke: Robj,
    ) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Markers {
            x: x.to_vec(), y: y.to_vec(), size: size.to_vec(),
            xu: codes(xu), yu: codes(yu), su: codes(su),
            shape: shape.iter().map(|&v| v.max(0) as u32).collect(), gp,
        });
    }

    /// A batch of hexagons for hex-binning. `flat` picks flat-top vs pointy-top;
    /// `fill` is a flat per-hex RGBA stream (`[r,g,b,a, r,g,b,a, ...]`, one quad per
    /// hex); `col`/`lwd`/`alpha`/`stroke` give the *uniform* stroke (the gpar's fill
    /// is unused — fill is per element). Geometry: if `w`/`h` are empty each hex is
    /// regular with circumradius `size`; otherwise `w`/`h` are the per-hex full
    /// width/height (corner-to-corner along each axis), resolved per-axis so a hex
    /// can tile a non-square lattice, and `size` is ignored.
    #[allow(clippy::too_many_arguments)]
    fn hexagons(
        &mut self, x: &[f64], y: &[f64], size: &[f64], w: &[f64], h: &[f64],
        xu: &[i32], yu: &[i32], su: &[i32], wu: &[i32], hu: &[i32],
        fill: &[i32], flat: bool,
        col: Robj, lwd: Robj, alpha: Robj, stroke: Robj,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &lwd, &alpha, &stroke);
        let fill = fill
            .chunks_exact(4)
            .map(|c| Rgba { r: c[0] as u8, g: c[1] as u8, b: c[2] as u8, a: c[3] as u8 })
            .collect();
        self.emit_node(Node::Hexagons {
            x: x.to_vec(), y: y.to_vec(), size: size.to_vec(), w: w.to_vec(), h: h.to_vec(),
            xu: codes(xu), yu: codes(yu), su: codes(su), wu: codes(wu), hu: codes(hu),
            fill, flat, gp,
        });
    }

    /// A batch of annular sectors (pie/donut/rose wedges). `(x,y)` is the centre,
    /// `r0`/`r1` the inner/outer radius, `theta0`/`theta1` the start/end angle in
    /// **radians** (0 at 3 o'clock, CCW). `fill` is a flat per-sector RGBA stream
    /// (one quad per sector, like `hexagons`); `col`/`lwd`/`alpha`/`stroke` give the
    /// uniform stroke. `r0=0` ⇒ pie slice; `r0=r1` ⇒ an arc outline (no fill).
    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_arguments)]
    fn sectors(
        &mut self, x: &[f64], y: &[f64], r0: &[f64], r1: &[f64], theta0: &[f64], theta1: &[f64],
        xu: &[i32], yu: &[i32], r0u: &[i32], r1u: &[i32], fill: &[i32],
        col: Robj, lwd: Robj, alpha: Robj, stroke: Robj,
        aangle: f64, alen: f64, aends: i32, aclosed: bool,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &lwd, &alpha, &stroke);
        let fill = fill
            .chunks_exact(4)
            .map(|c| Rgba { r: c[0] as u8, g: c[1] as u8, b: c[2] as u8, a: c[3] as u8 })
            .collect();
        self.emit_node(Node::Sectors {
            x: x.to_vec(), y: y.to_vec(), r0: r0.to_vec(), r1: r1.to_vec(),
            theta0: theta0.to_vec(), theta1: theta1.to_vec(),
            xu: codes(xu), yu: codes(yu), r0u: codes(r0u), r1u: codes(r1u),
            fill, arrow: arrow_from(aangle, alen, aends, aclosed), gp,
        });
    }

    /// A batch of disjoint line segments (stroke only), sharing one gpar.
    #[allow(clippy::too_many_arguments)]
    fn segments(
        &mut self, x0: &[f64], y0: &[f64], x1: &[f64], y1: &[f64],
        x0u: &[i32], y0u: &[i32], x1u: &[i32], y1u: &[i32],
        scap: &[f64], ecap: &[f64], scapu: &[i32], ecapu: &[i32],
        off: &[f64], offu: &[i32],
        col: Robj, lwd: Robj, alpha: Robj, stroke: Robj,
        aangle: f64, alen: f64, aends: i32, aclosed: bool,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Segments {
            x0: x0.to_vec(), y0: y0.to_vec(), x1: x1.to_vec(), y1: y1.to_vec(),
            x0u: codes(x0u), y0u: codes(y0u), x1u: codes(x1u), y1u: codes(y1u),
            scap: scap.to_vec(), ecap: ecap.to_vec(), scapu: codes(scapu), ecapu: codes(ecapu),
            off: off.to_vec(), offu: codes(offu),
            arrow: arrow_from(aangle, alen, aends, aclosed), gp,
        });
    }

    /// A batch of self-loops (cubic-Bézier teardrops). See `Node::Loop`.
    #[allow(clippy::too_many_arguments)]
    fn add_loop(
        &mut self, x: &[f64], y: &[f64], size: &[f64], foot: &[f64], angle: &[f64], width: &[f64],
        xu: &[i32], yu: &[i32], su: &[i32], fu: &[i32],
        col: Robj, lwd: Robj, alpha: Robj, stroke: Robj,
        aangle: f64, alen: f64, aends: i32, aclosed: bool,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Loop {
            x: x.to_vec(), y: y.to_vec(), xu: codes(xu), yu: codes(yu),
            size: size.to_vec(), su: codes(su), foot: foot.to_vec(), fu: codes(fu),
            angle: angle.to_vec(), width: width.to_vec(),
            arrow: arrow_from(aangle, alen, aends, aclosed), gp,
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
            gcol: Vec::new(),
            label: label.to_string(),
            family: family.to_string(),
            face: face.to_string(),
            size,
            gp,
        });
    }

    /// Add a whole batch of pre-shaped text labels in one call (one shaping pass
    /// on the R side, one FFI here). Glyphs are flat across all labels, split by
    /// `nper` (glyph count per label); positions/sizes/rot/labels are per-label;
    /// font + just + colour are shared.
    #[allow(clippy::too_many_arguments)]
    fn texts(
        &mut self,
        x: &[f64], y: &[f64], xu: &[i32], yu: &[i32], rot: &[f64],
        hjust: f64, vjust: f64, w: &[f64], h: &[f64], nper: &[i32],
        gid: &[i32], gx: &[f64], gy: &[f64], gsize: &[f64], gpath: Vec<String>, gface: &[i32],
        label: Vec<String>, family: &str, face: &str, size: f64, col: Robj, alpha: Robj,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &rnull(), &alpha, &rnull());
        let nlab = [x.len(), y.len(), xu.len(), yu.len(), rot.len(), w.len(), h.len(), nper.len(), label.len()]
            .into_iter().min().unwrap_or(0);
        // All glyph arrays are parallel; clamp the per-label slice to the shortest
        // so a (mis-sized, direct-FFI) call can't panic on an out-of-range slice.
        let gmax = [gid.len(), gx.len(), gy.len(), gsize.len(), gpath.len(), gface.len()]
            .into_iter().min().unwrap_or(0);
        let mut off = 0usize;
        for i in 0..nlab {
            let cnt = nper[i].max(0) as usize;
            let lo = off.min(gmax);
            let hi = (off + cnt).min(gmax);
            off = hi;
            self.emit_node(Node::Text {
                x: x[i], y: y[i], xu: Unit::from_code(xu[i]), yu: Unit::from_code(yu[i]),
                rot: rot[i], hjust, vjust, w: w[i], h: h[i],
                gid: gid[lo..hi].iter().map(|&v| v.max(0) as u32).collect(),
                gx: gx[lo..hi].to_vec(),
                gy: gy[lo..hi].to_vec(),
                gsize: gsize[lo..hi].to_vec(),
                gpath: gpath[lo..hi].to_vec(),
                gface: gface[lo..hi].iter().map(|&v| v.max(0) as u32).collect(),
                gcol: Vec::new(),
                label: label[i].clone(),
                family: family.to_string(),
                face: face.to_string(),
                size,
                gp: gp.clone(),
            });
        }
    }

    /// Like `texts`, but with a **per-glyph** fill colour stream (`gcol`, a flat RGBA
    /// int stream, 4 ints per glyph, parallel to the glyph arrays). Used by rich
    /// (multi-run) labels where colour varies within a single label. Everything else
    /// matches `texts`; the shared `col` becomes the fallback only when a glyph's
    /// colour is absent (it never is here, but keeps the gpar resolve consistent).
    #[allow(clippy::too_many_arguments)]
    fn texts_rich(
        &mut self,
        x: &[f64], y: &[f64], xu: &[i32], yu: &[i32], rot: &[f64],
        hjust: f64, vjust: f64, w: &[f64], h: &[f64], nper: &[i32],
        gid: &[i32], gx: &[f64], gy: &[f64], gsize: &[f64], gpath: Vec<String>, gface: &[i32],
        gcol: &[i32],
        label: Vec<String>, family: &str, face: &str, size: f64, col: Robj, alpha: Robj,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &rnull(), &alpha, &rnull());
        let nlab = [x.len(), y.len(), xu.len(), yu.len(), rot.len(), w.len(), h.len(), nper.len(), label.len()]
            .into_iter().min().unwrap_or(0);
        let gmax = [gid.len(), gx.len(), gy.len(), gsize.len(), gpath.len(), gface.len(), gcol.len() / 4]
            .into_iter().min().unwrap_or(0);
        let mut off = 0usize;
        for i in 0..nlab {
            let cnt = nper[i].max(0) as usize;
            let lo = off.min(gmax);
            let hi = (off + cnt).min(gmax);
            off = hi;
            self.emit_node(Node::Text {
                x: x[i], y: y[i], xu: Unit::from_code(xu[i]), yu: Unit::from_code(yu[i]),
                rot: rot[i], hjust, vjust, w: w[i], h: h[i],
                gid: gid[lo..hi].iter().map(|&v| v.max(0) as u32).collect(),
                gx: gx[lo..hi].to_vec(),
                gy: gy[lo..hi].to_vec(),
                gsize: gsize[lo..hi].to_vec(),
                gpath: gpath[lo..hi].to_vec(),
                gface: gface[lo..hi].iter().map(|&v| v.max(0) as u32).collect(),
                gcol: gcol[lo * 4..hi * 4]
                    .chunks_exact(4)
                    .map(|c| Rgba { r: c[0] as u8, g: c[1] as u8, b: c[2] as u8, a: c[3] as u8 })
                    .collect(),
                label: label[i].clone(),
                family: family.to_string(),
                face: face.to_string(),
                size,
                gp: gp.clone(),
            });
        }
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

    /// Open an isolated compositing group, modulated by mask index `mask`
    /// (negative = no mask, just isolation), group opacity `alpha`, and blend mode
    /// `blend` (a code; 0 = normal). Routed through `emit_node` so a group nested
    /// inside a mask (a mask grob that itself masks a viewport) lands in the same
    /// node list as its content, keeping markers and content in sync.
    fn group_start(&mut self, mask: i32, alpha: f64, blend: i32) {
        let mask = if mask >= 0 { Some(mask as usize) } else { None };
        self.emit_node(Node::GroupStart {
            mask,
            alpha: alpha.clamp(0.0, 1.0) as f32,
            blend: BlendKind::from_code(blend),
        });
    }

    /// Close the most recently opened group.
    fn group_end(&mut self) {
        self.emit_node(Node::GroupEnd);
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

    /// Render the scene to a PNG file. Returns any degradation warnings (none for
    /// the raster backend today; uniform with the SVG/PDF signatures).
    fn render_png(&self, path: &str) -> Vec<String> {
        let mut b = RasterBackend::new(self.w_px, self.h_px, self.bg);
        let warnings = self.render_to(&mut b);
        if let Err(e) = b.into_pixmap().save_png(path) {
            throw_r_error(format!("failed to write PNG: {e}"));
        }
        warnings
    }

    /// Render the scene to an SVG file. `outline_text` emits glyph outlines
    /// instead of selectable `<text>` (pixel-faithful, matches raster/PDF).
    /// Returns any degradation warnings.
    fn render_svg(&self, path: &str, outline_text: bool) -> Vec<String> {
        let mut b = SvgBackend::new(self.w_px, self.h_px, self.bg, outline_text);
        let warnings = self.render_to(&mut b);
        if let Err(e) = std::fs::write(path, b.into_string()) {
            throw_r_error(format!("failed to write SVG: {e}"));
        }
        warnings
    }

    /// Render the scene to a PDF file. Returns any degradation warnings (e.g. a
    /// tiling pattern or mask the PDF walk could not honour).
    fn render_pdf(&self, path: &str) -> Vec<String> {
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
        let warnings = {
            let mut b = PdfBackend::new(&mut surface);
            b.fill_background(self.w_px, self.h_px, self.bg);
            self.render_to(&mut b)
        };
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
        warnings
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

    /// Render and return the tight bounding box of non-transparent content as
    /// `c(min_x, min_y, max_x, max_y)` (device px, inclusive), or an empty vector
    /// if nothing was drawn. Used to measure a grob's extent (grobwidth/height).
    fn content_bbox(&self) -> Vec<i32> {
        let pm = self.rasterize();
        let w = self.w_px as usize;
        let (mut minx, mut miny, mut maxx, mut maxy) = (usize::MAX, usize::MAX, 0usize, 0usize);
        let mut any = false;
        for (i, p) in pm.pixels().iter().enumerate() {
            if p.alpha() > 0 {
                let (x, y) = (i % w, i / w);
                any = true;
                minx = minx.min(x);
                miny = miny.min(y);
                maxx = maxx.max(x);
                maxy = maxy.max(y);
            }
        }
        if any {
            vec![minx as i32, miny as i32, maxx as i32, maxy as i32]
        } else {
            Vec::new()
        }
    }

    /// Resolved per-viewport geometry for the debug overlay / `why_size()`. Runs
    /// the layout pass and returns, per viewport (row = viewport id), its parent
    /// id, local pixel size, affine transform (`c(sx, ky, kx, sy, tx, ty)` mapping
    /// local px -> device px), solved layout track edges (local px, plus the
    /// `respect` centering offset), and the device-px bbox of its innermost clip.
    /// R joins this with the viewport names it recorded during compilation.
    fn resolved_geometry(&self) -> List {
        let resolved = self.resolve_all();
        let n = resolved.len();
        let mut id = Vec::with_capacity(n);
        let mut parent = Vec::with_capacity(n);
        let mut w_px = Vec::with_capacity(n);
        let mut h_px = Vec::with_capacity(n);
        let mut transform: Vec<Robj> = Vec::with_capacity(n);
        let mut has_layout = Vec::with_capacity(n);
        let mut xedges: Vec<Robj> = Vec::with_capacity(n);
        let mut yedges: Vec<Robj> = Vec::with_capacity(n);
        let mut xoff = Vec::with_capacity(n);
        let mut yoff = Vec::with_capacity(n);
        let mut has_clip = Vec::with_capacity(n);
        let mut clip: Vec<Robj> = Vec::with_capacity(n);
        for (i, rv) in resolved.iter().enumerate() {
            id.push(i as i32);
            parent.push(self.viewports[i].parent.map(|p| p as i32).unwrap_or(-1));
            let vp = &rv.vp;
            w_px.push(vp.w);
            h_px.push(vp.h);
            let t = vp.transform;
            transform.push(Robj::from(vec![
                t.sx as f64, t.ky as f64, t.kx as f64, t.sy as f64, t.tx as f64, t.ty as f64,
            ]));
            match &self.viewports[i].layout {
                Some(layout) => {
                    let (xe, xo, ye, yo) = solve_layout(layout, vp.w, vp.h, self.dpi);
                    has_layout.push(1i32);
                    xedges.push(Robj::from(xe));
                    yedges.push(Robj::from(ye));
                    xoff.push(xo);
                    yoff.push(yo);
                }
                None => {
                    has_layout.push(0i32);
                    xedges.push(Robj::from(Vec::<f64>::new()));
                    yedges.push(Robj::from(Vec::<f64>::new()));
                    xoff.push(0.0);
                    yoff.push(0.0);
                }
            }
            match rv.clip_chain.last() {
                Some(shape) => {
                    let (x0, y0, x1, y1) = clip_shape_bbox(shape);
                    has_clip.push(1i32);
                    clip.push(Robj::from(vec![x0, y0, x1, y1]));
                }
                None => {
                    has_clip.push(0i32);
                    clip.push(Robj::from(Vec::<f64>::new()));
                }
            }
        }
        list!(
            id = id,
            parent = parent,
            w_px = w_px,
            h_px = h_px,
            transform = List::from_values(transform),
            has_layout = has_layout,
            xedges = List::from_values(xedges),
            yedges = List::from_values(yedges),
            xoff = xoff,
            yoff = yoff,
            has_clip = has_clip,
            clip = List::from_values(clip)
        )
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

    /// Hit-test: return the pick id of the topmost primitive covering device pixel
    /// `(x, y)`, or -1 if none. Implemented as a colour pick-buffer — each node is
    /// drawn opaque (AA off) in a colour encoding its pick id, respecting clips and
    /// paint order, then the pixel is decoded — so it is geometry/clip/overlap
    /// exact. Markers and text use a bounding box; lines/segments a pick band.
    fn hit_test(&self, x: i32, y: i32) -> i32 {
        if x < 0 || y < 0 || x as u32 >= self.w_px || y as u32 >= self.h_px {
            return -1;
        }
        let resolved = self.resolve_all();
        let mut pm = Pixmap::new(self.w_px, self.h_px).expect("pick pixmap");
        pm.fill(Color::WHITE); // 0xFFFFFF = "no hit"
        // Clip masks are page-sized; build one per viewport, not per node.
        let mut mask_cache: HashMap<usize, Option<Mask>> = HashMap::new();
        for (i, (vp_id, node)) in self.nodes.iter().enumerate() {
            let id = self.picks[i];
            if id < 0 || id > 0x00FF_FFFE {
                continue; // unpickable / would collide with the no-hit colour
            }
            let rv = &resolved[*vp_id];
            let vp = &rv.vp;
            let t = vp.transform;
            let mask = &*mask_cache
                .entry(*vp_id)
                .or_insert_with(|| build_clip_mask(self.w_px, self.h_px, &rv.clip_chain));
            let mut paint = tiny_skia::Paint::default();
            paint.set_color(Color::from_rgba8(
                ((id >> 16) & 255) as u8, ((id >> 8) & 255) as u8, (id & 255) as u8, 255,
            ));
            paint.anti_alias = false;
            let fill = |pm: &mut Pixmap, path: &tiny_skia::Path, rule: FillRule| {
                pm.fill_path(path, &paint, rule, t, mask.as_ref());
            };
            match node {
                Node::Rect { x, y, w, h, xu, yu, wu, hu, .. } => {
                    let (cx, cy) = (vp.x_pos(*x, *xu), vp.y_pos(*y, *yu));
                    let (pw, ph) = (vp.x_len(*w, *wu), vp.y_len(*h, *hu));
                    if let Some(p) = rect_path(cx - pw / 2.0, cy - ph / 2.0, pw, ph) {
                        fill(&mut pm, &p, FillRule::Winding);
                    }
                }
                Node::RoundRect { x, y, w, h, r, xu, yu, wu, hu, ru, .. } => {
                    let (cx, cy) = (vp.x_pos(*x, *xu), vp.y_pos(*y, *yu));
                    let (pw, ph) = (vp.x_len(*w, *wu), vp.y_len(*h, *hu));
                    if let Some(p) = roundrect_path(cx - pw / 2.0, cy - ph / 2.0, pw, ph, vp.r_len(*r, *ru)) {
                        fill(&mut pm, &p, FillRule::Winding);
                    }
                }
                Node::Rects { x, y, w, h, xu, yu, wu, hu, .. } => {
                    let n = [x.len(), y.len(), w.len(), h.len(), xu.len(), yu.len(), wu.len(), hu.len()]
                        .into_iter().min().unwrap_or(0);
                    for k in 0..n {
                        let (cx, cy) = (vp.x_pos(x[k], xu[k]), vp.y_pos(y[k], yu[k]));
                        let (pw, ph) = (vp.x_len(w[k], wu[k]), vp.y_len(h[k], hu[k]));
                        if let Some(p) = rect_path(cx - pw / 2.0, cy - ph / 2.0, pw, ph) {
                            fill(&mut pm, &p, FillRule::Winding);
                        }
                    }
                }
                Node::Circle { x, y, r, xu, yu, ru, .. } => {
                    let mut pb = PathBuilder::new();
                    pb.push_circle(vp.x_pos(*x, *xu) as f32, vp.y_pos(*y, *yu) as f32, vp.r_len(*r, *ru) as f32);
                    if let Some(p) = pb.finish() {
                        fill(&mut pm, &p, FillRule::Winding);
                    }
                }
                Node::Circles { x, y, r, xu, yu, ru, .. } => {
                    let n = [x.len(), y.len(), r.len(), xu.len(), yu.len(), ru.len()].into_iter().min().unwrap_or(0);
                    for k in 0..n {
                        let mut pb = PathBuilder::new();
                        pb.push_circle(vp.x_pos(x[k], xu[k]) as f32, vp.y_pos(y[k], yu[k]) as f32, vp.r_len(r[k], ru[k]) as f32);
                        if let Some(p) = pb.finish() {
                            fill(&mut pm, &p, FillRule::Winding);
                        }
                    }
                }
                Node::Markers { x, y, size, xu, yu, su, .. } => {
                    let n = [x.len(), y.len(), size.len(), xu.len(), yu.len(), su.len()].into_iter().min().unwrap_or(0);
                    for k in 0..n {
                        let (cx, cy) = (vp.x_pos(x[k], xu[k]), vp.y_pos(y[k], yu[k]));
                        let rr = vp.r_len(size[k], su[k]);
                        if let Some(p) = rect_path(cx - rr, cy - rr, 2.0 * rr, 2.0 * rr) {
                            fill(&mut pm, &p, FillRule::Winding); // bounding box covers any shape
                        }
                    }
                }
                Node::Hexagons { x, y, size, w, h, xu, yu, su, wu, hu, flat, .. } => {
                    // n excludes w/h: they are empty for the regular (size-driven) path.
                    let n = [x.len(), y.len(), xu.len(), yu.len()].into_iter().min().unwrap_or(0);
                    let nonreg = !w.is_empty();
                    for k in 0..n {
                        let (cx, cy) = (vp.x_pos(x[k], xu[k]), vp.y_pos(y[k], yu[k]));
                        let p = if nonreg {
                            hexagon_path_xy(cx, cy, vp.x_len(w[k], wu[k]) * 0.5,
                                            vp.y_len(h[k], hu[k]) * 0.5, *flat)
                        } else {
                            hexagon_path(cx, cy, vp.r_len(size[k], su[k]), *flat)
                        };
                        if let Some(p) = p {
                            fill(&mut pm, &p, FillRule::Winding);
                        }
                    }
                }
                Node::Sectors { x, y, r0, r1, theta0, theta1, xu, yu, r0u, r1u, .. } => {
                    let n = [x.len(), y.len(), r0.len(), r1.len(), theta0.len(), theta1.len(),
                             xu.len(), yu.len(), r0u.len(), r1u.len()].into_iter().min().unwrap_or(0);
                    for k in 0..n {
                        let (cx, cy) = (vp.x_pos(x[k], xu[k]), vp.y_pos(y[k], yu[k]));
                        if let Some(p) = sector_path(cx, cy, vp.r_len(r0[k], r0u[k]),
                                                     vp.r_len(r1[k], r1u[k]), theta0[k], theta1[k]) {
                            fill(&mut pm, &p, FillRule::Winding);
                        }
                    }
                }
                Node::Polygon { x, y, xu, yu, .. } => {
                    if let Some(p) = build_poly(x, y, xu, yu, vp, true) {
                        fill(&mut pm, &p, FillRule::Winding);
                    }
                }
                Node::Path { x, y, xu, yu, nper, evenodd, .. } => {
                    if let Some(p) = build_subpaths(x, y, xu, yu, nper, vp) {
                        fill(&mut pm, &p, if *evenodd { FillRule::EvenOdd } else { FillRule::Winding });
                    }
                }
                Node::Image { x, y, w, h, xu, yu, wu, hu, .. } => {
                    let (cx, cy) = (vp.x_pos(*x, *xu), vp.y_pos(*y, *yu));
                    let (pw, ph) = (vp.x_len(*w, *wu), vp.y_len(*h, *hu));
                    if let Some(p) = rect_path(cx - pw / 2.0, cy - ph / 2.0, pw, ph) {
                        fill(&mut pm, &p, FillRule::Winding);
                    }
                }
                Node::Text { x, y, xu, yu, w, h, hjust, vjust, .. } => {
                    let (ax, ay) = (vp.x_pos(*x, *xu), vp.y_pos(*y, *yu));
                    if let Some(p) = rect_path(ax - *hjust * *w, ay - (1.0 - *vjust) * *h, *w, *h) {
                        fill(&mut pm, &p, FillRule::Winding); // bounding box (rotation ignored)
                    }
                }
                Node::Lines { x, y, xu, yu, .. } => {
                    if let Some(p) = build_poly(x, y, xu, yu, vp, false) {
                        let st = Stroke { width: 4.0, ..Stroke::default() };
                        pm.stroke_path(&p, &paint, &st, t, mask.as_ref());
                    }
                }
                Node::Segments { x0, y0, x1, y1, x0u, y0u, x1u, y1u, .. } => {
                    let n = [x0.len(), y0.len(), x1.len(), y1.len(), x0u.len(), y0u.len(), x1u.len(), y1u.len()]
                        .into_iter().min().unwrap_or(0);
                    let mut pb = PathBuilder::new();
                    for k in 0..n {
                        pb.move_to(vp.x_pos(x0[k], x0u[k]) as f32, vp.y_pos(y0[k], y0u[k]) as f32);
                        pb.line_to(vp.x_pos(x1[k], x1u[k]) as f32, vp.y_pos(y1[k], y1u[k]) as f32);
                    }
                    if let Some(p) = pb.finish() {
                        let st = Stroke { width: 4.0, ..Stroke::default() };
                        pm.stroke_path(&p, &paint, &st, t, mask.as_ref());
                    }
                }
                Node::Loop { x, y, xu, yu, size, su, foot, fu, angle, width, .. } => {
                    let n = [x.len(), y.len(), xu.len(), yu.len(), size.len(), su.len(),
                             foot.len(), fu.len(), angle.len(), width.len()].into_iter().min().unwrap_or(0);
                    let mut pb = PathBuilder::new();
                    for k in 0..n {
                        let (cx, cy) = (vp.x_pos(x[k], xu[k]), vp.y_pos(y[k], yu[k]));
                        let cp = loop_control_points(cx, cy, vp.x_len(size[k], su[k]), vp.x_len(foot[k], fu[k]), angle[k], width[k]);
                        pb.move_to(cp[0].0, cp[0].1);
                        pb.cubic_to(cp[1].0, cp[1].1, cp[2].0, cp[2].1, cp[3].0, cp[3].1);
                    }
                    if let Some(p) = pb.finish() {
                        let st = Stroke { width: 4.0, ..Stroke::default() };
                        pm.stroke_path(&p, &paint, &st, t, mask.as_ref());
                    }
                }
                Node::GroupStart { .. } | Node::GroupEnd => {}
            }
        }
        match pm.pixel(x as u32, y as u32) {
            Some(px) => {
                let c = px.demultiply();
                if c.red() == 255 && c.green() == 255 && c.blue() == 255 {
                    -1
                } else {
                    ((c.red() as i32) << 16) | ((c.green() as i32) << 8) | (c.blue() as i32)
                }
            }
            None => -1,
        }
    }
}

/// Axis-aligned device-px bounding box `(min_x, min_y, max_x, max_y)` of a clip
/// shape (its local rect/path corners mapped through its own transform). Used by
/// `resolved_geometry` to draw the clip region in the debug overlay.
fn clip_shape_bbox(shape: &ClipShape) -> (f64, f64, f64, f64) {
    let (corners, t) = match shape {
        ClipShape::Rect { w, h, transform } => {
            (vec![(0.0, 0.0), (*w, 0.0), (*w, *h), (0.0, *h)], *transform)
        }
        ClipShape::Path { path, transform, .. } => {
            let b = path.bounds();
            (
                vec![
                    (b.left() as f64, b.top() as f64),
                    (b.right() as f64, b.top() as f64),
                    (b.right() as f64, b.bottom() as f64),
                    (b.left() as f64, b.bottom() as f64),
                ],
                *transform,
            )
        }
    };
    let map = |x: f64, y: f64| {
        (
            t.sx as f64 * x + t.kx as f64 * y + t.tx as f64,
            t.ky as f64 * x + t.sy as f64 * y + t.ty as f64,
        )
    };
    let (mut minx, mut miny, mut maxx, mut maxy) =
        (f64::INFINITY, f64::INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY);
    for (x, y) in corners {
        let (dx, dy) = map(x, y);
        minx = minx.min(dx);
        miny = miny.min(dy);
        maxx = maxx.max(dx);
        maxy = maxy.max(dy);
    }
    (minx, miny, maxx, maxy)
}

/// Build the intersection clip `Mask` for a resolved clip chain (device px), or
/// `None` when there is no clip. Mirrors the raster backend's `mask_for`.
fn build_clip_mask(w: u32, h: u32, chain: &[ClipShape]) -> Option<Mask> {
    if chain.is_empty() {
        return None;
    }
    let mut m = Mask::new(w, h)?;
    if let Some(p) = rect_path(0.0, 0.0, w as f64, h as f64) {
        m.fill_path(&p, FillRule::Winding, true, Transform::identity());
    }
    for shape in chain {
        match shape {
            ClipShape::Rect { w: rw, h: rh, transform } => match rect_path(0.0, 0.0, *rw, *rh) {
                Some(r) => m.intersect_path(&r, FillRule::Winding, true, *transform),
                None => m.clear(),
            },
            ClipShape::Path { path, evenodd, transform } => {
                let rule = if *evenodd { FillRule::EvenOdd } else { FillRule::Winding };
                m.intersect_path(path, rule, true, *transform);
            }
        }
    }
    Some(m)
}

impl Scene {
    /// Append a primitive to the current draw target: the mask being filled (if
    /// any), else the drawn scene. Tagged with the current viewport.
    fn emit_node(&mut self, node: Node) {
        let vp = self.current;
        match self.mask_target.last() {
            Some(&mi) => self.masks[mi].nodes.push((vp, node)),
            None => {
                self.nodes.push((vp, node));
                self.picks.push(self.cur_pick);
                self.meta.push(self.cur_meta.clone());
            }
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
            vec![ClipShape::Rect { w: self.w_px as f64, h: self.h_px as f64, transform: Transform::identity() }]
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
                let layout = match self.viewports[node.parent.unwrap()].layout.as_ref() {
                    Some(l) => l,
                    None => throw_r_error(
                        "a viewport placed by row/col must be inside a viewport that has a layout",
                    ),
                };
                if row >= layout.heights.len() || col >= layout.widths.len() {
                    throw_r_error("layout row/col is out of range for the parent layout's tracks");
                }
                // `respect` may shrink the null axis and center the grid (offsets).
                let (xe, xoff, ye, yoff) = solve_layout(layout, parent.vp.w, parent.vp.h, self.dpi);
                let cstart = col.min(xe.len().saturating_sub(1));
                let cend = (col + colspan).min(xe.len().saturating_sub(1));
                let rstart = row.min(ye.len().saturating_sub(1));
                let rend = (row + rowspan).min(ye.len().saturating_sub(1));
                let x_lo = xe.get(cstart).copied().unwrap_or(0.0);
                let x_hi = xe.get(cend).copied().unwrap_or(x_lo);
                let y_lo = ye.get(rstart).copied().unwrap_or(0.0);
                let y_hi = ye.get(rend).copied().unwrap_or(y_lo);
                (
                    xoff + x_lo,
                    yoff + y_lo,
                    (x_hi - x_lo).max(0.0),
                    (y_hi - y_lo).max(0.0),
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
        if let Some(cp) = &node.clip_path {
            if let Some(path) = build_subpaths(&cp.x, &cp.y, &cp.xu, &cp.yu, &cp.nper, &vp) {
                clip_chain.push(ClipShape::Path { path, evenodd: cp.evenodd, transform });
            }
        } else if node.clip {
            clip_chain.push(ClipShape::Rect { w: cw, h: ch, transform });
        }

        ResolvedVp {
            vp,
            gp_acc: parent.gp_acc.apply(&node.gp),
            clip_chain,
        }
    }

    /// Render the whole page to a pixmap.
    fn rasterize(&self) -> Pixmap {
        let mut b = RasterBackend::new(self.w_px, self.h_px, self.bg);
        self.render_to(&mut b);
        b.into_pixmap()
    }

    /// Walk the resolved scene in paint order, emitting each primitive through a
    /// [`RenderBackend`]. Geometry resolution (transform, clip, gpar, path) is
    /// shared; only the per-primitive draw calls are backend-specific.
    fn render_to<B: RenderBackend>(&self, b: &mut B) -> Vec<String> {
        let resolved = self.resolve_all();
        self.render_nodes(b, &resolved, &self.nodes, Some(&self.meta));
        b.take_warnings()
    }

    /// Render an ordered node list (the scene, or a mask's content) onto `b`.
    /// Group markers open/close isolated layers; a closing mask is rasterized
    /// (always to a `RasterBackend`) and handed to `end_group`. `meta`, when given,
    /// is parallel to `nodes`: each non-empty entry brackets its primitive with
    /// `begin_node`/`end_node` so vector backends can attach semantic attributes
    /// (mask content is drawn without metadata).
    fn render_nodes<B: RenderBackend>(&self, b: &mut B, resolved: &[ResolvedVp], nodes: &[(usize, Node)], meta: Option<&[NodeMeta]>) {
        for (i, (vp_id, node)) in nodes.iter().enumerate() {
            let attrs = meta
                .and_then(|m| m.get(i))
                .filter(|md| !md.is_empty())
                .map(|md| md.svg_attrs())
                .unwrap_or_default();
            let has_meta = !attrs.is_empty();
            match node {
                Node::GroupStart { mask, alpha, blend } => {
                    let ml = mask.and_then(|m| self.masks.get(m)).map(|md| {
                        let mut mb = RasterBackend::new(self.w_px, self.h_px, Rgba { r: 0, g: 0, b: 0, a: 0 });
                        self.render_nodes(&mut mb, resolved, &md.nodes, None);
                        MaskLayer { pixmap: mb.into_pixmap(), kind: md.kind }
                    });
                    b.begin_group(ml, *alpha, *blend);
                    continue;
                }
                Node::GroupEnd => {
                    b.end_group();
                    continue;
                }
                // Images carry no gpar; resolve geometry and draw directly.
                Node::Image { rgba, iw, ih, x, y, w, h, xu, yu, wu, hu, interpolate } => {
                    let rv = &resolved[*vp_id];
                    let vp = &rv.vp;
                    let clip = Clip { id: *vp_id, shapes: &rv.clip_chain };
                    let cx = vp.x_pos(*x, *xu);
                    let cy = vp.y_pos(*y, *yu);
                    let pw = vp.x_len(*w, *wu);
                    let ph = vp.y_len(*h, *hu);
                    if has_meta { b.begin_node(&attrs); }
                    b.draw_image(rgba, *iw, *ih, cx, cy, pw, ph, *interpolate, vp.transform, &clip);
                    if has_meta { b.end_node(); }
                    continue;
                }
                _ => {}
            }

            let rv = &resolved[*vp_id];
            let vp = &rv.vp;
            let gp = rv.gp_acc.apply(node.gp()).resolve();
            let t = vp.transform;
            let clip = Clip { id: *vp_id, shapes: &rv.clip_chain };

            if has_meta { b.begin_node(&attrs); }
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
                Node::RoundRect { x, y, w, h, r, xu, yu, wu, hu, ru, .. } => {
                    let cx = vp.x_pos(*x, *xu);
                    let cy = vp.y_pos(*y, *yu);
                    let pw = vp.x_len(*w, *wu);
                    let ph = vp.y_len(*h, *hu);
                    let pr = vp.r_len(*r, *ru); // isotropic radius (npc -> min side)
                    if let Some(path) = roundrect_path(cx - pw / 2.0, cy - ph / 2.0, pw, ph, pr) {
                        fill_then_stroke(b, &path, &gp, t, &clip, vp, FillRule::Winding);
                    }
                }
                Node::Lines { x, y, xu, yu, scap, ecap, off, arrow, .. } => {
                    if let Some(col) = gp.col {
                        let n = x.len().min(y.len()).min(xu.len()).min(yu.len());
                        if n >= 2 {
                            // Resolve to local px, rigidly translate the whole polyline by
                            // any perpendicular offset (along its chord normal), then trim
                            // the ends by any absolute caps (heads land on the capped ends).
                            let mut pts: Vec<(f32, f32)> = (0..n)
                                .map(|i| (vp.x_pos(x[i], xu[i]) as f32, vp.y_pos(y[i], yu[i]) as f32))
                                .collect();
                            if let Some((v, u)) = off {
                                let o = vp.x_len(*v, *u); // signed
                                offset_polyline(&mut pts, o);
                            }
                            let sc = scap.map_or(0.0, |(v, u)| vp.x_len(v.max(0.0), u));
                            let ec = ecap.map_or(0.0, |(v, u)| vp.x_len(v.max(0.0), u));
                            if sc > 0.0 || ec > 0.0 {
                                trim_poly_ends(&mut pts, sc, ec);
                            }
                            let style = stroke_style(&gp, vp.dpi);
                            if let Some(path) = build_poly_px(&pts, false) {
                                if style.width > 0.0 {
                                    b.stroke_lines(&path, t, col, &style, &clip);
                                }
                            }
                            if let Some(a) = arrow {
                                let finite = |q: (f32, f32)| q.0.is_finite() && q.1.is_finite();
                                let mut ends = Vec::new();
                                if a.ends & 2 != 0 {
                                    if let Some(z) = pts.iter().rposition(|&q| finite(q)) {
                                        if let Some(w) = (0..z).rev().find(|&j| finite(pts[j])) {
                                            let (ex, ey) = pts[z];
                                            let (qx, qy) = pts[w];
                                            ends.push((ex, ey, (ex - qx) as f64, (ey - qy) as f64));
                                        }
                                    }
                                }
                                if a.ends & 1 != 0 {
                                    if let Some(a0) = pts.iter().position(|&q| finite(q)) {
                                        if let Some(b0) = (a0 + 1..pts.len()).find(|&j| finite(pts[j])) {
                                            let (sx, sy) = pts[a0];
                                            let (qx, qy) = pts[b0];
                                            ends.push((sx, sy, (sx - qx) as f64, (sy - qy) as f64));
                                        }
                                    }
                                }
                                draw_arrows(b, a, &ends, col, &style, t, &clip, vp.dpi);
                            }
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
                Node::Markers { x, y, size, xu, yu, su, shape, .. } => {
                    let n = [x.len(), y.len(), size.len(), xu.len(), yu.len(), su.len(), shape.len()]
                        .into_iter().min().unwrap_or(0);
                    let style = stroke_style(&gp, vp.dpi);
                    for i in 0..n {
                        let cx = vp.x_pos(x[i], xu[i]);
                        let cy = vp.y_pos(y[i], yu[i]);
                        let rr = vp.r_len(size[i], su[i]);
                        // Drop a marker at a non-finite position (an R `NA`).
                        if rr <= 0.0 || !cx.is_finite() || !cy.is_finite() {
                            continue;
                        }
                        let (cxf, cyf, rrf) = (cx as f32, cy as f32, rr as f32);
                        let mut pb = PathBuilder::new();
                        match shape[i] {
                            // plus / cross: stroke-only line glyphs (no fill)
                            4 | 5 => {
                                if shape[i] == 4 {
                                    pb.move_to(cxf, cyf - rrf);
                                    pb.line_to(cxf, cyf + rrf);
                                    pb.move_to(cxf - rrf, cyf);
                                    pb.line_to(cxf + rrf, cyf);
                                } else {
                                    let d = rrf * std::f32::consts::FRAC_1_SQRT_2;
                                    pb.move_to(cxf - d, cyf - d);
                                    pb.line_to(cxf + d, cyf + d);
                                    pb.move_to(cxf - d, cyf + d);
                                    pb.line_to(cxf + d, cyf - d);
                                }
                                if let (Some(path), Some(col)) = (pb.finish(), gp.col) {
                                    if style.width > 0.0 {
                                        b.stroke_lines(&path, t, col, &style, &clip);
                                    }
                                }
                            }
                            // filled / outlined polygons + circle (y-down: -y is up)
                            s => {
                                match s {
                                    1 => {
                                        pb.move_to(cxf - rrf, cyf - rrf);
                                        pb.line_to(cxf + rrf, cyf - rrf);
                                        pb.line_to(cxf + rrf, cyf + rrf);
                                        pb.line_to(cxf - rrf, cyf + rrf);
                                        pb.close();
                                    }
                                    2 => {
                                        pb.move_to(cxf, cyf - rrf);
                                        pb.line_to(cxf + 0.866 * rrf, cyf + 0.5 * rrf);
                                        pb.line_to(cxf - 0.866 * rrf, cyf + 0.5 * rrf);
                                        pb.close();
                                    }
                                    3 => {
                                        pb.move_to(cxf, cyf - rrf);
                                        pb.line_to(cxf + rrf, cyf);
                                        pb.line_to(cxf, cyf + rrf);
                                        pb.line_to(cxf - rrf, cyf);
                                        pb.close();
                                    }
                                    _ => {
                                        pb.push_circle(cxf, cyf, rrf);
                                    }
                                }
                                if let Some(path) = pb.finish() {
                                    fill_then_stroke(b, &path, &gp, t, &clip, vp, FillRule::Winding);
                                }
                            }
                        }
                    }
                }
                Node::Hexagons { x, y, size, w, h, xu, yu, su, wu, hu, fill, flat, .. } => {
                    // n excludes w/h: they are empty for the regular (size-driven) path.
                    let n = [x.len(), y.len(), xu.len(), yu.len(), fill.len()]
                        .into_iter().min().unwrap_or(0);
                    let nonreg = !w.is_empty();
                    let style = stroke_style(&gp, vp.dpi);
                    let stroke = gp.col.filter(|_| style.width > 0.0);
                    for i in 0..n {
                        let cx = vp.x_pos(x[i], xu[i]);
                        let cy = vp.y_pos(y[i], yu[i]);
                        if !cx.is_finite() || !cy.is_finite() {
                            continue; // drop NA-positioned hexes
                        }
                        // hexagon_path / _xy drop non-positive extents -> None.
                        let path = if nonreg {
                            hexagon_path_xy(cx, cy, vp.x_len(w[i], wu[i]) * 0.5,
                                            vp.y_len(h[i], hu[i]) * 0.5, *flat)
                        } else {
                            hexagon_path(cx, cy, vp.r_len(size[i], su[i]), *flat)
                        };
                        if let Some(path) = path {
                            // Per-element fill (the binned-count colour); uniform stroke.
                            b.fill_path(&path, t, &ResolvedPaint::Solid(fill[i]), FillRule::Winding, &clip);
                            if let Some(c) = stroke {
                                b.stroke_path(&path, t, c, &style, &clip);
                            }
                        }
                    }
                }
                Node::Sectors { x, y, r0, r1, theta0, theta1, xu, yu, r0u, r1u, fill, arrow, .. } => {
                    let n = [x.len(), y.len(), r0.len(), r1.len(), theta0.len(), theta1.len(),
                             xu.len(), yu.len(), r0u.len(), r1u.len(), fill.len()]
                        .into_iter().min().unwrap_or(0);
                    let style = stroke_style(&gp, vp.dpi);
                    let stroke = gp.col.filter(|_| style.width > 0.0);
                    // Arrowheads (directed self-loops) accumulate across the batch and
                    // are drawn once at the end, tangent to each outer arc's end(s).
                    let mut ends: Vec<(f32, f32, f64, f64)> = Vec::new();
                    for i in 0..n {
                        let cx = vp.x_pos(x[i], xu[i]);
                        let cy = vp.y_pos(y[i], yu[i]);
                        if !cx.is_finite() || !cy.is_finite() {
                            continue; // drop NA-positioned sectors
                        }
                        let rr0 = vp.r_len(r0[i], r0u[i]);
                        let rr1 = vp.r_len(r1[i], r1u[i]);
                        if let Some(path) = sector_path(cx, cy, rr0, rr1, theta0[i], theta1[i]) {
                            // Per-element fill; uniform stroke (matches hexagons).
                            b.fill_path(&path, t, &ResolvedPaint::Solid(fill[i]), FillRule::Winding, &clip);
                            if let Some(c) = stroke {
                                b.stroke_path(&path, t, c, &style, &clip);
                            }
                        }
                        if let Some(a) = arrow {
                            // Endpoints and travel-tangent of the outer arc in local px.
                            // The path is (cx + r cos θ, cy + r sin θ), so the forward
                            // tangent is sgn·(-sin θ, cos θ); the arrowhead direction for
                            // the "last" end points forward, "first" points backward.
                            let (t0, t1) = (theta0[i], theta1[i]);
                            let sgn = if t1 >= t0 { 1.0 } else { -1.0 };
                            let outer = rr1.max(rr0);
                            if a.ends & 2 != 0 {
                                let (px, py) = ((cx + outer * t1.cos()) as f32, (cy + outer * t1.sin()) as f32);
                                ends.push((px, py, sgn * -t1.sin(), sgn * t1.cos()));
                            }
                            if a.ends & 1 != 0 {
                                let (px, py) = ((cx + outer * t0.cos()) as f32, (cy + outer * t0.sin()) as f32);
                                ends.push((px, py, sgn * t0.sin(), sgn * -t0.cos()));
                            }
                        }
                    }
                    if let (Some(a), Some(col)) = (arrow, gp.col) {
                        if !ends.is_empty() {
                            draw_arrows(b, a, &ends, col, &style, t, &clip, vp.dpi);
                        }
                    }
                }
                Node::Text {
                    x, y, xu, yu, rot, hjust, vjust, w, h,
                    gid, gx, gy, gsize, gpath, gface, gcol, label, family, face, size, ..
                } => {
                    // Per-glyph colours carry their own paint, so a rich label draws
                    // even when the shared `gp.col` is "inherit/none" (the base colour
                    // is folded into `gcol` on the R side). A plain label still needs a
                    // resolved shared colour.
                    let color = match gp.col {
                        Some(c) => c,
                        None if !gcol.is_empty() => Rgba { r: 0, g: 0, b: 0, a: 255 },
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
                        gcolor: gcol,
                        label,
                        family,
                        face,
                        size: *size,
                        dpi: vp.dpi,
                    };
                    b.draw_text(&run, t, &clip);
                }
                Node::Segments { x0, y0, x1, y1, x0u, y0u, x1u, y1u, scap, ecap, scapu, ecapu, off, offu, arrow, .. } => {
                    if let Some(col) = gp.col {
                        let style = stroke_style(&gp, vp.dpi);
                        let n = [x0.len(), y0.len(), x1.len(), y1.len(), x0u.len(), y0u.len(), x1u.len(), y1u.len()]
                            .into_iter().min().unwrap_or(0);
                        let has_caps = !scap.is_empty() || !ecap.is_empty();
                        let has_off = !off.is_empty();
                        // Resolve each segment's endpoints once, so the stroke and the
                        // arrowhead share the same geometry. Order per the handover:
                        // perpendicular offset first, then caps, then the arrow along the
                        // shifted+capped direction. A segment is dropped when a coordinate
                        // is non-finite (an R `NA`) or when caps shorten it away entirely.
                        let mut segs: Vec<(f32, f32, f32, f32)> = Vec::with_capacity(n);
                        for i in 0..n {
                            let (mut sx, mut sy) = (vp.x_pos(x0[i], x0u[i]) as f32, vp.y_pos(y0[i], y0u[i]) as f32);
                            let (mut ex, mut ey) = (vp.x_pos(x1[i], x1u[i]) as f32, vp.y_pos(y1[i], y1u[i]) as f32);
                            if !(sx.is_finite() && sy.is_finite() && ex.is_finite() && ey.is_finite()) {
                                continue;
                            }
                            if has_off {
                                // signed offset — keep the sign (no `.max(0)` clamp).
                                let o = off_len_px(off, offu, i, vp);
                                let (a, b, c, d) = offset_segment(sx, sy, ex, ey, o);
                                sx = a; sy = b; ex = c; ey = d;
                            }
                            if has_caps {
                                let sc = cap_len_px(scap, scapu, i, vp);
                                let ec = cap_len_px(ecap, ecapu, i, vp);
                                match cap_segment(sx, sy, ex, ey, sc, ec) {
                                    Some(p) => segs.push(p),
                                    None => continue,
                                }
                            } else {
                                segs.push((sx, sy, ex, ey));
                            }
                        }
                        if style.width > 0.0 {
                            let mut pb = PathBuilder::new();
                            for &(sx, sy, ex, ey) in &segs {
                                pb.move_to(sx, sy);
                                pb.line_to(ex, ey);
                            }
                            if let Some(path) = pb.finish() {
                                b.stroke_lines(&path, t, col, &style, &clip);
                            }
                        }
                        if let Some(a) = arrow {
                            let mut ends = Vec::new();
                            for &(sx, sy, ex, ey) in &segs {
                                if a.ends & 2 != 0 {
                                    ends.push((ex, ey, (ex - sx) as f64, (ey - sy) as f64));
                                }
                                if a.ends & 1 != 0 {
                                    ends.push((sx, sy, (sx - ex) as f64, (sy - ey) as f64));
                                }
                            }
                            draw_arrows(b, a, &ends, col, &style, t, &clip, vp.dpi);
                        }
                    }
                }
                Node::Loop { x, y, xu, yu, size, su, foot, fu, angle, width, arrow, .. } => {
                    if let Some(col) = gp.col {
                        let style = stroke_style(&gp, vp.dpi);
                        let n = [x.len(), y.len(), xu.len(), yu.len(), size.len(), su.len(),
                                 foot.len(), fu.len(), angle.len(), width.len()].into_iter().min().unwrap_or(0);
                        let mut ends: Vec<(f32, f32, f64, f64)> = Vec::new();
                        for i in 0..n {
                            let cx = vp.x_pos(x[i], xu[i]);
                            let cy = vp.y_pos(y[i], yu[i]);
                            if !cx.is_finite() || !cy.is_finite() {
                                continue;
                            }
                            let s = vp.x_len(size[i], su[i]); // mm -> device px
                            let f = vp.x_len(foot[i], fu[i]);
                            let cp = loop_control_points(cx, cy, s, f, angle[i], width[i]);
                            if style.width > 0.0 {
                                let mut pb = PathBuilder::new();
                                pb.move_to(cp[0].0, cp[0].1);
                                pb.cubic_to(cp[1].0, cp[1].1, cp[2].0, cp[2].1, cp[3].0, cp[3].1);
                                if let Some(path) = pb.finish() {
                                    b.stroke_path(&path, t, col, &style, &clip);
                                }
                            }
                            if let Some(a) = arrow {
                                // Head at the returning foot (P3), tangent = 3·(P3−P2) ∝ P3−P2.
                                if a.ends & 2 != 0 {
                                    ends.push((cp[3].0, cp[3].1,
                                               (cp[3].0 - cp[2].0) as f64, (cp[3].1 - cp[2].1) as f64));
                                }
                                if a.ends & 1 != 0 {
                                    ends.push((cp[0].0, cp[0].1,
                                               (cp[0].0 - cp[1].0) as f64, (cp[0].1 - cp[1].1) as f64));
                                }
                            }
                        }
                        if let Some(a) = arrow {
                            if !ends.is_empty() {
                                draw_arrows(b, a, &ends, col, &style, t, &clip, vp.dpi);
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
                Node::Image { .. } | Node::GroupStart { .. } | Node::GroupEnd => unreachable!("handled above"),
            }
            if has_meta { b.end_node(); }
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
    // `blank` suppresses the stroke (width 0 -> backends skip it). A dash pattern
    // scales by the line width (grid convention).
    let (width, dash) = match &gp.lty {
        Lty::Blank => (0.0, Vec::new()),
        Lty::Solid => (width, Vec::new()),
        Lty::Dash(nibs) => (width, nibs.iter().map(|n| n * width).collect()),
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

/// An arrowhead spec attached to a `Lines`/`Segments` node. `len` is in inches
/// (an absolute length, resolved to px via dpi); `ends` is a bitmask (1 = start,
/// 2 = end); `closed` fills a triangular head, else strokes a two-barb "V".
#[derive(Clone, Copy, Debug)]
struct Arrow {
    angle: f64,
    len: f64,
    ends: u8,
    closed: bool,
}

/// Build an arrow from FFI scalars, or `None` when there is no head (`len <= 0`).
fn arrow_from(angle: f64, len_in: f64, ends: i32, closed: bool) -> Option<Arrow> {
    if !(len_in > 0.0) || !len_in.is_finite() {
        return None;
    }
    Some(Arrow { angle, len: len_in, ends: (ends.clamp(0, 3)) as u8, closed })
}

/// Append one arrowhead at `(px, py)` whose line travels in direction `(dx, dy)`
/// (pointing toward the head). Open heads add two barb strokes to `open`; closed
/// heads add a filled triangle to `fill`.
fn push_arrow_head(
    open: &mut PathBuilder, fill: &mut PathBuilder, a: &Arrow, dpi: f64,
    px: f32, py: f32, dx: f64, dy: f64,
) {
    let mag = (dx * dx + dy * dy).sqrt();
    if mag < 1e-9 {
        return;
    }
    let (bx, by) = (-dx / mag, -dy / mag); // unit vector back along the line
    let ang = a.angle.to_radians();
    let (ca, sa) = (ang.cos(), ang.sin());
    let l = a.len * dpi;
    let b1 = (px + ((bx * ca - by * sa) * l) as f32, py + ((bx * sa + by * ca) * l) as f32);
    let b2 = (px + ((bx * ca + by * sa) * l) as f32, py + ((-bx * sa + by * ca) * l) as f32);
    if a.closed {
        fill.move_to(px, py);
        fill.line_to(b1.0, b1.1);
        fill.line_to(b2.0, b2.1);
        fill.close();
    } else {
        open.move_to(b1.0, b1.1);
        open.line_to(px, py);
        open.move_to(b2.0, b2.1);
        open.line_to(px, py);
    }
}

/// Draw the arrowheads for a polyline / batch of segments: `ends` is a list of
/// `(point, incoming-direction)` already resolved to local px. Open barbs stroke
/// in `col`; closed heads fill with `col` (and outline). Shared by both nodes.
fn draw_arrows<B: RenderBackend>(
    b: &mut B, arrow: &Arrow, ends: &[(f32, f32, f64, f64)], col: Rgba,
    style: &StrokeStyle, t: Transform, clip: &Clip, dpi: f64,
) {
    let mut open = PathBuilder::new();
    let mut fill = PathBuilder::new();
    for &(px, py, dx, dy) in ends {
        push_arrow_head(&mut open, &mut fill, arrow, dpi, px, py, dx, dy);
    }
    if let Some(path) = open.finish() {
        if style.width > 0.0 {
            b.stroke_lines(&path, t, col, style, clip);
        }
    }
    if let Some(path) = fill.finish() {
        b.fill_path(&path, t, &ResolvedPaint::Solid(col), FillRule::Winding, clip);
        if style.width > 0.0 {
            b.stroke_lines(&path, t, col, style, clip);
        }
    }
}

fn build_poly(x: &[f64], y: &[f64], xu: &[Unit], yu: &[Unit], vp: &Vp, close: bool) -> Option<tiny_skia::Path> {
    let n = x.len().min(y.len()).min(xu.len()).min(yu.len());
    if n < 2 {
        return None;
    }
    let pts: Vec<(f32, f32)> = (0..n)
        .map(|i| (vp.x_pos(x[i], xu[i]) as f32, vp.y_pos(y[i], yu[i]) as f32))
        .collect();
    build_poly_px(&pts, close)
}

/// Build a polyline/polygon path from points already resolved to local pixels.
/// A non-finite point (an R `NA`/`NaN`) breaks the line, matching grid: the
/// polyline splits into independent sub-paths, and for a polygon each run of
/// finite points becomes its own closed sub-polygon.
fn build_poly_px(pts: &[(f32, f32)], close: bool) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    let mut open = false; // a sub-path is currently being built
    let mut run = 0; // points in the current sub-path
    for &(px, py) in pts {
        if px.is_finite() && py.is_finite() {
            if open {
                pb.line_to(px, py);
            } else {
                pb.move_to(px, py);
                open = true;
            }
            run += 1;
        } else {
            if open && close && run >= 2 {
                pb.close();
            }
            open = false;
            run = 0;
        }
    }
    if open && close && run >= 2 {
        pb.close();
    }
    pb.finish()
}

/// Resolve an absolute-length cap (validated absolute on the R side) to a device
/// length in local pixels — the same resolution `size`/`r` use, so the gap is
/// exact for any dpi/page size. A negative value clamps to 0.
fn cap_len_px(cap: &[f64], capu: &[Unit], i: usize, vp: &Vp) -> f64 {
    if cap.is_empty() {
        return 0.0;
    }
    let idx = if i < cap.len() { i } else { cap.len() - 1 };
    let u = capu.get(idx).copied().unwrap_or(Unit::Mm);
    vp.x_len(cap[idx].max(0.0), u)
}

/// Shorten a segment inward from each end by `sc`/`ec` device pixels. Returns the
/// capped endpoints, or `None` when the segment should not be drawn: a zero-
/// length segment (direction undefined) or a cap that consumes the whole length
/// (clamp to nothing rather than inverting the direction).
fn cap_segment(sx: f32, sy: f32, ex: f32, ey: f32, sc: f64, ec: f64) -> Option<(f32, f32, f32, f32)> {
    let dx = (ex - sx) as f64;
    let dy = (ey - sy) as f64;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-9 || sc + ec >= len {
        return None;
    }
    let (ux, uy) = (dx / len, dy / len);
    Some((
        sx + (sc * ux) as f32,
        sy + (sc * uy) as f32,
        ex - (ec * ux) as f32,
        ey - (ec * uy) as f32,
    ))
}

/// Move point `from` toward `toward` by `cap` device pixels, clamped so it never
/// overshoots `toward`. `None` when the two points coincide (no direction).
fn move_toward(from: (f32, f32), toward: (f32, f32), cap: f64) -> Option<(f32, f32)> {
    let dx = (toward.0 - from.0) as f64;
    let dy = (toward.1 - from.1) as f64;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-9 {
        return None;
    }
    let d = cap.min(len);
    Some((from.0 + (d * dx / len) as f32, from.1 + (d * dy / len) as f32))
}

/// Trim the whole-polyline ends (first/last finite vertices) inward by the given
/// caps, along the direction of the first/last segment. Interior vertices and
/// NA-split sub-path joins are untouched. Mutates `pts` (already in local px).
fn trim_poly_ends(pts: &mut [(f32, f32)], sc: f64, ec: f64) {
    let finite = |q: (f32, f32)| q.0.is_finite() && q.1.is_finite();
    if sc > 0.0 {
        if let Some(a) = pts.iter().position(|&q| finite(q)) {
            if let Some(b) = (a + 1..pts.len()).find(|&j| finite(pts[j])) {
                if let Some(np) = move_toward(pts[a], pts[b], sc) {
                    pts[a] = np;
                }
            }
        }
    }
    if ec > 0.0 {
        if let Some(z) = pts.iter().rposition(|&q| finite(q)) {
            if let Some(w) = (0..z).rev().find(|&j| finite(pts[j])) {
                if let Some(np) = move_toward(pts[z], pts[w], ec) {
                    pts[z] = np;
                }
            }
        }
    }
}

/// Resolve a signed perpendicular offset (absolute unit) to a device length in
/// local px. Unlike `cap_len_px` this keeps the sign — it selects the side.
fn off_len_px(off: &[f64], offu: &[Unit], i: usize, vp: &Vp) -> f64 {
    if off.is_empty() {
        return 0.0;
    }
    let idx = if i < off.len() { i } else { off.len() - 1 };
    let u = offu.get(idx).copied().unwrap_or(Unit::Mm);
    vp.x_len(off[idx], u) // signed; do NOT clamp
}

/// Shift a segment sideways by `o` device px along its left normal `n̂ = (-û_y, û_x)`.
/// A zero-length segment has no direction, so it is returned unchanged.
fn offset_segment(sx: f32, sy: f32, ex: f32, ey: f32, o: f64) -> (f32, f32, f32, f32) {
    let dx = (ex - sx) as f64;
    let dy = (ey - sy) as f64;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-9 {
        return (sx, sy, ex, ey);
    }
    let (ox, oy) = ((o * -dy / len) as f32, (o * dx / len) as f32);
    (sx + ox, sy + oy, ex + ox, ey + oy)
}

/// Rigidly translate a whole polyline sideways by `o` device px along the normal of
/// its chord (first finite → last finite vertex). Non-finite points are left as-is
/// (they act as NA breaks). No-ops when the chord has no direction.
fn offset_polyline(pts: &mut [(f32, f32)], o: f64) {
    let finite = |q: (f32, f32)| q.0.is_finite() && q.1.is_finite();
    let a = match pts.iter().position(|&q| finite(q)) {
        Some(a) => a,
        None => return,
    };
    let z = pts.iter().rposition(|&q| finite(q)).unwrap_or(a);
    let dx = (pts[z].0 - pts[a].0) as f64;
    let dy = (pts[z].1 - pts[a].1) as f64;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-9 {
        return;
    }
    let (ox, oy) = ((o * -dy / len) as f32, (o * dx / len) as f32);
    for p in pts.iter_mut() {
        if finite(*p) {
            p.0 += ox;
            p.1 += oy;
        }
    }
}

/// The four device-px control points of a self-loop's cubic-Bézier teardrop
/// (igraph's `loop()` shape): it leaves and re-enters the vertex `(cx, cy)`,
/// bulging out to extent `s` along `angle` (radians), with the two feet placed on
/// the node boundary at radius `foot` (0 = both at the vertex). `width` scales only
/// the lateral (perpendicular) component of the lobes, narrowing the petal's waist
/// without changing its length (`width = 1` is the full teardrop). Control points in
/// the local frame (axis = +x) — feet along the ±lobe direction, lobes at igraph's
/// `(0.4s, ±0.2s·width)` — are rotated by `angle` about the vertex and translated to it.
fn loop_control_points(cx: f64, cy: f64, s: f64, foot: f64, angle: f64, width: f64) -> [(f32, f32); 4] {
    // Unit direction of the lobe (0.4, 0.2): the feet sit on the boundary there.
    let inv = 1.0 / (0.4f64 * 0.4 + 0.2 * 0.2).sqrt();
    let (fdx, fdy) = (0.4 * inv, 0.2 * inv);
    let local = [
        (foot * fdx, foot * fdy),   // P0 — leaving foot
        (0.4 * s, 0.2 * s * width), // P1 — lateral offset scaled by width
        (0.4 * s, -0.2 * s * width),// P2
        (foot * fdx, -foot * fdy),  // P3 — returning foot
    ];
    let (ca, sa) = (angle.cos(), angle.sin());
    let mut out = [(0.0f32, 0.0f32); 4];
    for (k, &(px, py)) in local.iter().enumerate() {
        // Rotate in device (y-down) space, consistent with `sector`'s cos/sin use.
        out[k] = ((cx + px * ca - py * sa) as f32, (cy + px * sa + py * ca) as f32);
    }
    out
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

/// Decode a scalar cap (value + code) from the parallel FFI streams: `None` when
/// empty (no cap), else the first element. Used by `lines` (whole-path caps).
fn cap_scalar(value: &[f64], code: &[i32]) -> Option<(f64, Unit)> {
    value.first().map(|&v| (v, code.first().map(|&c| Unit::from_code(c)).unwrap_or(Unit::Mm)))
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
