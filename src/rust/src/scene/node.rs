//! The primitives a scene holds (`Node`) and the per-node metadata carried
//! alongside them.

use super::*;

/// A baseline for text set along a curve.
///
/// The points resolve exactly like any other coordinate pair, and arc length is
/// measured on the *resolved device-px* polyline. That is why this lives here
/// rather than on the R side: a viewport's pixel extent is not known until
/// render time, so glyph advances (points) and path length (npc/native) cannot
/// be put in the same space any earlier.
#[derive(Clone, Debug)]
pub(super) struct TextPath {
    pub(super) px: Vec<f64>,
    pub(super) py: Vec<f64>,
    /// Per-vertex units, like every other multi-point primitive. A scalar unit
    /// would quietly misplace a path whose points came from mixed units.
    pub(super) pxu: Vec<Unit>,
    pub(super) pyu: Vec<Unit>,
    /// Baseline shift perpendicular to the path, in points (+ = left of travel).
    pub(super) offset: f64,
}

// --- primitives -------------------------------------------------------------

#[derive(Clone, Debug)]
pub(super) enum Node {
    Rect {
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        xu: Unit,
        yu: Unit,
        wu: Unit,
        hu: Unit,
        gp: PartialGpar,
    },
    RoundRect {
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        r: f64,
        xu: Unit,
        yu: Unit,
        wu: Unit,
        hu: Unit,
        ru: Unit,
        sketch: Option<crate::sketch::SketchOpts>,
        key: Option<String>,
        gp: PartialGpar,
    },
    Lines {
        x: Vec<f64>,
        y: Vec<f64>,
        xu: Vec<Unit>,
        yu: Vec<Unit>,
        /// Optional whole-path end caps (absolute-length units): trim the first/
        /// last vertex inward by this device length, resolved at render. `None` =
        /// untouched. See `Segments` for the per-element form.
        scap: Option<(f64, Unit)>,
        ecap: Option<(f64, Unit)>,
        /// Optional signed perpendicular offset (absolute unit): rigidly translate
        /// the whole polyline sideways by this device length along the normal of
        /// its overall (chord) direction. `None` = untouched.
        off: Option<(f64, Unit)>,
        arrow: Option<Arrow>,
        /// Optional hand-drawn (sketch) rendering; `None` = crisp. See `sketch.rs`.
        sketch: Option<crate::sketch::SketchOpts>,
        /// Optional per-vertex width MULTIPLIER of the resolved `lwd`, one per
        /// vertex. `None` = a uniform stroke (the byte-identical path). `Some`
        /// makes this a variable-width stroke: the draw arm builds the ribbon
        /// with `ribbon::variable_stroke` and FILLS it, because no backend can
        /// stroke one path at several widths. Mutually exclusive with `sketch`
        /// (rejected in R).
        ///
        /// A multiplier rather than an absolute half-width because `lwd` may be
        /// INHERITED from the enclosing gpar stack: only the resolved `Gpar` in
        /// the draw arm knows the width this profile is scaling.
        hw: Option<Vec<f64>>,
        gp: PartialGpar,
        /// Optional data key for this single element (interactivity): emitted as
        /// `data-key` in SVG. `None` = none. See `Rects.keys` for the batched form.
        key: Option<String>,
    },
    Polygon {
        x: Vec<f64>,
        y: Vec<f64>,
        xu: Vec<Unit>,
        yu: Vec<Unit>,
        sketch: Option<crate::sketch::SketchOpts>,
        gp: PartialGpar,
        /// Optional data key (see `Lines.key`).
        key: Option<String>,
    },
    Circle {
        x: f64,
        y: f64,
        r: f64,
        xu: Unit,
        yu: Unit,
        ru: Unit,
        sketch: Option<crate::sketch::SketchOpts>,
        gp: PartialGpar,
    },
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
        /// Optional halo (shadowtext): `(colour, width_px)`. The glyph outlines are
        /// stroked in this colour *under* the fill, so a label stays legible over
        /// busy marks or map imagery. `None` (the default) leaves every backend's
        /// text path byte-for-byte as it was.
        halo: Option<(Rgba, f64)>,
        /// Source string + font descriptor, for vector backends that emit real
        /// `<text>` / embedded glyphs rather than filled outlines.
        label: String,
        family: String,
        face: String,
        size: f64,
        /// Optional baseline path. `None` (every ordinary label) places the glyph
        /// run at `(x, y)` exactly as before. `Some` walks the polyline by arc
        /// length and places each glyph at its pen position along it, rotated to
        /// the local tangent — see `TextPath`.
        tpath: Option<TextPath>,
        /// Optional data key (see `Lines.key`). A vectorised text grob compiles to
        /// one node per label, so this is genuinely per-label.
        key: Option<String>,
        gp: PartialGpar,
    },
    /// A batch of rectangles sharing one gpar (one FFI call, one resolve).
    Rects {
        x: Vec<f64>,
        y: Vec<f64>,
        w: Vec<f64>,
        h: Vec<f64>,
        xu: Vec<Unit>,
        yu: Vec<Unit>,
        wu: Vec<Unit>,
        hu: Vec<Unit>,
        sketch: Option<crate::sketch::SketchOpts>,
        gp: PartialGpar,
        /// Optional per-element data keys (interactivity): empty = none, else
        /// length `n`. Emitted as `data-key` on each rect in the SVG backend;
        /// ignored by raster/PDF.
        keys: Vec<String>,
    },
    /// A batch of circles sharing one gpar (also serves `points`). Markers with a
    /// solid/no fill take a fast path (one path, per-element transform).
    Circles {
        x: Vec<f64>,
        y: Vec<f64>,
        r: Vec<f64>,
        xu: Vec<Unit>,
        yu: Vec<Unit>,
        ru: Vec<Unit>,
        sketch: Option<crate::sketch::SketchOpts>,
        gp: PartialGpar,
        /// Per-element data keys (see `Rects.keys`). Non-empty forces the
        /// per-element emission path (the batched `draw_circles` fast path can't
        /// tag individual elements).
        keys: Vec<String>,
    },
    /// A batch of point markers with per-element `shape` codes (0 circle, 1 square,
    /// 2 triangle, 3 diamond, 4 plus, 5 cross, 6 triangle_down, 7 star); `size` is
    /// the marker radius.
    Markers {
        x: Vec<f64>,
        y: Vec<f64>,
        size: Vec<f64>,
        xu: Vec<Unit>,
        yu: Vec<Unit>,
        su: Vec<Unit>,
        shape: Vec<u32>,
        sketch: Option<crate::sketch::SketchOpts>,
        gp: PartialGpar,
        /// Per-element data keys (see `Rects.keys`).
        keys: Vec<String>,
    },
    /// A batch of hexagons (for hex-binning): `flat` the orientation, and `fill` a
    /// **per-element** colour (the binned-count colour); `gp` supplies only the
    /// uniform stroke (col/lwd/alpha). Geometry comes from one of two paths: if `w`
    /// (and `h`) are empty, each hex is *regular* with circumradius `size`; if they
    /// are non-empty they give the per-hex **full** width/height (corner-to-corner
    /// along each axis), resolved per-axis so the hex can be non-regular (`size` is
    /// then ignored).
    Hexagons {
        x: Vec<f64>,
        y: Vec<f64>,
        size: Vec<f64>,
        w: Vec<f64>,
        h: Vec<f64>,
        xu: Vec<Unit>,
        yu: Vec<Unit>,
        su: Vec<Unit>,
        wu: Vec<Unit>,
        hu: Vec<Unit>,
        fill: Vec<Rgba>,
        flat: bool,
        gp: PartialGpar,
        /// Per-element data keys (see `Rects.keys`).
        keys: Vec<String>,
    },
    /// A batch of annular sectors: centre `(x,y)`, inner/outer radius `r0`/`r1`,
    /// angles `theta0`/`theta1` in radians (0 at 3 o'clock, CCW). `fill` is a
    /// **per-element** colour; `gp` supplies the uniform stroke. `r0=0` ⇒ pie slice;
    /// `r0=r1` ⇒ an unfilled arc outline.
    Sectors {
        x: Vec<f64>,
        y: Vec<f64>,
        r0: Vec<f64>,
        r1: Vec<f64>,
        theta0: Vec<f64>,
        theta1: Vec<f64>,
        xu: Vec<Unit>,
        yu: Vec<Unit>,
        r0u: Vec<Unit>,
        r1u: Vec<Unit>,
        fill: Vec<Rgba>,
        /// Optional arrowhead on the outer arc's end(s) — for directed self-loops
        /// (an open arc, `r0 == r1`, with an absolute mm radius at a native
        /// centre). Placed tangent to the arc. `None` = no head (unchanged).
        arrow: Option<Arrow>,
        sketch: Option<crate::sketch::SketchOpts>,
        gp: PartialGpar,
        /// Per-element data keys (see `Rects.keys`).
        keys: Vec<String>,
    },
    /// A batch of disjoint line segments `(x0,y0)->(x1,y1)`, stroked in one pass.
    Segments {
        x0: Vec<f64>,
        y0: Vec<f64>,
        x1: Vec<f64>,
        y1: Vec<f64>,
        x0u: Vec<Unit>,
        y0u: Vec<Unit>,
        x1u: Vec<Unit>,
        y1u: Vec<Unit>,
        /// Optional per-element start/end caps (absolute-length units): shorten
        /// the drawn segment inward from each end by this device length, resolved
        /// at render. Empty = no caps (the batch is unchanged). Recycled on the R
        /// side to the element count, so `scap.len()` is either 0 or `n`.
        scap: Vec<f64>,
        ecap: Vec<f64>,
        scapu: Vec<Unit>,
        ecapu: Vec<Unit>,
        /// Optional per-element signed perpendicular offset (absolute unit): shift
        /// both endpoints sideways by this device length along the segment's left
        /// normal, applied *before* the caps/arrow. Empty = none; else length `n`.
        off: Vec<f64>,
        offu: Vec<Unit>,
        arrow: Option<Arrow>,
        sketch: Option<crate::sketch::SketchOpts>,
        gp: PartialGpar,
        /// Per-element data keys (see `Rects.keys`). Non-empty forces per-segment
        /// emission (the batch is otherwise stroked as one combined path).
        keys: Vec<String>,
        /// Per-segment stroke colour / width. **Empty** => the shared `gp` applies
        /// to the whole batch, and the combined fast path stays byte-identical.
        /// Non-empty => one entry per segment, and each is stroked on its own
        /// (which is what varying them costs).
        cols: Vec<Rgba>,
        lwds: Vec<f64>,
    },
    /// A batch of igraph-style self-loops: a cubic-Bézier teardrop per element,
    /// leaving/re-entering the vertex `(x,y)`, sized by an absolute `size` (and
    /// `foot` = the node radius the feet attach at), bulging along `angle` (rad),
    /// with an optional arrowhead tangent to the returning foot. All lengths are
    /// resolved to device px at render, so the loop tracks an mm node at any size.
    Loop {
        x: Vec<f64>,
        y: Vec<f64>,
        xu: Vec<Unit>,
        yu: Vec<Unit>,
        size: Vec<f64>,
        su: Vec<Unit>,
        foot: Vec<f64>,
        fu: Vec<Unit>,
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
        x: Vec<f64>,
        y: Vec<f64>,
        xu: Vec<Unit>,
        yu: Vec<Unit>,
        nper: Vec<usize>,
        evenodd: bool,
        sketch: Option<crate::sketch::SketchOpts>,
        gp: PartialGpar,
        /// Optional data key (see `Lines.key`) — e.g. one sf feature's polygon.
        key: Option<String>,
    },
    /// A straight-RGBA image (`iw` x `ih`, top-left) filling a `w` x `h` cell
    /// centred at `(x, y)`. Carries no gpar (handled in the walk's pre-pass).
    Image {
        rgba: Vec<u8>,
        iw: u32,
        ih: u32,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        xu: Unit,
        yu: Unit,
        wu: Unit,
        hu: Unit,
        interpolate: bool,
    },
    /// Opens an isolated compositing layer (paired with `GroupEnd`), optionally
    /// modulated by mask `mask` (an index into `Scene::masks`), composited at group
    /// opacity `alpha` (1.0 = opaque) and blend mode `blend`. The mask/opacity/blend
    /// are attached at the start because PDF must install them before the content.
    GroupStart {
        mask: Option<usize>,
        alpha: f32,
        blend: BlendKind,
        effect: GroupEffect,
    },
    /// Closes the layer and composites it.
    GroupEnd,
    /// Opens a repaint boundary (paired with `SubrasterEnd`): the raster backend
    /// caches the enclosed subtree's rasterisation keyed on `nid` (a per-subtree
    /// content-identity token from R) plus the boundary's resolved transform/clip
    /// and page size/dpi, and reuses it on later renders when unchanged. Vector
    /// backends ignore it and render the subtree inline (staying vector).
    SubrasterStart { nid: f64 },
    /// Closes the repaint boundary; the captured layer is memoised and composited.
    SubrasterEnd,
    /// Opens a named panel group (paired with `PanelEnd`): the SVG backend wraps the
    /// enclosed nodes in `<g data-vellum-panel="name">` so a host can target the
    /// panel (e.g. for pan/zoom); raster/PDF ignore it. Emitted for named viewports.
    /// When `pannable`, the SVG backend instead emits an outer clipped
    /// `<g data-vellum-panel>` around an inner `<g data-vellum-pan>` (hoisting the
    /// panel's clip to the outer, untransformed group) so a host can set a
    /// `transform` on the inner group and pan/zoom the marks while the clip stays put.
    PanelStart { name: String, pannable: bool },
    /// Closes the named panel group.
    PanelEnd,
}

impl Node {
    /// This node's own graphical parameters, or `None` for a structural node
    /// (image/group/subraster/panel marker) that carries none. Returning `Option`
    /// — rather than an `unreachable!()` — lets the walk skip an unhandled
    /// structural node defensively instead of panicking, and keeps the match
    /// exhaustive so a new variant must be classified at compile time.
    pub(super) fn gp(&self) -> Option<&PartialGpar> {
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
            | Node::Text { gp, .. } => Some(gp),
            Node::Image { .. }
            | Node::GroupStart { .. }
            | Node::GroupEnd
            | Node::SubrasterStart { .. }
            | Node::SubrasterEnd
            | Node::PanelStart { .. }
            | Node::PanelEnd => None,
        }
    }

    /// Mutable access to the node's own gpar (see [`Node::gp`]): the animation
    /// tween fades an entering or leaving element through it.
    pub(super) fn gp_mut(&mut self) -> Option<&mut PartialGpar> {
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
            | Node::Text { gp, .. } => Some(gp),
            _ => None,
        }
    }

    /// Whether this node carries an interactivity data key on any element: the
    /// same notion as a non-NA `key` in `scene_model()$elements`, which is what
    /// the widget counts to decide raster mode. Structural nodes and images are
    /// never keyed. A batch counts as keyed if any of its elements is.
    pub(super) fn is_keyed(&self) -> bool {
        match self {
            Node::RoundRect { key, .. }
            | Node::Lines { key, .. }
            | Node::Polygon { key, .. }
            | Node::Text { key, .. }
            | Node::Path { key, .. } => key.as_deref().is_some_and(|k| !k.is_empty()),
            Node::Rects { keys, .. }
            | Node::Circles { keys, .. }
            | Node::Markers { keys, .. }
            | Node::Hexagons { keys, .. }
            | Node::Sectors { keys, .. }
            | Node::Segments { keys, .. } => keys.iter().any(|k| !k.is_empty()),
            Node::Rect { .. }
            | Node::Circle { .. }
            | Node::Loop { .. }
            | Node::Image { .. }
            | Node::GroupStart { .. }
            | Node::GroupEnd
            | Node::SubrasterStart { .. }
            | Node::SubrasterEnd
            | Node::PanelStart { .. }
            | Node::PanelEnd => false,
        }
    }
}

/// Which nodes a render walk draws (the split render, VR-13). `All` is every
/// render's default; `Keyed` draws only the mark layer (keyed marks); `Unkeyed`
/// draws everything else (axes, gridlines, legends, unkeyed annotations).
/// Structural nodes (groups, masks, clips, panels) are kept in every layer, so a
/// mark keeps its clip, mask, opacity and blend group. Composited `Keyed` over
/// `Unkeyed` reproduces `All` whenever no unkeyed node paints over a keyed one
/// and no keyed mark blends with an unkeyed backdrop.
///
/// `UnkeyedBelow` / `UnkeyedAbove` (VW-21) partition `Unkeyed` by paint order
/// relative to the mark layer, so `UnkeyedBelow`, `Keyed`, `UnkeyedAbove`
/// stacked bottom to top also reproduce an annotation drawn over the marks. An
/// unkeyed node is "above" when a mark was painted before it within its
/// innermost named panel (a mark in a nested panel counts for every enclosing
/// panel); outside every named panel, any earlier mark counts. So an unkeyed
/// node interleaved between two keyed batches is above, while a later facet's
/// gridlines stay below that facet's own marks.
///
/// `KeyedFlagged` (VW-30) draws only the marks the display list (version 2)
/// flags: those a client cannot draw from the list (masks, blend modes,
/// effects, hatches, patterns, repeating gradients, gradient strokes, text),
/// grouped into runs in paint order (`render::assign_runs`); `LayerFilter::run`
/// picks one run (0 = all of them).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Layer {
    All,
    Unkeyed,
    Keyed,
    UnkeyedBelow,
    UnkeyedAbove,
    KeyedFlagged,
}

impl Layer {
    /// Codes match `.layer_code()` in R: 0 all, 1 unkeyed, 2 keyed,
    /// 3 unkeyed_below, 4 unkeyed_above, 5 keyed_flagged.
    pub fn from_code(c: i32) -> Layer {
        match c {
            1 => Layer::Unkeyed,
            2 => Layer::Keyed,
            3 => Layer::UnkeyedBelow,
            4 => Layer::UnkeyedAbove,
            5 => Layer::KeyedFlagged,
            _ => Layer::All,
        }
    }

    /// Whether this layer is an overlay drawn on a transparent page (no page
    /// background): the mark layer and the furniture above it.
    pub fn is_overlay(self) -> bool {
        matches!(
            self,
            Layer::Keyed | Layer::UnkeyedAbove | Layer::KeyedFlagged
        )
    }

    /// Whether the layer needs the per-node paint-order split.
    pub fn needs_order(self) -> bool {
        matches!(self, Layer::UnkeyedBelow | Layer::UnkeyedAbove)
    }
}

/// A [`Layer`] plus the optional panel restriction of the mark layer: when
/// `panels` is `Some`, a keyed node counts as a mark only if its innermost named
/// panel is listed (so a keyed legend swatch can stay with the furniture). The
/// layers stay exact complements either way. `above` (filled by
/// `Scene::with_paint_order` for the below/above layers) is parallel to the
/// top-level node list: whether a mark precedes the node in its panel.
/// `flagged` (filled by `Scene::with_flagged_runs` for `KeyedFlagged`) maps a
/// top-level node to its flagged run, and `run` restricts that layer to one
/// run (0 = every run).
#[derive(Clone, Debug)]
pub struct LayerFilter {
    pub layer: Layer,
    pub panels: Option<Vec<String>>,
    pub above: Vec<bool>,
    pub flagged: Option<std::collections::HashMap<u32, u32>>,
    pub run: u32,
}

impl LayerFilter {
    pub fn all() -> Self {
        LayerFilter {
            layer: Layer::All,
            panels: None,
            above: Vec::new(),
            flagged: None,
            run: 0,
        }
    }

    pub fn is_all(&self) -> bool {
        self.layer == Layer::All
    }

    /// Whether a drawing node inside innermost named panel `panel` is a mark
    /// (belongs to the keyed layer).
    pub(super) fn is_mark(&self, node: &Node, panel: &str) -> bool {
        node.is_keyed()
            && self
                .panels
                .as_ref()
                .is_none_or(|ps| ps.iter().any(|p| p == panel))
    }

    /// Whether drawing node `i`, inside innermost named panel `panel` (empty
    /// when outside every panel), belongs to this layer.
    pub(super) fn keeps(&self, i: usize, node: &Node, panel: &str) -> bool {
        match self.layer {
            Layer::All => true,
            Layer::Keyed => self.is_mark(node, panel),
            Layer::KeyedFlagged => {
                self.is_mark(node, panel)
                    && self
                        .flagged
                        .as_ref()
                        .and_then(|f| f.get(&(i as u32)))
                        .is_some_and(|&r| self.run == 0 || r == self.run)
            }
            Layer::Unkeyed => !self.is_mark(node, panel),
            Layer::UnkeyedBelow | Layer::UnkeyedAbove => {
                !self.is_mark(node, panel)
                    && self.above.get(i).copied().unwrap_or(false)
                        == (self.layer == Layer::UnkeyedAbove)
            }
        }
    }
}

/// A mask attached to a viewport: the grob content to rasterize plus how its
/// pixels modulate coverage. Filled while the mask grob is compiled.
#[derive(Clone, Debug)]
pub(super) struct MaskDef {
    pub(super) kind: MaskKind,
    pub(super) nodes: Vec<(usize, Node)>,
}

/// Per-node semantic metadata (Feature: per-element identity). Carried alongside
/// each drawn node and emitted by vector backends (SVG `data-*`/`role`) for
/// interactivity, accessibility, and testing. Empty fields are omitted.
#[derive(Clone, Default, Debug)]
pub struct NodeMeta {
    pub id: String,
    pub role: String,
    pub name: String,
}

impl NodeMeta {
    pub fn is_empty(&self) -> bool {
        self.id.is_empty() && self.role.is_empty() && self.name.is_empty()
    }
    /// Pre-formatted SVG attributes (`data-vellum-*` + ARIA `role`) for this node.
    pub fn svg_attrs(&self) -> String {
        let mut s = String::new();
        if !self.id.is_empty() {
            s.push_str(&format!("data-vellum-id=\"{}\"", xml_escape(&self.id)));
        }
        if !self.name.is_empty() {
            if !s.is_empty() {
                s.push(' ');
            }
            s.push_str(&format!("data-vellum-name=\"{}\"", xml_escape(&self.name)));
        }
        if !self.role.is_empty() {
            if !s.is_empty() {
                s.push(' ');
            }
            s.push_str(&format!("role=\"{}\"", xml_escape(&self.role)));
        }
        s
    }
}

/// An arrowhead spec attached to a `Lines`/`Segments` node. `len` is in inches
/// (an absolute length, resolved to px via dpi); `ends` is a bitmask (1 = start,
/// 2 = end); `closed` fills a triangular head, else strokes a two-barb "V".
#[derive(Clone, Copy, Debug)]
pub(super) struct Arrow {
    pub(super) angle: f64,
    pub(super) len: f64,
    pub(super) ends: u8,
    pub(super) closed: bool,
}

/// The per-element data key at index `i`, or `None` when the batch carries no
/// keys (or `i` is out of range, or the key is empty). Used by the render loop to
/// tag each drawn element with `data-key` in the SVG backend.
pub(super) fn key_at(keys: &[String], i: usize) -> Option<&str> {
    match keys.get(i) {
        Some(k) if !k.is_empty() => Some(k.as_str()),
        _ => None,
    }
}
