//! One geometry source for every query, recorded from the render walk.
//!
//! The queries that answer "where is this mark" -- `element_geometry()`,
//! `vl_nearest()` (the pick table), `hit_test()`, and the per-node and
//! per-element boxes behind `scene_model()` and the linter -- used to carry one
//! hand-written geometry arm per node kind each. Four copies of "where does a
//! segment land" drifted from the one copy that mattered, the renderer's: they
//! ignored segment offsets and end caps, dropped hexagons and sectors from
//! picking, and kept rotated text in an unrotated box.
//!
//! Now there is one copy. The render walk (`Scene::render_nodes`) hands the
//! geometry it resolves for each element -- after offsets, caps, trims and
//! rotation -- to a [`GeomSink`] when the backend has one. The painting backends
//! have none, so a normal render pays nothing; [`RecordBackend`] has one and
//! paints nothing, so a recording walk does no rasterisation. Each query then
//! reads the recording instead of re-deriving shapes.
//!
//! Geometry is recorded whether or not it is painted: a mark with no fill and no
//! stroke (an invisible hover target) still occupies its shape, exactly as it
//! did when each query computed it from the node.

use tiny_skia::{FillRule, Path, Transform};

use crate::color::Rgba;
use crate::pick::{circle_dist, inside_rings, poly_dist, seg_dist2};
use crate::render::{flatten_rings, BlendKind, Clip, GroupEffect, MaskLayer, RenderBackend, ResolvedPaint, StrokeStyle, TextRun};
use crate::units::rotation_about;

/// One recorded piece of an element, in device px (y down).
#[derive(Clone, Debug)]
pub enum Part {
    /// Closed rings filled under one rule: a rect, polygon, path (holes and
    /// all), hexagon, sector wedge, image cell, or a text label's quad.
    Fill { rings: Vec<Vec<(f64, f64)>>, evenodd: bool },
    /// An open centre-line, stroked `width` px wide: a segment or polyline after
    /// its offset and caps. Non-finite vertices are breaks (an R `NA`).
    Stroke { pts: Vec<(f64, f64)>, width: f64 },
    /// A round mark: centre and radius.
    Disc { cx: f64, cy: f64, r: f64 },
}

/// The recorded geometry of a scene: `[node][element]` -> parts, indexed by the
/// node's position in the scene's draw order and the element's position within
/// its batch (0 for a single-shape node). An element that drew nothing -- an
/// `NA` position, a segment its caps consumed -- has no parts.
pub type Recording = Vec<Vec<Vec<Part>>>;

/// Where the render walk deposits geometry. Coordinates arrive in the current
/// viewport's local px and are stored in device px.
#[derive(Debug)]
pub struct GeomSink {
    t: Transform,
    node: usize,
    rec: Recording,
}

impl GeomSink {
    pub fn new(n_nodes: usize) -> Self {
        GeomSink { t: Transform::identity(), node: 0, rec: vec![Vec::new(); n_nodes] }
    }

    /// Start recording node `node`, drawn through viewport transform `t`.
    pub fn begin(&mut self, node: usize, t: Transform) {
        if self.rec.len() <= node {
            self.rec.resize(node + 1, Vec::new());
        }
        self.node = node;
        self.t = t;
    }

    pub fn finish(self) -> Recording {
        self.rec
    }

    fn push(&mut self, elem: usize, part: Part) {
        let node = &mut self.rec[self.node];
        if node.len() <= elem {
            node.resize(elem + 1, Vec::new());
        }
        node[elem].push(part);
    }

    fn dev(&self, x: f64, y: f64) -> (f64, f64) {
        map(&self.t, x, y)
    }

    /// One closed ring (nonzero), local px.
    pub fn ring(&mut self, elem: usize, pts: &[(f64, f64)]) {
        let ring = pts.iter().map(|&(x, y)| self.dev(x, y)).collect();
        self.push(elem, Part::Fill { rings: vec![ring], evenodd: false });
    }

    /// An axis-aligned local rect, as a ring.
    pub fn rect(&mut self, elem: usize, x0: f64, y0: f64, w: f64, h: f64) {
        self.ring(elem, &[(x0, y0), (x0 + w, y0), (x0 + w, y0 + h), (x0, y0 + h)]);
    }

    /// The closed rings of a path exactly as it is filled, under `rule`.
    pub fn path(&mut self, elem: usize, path: &Path, rule: FillRule) {
        let rings: Vec<Vec<(f64, f64)>> = flatten_rings(path)
            .into_iter()
            .map(|r| r.into_iter().map(|(x, y)| self.dev(x as f64, y as f64)).collect())
            .collect();
        if !rings.is_empty() {
            self.push(elem, Part::Fill { rings, evenodd: rule == FillRule::EvenOdd });
        }
    }

    /// An open polyline stroked `width` px wide, local px.
    pub fn stroke(&mut self, elem: usize, pts: &[(f32, f32)], width: f64) {
        let pts = pts.iter().map(|&(x, y)| self.dev(x as f64, y as f64)).collect();
        self.push(elem, Part::Stroke { pts, width });
    }

    /// An open path (curves flattened) stroked `width` px wide.
    pub fn stroke_path(&mut self, elem: usize, path: &Path, width: f64) {
        for run in flatten_rings(path) {
            self.stroke(elem, &run, width);
        }
    }

    /// A disc, local px. The radius takes the transform's scale.
    pub fn disc(&mut self, elem: usize, cx: f64, cy: f64, r: f64) {
        let (dx, dy) = self.dev(cx, cy);
        let t = self.t;
        let s = ((t.sx as f64) * (t.sy as f64) - (t.kx as f64) * (t.ky as f64)).abs().sqrt();
        self.push(elem, Part::Disc { cx: dx, cy: dy, r: r * s });
    }

    /// A text run's box, rotated about its anchor exactly as backends draw it.
    pub fn text(&mut self, run: &TextRun, t: Transform) {
        let tr = if run.rot != 0.0 { t.pre_concat(rotation_about(run.rot, run.ax, run.ay)) } else { t };
        let x0 = run.ax - run.hjust * run.w;
        let y0 = run.ay - (1.0 - run.vjust) * run.h;
        let ring = [(x0, y0), (x0 + run.w, y0), (x0 + run.w, y0 + run.h), (x0, y0 + run.h)]
            .iter()
            .map(|&(x, y)| map(&tr, x, y))
            .collect();
        self.push(0, Part::Fill { rings: vec![ring], evenodd: false });
    }
}

fn map(t: &Transform, x: f64, y: f64) -> (f64, f64) {
    let (sx, ky, kx, sy, tx, ty) = (t.sx as f64, t.ky as f64, t.kx as f64, t.sy as f64, t.tx as f64, t.ty as f64);
    (sx * x + kx * y + tx, ky * x + sy * y + ty)
}

/// A backend that paints nothing and records every element's geometry.
pub struct RecordBackend {
    pub sink: GeomSink,
}

impl RecordBackend {
    pub fn new(n_nodes: usize) -> Self {
        RecordBackend { sink: GeomSink::new(n_nodes) }
    }
}

impl RenderBackend for RecordBackend {
    fn fill_path(&mut self, _: &Path, _: Transform, _: &ResolvedPaint, _: FillRule, _: &Clip) {}
    fn stroke_path(&mut self, _: &Path, _: Transform, _: Rgba, _: &StrokeStyle, _: &Clip) {}
    /// Text is recorded here rather than in the walk, so a label set along a
    /// path (fanned out into one run per glyph) records each glyph's box.
    fn draw_text(&mut self, run: &TextRun, transform: Transform, _: &Clip) {
        self.sink.text(run, transform);
    }
    fn begin_group(&mut self, _: Option<MaskLayer>, _: f32, _: BlendKind, _: GroupEffect) {}
    fn end_group(&mut self) {}
    fn draw_image(&mut self, _: &[u8], _: u32, _: u32, _: f64, _: f64, _: f64, _: f64, _: bool, _: Transform, _: &Clip) {}
    fn geom_sink(&mut self) -> Option<&mut GeomSink> {
        Some(&mut self.sink)
    }
}

// --- reading a recording -----------------------------------------------------

/// Device-px bounding box over an element's parts (finite vertices only; a
/// disc contributes its full extent). `None` when nothing finite was recorded.
pub fn parts_bbox(parts: &[Part]) -> Option<(f64, f64, f64, f64)> {
    let mut acc: Option<(f64, f64, f64, f64)> = None;
    let mut add = |x0: f64, y0: f64, x1: f64, y1: f64| {
        if !(x0.is_finite() && y0.is_finite() && x1.is_finite() && y1.is_finite()) {
            return;
        }
        acc = Some(match acc {
            None => (x0, y0, x1, y1),
            Some(a) => (a.0.min(x0), a.1.min(y0), a.2.max(x1), a.3.max(y1)),
        });
    };
    for p in parts {
        match p {
            Part::Fill { rings, .. } => {
                for &(x, y) in rings.iter().flatten() {
                    add(x, y, x, y);
                }
            }
            Part::Stroke { pts, .. } => {
                for &(x, y) in pts {
                    add(x, y, x, y);
                }
            }
            Part::Disc { cx, cy, r } => add(cx - r, cy - r, cx + r, cy + r),
        }
    }
    acc
}

/// Union of two optional boxes.
pub fn union_bbox(a: Option<(f64, f64, f64, f64)>, b: Option<(f64, f64, f64, f64)>) -> Option<(f64, f64, f64, f64)> {
    match (a, b) {
        (Some(a), Some(b)) => Some((a.0.min(b.0), a.1.min(b.1), a.2.max(b.2), a.3.max(b.3))),
        (a, None) => a,
        (None, b) => b,
    }
}

fn unzip(pts: &[(f64, f64)]) -> (Vec<f64>, Vec<f64>) {
    pts.iter().copied().unzip()
}

/// Distance from a device-px point to an element: zero inside a filled shape or
/// a disc, perpendicular distance to a stroke's centre-line, the minimum over
/// parts.
///
/// A filled shape's inside is decided once, across all its rings, by the rule
/// it is painted with -- even-odd parity or nonzero winding -- so a point in a
/// polygon's hole is outside, exactly as the renderer leaves it unpainted.
/// Outside, the distance is to the nearest edge of any ring (for a point in a
/// hole, the hole's own boundary).
pub fn parts_dist(parts: &[Part], px: f64, py: f64) -> f64 {
    let mut best = f64::INFINITY;
    for p in parts {
        let d = match p {
            Part::Fill { rings, evenodd } => {
                if inside_rings(px, py, rings, *evenodd) {
                    0.0
                } else {
                    rings
                        .iter()
                        .map(|r| {
                            let (xs, ys) = unzip(r);
                            // Edges only: containment was settled above.
                            poly_dist(px, py, &xs, &ys, false).min(closing_edge(px, py, r))
                        })
                        .fold(f64::INFINITY, f64::min)
                }
            }
            Part::Stroke { pts, .. } => {
                let (xs, ys) = unzip(pts);
                poly_dist(px, py, &xs, &ys, false)
            }
            Part::Disc { cx, cy, r } => circle_dist(px, py, *cx, *cy, *r),
        };
        best = best.min(d);
    }
    best
}

/// Distance to a ring's closing edge (last vertex back to the first).
fn closing_edge(px: f64, py: f64, r: &[(f64, f64)]) -> f64 {
    match (r.first(), r.last()) {
        (Some(a), Some(z)) if r.len() > 2 => seg_dist2(px, py, z.0, z.1, a.0, a.1).sqrt(),
        _ => f64::INFINITY,
    }
}

/// The fill rule an element is hit-tested (and painted) under, for
/// `element_geometry()`'s `rule` column: `"evenodd"` or `"nonzero"` for a
/// filled shape, `None` for one with no interior (a stroke, a disc).
pub fn parts_rule(parts: &[Part]) -> Option<&'static str> {
    let mut rule = None;
    for p in parts {
        if let Part::Fill { evenodd, .. } = p {
            if *evenodd {
                return Some("evenodd");
            }
            rule = Some("nonzero");
        }
    }
    rule
}

/// Does an element cover a device-px point, the way the rasteriser would fill
/// it? Fills follow their fill rule; a stroke covers a band of half its width,
/// but never narrower than `min_half` (a hairline must stay clickable).
pub fn parts_cover(parts: &[Part], px: f64, py: f64, min_half: f64) -> bool {
    parts.iter().any(|p| match p {
        Part::Fill { rings, evenodd } => inside_rings(px, py, rings, *evenodd),
        Part::Disc { cx, cy, r } => (px - cx).powi(2) + (py - cy).powi(2) <= r * r,
        Part::Stroke { pts, width } => {
            let band = (width * 0.5).max(min_half);
            pts.windows(2).any(|w| seg_dist2(px, py, w[0].0, w[0].1, w[1].0, w[1].1) <= band * band)
        }
    })
}

/// An element's vertex runs, one per ring/polyline, for `element_geometry()`.
/// A disc is its centre.
pub fn parts_runs(parts: &[Part]) -> Vec<Vec<(f64, f64)>> {
    let mut out = Vec::new();
    for p in parts {
        match p {
            Part::Fill { rings, .. } => out.extend(rings.iter().cloned()),
            Part::Stroke { pts, .. } => out.push(pts.clone()),
            Part::Disc { cx, cy, .. } => out.push(vec![(*cx, *cy)]),
        }
    }
    out
}
