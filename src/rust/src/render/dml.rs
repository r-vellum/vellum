//! The DrawingML backend: a scene as editable PowerPoint shapes.
//!
//! The output is one `<p:grpSp>` holding a `p:sp` per path (`a:custGeom`), a
//! text box per label, a `p:pic` per raster and a nested `p:grpSp` per panel,
//! which officer's `ph_with()` or the standalone `.pptx` writer places on a
//! slide. Point marks are the exception: a layer of them is merged into a few
//! multi-path shapes (see `DmlBackend::flush_points`).
//!
//! DrawingML's `a:xfrm` carries only an offset, an extent, a rotation and flips:
//! there is no general affine transform. So, as the SVG backend does for solid
//! fills, every path is baked into slide coordinates (EMU, 914400 per inch) and
//! written relative to its own bounding box: `a:off`/`a:ext` are the box, and the
//! `a:path` coordinate space is the box size, so one path unit is one EMU.
//!
//! Text is native (an editable `a:t` run in a box sized to vellum's measured
//! extents, aligned from `hjust`/`vjust` so a substituted font grows away from
//! the anchor). An `md()` label writes one run per styled span. Labels text
//! runs cannot express -- `tex()` labels and math in `md()`, halos, text set on
//! a path -- become glyph outlines, as in SVG.

use super::*;
use crate::font::font_family_name;

/// EMU per inch: DrawingML's length unit.
pub const EMU_PER_INCH: f64 = 914_400.0;

/// Marks a media reference in the fragment until the caller decides what it
/// resolves to (a file path for officer, a relationship id for a package).
/// R strings cannot hold NUL, so no label or name contains it.
pub(crate) const MEDIA_TOKEN: char = '\0';

/// The namespaces a stand-alone fragment declares on its root group.
pub(crate) const DML_NS: &str =
    "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" \
     xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" \
     xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"";

/// Curve flattening tolerance in device px, for the geometry that has to be
/// polygons (fill normalisation, clipping).
const FLATTEN_TOL: f64 = 0.05;

pub(super) type Pt = (f64, f64);

/// One segment of a path baked into device px.
#[derive(Clone, Debug)]
pub(super) enum Seg {
    Move(Pt),
    Line(Pt),
    Quad(Pt, Pt),
    Cubic(Pt, Pt, Pt),
    Close,
}

/// A path in device px, the form every shape is written from.
#[derive(Clone, Debug, Default)]
pub(super) struct DevPath {
    pub segs: Vec<Seg>,
}

fn map_pt(t: Transform, p: tiny_skia::Point) -> Pt {
    let (x, y) = (p.x as f64, p.y as f64);
    (
        t.sx as f64 * x + t.kx as f64 * y + t.tx as f64,
        t.ky as f64 * x + t.sy as f64 * y + t.ty as f64,
    )
}

impl DevPath {
    /// Bake `path` through `t` into device px.
    pub fn from_path(path: &Path, t: Transform) -> DevPath {
        use tiny_skia::PathSegment as S;
        let segs = path
            .segments()
            .map(|s| match s {
                S::MoveTo(p) => Seg::Move(map_pt(t, p)),
                S::LineTo(p) => Seg::Line(map_pt(t, p)),
                S::QuadTo(c, p) => Seg::Quad(map_pt(t, c), map_pt(t, p)),
                S::CubicTo(c1, c2, p) => Seg::Cubic(map_pt(t, c1), map_pt(t, c2), map_pt(t, p)),
                S::Close => Seg::Close,
            })
            .collect();
        DevPath { segs }
    }

    /// A closed polygon per ring.
    pub fn from_rings(rings: &[Vec<Pt>]) -> DevPath {
        let mut segs = Vec::new();
        for r in rings {
            if r.len() < 2 {
                continue;
            }
            segs.push(Seg::Move(r[0]));
            for p in &r[1..] {
                segs.push(Seg::Line(*p));
            }
            segs.push(Seg::Close);
        }
        DevPath { segs }
    }

    /// An open polyline per entry.
    pub fn from_polylines(lines: &[Vec<Pt>]) -> DevPath {
        let mut segs = Vec::new();
        for l in lines {
            if l.len() < 2 {
                continue;
            }
            segs.push(Seg::Move(l[0]));
            for p in &l[1..] {
                segs.push(Seg::Line(*p));
            }
        }
        DevPath { segs }
    }

    pub fn is_empty(&self) -> bool {
        !self
            .segs
            .iter()
            .any(|s| !matches!(s, Seg::Move(_) | Seg::Close))
    }

    fn points(&self) -> impl Iterator<Item = Pt> + '_ {
        self.segs.iter().flat_map(|s| {
            let v: Vec<Pt> = match *s {
                Seg::Move(p) | Seg::Line(p) => vec![p],
                Seg::Quad(c, p) => vec![c, p],
                Seg::Cubic(c1, c2, p) => vec![c1, c2, p],
                Seg::Close => vec![],
            };
            v.into_iter()
        })
    }

    /// Bounds of every point, control points included (`[x0, y0, x1, y1]`).
    pub fn bounds(&self) -> Option<[f64; 4]> {
        let mut b: Option<[f64; 4]> = None;
        for (x, y) in self.points() {
            if !(x.is_finite() && y.is_finite()) {
                continue;
            }
            b = Some(match b {
                None => [x, y, x, y],
                Some([x0, y0, x1, y1]) => [x0.min(x), y0.min(y), x1.max(x), y1.max(y)],
            });
        }
        b
    }

    /// Each subpath flattened to points, with whether it was closed.
    pub fn flatten(&self) -> Vec<(Vec<Pt>, bool)> {
        let mut out: Vec<(Vec<Pt>, bool)> = Vec::new();
        let mut cur: Vec<Pt> = Vec::new();
        let flush = |cur: &mut Vec<Pt>, closed: bool, out: &mut Vec<(Vec<Pt>, bool)>| {
            if cur.len() >= 2 {
                out.push((std::mem::take(cur), closed));
            } else {
                cur.clear();
            }
        };
        let mut start: Option<Pt> = None;
        for s in &self.segs {
            match *s {
                Seg::Move(p) => {
                    flush(&mut cur, false, &mut out);
                    cur.push(p);
                    start = Some(p);
                }
                Seg::Line(p) => cur.push(p),
                Seg::Quad(c, p) => {
                    let a = *cur.last().unwrap_or(&c);
                    let n = curve_steps(&[a, c, p]);
                    for i in 1..=n {
                        let t = i as f64 / n as f64;
                        let mt = 1.0 - t;
                        cur.push((
                            mt * mt * a.0 + 2.0 * mt * t * c.0 + t * t * p.0,
                            mt * mt * a.1 + 2.0 * mt * t * c.1 + t * t * p.1,
                        ));
                    }
                }
                Seg::Cubic(c1, c2, p) => {
                    let a = *cur.last().unwrap_or(&c1);
                    let n = curve_steps(&[a, c1, c2, p]);
                    for i in 1..=n {
                        let t = i as f64 / n as f64;
                        let mt = 1.0 - t;
                        let (b0, b1, b2, b3) =
                            (mt * mt * mt, 3.0 * mt * mt * t, 3.0 * mt * t * t, t * t * t);
                        cur.push((
                            b0 * a.0 + b1 * c1.0 + b2 * c2.0 + b3 * p.0,
                            b0 * a.1 + b1 * c1.1 + b2 * c2.1 + b3 * p.1,
                        ));
                    }
                }
                Seg::Close => {
                    let st = start;
                    flush(&mut cur, true, &mut out);
                    // A segment after a close continues from the subpath start.
                    if let Some(p) = st {
                        cur.push(p);
                    }
                }
            }
        }
        flush(&mut cur, false, &mut out);
        out
    }

    /// The number of subpaths that draw something.
    fn subpath_bounds(&self) -> Vec<[f64; 4]> {
        let mut out = Vec::new();
        let mut cur: Option<[f64; 4]> = None;
        let grow = |cur: &mut Option<[f64; 4]>, (x, y): Pt| {
            *cur = Some(match *cur {
                None => [x, y, x, y],
                Some([x0, y0, x1, y1]) => [x0.min(x), y0.min(y), x1.max(x), y1.max(y)],
            });
        };
        for s in &self.segs {
            match *s {
                Seg::Move(p) => {
                    if let Some(b) = cur.take() {
                        out.push(b);
                    }
                    grow(&mut cur, p);
                }
                Seg::Line(p) => grow(&mut cur, p),
                Seg::Quad(c, p) => {
                    grow(&mut cur, c);
                    grow(&mut cur, p);
                }
                Seg::Cubic(c1, c2, p) => {
                    grow(&mut cur, c1);
                    grow(&mut cur, c2);
                    grow(&mut cur, p);
                }
                Seg::Close => {}
            }
        }
        if let Some(b) = cur {
            out.push(b);
        }
        out
    }
}

/// Subdivision count keeping a curve within [`FLATTEN_TOL`] of its chords.
fn curve_steps(ctrl: &[Pt]) -> usize {
    let (a, b) = (ctrl[0], ctrl[ctrl.len() - 1]);
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let len = dx.hypot(dy);
    let dev = ctrl[1..ctrl.len() - 1]
        .iter()
        .map(|p| {
            if len > 0.0 {
                ((p.0 - a.0) * dy - (p.1 - a.1) * dx).abs() / len
            } else {
                (p.0 - a.0).hypot(p.1 - a.1)
            }
        })
        .fold(0.0, f64::max);
    let n = (dev / FLATTEN_TOL).sqrt().ceil();
    if n.is_finite() {
        (n as usize).clamp(1, 256)
    } else {
        1
    }
}

/// Whether any two of `boxes` overlap (sweep over x).
fn any_overlap(boxes: &[[f64; 4]]) -> bool {
    let mut idx: Vec<usize> = (0..boxes.len()).collect();
    idx.sort_by(|&a, &b| boxes[a][0].total_cmp(&boxes[b][0]));
    let mut active: Vec<usize> = Vec::new();
    for &i in &idx {
        let b = boxes[i];
        active.retain(|&j| boxes[j][2] >= b[0]);
        if active
            .iter()
            .any(|&j| boxes[j][1] <= b[3] && b[1] <= boxes[j][3])
        {
            return true;
        }
        active.push(i);
    }
    false
}

/// Rewrite a fill so it means the same under either fill rule. DrawingML has no
/// fill-rule attribute, so a path whose subpaths overlap could come out with or
/// without holes depending on the application. Subpaths with disjoint bounds
/// cannot disagree and stay as they are (curves kept); overlapping ones are
/// resolved with `i_overlay` into outlines with explicit holes.
pub(super) fn normalize_fill(path: DevPath, rule: FillRule) -> DevPath {
    let boxes = path.subpath_bounds();
    if boxes.len() <= 1 || !any_overlap(&boxes) {
        return path;
    }
    use i_overlay::core::fill_rule::FillRule as IFill;
    use i_overlay::float::simplify::SimplifyShape;
    let rings: Vec<Vec<[f64; 2]>> = path
        .flatten()
        .into_iter()
        .filter(|(r, _)| r.len() >= 3)
        .map(|(r, _)| r.into_iter().map(|(x, y)| [x, y]).collect())
        .collect();
    let fr = match rule {
        FillRule::EvenOdd => IFill::EvenOdd,
        FillRule::Winding => IFill::NonZero,
    };
    let shapes = rings.simplify_shape(fr);
    let rings: Vec<Vec<Pt>> = shapes
        .into_iter()
        .flatten()
        .filter(|c| c.len() >= 3)
        .map(|c| c.into_iter().map(|p| (p[0], p[1])).collect())
        .collect();
    DevPath::from_rings(&rings)
}

/// The scale of `t` when it is a similarity (uniform scale, rotation,
/// translation, possibly a reflection), so lengths drawn under it scale by one
/// factor.
fn uniform_scale(t: Transform) -> Option<f64> {
    let (sx, ky, kx, sy) = (t.sx as f64, t.ky as f64, t.kx as f64, t.sy as f64);
    let a = sx.hypot(ky);
    let b = kx.hypot(sy);
    let tol = 1e-6 * a.max(b);
    let orth = (sx * kx + ky * sy).abs() <= tol * a.max(b);
    if a > 0.0 && a.is_finite() && (a - b).abs() <= tol && orth {
        Some(a)
    } else {
        None
    }
}

/// `RRGGBB` for an sRGB colour.
fn hex(c: Rgba) -> String {
    format!("{:02X}{:02X}{:02X}", c.r, c.g, c.b)
}

/// `<a:srgbClr>` with an `a:alpha` child when the colour is translucent.
/// `mul` scales the alpha (group opacity folded into a lone child).
fn srgb(c: Rgba, mul: f32) -> String {
    let a = (c.a as f64 / 255.0) * mul as f64;
    if a >= 1.0 {
        format!("<a:srgbClr val=\"{}\"/>", hex(c))
    } else {
        format!(
            "<a:srgbClr val=\"{}\"><a:alpha val=\"{}\"/></a:srgbClr>",
            hex(c),
            (a.max(0.0) * 100_000.0).round() as i64
        )
    }
}

fn solid_fill(c: Rgba, mul: f32) -> String {
    format!("<a:solidFill>{}</a:solidFill>", srgb(c, mul))
}

/// `bold`, `italic` from a text run's face string (`"bold.italic"`, or with a
/// numeric weight suffix, `"italic@300"`: weight 600 and up is bold).
fn face_flags(face: &str) -> (bool, bool) {
    let (name, weight) = match face.split_once('@') {
        Some((f, w)) => (f, w.parse::<u16>().ok()),
        None => (face, None),
    };
    let bold = match weight {
        Some(w) => w >= 600,
        None => name.contains("bold"),
    };
    let italic = name.contains("italic") || name.contains("oblique");
    (bold, italic)
}

/// The typeface a text run names: the family of the font file vellum measured
/// with (so a viewer that has it lays the text out exactly), else the requested
/// family, with R's generic aliases mapped to fonts Office ships.
fn typeface(run: &TextRun) -> String {
    typeface_at(run, 0)
}

/// [`typeface`] from the font of glyph `g` (the first glyph of a run).
fn typeface_at(run: &TextRun, g: usize) -> String {
    if let (Some(p), Some(f)) = (run.gpath.get(g), run.gface.get(g)) {
        if let Some(name) = font_family_name(p, *f) {
            return name;
        }
    }
    match run.family {
        "" | "sans" | "sans-serif" => "Arial".to_string(),
        "serif" => "Times New Roman".to_string(),
        "mono" | "monospace" => "Courier New".to_string(),
        f => f.to_string(),
    }
}

/// Device-px bounds of several paths.
fn bounds_of(paths: &[DevPath]) -> Option<[f64; 4]> {
    paths.iter().filter_map(|p| p.bounds()).reduce(|a, b| {
        [
            a[0].min(b[0]),
            a[1].min(b[1]),
            a[2].max(b[2]),
            a[3].max(b[3]),
        ]
    })
}

/// The most point marks merged into one shape: enough that a large layer
/// becomes a few dozen shapes, few enough that each stays quick to select,
/// edit and draw in applications that redraw a shape whole.
const MAX_MARKS: usize = 1000;

/// The largest device-px coordinate written: far inside DrawingML's
/// coordinate range (about 2.7e13 EMU) at any resolution, and far enough off
/// the page that clamping a long line's end leaves its visible part straight.
const MAX_PX: f64 = 1.0e8;

fn clamp_px(v: f64) -> f64 {
    if v.is_nan() {
        0.0
    } else {
        v.clamp(-MAX_PX, MAX_PX)
    }
}

/// Escape text for DrawingML XML: drop the characters XML 1.0 cannot carry
/// (C0 controls other than tab, newline and carriage return, U+FFFE, U+FFFF),
/// then escape markup. A label holding a stray control character would
/// otherwise make the whole slide unreadable.
pub(crate) fn dml_escape(s: &str) -> String {
    let clean: String = s
        .chars()
        .filter(|&c| {
            !(c < ' ' && c != '\t' && c != '\n' && c != '\r') && c != '\u{FFFE}' && c != '\u{FFFF}'
        })
        .collect();
    xml_escape(&clean).into_owned()
}

/// Bounds in EMU (`[x0, y0, x1, y1]`).
type Bounds = [i64; 4];

fn union(a: Option<Bounds>, b: Bounds) -> Bounds {
    match a {
        None => b,
        Some(a) => [
            a[0].min(b[0]),
            a[1].min(b[1]),
            a[2].max(b[2]),
            a[3].max(b[3]),
        ],
    }
}

/// An open output frame: the root group or a panel group.
struct Frame {
    body: String,
    bbox: Option<Bounds>,
    name: String,
    /// The bounds of each shape written into this frame, nested groups'
    /// shapes included, so a group whose opacity could be folded into its
    /// children can check they do not overlap.
    items: Vec<Bounds>,
    /// Some shape in the frame overlaps itself (a fill under its own outline,
    /// glyphs that touch): folding an opacity into it would double it there.
    self_overlap: bool,
}

impl Frame {
    fn new(name: &str) -> Frame {
        Frame {
            body: String::new(),
            bbox: None,
            name: name.to_string(),
            items: Vec::new(),
            self_overlap: false,
        }
    }
}

/// What a `begin_group` turned into, so `end_group` can close it.
enum GroupKind {
    /// A plain compositing group means nothing in DrawingML: its children are
    /// written straight into the enclosing frame.
    Plain,
    /// The group that opened the active capture (see [`Capture`]).
    Capture,
    /// A group with only an opacity, nested in a shadow capture: its shapes
    /// get their own frame and the opacity is folded into them when it closes.
    Fold(f32),
}

/// A group DrawingML cannot express, being drawn through the raster backend.
///
/// An *exclusive* capture (a mask, a blend mode, a blur or shadow) takes every
/// draw until the group closes and becomes a picture of the region it covers.
/// A *shadow* capture is for group opacity alone: the shapes are written as
/// usual into their own frame while the capture draws them too, and when the
/// group closes, opacity over non-overlapping shapes is folded into their
/// colours (exactly what the group would composite to) and the capture is
/// thrown away; only when shapes overlap does the picture replace them.
struct Capture {
    rb: RasterBackend,
    /// Open groups inside the capture, the opening one included.
    depth: usize,
    exclusive: bool,
    /// For a blend mode: colour comes from the mirror, coverage from `rb`.
    blend: bool,
    alpha: f32,
    /// A shadow capture that met something folding cannot express.
    failed: bool,
    reason: &'static str,
}

/// The DrawingML backend. Coordinates are written in EMU, offset by
/// `(left, top)` so the fragment lands at its place on the slide.
pub struct DmlBackend {
    w: u32,
    h: u32,
    /// EMU per device px.
    k: f64,
    left: i64,
    top: i64,
    outline_text: bool,
    frames: Vec<Frame>,
    groups: Vec<GroupKind>,
    next_id: u32,
    /// Encoded PNGs in first-use order, referenced as `MEDIA_TOKEN k MEDIA_TOKEN`.
    media: Vec<Vec<u8>>,
    media_index: HashMap<u64, usize>,
    warnings: Vec<String>,
    /// Alt text for the root group (the scene's description, else its title).
    descr: String,
    /// Each viewport's clip region, resolved once (keyed like the SVG
    /// backend's `<clipPath>` cache, by the clip's viewport id).
    regions: HashMap<usize, Rc<Region>>,
    capture: Option<Capture>,
    /// A full-page raster of everything drawn so far, kept only when the scene
    /// has a blend mode: a blended group's pixels depend on what lies beneath.
    mirror: Option<RasterBackend>,
    /// Point marks held back to be merged into a few shapes (VR-39).
    points: Vec<PendingMark>,
    /// The next shapes paint a point marker: set by `begin_marker`, cleared
    /// when the walk moves to another element or node (`set_element_key`).
    marker_armed: bool,
    /// Inside a `draw_circles` batch.
    in_circles: bool,
}

/// A point mark's shape, held back so a layer of points can be written as a
/// few multi-path shapes instead of one `p:sp` per point (VR-39).
struct PendingMark {
    name: String,
    paths: Vec<DevPath>,
    fill: String,
    ln: String,
    filled: bool,
    /// What the mark can paint, in device px: its geometry grown by the
    /// reach of its outline.
    reach: [f64; 4],
}

impl DmlBackend {
    /// A backend for a `w` x `h` px page at `dpi`, placed `(left, top)` EMU from
    /// the slide's top-left corner. `outline_text` writes every label as glyph
    /// outlines (pixel-faithful, not editable as text).
    pub fn new(
        w: u32,
        h: u32,
        dpi: f64,
        bg: Rgba,
        left: i64,
        top: i64,
        outline_text: bool,
    ) -> Self {
        let dpi = if dpi > 0.0 && dpi.is_finite() {
            dpi
        } else {
            96.0
        };
        let mut b = DmlBackend {
            w,
            h,
            k: EMU_PER_INCH / dpi,
            left,
            top,
            outline_text,
            frames: vec![Frame::new("vellum")],
            groups: Vec::new(),
            next_id: 2,
            media: Vec::new(),
            media_index: HashMap::new(),
            warnings: Vec::new(),
            descr: String::new(),
            regions: HashMap::new(),
            capture: None,
            mirror: None,
            points: Vec::new(),
            marker_armed: false,
            in_circles: false,
        };
        if bg.a > 0 {
            if let Some(p) = rect_path(0.0, 0.0, w as f64, h as f64) {
                let dp = DevPath::from_path(&p, Transform::identity());
                let fill = solid_fill(bg, 1.0);
                b.emit_geom("Background", &[dp], &fill, "", true, 0.0);
            }
        }
        b
    }

    /// Record a degradation warning once.
    pub(super) fn warn(&mut self, msg: &str) {
        if !self.warnings.iter().any(|w| w == msg) {
            self.warnings.push(msg.to_string());
        }
    }

    fn id(&mut self) -> u32 {
        let id = self.next_id;
        self.next_id += 1;
        id
    }

    /// Device px to slide EMU. Coordinates are clamped to [`MAX_PX`], so a
    /// point far off the page (an unclipped mark at 1e12) cannot overflow
    /// DrawingML's coordinate range.
    fn ex(&self, x: f64) -> i64 {
        self.left + (clamp_px(x) * self.k).round() as i64
    }
    fn ey(&self, y: f64) -> i64 {
        self.top + (clamp_px(y) * self.k).round() as i64
    }
    /// A device-px length in EMU.
    fn len(&self, v: f64) -> i64 {
        (clamp_px(v) * self.k).round() as i64
    }

    /// Whether device-px bounds lie wholly outside the page grown by one page
    /// size on each side: such geometry cannot be seen and is dropped.
    fn off_page(&self, b: [f64; 4]) -> bool {
        let (w, h) = (self.w as f64, self.h as f64);
        !(b.iter().all(|v| v.is_finite() || v.is_nan()))
            || b[2] < -w
            || b[0] > 2.0 * w
            || b[3] < -h
            || b[1] > 2.0 * h
    }

    fn out(&mut self) -> &mut Frame {
        self.frames.last_mut().expect("root frame")
    }

    /// Append a finished element covering `b` to the current frame.
    fn push(&mut self, xml: &str, b: Bounds) {
        self.flush_points();
        let f = self.out();
        f.body.push_str(xml);
        f.bbox = Some(union(f.bbox, b));
        f.items.push(b);
    }

    /// Append a closed frame's output (`xml`, covering `b`) to the current
    /// frame, carrying its shapes' bounds and overlap flag up.
    fn splice(&mut self, xml: &str, b: Bounds, items: Vec<Bounds>, self_overlap: bool) {
        self.flush_points();
        let f = self.out();
        f.body.push_str(xml);
        f.bbox = Some(union(f.bbox, b));
        f.items.extend(items);
        f.self_overlap |= self_overlap;
    }

    /// The `a:custGeom` for `paths` (one `a:path` each) in the box at
    /// `(x0, y0)` of size `w` x `h` (EMU). `open` marks a stroke-only shape whose
    /// paths must not be filled. `arcs` writes an ellipse as two `a:arcTo`
    /// halves rather than its curves: a few dozen bytes, for the many circles
    /// of a merged point layer.
    #[allow(clippy::too_many_arguments)]
    fn cust_geom(
        &self,
        paths: &[DevPath],
        x0: i64,
        y0: i64,
        w: i64,
        h: i64,
        open: bool,
        arcs: bool,
    ) -> String {
        use std::fmt::Write;
        let mut s = String::from(
            "<a:custGeom><a:avLst/><a:gdLst/><a:ahLst/><a:cxnLst/>\
             <a:rect l=\"l\" t=\"t\" r=\"r\" b=\"b\"/><a:pathLst>",
        );
        for p in paths {
            let _ = write!(s, "<a:path w=\"{w}\" h=\"{h}\"");
            if open {
                s.push_str(" fill=\"none\"");
            }
            s.push('>');
            if arcs && is_ellipse(p) {
                if let Some(b) = p.bounds() {
                    let (ex0, ex1) = (self.ex(b[0]) as f64, self.ex(b[2]) as f64);
                    let (ey0, ey1) = (self.ey(b[1]) as f64, self.ey(b[3]) as f64);
                    let (wr, hr) = (((ex1 - ex0) / 2.0).round(), ((ey1 - ey0) / 2.0).round());
                    let _ = write!(
                        s,
                        "<a:moveTo><a:pt x=\"{}\" y=\"{}\"/></a:moveTo>\
                         <a:arcTo wR=\"{wr}\" hR=\"{hr}\" stAng=\"0\" swAng=\"10800000\"/>\
                         <a:arcTo wR=\"{wr}\" hR=\"{hr}\" stAng=\"10800000\" swAng=\"10800000\"/>\
                         <a:close/></a:path>",
                        ex1 as i64 - x0,
                        ((ey0 + ey1) / 2.0).round() as i64 - y0,
                    );
                    continue;
                }
            }
            let pt = |s: &mut String, (x, y): Pt| {
                let _ = write!(
                    s,
                    "<a:pt x=\"{}\" y=\"{}\"/>",
                    self.ex(x) - x0,
                    self.ey(y) - y0
                );
            };
            for seg in &p.segs {
                match *seg {
                    Seg::Move(a) => {
                        s.push_str("<a:moveTo>");
                        pt(&mut s, a);
                        s.push_str("</a:moveTo>");
                    }
                    Seg::Line(a) => {
                        s.push_str("<a:lnTo>");
                        pt(&mut s, a);
                        s.push_str("</a:lnTo>");
                    }
                    Seg::Quad(c, a) => {
                        s.push_str("<a:quadBezTo>");
                        pt(&mut s, c);
                        pt(&mut s, a);
                        s.push_str("</a:quadBezTo>");
                    }
                    Seg::Cubic(c1, c2, a) => {
                        s.push_str("<a:cubicBezTo>");
                        pt(&mut s, c1);
                        pt(&mut s, c2);
                        pt(&mut s, a);
                        s.push_str("</a:cubicBezTo>");
                    }
                    Seg::Close => s.push_str("<a:close/>"),
                }
            }
            s.push_str("</a:path>");
        }
        s.push_str("</a:pathLst></a:custGeom>");
        s
    }

    /// The EMU box of device-px bounds (at least 1 EMU each way, so the path
    /// coordinate space never divides by zero).
    fn emu_box(&self, b: [f64; 4]) -> (i64, i64, i64, i64) {
        let (x0, y0) = (self.ex(b[0]), self.ey(b[1]));
        let (x1, y1) = (self.ex(b[2]), self.ey(b[3]));
        (x0, y0, (x1 - x0).max(1), (y1 - y0).max(1))
    }

    /// Write one `p:sp` from device-px `paths` with the given fill and line XML.
    /// `filled` false marks open, stroke-only geometry; `pad` is how far the
    /// outline reaches past the geometry (device px). Returns false when there
    /// was nothing to draw. A point mark is held back to be merged with the
    /// rest of its layer (see [`DmlBackend::flush_points`]).
    pub(super) fn emit_geom(
        &mut self,
        name: &str,
        paths: &[DevPath],
        fill: &str,
        ln: &str,
        filled: bool,
        pad: f64,
    ) -> bool {
        let Some(bb) = bounds_of(paths) else {
            return false;
        };
        if self.off_page(bb) {
            return false;
        }
        if self.marker_armed || self.in_circles {
            // An outline of unknown reach overlaps everything: never merged.
            let pad = if pad.is_finite() {
                pad.max(0.0)
            } else {
                f64::INFINITY
            };
            self.points.push(PendingMark {
                name: name.to_string(),
                paths: paths.to_vec(),
                fill: fill.to_string(),
                ln: ln.to_string(),
                filled,
                reach: [bb[0] - pad, bb[1] - pad, bb[2] + pad, bb[3] + pad],
            });
            return true;
        }
        self.flush_points();
        self.write_geom(name, paths, fill, ln, filled, bb, None);
        true
    }

    /// Write the held-back point marks. A mark goes one level above every
    /// earlier mark it could overlap, so overlapping marks keep their order
    /// while marks on one level are disjoint; each level then writes one shape
    /// per style, with one `a:path` per mark. Disjoint paths paint the same
    /// whether an application fills a shape's paths separately or together,
    /// so the merged shapes draw exactly what one shape per mark drew.
    fn flush_points(&mut self) {
        let marks = std::mem::take(&mut self.points);
        if marks.is_empty() {
            return;
        }
        let level = point_levels(&marks.iter().map(|m| m.reach).collect::<Vec<_>>());
        // Shapes in drawing order: by level, then by each style's first mark.
        let mut shapes: Vec<(usize, Vec<usize>)> = Vec::new();
        let mut index: HashMap<(usize, &str, &str, bool, usize), usize> = HashMap::new();
        for (i, m) in marks.iter().enumerate() {
            // A gradient or picture fill is laid out over the shape's box, so
            // only solid paint can be shared by several marks.
            let solid = |x: &str| {
                !(x.contains("<a:gradFill")
                    || x.contains("<a:blipFill")
                    || x.contains("<a:pattFill"))
            };
            let alone = if solid(&m.fill) && solid(&m.ln) {
                0
            } else {
                i + 1
            };
            let k = (level[i], m.fill.as_str(), m.ln.as_str(), m.filled, alone);
            match index.get(&k) {
                // A full shape starts another (see `MAX_MARKS`).
                Some(&s) if shapes[s].1.len() < MAX_MARKS => shapes[s].1.push(i),
                _ => {
                    index.insert(k, shapes.len());
                    shapes.push((level[i], vec![i]));
                }
            }
        }
        shapes.sort_by_key(|(lv, items)| (*lv, items[0]));
        for (_, items) in shapes {
            let first = &marks[items[0]];
            let paths: Vec<DevPath> = items
                .iter()
                .flat_map(|&i| marks[i].paths.iter().cloned())
                .collect();
            let Some(bb) = bounds_of(&paths) else {
                continue;
            };
            if items.len() == 1 {
                self.write_geom(
                    &first.name,
                    &paths,
                    &first.fill,
                    &first.ln,
                    first.filled,
                    bb,
                    None,
                );
                continue;
            }
            // Each mark's own box, so a group opacity folded over the shape
            // still sees which marks overlap other shapes.
            let boxes: Vec<Bounds> = items
                .iter()
                .filter_map(|&i| bounds_of(&marks[i].paths))
                .map(|b| {
                    let (x0, y0, w, h) = self.emu_box(b);
                    [x0, y0, x0 + w, y0 + h]
                })
                .collect();
            self.write_geom(
                "Points",
                &paths,
                &first.fill,
                &first.ln,
                first.filled,
                bb,
                Some(boxes),
            );
        }
    }

    /// Write one `p:sp` (see [`DmlBackend::emit_geom`]) covering device-px
    /// bounds `bb`. `items` are the boxes of the marks a merged shape holds.
    #[allow(clippy::too_many_arguments)]
    fn write_geom(
        &mut self,
        name: &str,
        paths: &[DevPath],
        fill: &str,
        ln: &str,
        filled: bool,
        bb: [f64; 4],
        items: Option<Vec<Bounds>>,
    ) {
        let (x0, y0, w, h) = self.emu_box(bb);
        let geom = match (paths, rect_of(paths)) {
            // An axis-aligned rectangle stays a real rectangle when edited.
            ([_], Some(_)) if filled => prst("rect"),
            ([p], _) if filled && is_ellipse(p) => prst("ellipse"),
            _ => self.cust_geom(paths, x0, y0, w, h, !filled, items.is_some()),
        };
        // A filled shape with an outline paints the inner half of the line
        // over its fill; overlapping glyph paths paint twice too.
        // A merged shape's marks are disjoint by construction (they may only
        // touch), so only a lone shape's paths are checked against each other.
        let overlaps_itself = (!fill.is_empty() && !ln.is_empty())
            || (paths.len() > 1 && items.is_none() && {
                let boxes: Vec<[f64; 4]> = paths.iter().filter_map(|p| p.bounds()).collect();
                any_overlap(&boxes)
            });
        if overlaps_itself {
            self.out().self_overlap = true;
        }
        let id = self.id();
        let fill = if fill.is_empty() { "<a:noFill/>" } else { fill };
        let ln = if ln.is_empty() {
            "<a:ln><a:noFill/></a:ln>".to_string()
        } else {
            ln.to_string()
        };
        let xml = format!(
            "<p:sp><p:nvSpPr><p:cNvPr id=\"{id}\" name=\"{name} {id}\"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr>\
             <p:spPr><a:xfrm><a:off x=\"{x0}\" y=\"{y0}\"/><a:ext cx=\"{w}\" cy=\"{h}\"/></a:xfrm>\
             {geom}{fill}{ln}</p:spPr></p:sp>"
        );
        let b = [x0, y0, x0 + w, y0 + h];
        match items {
            None => self.push(&xml, b),
            Some(items) => self.splice(&xml, b, items, false),
        }
    }

    /// The fill XML for a paint (empty for no fill). Gradient and pattern
    /// geometry is in local px placed by `t`; DrawingML lays them out relative
    /// to the shape's box, `bb` (device px).
    fn fill_xml(&mut self, paint: &ResolvedPaint, t: Transform, bb: Option<[f64; 4]>) -> String {
        let bb = bb.unwrap_or([0.0, 0.0, 1.0, 1.0]);
        match paint {
            ResolvedPaint::Solid(c) => solid_fill(*c, 1.0),
            ResolvedPaint::Hatch { .. } => String::new(),
            ResolvedPaint::Linear {
                x1,
                y1,
                x2,
                y2,
                stops,
                extend,
            } => {
                let p1 = map_pt(t, tiny_skia::Point::from_xy(*x1 as f32, *y1 as f32));
                let p2 = map_pt(t, tiny_skia::Point::from_xy(*x2 as f32, *y2 as f32));
                let (dx, dy) = (p2.0 - p1.0, p2.1 - p1.1);
                let d = dx.hypot(dy);
                if !(d > 0.0) || stops.is_empty() {
                    return solid_fill(stops.last().map(|s| s.color).unwrap_or(Rgba::BLACK), 1.0);
                }
                let (ux, uy) = (dx / d, dy / d);
                // DrawingML's linear gradient runs along `ang` across the box:
                // 0 where the line through the box's trailing corner crosses the
                // axis, 1 at the leading corner (the box projected on the axis).
                let (w, h) = (bb[2] - bb[0], bb[3] - bb[1]);
                let len = (w * ux).abs() + (h * uy).abs();
                let (cx, cy) = ((bb[0] + bb[2]) / 2.0, (bb[1] + bb[3]) / 2.0);
                let c = (cx - p1.0) * ux + (cy - p1.1) * uy;
                let (t0, t1) = ((c - len / 2.0) / d, (c + len / 2.0) / d);
                let gs = self.gradient_stops(stops, *extend, t0, t1);
                let ang = (uy.atan2(ux).to_degrees().rem_euclid(360.0) * 60_000.0).round() as i64
                    % 21_600_000;
                format!("<a:gradFill flip=\"none\" rotWithShape=\"1\">{gs}<a:lin ang=\"{ang}\" scaled=\"0\"/></a:gradFill>")
            }
            ResolvedPaint::Radial {
                cx,
                cy,
                r,
                fx,
                fy,
                fr,
                stops,
                extend,
            } => {
                if stops.is_empty() {
                    return String::new();
                }
                if fx != cx || fy != cy {
                    self.warn("a radial gradient's focal point is moved to its centre");
                }
                let (ccx, ccy) = map_pt(t, tiny_skia::Point::from_xy(*cx as f32, *cy as f32));
                let det = (t.sx as f64 * t.sy as f64 - t.kx as f64 * t.ky as f64).abs();
                let sc = det.sqrt();
                let (rr, ff) = (r * sc, fr * sc);
                // A circle path gradient runs from the centre (0) to the
                // corner of the box farthest from it (1).
                let far = [
                    (bb[0], bb[1]),
                    (bb[2], bb[1]),
                    (bb[0], bb[3]),
                    (bb[2], bb[3]),
                ]
                .iter()
                .map(|(x, y)| (x - ccx).hypot(y - ccy))
                .fold(0.0, f64::max);
                let span = rr - ff;
                if !(span > 0.0) || !(far > 0.0) {
                    return solid_fill(stops.last().unwrap().color, 1.0);
                }
                let (t0, t1) = (-ff / span, (far - ff) / span);
                let gs = self.gradient_stops(stops, *extend, t0, t1);
                let (w, h) = ((bb[2] - bb[0]).max(1e-9), (bb[3] - bb[1]).max(1e-9));
                let pc = |v: f64| (v * 100_000.0).round() as i64;
                format!(
                    "<a:gradFill flip=\"none\" rotWithShape=\"1\">{gs}<a:path path=\"circle\">\
                     <a:fillToRect l=\"{}\" t=\"{}\" r=\"{}\" b=\"{}\"/></a:path></a:gradFill>",
                    pc((ccx - bb[0]) / w),
                    pc((ccy - bb[1]) / h),
                    pc((bb[2] - ccx) / w),
                    pc((bb[3] - ccy) / h),
                )
            }
            ResolvedPaint::Pattern {
                tile,
                tw,
                th,
                x,
                y,
                w,
                h,
                extend,
                opacity,
            } => {
                // A tiled picture fill. The tile's PNG declares the resolution
                // that makes one tile exactly one cell, so it tiles at 100%.
                let (sx, sy) = (
                    (t.sx as f64).hypot(t.ky as f64),
                    (t.kx as f64).hypot(t.sy as f64),
                );
                let (cw, ch) = (w * sx, h * sy);
                if !(cw > 0.0 && ch > 0.0) || *tw == 0 || *th == 0 {
                    return String::new();
                }
                let o = map_pt(
                    t,
                    tiny_skia::Point::from_xy((x - w / 2.0) as f32, (y - h / 2.0) as f32),
                );
                let dpi = EMU_PER_INCH / self.k;
                let ppm = |px: u32, dev: f64| {
                    ((px as f64) / (dev / dpi * 0.0254)).round().max(1.0) as u32
                };
                let Some(png) = png_with_density(tile, *tw, *th, ppm(*tw, cw), ppm(*th, ch)) else {
                    return String::new();
                };
                let token = self.media_ref(png);
                let (cwe, che) = (cw * self.k, ch * self.k);
                let tx = ((o.0 - bb[0]) * self.k).rem_euclid(cwe).round() as i64;
                let ty = ((o.1 - bb[1]) * self.k).rem_euclid(che).round() as i64;
                let flip = if matches!(extend, Extend::Reflect) {
                    "xy"
                } else {
                    "none"
                };
                let alpha = if *opacity < 1.0 {
                    format!(
                        "<a:alphaModFix amt=\"{}\"/>",
                        (opacity.max(0.0) as f64 * 100_000.0).round() as i64
                    )
                } else {
                    String::new()
                };
                format!(
                    "<a:blipFill dpi=\"0\" rotWithShape=\"1\"><a:blip r:embed=\"{token}\">{alpha}</a:blip><a:srcRect/>\
                     <a:tile tx=\"{tx}\" ty=\"{ty}\" sx=\"100000\" sy=\"100000\" flip=\"{flip}\" algn=\"tl\"/></a:blipFill>"
                )
            }
        }
    }

    /// `a:gsLst` for the part `[t0, t1]` of a gradient's parameter (`t` = 0 at
    /// the first stop's position, 1 at the last's), stretched to DrawingML's
    /// 0..100%: the colour at every stop crossing (both sides of a hard stop),
    /// at both ends, minus stops a straight blend between their neighbours
    /// already reproduces.
    fn gradient_stops(&mut self, stops: &[Stop], extend: Extend, t0: f64, t1: f64) -> String {
        let span = t1 - t0;
        let mut pts: Vec<(f64, Rgba)> = Vec::new();
        if !(span > 0.0) || !span.is_finite() {
            let c = grad_color(stops, extend, t0);
            pts.push((0.0, c));
            pts.push((1.0, c));
        } else {
            let mut ts: Vec<f64> = vec![t0, t1];
            let periods = span.ceil() + 2.0;
            if matches!(extend, Extend::Pad) || periods <= 64.0 {
                let (k0, k1) = match extend {
                    Extend::Pad => (0i64, 0i64),
                    _ => (t0.floor() as i64 - 1, t1.ceil() as i64 + 1),
                };
                for k in k0..=k1 {
                    for st in stops {
                        let o = st.offset as f64;
                        ts.push(k as f64 + o);
                        if matches!(extend, Extend::Reflect) {
                            ts.push(k as f64 + 1.0 - o);
                        }
                    }
                }
            } else {
                self.warn("a gradient repeating many times is approximated");
                for i in 0..=256 {
                    ts.push(t0 + span * i as f64 / 256.0);
                }
            }
            ts.retain(|t| *t >= t0 && *t <= t1);
            ts.sort_by(f64::total_cmp);
            ts.dedup();
            let eps = 1e-9 * span.max(1.0);
            for &tt in &ts {
                let a = grad_color(stops, extend, (tt - eps).max(t0));
                let b = grad_color(stops, extend, (tt + eps).min(t1));
                let pos = (tt - t0) / span;
                pts.push((pos, a));
                if a != b {
                    pts.push((pos, b));
                }
            }
        }
        // Drop stops that interpolation between their neighbours reproduces.
        let mut keep: Vec<(f64, Rgba)> = Vec::with_capacity(pts.len());
        for (i, p) in pts.iter().enumerate() {
            if i == 0 || i == pts.len() - 1 {
                keep.push(*p);
                continue;
            }
            let prev = *keep.last().unwrap();
            let next = pts[i + 1];
            let span = next.0 - prev.0;
            let f = if span > 0.0 {
                (p.0 - prev.0) / span
            } else {
                0.0
            };
            let lerp = |a: u8, b: u8| a as f64 + (b as f64 - a as f64) * f;
            let near = |a: u8, b: u8, c: u8| (lerp(a, b) - c as f64).abs() <= 1.0;
            let redundant = span > 0.0
                && p.0 > prev.0
                && p.0 < next.0
                && near(prev.1.r, next.1.r, p.1.r)
                && near(prev.1.g, next.1.g, p.1.g)
                && near(prev.1.b, next.1.b, p.1.b)
                && near(prev.1.a, next.1.a, p.1.a);
            if !redundant {
                keep.push(*p);
            }
        }
        let mut out = String::from("<a:gsLst>");
        for (pos, c) in keep {
            out.push_str(&format!(
                "<a:gs pos=\"{}\">{}</a:gs>",
                (pos.clamp(0.0, 1.0) * 100_000.0).round() as i64,
                srgb(c, 1.0)
            ));
        }
        out.push_str("</a:gsLst>");
        out
    }

    /// The `a:ln` for a stroke whose lengths scale by `scale` into device px.
    fn ln_xml(
        &mut self,
        color: Rgba,
        st: &StrokeStyle,
        scale: f64,
        t: Transform,
        bb: Option<[f64; 4]>,
    ) -> String {
        // DrawingML caps a line at 20116800 EMU (1584 pt).
        let w = self.len(st.width as f64 * scale).clamp(1, 20_116_800);
        let cap = match st.cap {
            LineCap::Butt => "flat",
            LineCap::Round => "rnd",
            LineCap::Square => "sq",
        };
        let fill = match &st.paint {
            None => solid_fill(color, 1.0),
            Some(p) => {
                let f = self.fill_xml(p, t, bb);
                if f.is_empty() {
                    "<a:noFill/>".to_string()
                } else {
                    f
                }
            }
        };
        let dash = self.dash_xml(st);
        let join = match st.join {
            LineJoin::Round => "<a:round/>".to_string(),
            LineJoin::Bevel => "<a:bevel/>".to_string(),
            LineJoin::Mitre => format!(
                "<a:miter lim=\"{}\"/>",
                (st.miter.max(1.0) as f64 * 100_000.0).round() as i64
            ),
        };
        format!("<a:ln w=\"{w}\" cap=\"{cap}\">{fill}{dash}{join}</a:ln>")
    }

    /// `a:custDash` for a dashed stroke: dash and gap lengths in thousandths of
    /// a percent of the line width. A dash phase has no DrawingML equivalent;
    /// it is folded in by rotating the pattern, which is exact for butt caps.
    fn dash_xml(&mut self, st: &StrokeStyle) -> String {
        if st.dash.is_empty() || st.width <= 0.0 {
            return String::new();
        }
        let mut cyc: Vec<f64> = st.dash.iter().map(|d| *d as f64).collect();
        let total: f64 = cyc.iter().sum();
        let mut phase = (st.phase as f64).rem_euclid(total.max(f64::MIN_POSITIVE));
        // Find the entry the phase falls in. Rounding can leave the phase a
        // whisker short of a whole cycle (`rem_euclid` of a tiny negative
        // phase), past the last entry: that is no phase at all.
        let mut i = 0;
        let shifted = phase > 0.0 && phase.is_finite();
        if shifted {
            while i < cyc.len() && phase >= cyc[i] {
                phase -= cyc[i];
                i += 1;
            }
        }
        if shifted && i < cyc.len() {
            // Rotate the cycle so it starts `phase` in: entries alternate
            // dash/gap, so keep the parity by padding with zero-length entries.
            let mut rot: Vec<f64> = Vec::with_capacity(cyc.len() + 2);
            if i % 2 == 1 {
                rot.push(0.0); // the pattern now opens in a gap
            }
            rot.push(cyc[i] - phase);
            rot.extend_from_slice(&cyc[i + 1..]);
            rot.extend_from_slice(&cyc[..i]);
            rot.push(phase);
            if rot.len() % 2 == 1 {
                rot.push(0.0);
            }
            let zero_dash = rot.iter().step_by(2).any(|d| *d == 0.0);
            if zero_dash && !matches!(st.cap, LineCap::Butt) {
                self.warn("dash phase is approximated on capped dashes");
            }
            cyc = rot;
        }
        let wd = st.width as f64;
        let pct = |v: f64| ((v / wd) * 100_000.0).round().max(0.0) as i64;
        let mut s = String::from("<a:custDash>");
        for pair in cyc.chunks(2) {
            let d = pct(pair[0]);
            let sp = pct(*pair.get(1).unwrap_or(&0.0));
            s.push_str(&format!("<a:ds d=\"{d}\" sp=\"{sp}\"/>"));
        }
        s.push_str("</a:custDash>");
        s
    }

    /// The resolved region of a clip chain (`None`: no clip).
    fn region(&mut self, clip: &Clip) -> Option<Rc<Region>> {
        if clip.shapes.is_empty() {
            return None;
        }
        if let Some(r) = self.regions.get(&clip.id) {
            return Some(Rc::clone(r));
        }
        let r = Rc::new(Region::new(clip, self.w, self.h));
        self.regions.insert(clip.id, Rc::clone(&r));
        Some(r)
    }

    /// Where geometry with device-px bounds `b` lies relative to the clip.
    fn coverage(&mut self, b: Option<[f64; 4]>, clip: &Clip) -> Coverage {
        let Some(r) = self.region(clip) else {
            return Coverage::Inside;
        };
        let Some(b) = b else { return Coverage::Outside };
        r.coverage(b)
    }

    /// Cut a fill to the clip: DrawingML cannot clip, so the visible part of
    /// the geometry is computed here (curves inside the clip are kept; a cut
    /// shape's curves are flattened).
    fn clip_area(&mut self, dp: DevPath, rule: FillRule, clip: &Clip) -> Clipped {
        let Some(r) = self.region(clip) else {
            return Clipped::Keep(dp);
        };
        match dp.bounds().map(|b| r.coverage(b)) {
            None | Some(Coverage::Outside) => Clipped::Drop,
            Some(Coverage::Inside) => Clipped::Keep(dp),
            Some(Coverage::Partial) => {
                use i_overlay::core::fill_rule::FillRule as IFill;
                use i_overlay::core::overlay_rule::OverlayRule;
                use i_overlay::float::single::SingleFloatOverlay;
                let subj: Vec<Vec<[f64; 2]>> = dp
                    .flatten()
                    .into_iter()
                    .filter(|(c, _)| c.len() >= 3)
                    .map(|(c, _)| c.into_iter().map(|(x, y)| [x, y]).collect())
                    .collect();
                let fr = match rule {
                    FillRule::EvenOdd => IFill::EvenOdd,
                    FillRule::Winding => IFill::NonZero,
                };
                let shapes = subj.overlay(&r.contours, OverlayRule::Intersect, fr);
                let rings: Vec<Vec<Pt>> = shapes
                    .into_iter()
                    .flatten()
                    .filter(|c| c.len() >= 3)
                    .map(|c| c.into_iter().map(|p| (p[0], p[1])).collect())
                    .collect();
                if rings.is_empty() {
                    Clipped::Drop
                } else {
                    Clipped::Cut(DevPath::from_rings(&rings))
                }
            }
        }
    }

    /// Cut a stroke's centreline to the clip. The pen keeps its width, so a
    /// round or square cap at a cut end reaches half a line width past the clip
    /// edge (a butt cap ends on it).
    fn clip_line(&mut self, dp: DevPath, clip: &Clip) -> Clipped {
        let Some(r) = self.region(clip) else {
            return Clipped::Keep(dp);
        };
        match dp.bounds().map(|b| r.coverage(b)) {
            None | Some(Coverage::Outside) => Clipped::Drop,
            Some(Coverage::Inside) => Clipped::Keep(dp),
            Some(Coverage::Partial) => {
                use i_overlay::core::fill_rule::FillRule as IFill;
                use i_overlay::float::clip::FloatClip;
                use i_overlay::string::clip::ClipRule;
                let mut lines: Vec<Vec<[f64; 2]>> = Vec::new();
                for (mut pts, closed) in dp.flatten() {
                    if closed {
                        if let Some(&p) = pts.first() {
                            pts.push(p);
                        }
                    }
                    lines.push(pts.into_iter().map(|(x, y)| [x, y]).collect());
                }
                let rule = ClipRule {
                    invert: false,
                    boundary_included: true,
                };
                let mut out: Vec<Vec<Pt>> = Vec::new();
                for l in &lines {
                    for piece in l.clip_by(&r.contours, IFill::NonZero, rule) {
                        if piece.len() >= 2 {
                            out.push(piece.into_iter().map(|p| (p[0], p[1])).collect());
                        }
                    }
                }
                if out.is_empty() {
                    Clipped::Drop
                } else {
                    Clipped::Cut(DevPath::from_polylines(&out))
                }
            }
        }
    }

    /// Stroke `path` into a filled outline (local px), then bake it: the
    /// faithful route under a transform that would stretch the pen.
    fn stroke_outline(
        &mut self,
        path: &Path,
        t: Transform,
        color: Rgba,
        st: &StrokeStyle,
        clip: &Clip,
    ) {
        let mut stroke = Stroke {
            width: st.width,
            miter_limit: st.miter,
            line_cap: match st.cap {
                LineCap::Butt => tiny_skia::LineCap::Butt,
                LineCap::Round => tiny_skia::LineCap::Round,
                LineCap::Square => tiny_skia::LineCap::Square,
            },
            line_join: match st.join {
                LineJoin::Round => tiny_skia::LineJoin::Round,
                LineJoin::Bevel => tiny_skia::LineJoin::Bevel,
                LineJoin::Mitre => tiny_skia::LineJoin::Miter,
            },
            dash: None,
        };
        if !st.dash.is_empty() {
            stroke.dash = StrokeDash::new(st.dash.clone(), st.phase);
        }
        let Some(outline) = path.stroke(&stroke, 1.0) else {
            return;
        };
        let paint = match &st.paint {
            Some(p) => p.clone(),
            None => ResolvedPaint::Solid(color),
        };
        self.vec_fill(&outline, t, &paint, FillRule::Winding, clip);
    }

    /// Text that has to be drawn as glyph outlines: one shape per colour (each
    /// glyph its own `a:path`, so overlapping glyphs never punch holes), the
    /// halo as an outlined shape underneath, `tex()` rules as rectangles.
    fn text_outlines(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        let base = if run.rot != 0.0 {
            transform.pre_concat(crate::units::rotation_about(run.rot, run.ax, run.ay))
        } else {
            transform
        };
        let n = run
            .gid
            .len()
            .min(run.gx.len())
            .min(run.gy.len())
            .min(run.gsize.len())
            .min(run.gpath.len())
            .min(run.gface.len());
        // Glyph paths grouped by colour, in first-use order.
        let mut by_col: Vec<(Rgba, Vec<DevPath>)> = Vec::new();
        let mut all: Vec<DevPath> = Vec::new();
        let add = |by_col: &mut Vec<(Rgba, Vec<DevPath>)>, c: Rgba, p: DevPath| match by_col
            .iter_mut()
            .find(|(k, _)| *k == c)
        {
            Some((_, v)) => v.push(p),
            None => by_col.push((c, vec![p])),
        };
        for i in 0..n {
            let Some(outline) =
                glyph_outline_cached(&run.gpath[i], run.gface[i], run.gid[i], run.gsize[i] as f32)
            else {
                continue;
            };
            let ox = run.ax + run.gx[i] - run.hjust * run.w;
            let oy = run.ay - (run.gy[i] - run.vjust * run.h);
            let place = base.pre_concat(Transform::from_row(
                1.0, 0.0, 0.0, -1.0, ox as f32, oy as f32,
            ));
            let dp = DevPath::from_path(outline.as_ref(), place);
            let col = run.gcolor.get(i).copied().unwrap_or(run.color);
            all.push(dp.clone());
            add(&mut by_col, col, dp);
        }
        for r in run.rules {
            if let Some(p) = text_rule_path(run, r) {
                let dp = DevPath::from_path(&p, base);
                all.push(dp.clone());
                add(&mut by_col, r.col, dp);
            }
        }
        // Cut every glyph to the clip, as a fill.
        let cut = |paths: Vec<DevPath>, me: &mut Self| -> Vec<DevPath> {
            paths
                .into_iter()
                .filter_map(|p| match me.clip_area(p, FillRule::Winding, clip) {
                    Clipped::Drop => None,
                    Clipped::Keep(p) | Clipped::Cut(p) => Some(p),
                })
                .collect()
        };
        let halo_paths = if run.halo.is_some() {
            all.clone()
        } else {
            Vec::new()
        };
        let all = cut(all, self);
        let by_col: Vec<(Rgba, Vec<DevPath>)> = by_col
            .into_iter()
            .map(|(c, v)| (c, cut(v, self)))
            .filter(|(_, v)| !v.is_empty())
            .collect();
        if all.is_empty() {
            return;
        }
        self.frames
            .push(Frame::new(&format!("Text: {}", run.label)));
        if let Some((hcol, hw)) = run.halo {
            if hcol.a > 0 {
                let scale = uniform_scale(base).unwrap_or(1.0);
                let st = StrokeStyle {
                    width: (hw * 2.0) as f32,
                    dash: Vec::new(),
                    cap: LineCap::Round,
                    join: LineJoin::Round,
                    miter: 10.0,
                    crisp: false,
                    paint: None,
                    phase: 0.0,
                };
                let ln = self.ln_xml(hcol, &st, scale, base, None);
                // The halo is an outline of whole glyphs; where the clip cuts
                // the glyphs, outline the cut shapes instead.
                let paths = if self.coverage(bounds_of(&halo_paths), clip) == Coverage::Inside {
                    halo_paths
                } else {
                    all.clone()
                };
                self.emit_geom("Halo", &paths, "", &ln, true, 0.0);
            }
        }
        for (c, paths) in by_col {
            if c.a == 0 {
                continue;
            }
            let fill = solid_fill(c, 1.0);
            self.emit_geom("Glyphs", &paths, &fill, "", true, 0.0);
        }
        self.close_frame(true);
    }

    /// Pop the innermost frame into its parent: a named `p:grpSp`, or, when it
    /// holds a single element and `unwrap` is set, that element itself.
    fn close_frame(&mut self, unwrap: bool) {
        self.flush_points();
        let f = self.frames.pop().expect("frame");
        let Some(b) = f.bbox else { return };
        let single = f.body.matches("<p:cNvPr ").count() == 1;
        if unwrap && single {
            self.splice(&f.body, b, f.items, f.self_overlap);
            return;
        }
        let id = self.id();
        let xml = format!(
            "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"{id}\" name=\"{name}\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
             <p:grpSpPr><a:xfrm><a:off x=\"{x}\" y=\"{y}\"/><a:ext cx=\"{w}\" cy=\"{h}\"/>\
             <a:chOff x=\"{x}\" y=\"{y}\"/><a:chExt cx=\"{w}\" cy=\"{h}\"/></a:xfrm></p:grpSpPr>{body}</p:grpSp>",
            name = dml_escape(&truncate(&f.name, 200)),
            x = b[0],
            y = b[1],
            w = (b[2] - b[0]).max(1),
            h = (b[3] - b[1]).max(1),
            body = f.body,
        );
        self.splice(&xml, b, f.items, f.self_overlap);
    }

    /// A raster the clip cuts in a way a picture crop cannot express (a path
    /// clip, or a rotated picture): draw it through the raster backend with
    /// the clip applied and place the visible part as a picture.
    #[allow(clippy::too_many_arguments)]
    fn raster_region(
        &mut self,
        rgba: &[u8],
        iw: u32,
        ih: u32,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        interpolate: bool,
        t: Transform,
        clip: &Clip,
        ib: [f64; 4],
    ) {
        self.warn(
            "a raster under a clip it cannot crop to is drawn as a picture of its visible part",
        );
        let mut rb = RasterBackend::new(
            self.w,
            self.h,
            Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            },
        );
        rb.draw_image(rgba, iw, ih, x, y, w, h, interpolate, t, clip);
        let pm = rb.into_pixmap();
        self.emit_pixmap_region(&pm, ib);
    }

    /// Place the part of a page-sized pixmap inside device-px bounds `b` as a
    /// picture, trimmed to what it actually covers. Returns false when the
    /// region is empty.
    pub(super) fn emit_pixmap_region(&mut self, pm: &Pixmap, b: [f64; 4]) -> bool {
        let (pw, ph) = (pm.width() as i64, pm.height() as i64);
        let x0 = (b[0].floor() as i64).clamp(0, pw);
        let y0 = (b[1].floor() as i64).clamp(0, ph);
        let x1 = (b[2].ceil() as i64).clamp(0, pw);
        let y1 = (b[3].ceil() as i64).clamp(0, ph);
        // Trim to non-transparent pixels.
        let px = pm.pixels();
        let (mut tx0, mut ty0, mut tx1, mut ty1) = (x1, y1, x0, y0);
        for yy in y0..y1 {
            for xx in x0..x1 {
                if px[(yy * pw + xx) as usize].alpha() > 0 {
                    tx0 = tx0.min(xx);
                    ty0 = ty0.min(yy);
                    tx1 = tx1.max(xx + 1);
                    ty1 = ty1.max(yy + 1);
                }
            }
        }
        if tx1 <= tx0 || ty1 <= ty0 {
            return false;
        }
        let (cw, ch) = ((tx1 - tx0) as u32, (ty1 - ty0) as u32);
        let mut rgba = Vec::with_capacity((cw * ch * 4) as usize);
        for yy in ty0..ty1 {
            for xx in tx0..tx1 {
                let c = px[(yy * pw + xx) as usize].demultiply();
                rgba.extend_from_slice(&[c.red(), c.green(), c.blue(), c.alpha()]);
            }
        }
        let Some(png) = straight_png(&rgba, cw, ch) else {
            return false;
        };
        self.emit_picture(
            png,
            (tx0 + tx1) as f64 / 2.0,
            (ty0 + ty1) as f64 / 2.0,
            cw as f64,
            ch as f64,
            0.0,
            false,
            None,
        );
        true
    }

    /// Register a PNG and return its media token.
    pub(super) fn media_ref(&mut self, png: Vec<u8>) -> String {
        let key = fnv64(&png);
        let idx = match self.media_index.get(&key) {
            Some(&i) => i,
            None => {
                self.media.push(png);
                self.media_index.insert(key, self.media.len() - 1);
                self.media.len() - 1
            }
        };
        format!("{MEDIA_TOKEN}{idx}{MEDIA_TOKEN}")
    }

    /// Write a picture of `png` covering the device-px box centred at `(cx, cy)`
    /// of size `w` x `h`, rotated `rot` degrees clockwise, flipped vertically
    /// when `flip`. `src` crops the image (fractions of each edge, `l t r b`).
    #[allow(clippy::too_many_arguments)]
    pub(super) fn emit_picture(
        &mut self,
        png: Vec<u8>,
        cx: f64,
        cy: f64,
        w: f64,
        h: f64,
        rot: f64,
        flip: bool,
        src: Option<[f64; 4]>,
    ) {
        let ew = self.len(w).max(1);
        let eh = self.len(h).max(1);
        let x0 = self.ex(cx) - ew / 2;
        let y0 = self.ey(cy) - eh / 2;
        let token = self.media_ref(png);
        let id = self.id();
        let rot_emu = (rot * 60_000.0).round() as i64 % 21_600_000;
        let rot_attr = if rot_emu != 0 {
            format!(" rot=\"{rot_emu}\"")
        } else {
            String::new()
        };
        let flip_attr = if flip { " flipV=\"1\"" } else { "" };
        let src_rect = match src {
            Some([l, t, r, b]) => {
                let p = |v: f64| (v * 100_000.0).round() as i64;
                format!(
                    "<a:srcRect l=\"{}\" t=\"{}\" r=\"{}\" b=\"{}\"/>",
                    p(l),
                    p(t),
                    p(r),
                    p(b)
                )
            }
            None => String::new(),
        };
        let xml = format!(
            "<p:pic><p:nvPicPr><p:cNvPr id=\"{id}\" name=\"Picture {id}\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
             <p:blipFill><a:blip r:embed=\"{token}\"/>{src_rect}<a:stretch><a:fillRect/></a:stretch></p:blipFill>\
             <p:spPr><a:xfrm{rot_attr}{flip_attr}><a:off x=\"{x0}\" y=\"{y0}\"/><a:ext cx=\"{ew}\" cy=\"{eh}\"/></a:xfrm>\
             <a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
        );
        let b = rotated_bounds(x0, y0, ew, eh, rot);
        self.push(&xml, b);
    }

    /// The finished fragment (one root `p:grpSp`), with media still tokenised,
    /// the encoded PNGs it references, and the degradation warnings.
    pub fn finish(mut self) -> (String, Vec<Vec<u8>>, Vec<String>) {
        self.flush_points();
        while self.frames.len() > 1 {
            self.close_frame(false);
        }
        let root = self.frames.pop().expect("root frame");
        let (w, h) = (
            self.len(self.w as f64).max(1),
            self.len(self.h as f64).max(1),
        );
        let (x, y) = (self.left, self.top);
        let xml = format!(
            "<p:grpSp {DML_NS}><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"{name}\"{descr}/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
             <p:grpSpPr><a:xfrm><a:off x=\"{x}\" y=\"{y}\"/><a:ext cx=\"{w}\" cy=\"{h}\"/>\
             <a:chOff x=\"{x}\" y=\"{y}\"/><a:chExt cx=\"{w}\" cy=\"{h}\"/></a:xfrm></p:grpSpPr>{body}</p:grpSp>",
            name = dml_escape(&root.name),
            descr = if self.descr.is_empty() {
                String::new()
            } else {
                format!(" descr=\"{}\"", dml_escape(&self.descr))
            },
            body = root.body,
        );
        (xml, self.media, self.warnings)
    }

    /// Keep a raster mirror of the page (call before drawing, with the page
    /// background), so blended groups can be drawn over what lies beneath.
    pub fn enable_mirror(&mut self, bg: Rgba) {
        self.mirror = Some(RasterBackend::new(self.w, self.h, bg));
    }

    /// Name the root group after the scene's title and give it the scene's
    /// description (else its title) as alt text. officer renames the root to
    /// the placeholder label, but keeps the alt text.
    pub fn set_a11y(&mut self, title: &str, desc: &str) {
        if !title.is_empty() {
            self.frames[0].name = title.to_string();
        }
        self.descr = if desc.is_empty() { title } else { desc }.to_string();
    }
}

fn truncate(s: &str, n: usize) -> String {
    let s = s.replace('\n', " ");
    if s.chars().count() <= n {
        s
    } else {
        s.chars().take(n).collect::<String>() + "..."
    }
}

fn prst(name: &str) -> String {
    format!("<a:prstGeom prst=\"{name}\"><a:avLst/></a:prstGeom>")
}

/// `Some` when `paths` is one closed axis-aligned rectangle.
fn rect_of(paths: &[DevPath]) -> Option<()> {
    let [p] = paths else { return None };
    let pts: Vec<Pt> = match p.segs.as_slice() {
        [Seg::Move(a), Seg::Line(b), Seg::Line(c), Seg::Line(d), Seg::Close] => {
            vec![*a, *b, *c, *d]
        }
        [Seg::Move(a), Seg::Line(b), Seg::Line(c), Seg::Line(d), Seg::Line(e), Seg::Close]
            if close(*a, *e) =>
        {
            vec![*a, *b, *c, *d]
        }
        _ => return None,
    };
    let eq = |u: f64, v: f64| (u - v).abs() <= 1e-6 * (1.0 + u.abs().max(v.abs()));
    let ok = |a: Pt, b: Pt| eq(a.0, b.0) || eq(a.1, b.1);
    let alternating = (eq(pts[0].0, pts[1].0)
        && eq(pts[1].1, pts[2].1)
        && eq(pts[2].0, pts[3].0)
        && eq(pts[3].1, pts[0].1))
        || (eq(pts[0].1, pts[1].1)
            && eq(pts[1].0, pts[2].0)
            && eq(pts[2].1, pts[3].1)
            && eq(pts[3].0, pts[0].0));
    (alternating && ok(pts[0], pts[1])).then_some(())
}

fn close(a: Pt, b: Pt) -> bool {
    (a.0 - b.0).abs() < 1e-9 && (a.1 - b.1).abs() < 1e-9
}

/// Whether `p` is an axis-aligned ellipse as tiny-skia builds circles and ovals
/// (move to the east point, four or eight conic-approximating curves, close),
/// mapped by a transform that kept its axes: every on-curve point then lies on
/// the ellipse inscribed in the bounds.
fn is_ellipse(p: &DevPath) -> bool {
    let Some(b) = p.bounds() else { return false };
    let segs = &p.segs;
    let curves = segs
        .iter()
        .filter(|s| matches!(s, Seg::Quad(..) | Seg::Cubic(..)))
        .count();
    let lines = segs.iter().filter(|s| matches!(s, Seg::Line(_))).count();
    let moves = segs.iter().filter(|s| matches!(s, Seg::Move(_))).count();
    if moves != 1
        || lines != 0
        || !(curves == 4 || curves == 8)
        || !matches!(segs.last(), Some(Seg::Close))
    {
        return false;
    }
    let (cx, cy) = ((b[0] + b[2]) / 2.0, (b[1] + b[3]) / 2.0);
    let (rx, ry) = ((b[2] - b[0]) / 2.0, (b[3] - b[1]) / 2.0);
    if !(rx > 0.0 && ry > 0.0) {
        return false;
    }
    // Control points of a quadratic arc lie outside the ellipse, so the bounds
    // above are slightly loose; measure on-curve points against the box spanned
    // by on-curve points only.
    let on: Vec<Pt> = segs
        .iter()
        .filter_map(|s| match *s {
            Seg::Move(a) | Seg::Quad(_, a) | Seg::Cubic(_, _, a) => Some(a),
            _ => None,
        })
        .collect();
    let (mut x0, mut y0, mut x1, mut y1) = (
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    );
    for (x, y) in &on {
        x0 = x0.min(*x);
        y0 = y0.min(*y);
        x1 = x1.max(*x);
        y1 = y1.max(*y);
    }
    let _ = (cx, cy, rx, ry);
    let (cx, cy, rx, ry) = (
        (x0 + x1) / 2.0,
        (y0 + y1) / 2.0,
        (x1 - x0) / 2.0,
        (y1 - y0) / 2.0,
    );
    if !(rx > 0.0 && ry > 0.0) {
        return false;
    }
    // The control-point bounds must match the on-curve bounds for the
    // prstGeom box (which is the ellipse's own box) to be right: a quad arc's
    // control points overshoot, so the shape's xfrm would be too big. Accept
    // only when the overshoot is what a circle's eight-arc build produces
    // (1/cos(22.5 deg) at 45 degrees, never past the box on the axes).
    if (b[0] - x0).abs() > 1e-6 * (1.0 + rx) || (b[2] - x1).abs() > 1e-6 * (1.0 + rx) {
        return false;
    }
    if (b[1] - y0).abs() > 1e-6 * (1.0 + ry) || (b[3] - y1).abs() > 1e-6 * (1.0 + ry) {
        return false;
    }
    on.iter().all(|(x, y)| {
        let u = (x - cx) / rx;
        let v = (y - cy) / ry;
        ((u * u + v * v) - 1.0).abs() < 1e-3
    })
}

/// Bounds of a `w` x `h` box at `(x0, y0)` rotated `rot` degrees about its centre.
fn rotated_bounds(x0: i64, y0: i64, w: i64, h: i64, rot: f64) -> Bounds {
    if rot == 0.0 {
        return [x0, y0, x0 + w, y0 + h];
    }
    let (s, c) = rot.to_radians().sin_cos();
    let (hw, hh) = (w as f64 / 2.0, h as f64 / 2.0);
    let ew = (hw * c).abs() + (hh * s).abs();
    let eh = (hw * s).abs() + (hh * c).abs();
    let (cx, cy) = (x0 as f64 + hw, y0 as f64 + hh);
    [
        (cx - ew).floor() as i64,
        (cy - eh).floor() as i64,
        (cx + ew).ceil() as i64,
        (cy + eh).ceil() as i64,
    ]
}

/// Device-px bounds of a clip chain (the intersection of its shapes' bounds).
pub(super) fn clip_bounds(clip: &Clip) -> Option<[f64; 4]> {
    let mut out: Option<[f64; 4]> = None;
    for s in clip.shapes {
        let b = match s {
            ClipShape::Rect { w, h, transform } => {
                let c = rect_corners(*w, *h, *transform);
                let xs = c.iter().map(|p| p.0);
                let ys = c.iter().map(|p| p.1);
                [
                    xs.clone().fold(f64::INFINITY, f64::min),
                    ys.clone().fold(f64::INFINITY, f64::min),
                    xs.fold(f64::NEG_INFINITY, f64::max),
                    ys.fold(f64::NEG_INFINITY, f64::max),
                ]
            }
            ClipShape::Path {
                path, transform, ..
            } => match DevPath::from_path(path, *transform).bounds() {
                Some(b) => b,
                None => [0.0, 0.0, 0.0, 0.0],
            },
        };
        out = Some(match out {
            None => b,
            Some(a) => [
                a[0].max(b[0]),
                a[1].max(b[1]),
                a[2].min(b[2]),
                a[3].min(b[3]),
            ],
        });
    }
    out
}

/// Where geometry lies relative to a clip region.
#[derive(Clone, Copy, PartialEq, Debug)]
pub(super) enum Coverage {
    Inside,
    Outside,
    Partial,
}

/// A fill or stroke after clipping.
pub(super) enum Clipped {
    /// Entirely inside: unchanged, curves and all.
    Keep(DevPath),
    /// Cut at the clip edge.
    Cut(DevPath),
    /// Entirely outside.
    Drop,
}

/// A clip chain resolved to device px: the intersection of its shapes, as
/// contours `i_overlay` can clip against, plus its bounds. `rect` marks a chain
/// of axis-aligned rectangles (a panel), whose region is exactly its bounds.
pub(super) struct Region {
    pub bbox: [f64; 4],
    pub rect: bool,
    pub contours: Vec<Vec<[f64; 2]>>,
}

impl Region {
    fn new(clip: &Clip, w: u32, h: u32) -> Region {
        use i_overlay::core::fill_rule::FillRule as IFill;
        use i_overlay::core::overlay_rule::OverlayRule;
        use i_overlay::float::simplify::SimplifyShape;
        use i_overlay::float::single::SingleFloatOverlay;
        let axis = |t: &Transform| t.kx == 0.0 && t.ky == 0.0;
        let rect = clip
            .shapes
            .iter()
            .all(|s| matches!(s, ClipShape::Rect { transform, .. } if axis(transform)));
        let bbox = clip_bounds(clip).unwrap_or([0.0; 4]);
        if rect {
            let [x0, y0, x1, y1] = bbox;
            let contours = if x1 > x0 && y1 > y0 {
                vec![vec![[x0, y0], [x1, y0], [x1, y1], [x0, y1]]]
            } else {
                Vec::new()
            };
            return Region {
                bbox,
                rect: true,
                contours,
            };
        }
        // A region's rings in device px. One reaching far beyond the page is
        // cut to it first (in f64, see `fit`): `i_overlay` snaps to an integer
        // grid scaled to the input's extent, so at 1e20 px the page shrank to
        // nothing and everything under the clip was dropped.
        let rings_of = |path: &Path, t: Transform| -> Vec<Vec<[f64; 2]>> {
            let dp = match super::fit::fit_fill(path, t, w, h) {
                super::fit::Fit::Keep(p) => DevPath::from_path(p, t),
                super::fit::Fit::Clipped(dev) => DevPath::from_path(&dev, Transform::identity()),
                super::fit::Fit::Outline | super::fit::Fit::Skip => return Vec::new(),
            };
            dp.flatten()
                .into_iter()
                .filter(|(c, _)| c.len() >= 3)
                .map(|(c, _)| c.into_iter().map(|(x, y)| [x, y]).collect())
                .collect()
        };
        let mut acc: Option<Vec<Vec<[f64; 2]>>> = None;
        for shape in clip.shapes {
            let (rings, fr) = match shape {
                ClipShape::Rect {
                    w: rw,
                    h: rh,
                    transform,
                } => {
                    let c = rect_corners(*rw, *rh, *transform);
                    let near = c
                        .iter()
                        .all(|p| p.0.abs().max(p.1.abs()) <= super::fit::SAFE);
                    let mut pb = PathBuilder::new();
                    pb.move_to(0.0, 0.0);
                    pb.line_to(*rw as f32, 0.0);
                    pb.line_to(*rw as f32, *rh as f32);
                    pb.line_to(0.0, *rh as f32);
                    pb.close();
                    let rings = match (near, pb.finish()) {
                        (false, Some(p)) => rings_of(&p, *transform),
                        _ => vec![c.iter().map(|p| [p.0, p.1]).collect::<Vec<_>>()],
                    };
                    (rings, IFill::NonZero)
                }
                ClipShape::Path {
                    path,
                    evenodd,
                    transform,
                } => (
                    rings_of(path, *transform),
                    if *evenodd {
                        IFill::EvenOdd
                    } else {
                        IFill::NonZero
                    },
                ),
            };
            let clean: Vec<Vec<[f64; 2]>> =
                rings.simplify_shape(fr).into_iter().flatten().collect();
            acc = Some(match acc {
                None => clean,
                Some(a) => a
                    .overlay(&clean, OverlayRule::Intersect, IFill::NonZero)
                    .into_iter()
                    .flatten()
                    .collect(),
            });
        }
        Region {
            bbox,
            rect: false,
            contours: acc.unwrap_or_default(),
        }
    }

    /// Where a box lies relative to the region. Only a rectangular region can
    /// say "inside" from bounds alone; anything else that meets it is cut.
    fn coverage(&self, b: [f64; 4]) -> Coverage {
        let [x0, y0, x1, y1] = self.bbox;
        let eps = 1e-6;
        if self.contours.is_empty()
            || b[2] < x0 - eps
            || b[0] > x1 + eps
            || b[3] < y0 - eps
            || b[1] > y1 + eps
        {
            return Coverage::Outside;
        }
        if self.rect && b[0] >= x0 - eps && b[1] >= y0 - eps && b[2] <= x1 + eps && b[3] <= y1 + eps
        {
            return Coverage::Inside;
        }
        Coverage::Partial
    }
}

/// A gradient's colour at parameter `t`, with `extend` applied outside 0..1,
/// interpolated in straight RGBA between the stops around it.
fn grad_color(stops: &[Stop], extend: Extend, t: f64) -> Rgba {
    let Some(first) = stops.first() else {
        return Rgba::BLACK;
    };
    let t = match extend {
        Extend::Pad => t.clamp(0.0, 1.0),
        Extend::Repeat => t - t.floor(),
        Extend::Reflect => {
            let m = t.rem_euclid(2.0);
            if m > 1.0 {
                2.0 - m
            } else {
                m
            }
        }
    };
    if t <= first.offset as f64 {
        return first.color;
    }
    for w in stops.windows(2) {
        let (a, b) = (&w[0], &w[1]);
        if t <= b.offset as f64 {
            let span = (b.offset - a.offset) as f64;
            let f = if span > 0.0 {
                (t - a.offset as f64) / span
            } else {
                1.0
            };
            let l = |x: u8, y: u8| {
                (x as f64 + (y as f64 - x as f64) * f)
                    .round()
                    .clamp(0.0, 255.0) as u8
            };
            return Rgba {
                r: l(a.color.r, b.color.r),
                g: l(a.color.g, b.color.g),
                b: l(a.color.b, b.color.b),
                a: l(a.color.a, b.color.a),
            };
        }
    }
    stops.last().unwrap().color
}

/// Encode straight RGBA as PNG declaring `xppm` x `yppm` pixels per metre, so
/// an application that sizes a picture from its resolution sizes it exactly.
fn png_with_density(rgba: &[u8], w: u32, h: u32, xppm: u32, yppm: u32) -> Option<Vec<u8>> {
    let n = (w as usize).checked_mul(h as usize)?;
    if rgba.len() < n * 4 {
        return None;
    }
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, w, h);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        enc.set_pixel_dims(Some(png::PixelDimensions {
            xppu: xppm,
            yppu: yppm,
            unit: png::Unit::Meter,
        }));
        let mut writer = enc.write_header().ok()?;
        writer.write_image_data(&rgba[..n * 4]).ok()?;
    }
    Some(out)
}

/// FNV-1a over bytes: a stable key for de-duplicating media.
pub(super) fn fnv64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// Nearest-neighbour upscale of straight RGBA by an integer factor: DrawingML
/// has no "don't interpolate" flag, so a pixelated raster is enlarged until
/// smoothing cannot blur its cells.
fn upscale_nearest(rgba: &[u8], iw: u32, ih: u32, f: u32) -> Vec<u8> {
    let (ow, oh) = (iw * f, ih * f);
    let mut out = vec![0u8; (ow as usize) * (oh as usize) * 4];
    for y in 0..oh {
        let sy = (y / f) as usize;
        for x in 0..ow {
            let sx = (x / f) as usize;
            let s = (sy * iw as usize + sx) * 4;
            let d = (y as usize * ow as usize + x as usize) * 4;
            out[d..d + 4].copy_from_slice(&rgba[s..s + 4]);
        }
    }
    out
}

impl DmlBackend {
    fn vec_fill(
        &mut self,
        path: &Path,
        transform: Transform,
        paint: &ResolvedPaint,
        rule: FillRule,
        clip: &Clip,
    ) {
        if matches!(paint, ResolvedPaint::Hatch { .. }) {
            return;
        }
        // Far geometry is cut to the page first, as on PNG (VR-44). Clamping
        // each point to `MAX_PX` alone bent a long line's visible part.
        let fitted;
        let solid = matches!(paint, ResolvedPaint::Solid(_));
        let (path, transform) =
            match super::fit::vector_fill(path, transform, self.w, self.h, solid) {
                super::fit::VecFill::Keep => (path, transform),
                super::fit::VecFill::Draw(p, t) => {
                    fitted = p;
                    (&fitted, t)
                }
                super::fit::VecFill::Skip => return,
            };
        let dp = match self.clip_area(DevPath::from_path(path, transform), rule, clip) {
            Clipped::Drop => return,
            // A cut is already free of overlaps (the overlay resolved them).
            Clipped::Cut(dp) => dp,
            Clipped::Keep(dp) => normalize_fill(dp, rule),
        };
        if dp.is_empty() {
            return;
        }
        let fill = self.fill_xml(paint, transform, dp.bounds());
        if fill.is_empty() {
            return;
        }
        self.emit_geom("Freeform", &[dp], &fill, "", true, 0.0);
    }

    fn vec_stroke(
        &mut self,
        path: &Path,
        transform: Transform,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    ) {
        if stroke.width <= 0.0 {
            return;
        }
        // Far geometry is cut to the page first, as on PNG (VR-44).
        use super::fit::VecStroke;
        match super::fit::vector_stroke_style(path, transform, stroke, self.w, self.h) {
            VecStroke::Keep => self.vec_stroke_unfitted(path, transform, color, stroke, clip),
            VecStroke::Runs(runs) => {
                for (run, phase) in runs {
                    let style = StrokeStyle {
                        phase,
                        ..stroke.clone()
                    };
                    self.vec_stroke_unfitted(&run, transform, color, &style, clip);
                }
            }
            VecStroke::Outline => self.stroke_outline(path, transform, color, stroke, clip),
            VecStroke::Skip => {}
        }
    }

    /// A stroke whose geometry is in range (see `vec_stroke`).
    fn vec_stroke_unfitted(
        &mut self,
        path: &Path,
        transform: Transform,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    ) {
        // DrawingML lines take no picture fill: a patterned stroke is drawn as
        // its outline, filled with the pattern.
        let patterned = matches!(stroke.paint, Some(ResolvedPaint::Pattern { .. }));
        let Some(scale) = uniform_scale(transform).filter(|_| !patterned) else {
            self.stroke_outline(path, transform, color, stroke, clip);
            return;
        };
        let dp = match self.clip_line(DevPath::from_path(path, transform), clip) {
            Clipped::Drop => return,
            Clipped::Cut(dp) | Clipped::Keep(dp) => dp,
        };
        if dp.is_empty() {
            return;
        }
        let ln = self.ln_xml(color, stroke, scale, transform, dp.bounds());
        let closed = dp_all_closed(&dp);
        let pad = stroke_reach(stroke, scale);
        self.emit_geom("Line", &[dp], "", &ln, closed, pad);
    }

    #[allow(clippy::too_many_arguments)]
    fn vec_fill_stroke(
        &mut self,
        path: &Path,
        transform: Transform,
        paint: &ResolvedPaint,
        rule: FillRule,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    ) {
        // One shape with both a fill and an outline, as a user would draw it,
        // when the outline can be a DrawingML line: the geometry must not need
        // rewriting for the fill rule (that would change where the outline runs)
        // and the pen must scale uniformly.
        let scale = uniform_scale(transform);
        let dp = DevPath::from_path(path, transform);
        let boxes = dp.subpath_bounds();
        let plain = boxes.len() <= 1 || !any_overlap(&boxes);
        // A shape the clip cuts is drawn as its cut fill and its cut outline.
        let cov = self.coverage(dp.bounds(), clip);
        if cov == Coverage::Outside {
            return;
        }
        if cov == Coverage::Partial
            || scale.is_none()
            || !plain
            || matches!(paint, ResolvedPaint::Hatch { .. })
            || matches!(stroke.paint, Some(ResolvedPaint::Pattern { .. }))
            || stroke.width <= 0.0
            || !matches!(
                super::fit::vector_stroke_style(path, transform, stroke, self.w, self.h),
                super::fit::VecStroke::Keep
            )
        {
            self.vec_fill(path, transform, paint, rule, clip);
            self.vec_stroke(path, transform, color, stroke, clip);
            return;
        }
        if dp.is_empty() {
            return;
        }
        let bb = dp.bounds();
        let fill = self.fill_xml(paint, transform, bb);
        let ln = self.ln_xml(color, stroke, scale.unwrap_or(1.0), transform, bb);
        let pad = stroke_reach(stroke, scale.unwrap_or(1.0));
        self.emit_geom("Freeform", &[dp], &fill, &ln, true, pad);
    }

    fn vec_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        if run.label.is_empty() && run.rules.is_empty() {
            return;
        }
        // An `md()` label whose runs are all text (no math) is written as one
        // text run per styled span (VR-40); `paras` holds each line's spans.
        let paras = rich_paras(run);
        let (lines, nonblank, label_lines): (Vec<(usize, usize)>, Vec<usize>, Vec<&str>) =
            match &paras {
                Some(ps) => {
                    let mut lines = Vec::new();
                    let mut nonblank = Vec::new();
                    let mut g = 0usize;
                    for (i, p) in ps.iter().enumerate() {
                        let n: usize = p.iter().map(|sp| sp.glyphs).sum();
                        if p.iter().any(|sp| !sp.text.is_empty()) {
                            nonblank.push(i);
                            lines.push((g, g + n));
                        }
                        g += n;
                    }
                    (lines, nonblank, Vec::new())
                }
                None => {
                    let label_lines: Vec<&str> = run.label.split('\n').collect();
                    // Indices of the label lines that hold text, in order.
                    let nonblank = (0..label_lines.len())
                        .filter(|&i| !label_lines[i].is_empty())
                        .collect();
                    (line_runs(run), nonblank, label_lines)
                }
            };
        let scale = uniform_scale(transform);
        let reflected = (transform.sx as f64 * transform.sy as f64
            - transform.kx as f64 * transform.ky as f64)
            < 0.0;
        let outline = self.outline_text
            || (!run.gcolor.is_empty() && paras.is_none())
            || !run.rules.is_empty()
            || run.halo.is_some()
            || run.w <= 0.0
            || run.color.a == 0
            || scale.is_none()
            || reflected
            // Each glyph line must be one of the label's non-blank lines (a
            // blank line has no glyphs, so it has no glyph line either).
            || (lines.len() > 1 && lines.len() != nonblank.len());
        // The label's box in local px, before rotation.
        let x0 = run.ax - run.hjust * run.w;
        let y0 = run.ay - (1.0 - run.vjust) * run.h;
        let rot_t = crate::units::rotation_about(run.rot, run.ax, run.ay);
        let full = transform.pre_concat(rot_t);
        {
            let corners = [
                (x0, y0),
                (x0 + run.w, y0),
                (x0 + run.w, y0 + run.h),
                (x0, y0 + run.h),
            ];
            let pts: Vec<Pt> = corners
                .iter()
                .map(|(x, y)| map_pt(full, tiny_skia::Point::from_xy(*x as f32, *y as f32)))
                .collect();
            let b = [
                pts.iter().map(|p| p.0).fold(f64::INFINITY, f64::min),
                pts.iter().map(|p| p.1).fold(f64::INFINITY, f64::min),
                pts.iter().map(|p| p.0).fold(f64::NEG_INFINITY, f64::max),
                pts.iter().map(|p| p.1).fold(f64::NEG_INFINITY, f64::max),
            ];
            match self.coverage(Some(b), clip) {
                Coverage::Outside => return,
                // Outlines are cut exactly, below; a text run cannot be.
                Coverage::Partial if !outline => {
                    self.warn("text crossing a clip edge is drawn whole")
                }
                _ => {}
            }
        }
        if outline {
            self.text_outlines(run, transform, clip);
            return;
        }
        let s = scale.unwrap_or(1.0);
        // Centre of the box on the page, and the box size.
        let (ccx, ccy) = map_pt(
            full,
            tiny_skia::Point::from_xy((x0 + run.w / 2.0) as f32, (y0 + run.h / 2.0) as f32),
        );
        let (bw, bh) = (run.w * s, run.h * s);
        // Page rotation: the label's own (counter-clockwise) plus the
        // transform's, as DrawingML's clockwise 60000ths of a degree.
        let t_ang = (transform.ky as f64)
            .atan2(transform.sx as f64)
            .to_degrees();
        let rot = (t_ang - run.rot).rem_euclid(360.0);
        let rot_emu = (rot * 60_000.0).round() as i64 % 21_600_000;
        let ew = self.len(bw).max(1);
        let eh = self.len(bh).max(1);
        let ox = self.ex(ccx) - ew / 2;
        let oy = self.ey(ccy) - eh / 2;
        // One line aligns away from its anchor; several keep the alignment
        // their glyphs were set with.
        let algn = if lines.len() > 1 {
            infer_align(run, &lines)
        } else {
            match run.hjust {
                h if h <= 0.25 => "l",
                h if h >= 0.75 => "r",
                _ => "ctr",
            }
        };
        let anchor = match run.vjust {
            v if v <= 0.25 => "b",
            v if v >= 0.75 => "t",
            _ => "ctr",
        };
        let pt = run.size * s;
        let sz = ((pt * 100.0).round() as i64).clamp(100, 400_000);
        let (bold, italic) = face_flags(run.face);
        let face = dml_escape(&typeface(run));
        let mut rpr = format!("<a:rPr sz=\"{sz}\"");
        if bold {
            rpr.push_str(" b=\"1\"");
        }
        if italic {
            rpr.push_str(" i=\"1\"");
        }
        rpr.push_str(&format!(
            " dirty=\"0\">{}<a:latin typeface=\"{face}\"/><a:ea typeface=\"{face}\"/><a:cs typeface=\"{face}\"/></a:rPr>",
            solid_fill(run.color, 1.0)
        ));
        // Line pitch from the glyph baselines, so a multi-line label keeps
        // vellum's spacing rather than the font's default.
        let ln_spc = if lines.len() > 1 {
            let (a, b) = (lines[0].0, lines[1].0);
            // The first two glyph lines may have blank lines between them.
            let steps = (nonblank[1] - nonblank[0]).max(1) as f64;
            // A rich label's line breaks carry vellum's line pitch (its glyphs
            // sit at run-dependent heights, so they cannot give it).
            let rich_pitch = run
                .spans
                .iter()
                .find(|sp| sp.brk && sp.size > 0.0)
                .filter(|_| paras.is_some())
                .map(|sp| sp.size * s);
            let pitch_pt = match rich_pitch {
                Some(p) => p,
                None => {
                    let pitch_px = (run.gy[a] - run.gy[b]).abs() * s / steps;
                    pitch_px * 72.0 / (EMU_PER_INCH / self.k)
                }
            };
            format!(
                "<a:lnSpc><a:spcPts val=\"{}\"/></a:lnSpc>",
                (pitch_pt * 100.0).round() as i64
            )
        } else {
            String::new()
        };
        let mut body = String::new();
        if let Some(ps) = &paras {
            let mut g = 0usize;
            let mut col = run.color;
            for p in ps {
                body.push_str(&format!("<a:p><a:pPr algn=\"{algn}\">{ln_spc}</a:pPr>"));
                let mut any = false;
                for sp in p {
                    if let Some(c) = run.gcolor.get(g).filter(|_| sp.glyphs > 0) {
                        col = *c;
                    }
                    g += sp.glyphs;
                    if sp.text.is_empty() {
                        continue;
                    }
                    any = true;
                    let rpr = span_rpr(run, sp, g - sp.glyphs, s, col);
                    body.push_str(&format!(
                        "<a:r>{rpr}<a:t>{}</a:t></a:r>",
                        dml_escape(&sp.text)
                    ));
                }
                if !any {
                    body.push_str(&format!("<a:endParaRPr sz=\"{sz}\" dirty=\"0\"/>"));
                }
                body.push_str("</a:p>");
            }
        }
        for line in label_lines {
            body.push_str(&format!("<a:p><a:pPr algn=\"{algn}\">{ln_spc}</a:pPr>"));
            if line.is_empty() {
                body.push_str(&format!("<a:endParaRPr sz=\"{sz}\" dirty=\"0\"/>"));
            } else {
                body.push_str(&format!("<a:r>{rpr}<a:t>{}</a:t></a:r>", dml_escape(line)));
            }
            body.push_str("</a:p>");
        }
        let id = self.id();
        let rot_attr = if rot_emu != 0 {
            format!(" rot=\"{rot_emu}\"")
        } else {
            String::new()
        };
        let xml = format!(
            "<p:sp><p:nvSpPr><p:cNvPr id=\"{id}\" name=\"TextBox {id}\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr>\
             <p:spPr><a:xfrm{rot_attr}><a:off x=\"{ox}\" y=\"{oy}\"/><a:ext cx=\"{ew}\" cy=\"{eh}\"/></a:xfrm>\
             {geom}<a:noFill/></p:spPr>\
             <p:txBody><a:bodyPr wrap=\"none\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" anchor=\"{anchor}\" rtlCol=\"0\">\
             <a:noAutofit/></a:bodyPr><a:lstStyle/>{body}</p:txBody></p:sp>",
            geom = prst("rect"),
        );
        let b = rotated_bounds(ox, oy, ew, eh, rot);
        self.push(&xml, b);
    }

    fn vec_image(
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
    ) {
        if iw == 0 || ih == 0 {
            return;
        }
        // A far image is cut to the part over the page first (VR-46).
        let fitted;
        let (rgba, iw, ih, x, y, w, h, interpolate) = match super::fit::vector_image(
            rgba,
            iw,
            ih,
            x,
            y,
            w,
            h,
            interpolate,
            transform,
            self.w,
            self.h,
        ) {
            super::fit::VecImage::Keep => (rgba, iw, ih, x, y, w, h, interpolate),
            super::fit::VecImage::Draw(f) => {
                fitted = f;
                (
                    &fitted.rgba[..],
                    fitted.iw,
                    fitted.ih,
                    fitted.x,
                    fitted.y,
                    fitted.w,
                    fitted.h,
                    fitted.interpolate,
                )
            }
            super::fit::VecImage::Skip => return,
        };
        let t = transform;
        let (sx, ky, kx, sy) = (t.sx as f64, t.ky as f64, t.kx as f64, t.sy as f64);
        let (ax, ay) = (sx.hypot(ky), kx.hypot(sy));
        if (sx * kx + ky * sy).abs() > 1e-6 * ax.max(ay) * ax.max(ay) {
            self.warn("a skewed raster is drawn unskewed");
        }
        let (cx, cy) = map_pt(t, tiny_skia::Point::from_xy(x as f32, y as f32));
        let (dw, dh) = ((w * ax).abs(), (h * ay).abs());
        let rot = ky.atan2(sx).to_degrees().rem_euclid(360.0);
        let flip = sx * sy - kx * ky < 0.0;
        // The cell's corners on the page.
        let corners: Vec<Pt> = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)]
            .iter()
            .map(|(u, v)| {
                map_pt(
                    t,
                    tiny_skia::Point::from_xy((x + u * w) as f32, (y + v * h) as f32),
                )
            })
            .collect();
        let ib = [
            corners.iter().map(|p| p.0).fold(f64::INFINITY, f64::min),
            corners.iter().map(|p| p.1).fold(f64::INFINITY, f64::min),
            corners
                .iter()
                .map(|p| p.0)
                .fold(f64::NEG_INFINITY, f64::max),
            corners
                .iter()
                .map(|p| p.1)
                .fold(f64::NEG_INFINITY, f64::max),
        ];
        let mut crop: Option<[f64; 4]> = None;
        let (mut cx, mut cy, mut dw, mut dh) = (cx, cy, dw, dh);
        match self.coverage(Some(ib), clip) {
            Coverage::Outside => return,
            Coverage::Inside => {}
            Coverage::Partial => {
                let r = self.region(clip).expect("a partial coverage has a region");
                let upright = rot.abs() < 1e-9 && !flip;
                if !(r.rect && upright) {
                    self.raster_region(rgba, iw, ih, x, y, w, h, interpolate, t, clip, ib);
                    return;
                }
                // An upright picture in a rectangular clip: crop the image
                // (`a:srcRect`) and shrink the frame to the visible part.
                let v = [
                    ib[0].max(r.bbox[0]),
                    ib[1].max(r.bbox[1]),
                    ib[2].min(r.bbox[2]),
                    ib[3].min(r.bbox[3]),
                ];
                if v[2] <= v[0] || v[3] <= v[1] {
                    return;
                }
                let (iw_, ih_) = (ib[2] - ib[0], ib[3] - ib[1]);
                crop = Some([
                    (v[0] - ib[0]) / iw_,
                    (v[1] - ib[1]) / ih_,
                    (ib[2] - v[2]) / iw_,
                    (ib[3] - v[3]) / ih_,
                ]);
                cx = (v[0] + v[2]) / 2.0;
                cy = (v[1] + v[3]) / 2.0;
                dw = v[2] - v[0];
                dh = v[3] - v[1];
            }
        }
        let png = if interpolate {
            straight_png(rgba, iw, ih)
        } else {
            // Enlarge until each cell spans at least a few output pixels at
            // twice the scene's resolution, within a pixel budget.
            let target = (dw.max(dh) * 2.0) / iw.max(ih) as f64;
            let budget = (16_000_000.0 / (iw as f64 * ih as f64)).sqrt();
            let f = target.ceil().min(budget.floor()).max(1.0) as u32;
            if f > 1 {
                straight_png(&upscale_nearest(rgba, iw, ih, f), iw * f, ih * f)
            } else {
                straight_png(rgba, iw, ih)
            }
        };
        let Some(png) = png else { return };
        self.emit_picture(png, cx, cy, dw, dh, rot, flip, crop);
    }
}

/// Mirror a call to the page raster, if kept, then route it to the active
/// capture (returning) or fall through to the vector writer.
macro_rules! route {
    ($self:ident, $call:ident ( $($arg:expr),* )) => {
        if let Some(m) = $self.mirror.as_mut() {
            m.$call($($arg),*);
        }
        if let Some(c) = $self.capture.as_mut() {
            c.rb.$call($($arg),*);
            if c.exclusive {
                return;
            }
        }
    };
}

fn copy_mask(m: &Option<MaskLayer>) -> Option<MaskLayer> {
    m.as_ref().map(|m| MaskLayer {
        pixmap: m.pixmap.clone(),
        kind: m.kind,
    })
}

impl RenderBackend for DmlBackend {
    fn far_window(&self, transform: Transform) -> FarWin {
        let (w, h) = (self.w, self.h);
        FarWin::for_page(transform, w, h)
    }
    /// A `push_circle` path becomes a preset ellipse (`is_ellipse`).
    fn exact_circles(&self, _dashed: bool) -> bool {
        true
    }
    fn fill_path(
        &mut self,
        path: &Path,
        transform: Transform,
        paint: &ResolvedPaint,
        rule: FillRule,
        clip: &Clip,
    ) {
        route!(self, fill_path(path, transform, paint, rule, clip));
        self.vec_fill(path, transform, paint, rule, clip);
    }

    fn stroke_path(
        &mut self,
        path: &Path,
        transform: Transform,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    ) {
        route!(self, stroke_path(path, transform, color, stroke, clip));
        self.vec_stroke(path, transform, color, stroke, clip);
    }

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
        route!(
            self,
            fill_and_stroke_path(path, transform, paint, rule, color, stroke, clip)
        );
        self.vec_fill_stroke(path, transform, paint, rule, color, stroke, clip);
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        self.flush_points();
        route!(self, draw_text(run, transform, clip));
        self.vec_text(run, transform, clip);
    }

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
    ) {
        self.flush_points();
        route!(
            self,
            draw_image(rgba, iw, ih, x, y, w, h, interpolate, transform, clip)
        );
        self.vec_image(rgba, iw, ih, x, y, w, h, interpolate, transform, clip);
    }

    fn begin_group(
        &mut self,
        mask: Option<MaskLayer>,
        alpha: f32,
        blend: BlendKind,
        effect: GroupEffect,
    ) {
        self.flush_points();
        if let Some(m) = self.mirror.as_mut() {
            m.begin_group(copy_mask(&mask), alpha, blend, effect);
        }
        let plain =
            mask.is_none() && alpha >= 1.0 && blend == BlendKind::Normal && effect.is_none();
        let opacity_only =
            mask.is_none() && blend == BlendKind::Normal && effect.is_none() && alpha < 1.0;
        if let Some(c) = self.capture.as_mut() {
            c.depth += 1;
            let shadow = !c.exclusive;
            if shadow && !plain && !opacity_only && !c.failed {
                // Folding stops here; say why the region became a picture.
                c.failed = true;
                c.reason = group_reason(mask.is_some(), blend, effect);
            }
            c.rb.begin_group(mask, alpha, blend, effect);
            if shadow && opacity_only {
                self.frames.push(Frame::new("Group"));
                self.groups.push(GroupKind::Fold(alpha));
            } else {
                self.groups.push(GroupKind::Plain);
            }
            return;
        }
        if plain {
            self.groups.push(GroupKind::Plain);
            return;
        }
        let reason = group_reason(mask.is_some(), blend, effect);
        let exclusive = mask.is_some() || blend != BlendKind::Normal || !effect.is_none();
        let is_blend = blend != BlendKind::Normal && self.mirror.is_some();
        let mut rb = RasterBackend::new(
            self.w,
            self.h,
            Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            },
        );
        // For a blend, the capture only measures coverage: composite normally.
        let cap_blend = if is_blend { BlendKind::Normal } else { blend };
        rb.begin_group(mask, alpha, cap_blend, effect);
        if !exclusive {
            self.frames.push(Frame::new("Group"));
        }
        self.capture = Some(Capture {
            rb,
            depth: 1,
            exclusive,
            blend: is_blend,
            alpha,
            failed: false,
            reason,
        });
        self.groups.push(GroupKind::Capture);
    }

    fn end_group(&mut self) {
        self.flush_points();
        if let Some(m) = self.mirror.as_mut() {
            m.end_group();
        }
        let kind = self.groups.pop();
        let Some(c) = self.capture.as_mut() else {
            return;
        };
        c.rb.end_group();
        c.depth -= 1;
        if let Some(GroupKind::Fold(alpha)) = kind {
            // A nested opacity: fold it into its own shapes, or give up on
            // folding the whole capture if they overlap.
            let frame = self.frames.pop().expect("fold frame");
            if !self.fold_into_parent(frame, alpha) {
                let c = self.capture.as_mut().expect("capture");
                c.failed = true;
                c.reason = "group opacity over overlapping shapes";
            }
            return;
        }
        if c.depth > 0 || !matches!(kind, Some(GroupKind::Capture)) {
            return;
        }
        let c = self.capture.take().expect("capture");
        if !c.exclusive {
            let frame = self.frames.pop().expect("group frame");
            if !c.failed && self.fold_into_parent(frame, c.alpha) {
                return;
            }
        }
        let mut pm = c.rb.into_pixmap();
        if c.blend {
            // The blended result, where the group reaches.
            if let Some(m) = self.mirror.as_ref() {
                blend_from_mirror(&mut pm, m.page());
            }
        }
        if self.emit_pixmap_region(&pm, [0.0, 0.0, self.w as f64, self.h as f64]) {
            self.warn(&format!(
                "{} are drawn as a picture of the region they cover",
                c.reason
            ));
        }
    }

    fn begin_panel(&mut self, name: &str, _pannable: bool) {
        self.flush_points();
        self.frames.push(Frame::new(name));
    }

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
        _keys: &[String],
    ) {
        // Every circle is a point mark: held back and merged (VR-39).
        self.in_circles = true;
        circles_by_path(self, cx, cy, r, fill, stroke.as_ref(), transform, clip);
        self.in_circles = false;
    }

    fn begin_marker(
        &mut self,
        _shape: u32,
        _cx: f64,
        _cy: f64,
        _r: f64,
        _transform: Transform,
        _clip: &Clip,
    ) {
        self.marker_armed = true;
    }

    fn set_element_key(&mut self, _key: Option<&str>) {
        // A new element or node: what follows is a point mark only if it
        // announces itself with `begin_marker`.
        self.marker_armed = false;
    }

    fn end_panel(&mut self) {
        // A panel opened inside a capture frame closes into it.
        if self.frames.len() > 1 {
            self.close_frame(false);
        }
    }

    fn take_warnings(&mut self) -> Vec<String> {
        self.warnings.clone()
    }
}

impl DmlBackend {
    /// Fold `alpha` into a closed frame's shapes and splice them into the
    /// current frame, when that is exactly what the group would composite to:
    /// no two shapes overlap and none overlaps itself. Returns false (and
    /// writes nothing) otherwise.
    fn fold_into_parent(&mut self, frame: Frame, alpha: f32) -> bool {
        if frame.self_overlap || any_overlap_bounds(&frame.items) {
            return false;
        }
        if let Some(b) = frame.bbox {
            let body = fold_alpha(&frame.body, alpha);
            self.splice(&body, b, frame.items, false);
        }
        true
    }
}

/// Why a group has to be drawn as a picture, for the warning.
fn group_reason(mask: bool, blend: BlendKind, effect: GroupEffect) -> &'static str {
    if mask {
        "masks"
    } else if blend != BlendKind::Normal {
        "blend modes"
    } else if !effect.is_none() {
        "blur and shadow effects"
    } else {
        "group opacity over overlapping shapes"
    }
}

/// How far a stroke drawn under a uniform `scale` reaches past its geometry,
/// in device px: half the line width; a square cap reaches a half-width
/// diagonal (`half * sqrt 2`) past an end, and a miter join up to the miter
/// limit's worth.
fn stroke_reach(st: &StrokeStyle, scale: f64) -> f64 {
    let half = st.width as f64 * scale / 2.0;
    let cap = match st.cap {
        crate::color::LineCap::Square => half * std::f64::consts::SQRT_2,
        _ => half,
    };
    let join = match st.join {
        crate::color::LineJoin::Mitre => half * (st.miter as f64).max(1.0),
        _ => half,
    };
    cap.max(join)
}

/// The level of each box (see [`DmlBackend::flush_points`]): one above the
/// highest earlier box it overlaps (touching edges do not count).
///
/// Boxes are found through a uniform grid of cells half a typical box in
/// size, so a typical box covers at least one cell whole. A box covering a
/// cell overlaps every later box reaching into that cell and outranks every
/// earlier one there, so the cell keeps only the highest such level (its
/// floor) and the boxes registered since that only reach in partly. A dense
/// layer then stays linear: each cell holds a handful of boxes.
fn point_levels(boxes: &[[f64; 4]]) -> Vec<usize> {
    #[derive(Default)]
    struct Cell {
        /// One above the highest level of a box covering the cell (0: none).
        floor: usize,
        /// Boxes reaching partly into the cell, above the floor.
        part: Vec<usize>,
    }
    let n = boxes.len();
    let mut level = vec![0usize; n];
    if n < 2 {
        return level;
    }
    let mut sizes: Vec<f64> = boxes
        .iter()
        .map(|b| (b[2] - b[0]).max(b[3] - b[1]))
        .filter(|v| v.is_finite() && *v > 0.0)
        .collect();
    sizes.sort_by(|a, b| a.total_cmp(b));
    let cell = (sizes.get(sizes.len() / 2).copied().unwrap_or(1.0) / 2.0).max(0.5);
    let overlap =
        |a: &[f64; 4], b: &[f64; 4]| a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3];
    let mut grid: HashMap<(i64, i64), Cell> = HashMap::new();
    // Boxes spanning too many cells are checked against every other box.
    let mut wide: Vec<usize> = Vec::new();
    const MAX_CELLS: i64 = 256;
    for i in 0..n {
        let b = &boxes[i];
        // The cells the box's interior reaches into.
        let lo = |v: f64| (v / cell).floor().clamp(-1e15, 1e15) as i64;
        let hi = |v: f64| (v / cell).ceil().clamp(-1e15, 1e15) as i64 - 1;
        let (cx0, cy0) = (lo(b[0]), lo(b[1]));
        let (cx1, cy1) = (hi(b[2]).max(cx0), hi(b[3]).max(cy0));
        let many = (cx1 - cx0 + 1).saturating_mul(cy1 - cy0 + 1) > MAX_CELLS;
        let mut lv = 0usize;
        for &j in &wide {
            if overlap(b, &boxes[j]) {
                lv = lv.max(level[j] + 1);
            }
        }
        if many {
            for j in 0..i {
                if overlap(b, &boxes[j]) {
                    lv = lv.max(level[j] + 1);
                }
            }
            level[i] = lv;
            wide.push(i);
            continue;
        }
        for gx in cx0..=cx1 {
            for gy in cy0..=cy1 {
                if let Some(c) = grid.get(&(gx, gy)) {
                    lv = lv.max(c.floor);
                    for &j in &c.part {
                        if level[j] + 1 > lv && overlap(b, &boxes[j]) {
                            lv = level[j] + 1;
                        }
                    }
                }
            }
        }
        level[i] = lv;
        for gx in cx0..=cx1 {
            for gy in cy0..=cy1 {
                let c = grid.entry((gx, gy)).or_default();
                let covers = b[0] <= gx as f64 * cell
                    && b[2] >= (gx + 1) as f64 * cell
                    && b[1] <= gy as f64 * cell
                    && b[3] >= (gy + 1) as f64 * cell;
                if covers {
                    // Every box already here reaches into the cell, so it
                    // overlaps this one and sits below it.
                    c.floor = c.floor.max(lv + 1);
                    let floor = c.floor;
                    c.part.retain(|&j| level[j] + 1 > floor);
                } else {
                    c.part.push(i);
                }
            }
        }
    }
    level
}

/// Whether any two EMU boxes overlap (touching edges do not count).
fn any_overlap_bounds(items: &[Bounds]) -> bool {
    let boxes: Vec<[f64; 4]> = items
        .iter()
        .map(|b| {
            [
                b[0] as f64 + 0.5,
                b[1] as f64 + 0.5,
                b[2] as f64 - 0.5,
                b[3] as f64 - 0.5,
            ]
        })
        .collect();
    boxes.len() > 1 && any_overlap(&boxes)
}

/// Replace a capture with the page mirror wherever the capture covers
/// anything. The mirror already holds the blended result composited over
/// everything beneath, so where the group reaches, the picture shows the
/// mirror as it is (a faint glow included); elsewhere it stays transparent.
fn blend_from_mirror(pm: &mut Pixmap, page: &Pixmap) {
    let src = page.pixels();
    for (i, p) in pm.pixels_mut().iter_mut().enumerate() {
        if p.alpha() > 0 {
            *p = src[i];
        }
    }
}

/// Multiply the number after every `key` (an attribute value ending in `"`)
/// by `a`.
fn scale_values(xml: &str, key: &str, a: f64) -> String {
    let mut out = String::with_capacity(xml.len());
    let mut rest = xml;
    while let Some(i) = rest.find(key) {
        let j = i + key.len();
        out.push_str(&rest[..j]);
        let end = rest[j..].find('"').map(|e| j + e).unwrap_or(rest.len());
        let v: f64 = rest[j..end].parse().unwrap_or(100_000.0);
        out.push_str(&((v * a).round() as i64).to_string());
        rest = &rest[end..];
    }
    out.push_str(rest);
    out
}

/// Multiply the opacity of every colour and picture in a run of shapes by `a`.
fn fold_alpha(xml: &str, a: f32) -> String {
    let a = a.clamp(0.0, 1.0) as f64;
    // Existing alpha values (colours and pictures) scale.
    let mut s = scale_values(xml, "<a:alpha val=\"", a);
    s = scale_values(&s, "<a:alphaModFix amt=\"", a);
    let amt = (a * 100_000.0).round() as i64;
    // Opaque colours gain an alpha.
    let mut o = String::with_capacity(s.len() + 64);
    let key = "<a:srgbClr val=\"";
    let mut r = s.as_str();
    while let Some(i) = r.find(key) {
        let j = i + key.len() + 6; // the six hex digits
        o.push_str(&r[..j]);
        let tail = &r[j..];
        if let Some(stripped) = tail.strip_prefix("\"/>") {
            o.push_str(&format!("\"><a:alpha val=\"{amt}\"/></a:srgbClr>"));
            r = stripped;
        } else {
            r = tail;
        }
    }
    o.push_str(r);
    s = o;
    // Pictures without an alpha gain one.
    let mut o = String::with_capacity(s.len() + 64);
    let mut r = s.as_str();
    let key = "<a:blip r:embed=\"";
    while let Some(i) = r.find(key) {
        let j = i + key.len();
        let end = r[j..].find('"').map(|e| j + e).unwrap_or(r.len());
        o.push_str(&r[..end]);
        let tail = &r[end..];
        if let Some(stripped) = tail.strip_prefix("\"/>") {
            o.push_str(&format!("\"><a:alphaModFix amt=\"{amt}\"/></a:blip>"));
            r = stripped;
        } else {
            r = tail;
        }
    }
    o.push_str(r);
    o
}

/// A rich label's styled runs split into lines, when the label can be written
/// as native text runs: it has runs (an `md()` label; a `tex()` label and an
/// `md()` label with math have none, and math has rules and glyph text too),
/// and they account for exactly the label's glyphs.
fn rich_paras<'r>(run: &'r TextRun) -> Option<Vec<Vec<&'r TextSpan>>> {
    if run.gcolor.is_empty()
        || run.spans.is_empty()
        || !run.rules.is_empty()
        || !run.gtext.is_empty()
    {
        return None;
    }
    let n: usize = run.spans.iter().map(|sp| sp.glyphs).sum();
    if n != run.gid.len() || n != run.gcolor.len() {
        return None;
    }
    let mut paras = vec![Vec::new()];
    for sp in run.spans {
        if sp.brk {
            paras.push(Vec::new());
        } else if let Some(p) = paras.last_mut() {
            p.push(sp);
        }
    }
    Some(paras)
}

/// The `a:rPr` of one styled run whose glyphs start at `g0`, drawn under a
/// uniform `scale`, in colour `col`. A raised or lowered run (`^sup^`,
/// `~sub~`) is written as a DrawingML baseline shift at the size of the text
/// around it, because PowerPoint and LibreOffice shrink a shifted run
/// themselves: writing the shrunk size too would shrink it twice.
fn span_rpr(run: &TextRun, sp: &TextSpan, g0: usize, scale: f64, col: Rgba) -> String {
    // markdown sets a shifted run at 0.7 of the size around it.
    let (size, baseline) = if sp.dy != 0.0 && sp.size > 0.0 {
        let around = sp.size / 0.7;
        (around, (sp.dy / around * 100_000.0).round() as i64)
    } else {
        (sp.size, 0)
    };
    let sz = ((size * scale * 100.0).round() as i64).clamp(100, 400_000);
    let (bold, italic) = face_flags(&sp.face);
    let face = dml_escape(&typeface_at(run, g0));
    let mut rpr = format!("<a:rPr sz=\"{sz}\"");
    if bold {
        rpr.push_str(" b=\"1\"");
    }
    if italic {
        rpr.push_str(" i=\"1\"");
    }
    if baseline != 0 {
        rpr.push_str(&format!(
            " baseline=\"{}\"",
            baseline.clamp(-100_000, 100_000)
        ));
    }
    rpr.push_str(&format!(
        " dirty=\"0\">{}<a:latin typeface=\"{face}\"/><a:ea typeface=\"{face}\"/><a:cs typeface=\"{face}\"/></a:rPr>",
        solid_fill(col, 1.0)
    ));
    rpr
}

/// The alignment a multi-line label's lines were set with, read back from the
/// glyph positions: lines sharing a left edge are left-aligned, else the edge
/// (right, or centre) that varies least. A line's right edge is its last
/// glyph's pen position plus its outline's extent.
fn infer_align(run: &TextRun, lines: &[(usize, usize)]) -> &'static str {
    let mut edges: Vec<(f64, f64)> = Vec::new();
    for &(lo, hi) in lines {
        if lo >= hi {
            continue;
        }
        let left = run.gx[lo];
        let last = hi - 1;
        let ext = glyph_outline_cached(
            &run.gpath[last],
            run.gface[last],
            run.gid[last],
            run.gsize[last] as f32,
        )
        .map(|p| p.bounds().right() as f64)
        .unwrap_or(0.0);
        edges.push((left, run.gx[last] + ext.max(0.0)));
    }
    if edges.len() < 2 {
        return "l";
    }
    let spread = |f: &dyn Fn(&(f64, f64)) -> f64| {
        let v: Vec<f64> = edges.iter().map(f).collect();
        v.iter().cloned().fold(f64::NEG_INFINITY, f64::max)
            - v.iter().cloned().fold(f64::INFINITY, f64::min)
    };
    let l = spread(&|e| e.0);
    let r = spread(&|e| e.1);
    let c = spread(&|e| (e.0 + e.1) / 2.0);
    if l <= 0.5 || (l <= r && l <= c) {
        "l"
    } else if r <= c {
        "r"
    } else {
        "ctr"
    }
}

/// Whether every subpath of `p` ends in a close.
fn dp_all_closed(p: &DevPath) -> bool {
    let mut open = false;
    let mut any = false;
    for s in &p.segs {
        match s {
            Seg::Move(_) => {
                if open {
                    return false;
                }
                open = true;
                any = true;
            }
            Seg::Close => open = false,
            _ => {}
        }
    }
    any && !open
}

/// Write each PNG to `dir` as `vellum-<content hash>.png` and return the paths,
/// in media order. Content-named, so writing the same image twice is harmless.
pub fn write_media_files(media: &[Vec<u8>], dir: &str) -> std::io::Result<Vec<String>> {
    media
        .iter()
        .map(|png| {
            let p = std::path::Path::new(dir).join(format!("vellum-{:016x}.png", fnv64(png)));
            std::fs::write(&p, png)?;
            Ok(p.to_string_lossy().into_owned())
        })
        .collect()
}

/// Resolve a fragment's media tokens with `f(index)`.
pub fn resolve_media(xml: &str, mut f: impl FnMut(usize) -> String) -> String {
    let mut out = String::with_capacity(xml.len());
    let mut parts = xml.split(MEDIA_TOKEN);
    if let Some(first) = parts.next() {
        out.push_str(first);
    }
    let mut in_token = true;
    for part in parts {
        if in_token {
            match part.parse::<usize>() {
                Ok(i) => out.push_str(&xml_escape(&f(i))),
                Err(_) => out.push_str(part),
            }
        } else {
            out.push_str(part);
        }
        in_token = !in_token;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clip0() -> Clip<'static> {
        Clip { id: 0, shapes: &[] }
    }

    fn pen(w: f32) -> StrokeStyle {
        StrokeStyle {
            width: w,
            dash: Vec::new(),
            cap: LineCap::Butt,
            join: LineJoin::Mitre,
            miter: 10.0,
            crisp: false,
            paint: None,
            phase: 0.0,
        }
    }

    const RED: Rgba = Rgba {
        r: 255,
        g: 0,
        b: 0,
        a: 255,
    };

    #[test]
    fn a_rect_fill_is_a_preset_rect_at_its_emu_box() {
        let mut b = DmlBackend::new(
            100,
            100,
            96.0,
            Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            },
            0,
            0,
            false,
        );
        let p = rect_path(10.0, 20.0, 30.0, 40.0).unwrap();
        b.fill_path(
            &p,
            Transform::identity(),
            &ResolvedPaint::Solid(RED),
            FillRule::Winding,
            &clip0(),
        );
        let (xml, media, warns) = b.finish();
        assert!(media.is_empty() && warns.is_empty());
        // 1 px = 9525 EMU at 96 dpi
        assert!(
            xml.contains("<a:off x=\"95250\" y=\"190500\"/><a:ext cx=\"285750\" cy=\"381000\"/>"),
            "{xml}"
        );
        assert!(xml.contains("prst=\"rect\""));
        assert!(xml.contains("<a:solidFill><a:srgbClr val=\"FF0000\"/></a:solidFill>"));
    }

    #[test]
    fn a_translucent_dashed_stroke_maps_width_cap_join_and_dash() {
        let mut b = DmlBackend::new(
            100,
            100,
            96.0,
            Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            },
            0,
            0,
            false,
        );
        let mut pb = PathBuilder::new();
        pb.move_to(0.0, 0.0);
        pb.line_to(50.0, 50.0);
        let mut st = pen(2.0);
        st.dash = vec![4.0, 2.0];
        st.cap = LineCap::Round;
        st.join = LineJoin::Round;
        let col = Rgba {
            r: 0,
            g: 0,
            b: 255,
            a: 128,
        };
        b.stroke_path(
            &pb.finish().unwrap(),
            Transform::identity(),
            col,
            &st,
            &clip0(),
        );
        let (xml, _, _) = b.finish();
        assert!(xml.contains("<a:ln w=\"19050\" cap=\"rnd\">"), "{xml}");
        assert!(xml.contains("<a:alpha val=\"50196\"/>"));
        assert!(
            xml.contains("<a:custDash><a:ds d=\"200000\" sp=\"100000\"/></a:custDash><a:round/>")
        );
        assert!(xml.contains("<a:path w=\"476250\" h=\"476250\" fill=\"none\">"));
    }

    #[test]
    fn dash_phase_rotates_the_pattern() {
        let mut b = DmlBackend::new(10, 10, 96.0, Rgba::WHITE, 0, 0, false);
        let mut st = pen(1.0);
        st.dash = vec![4.0, 2.0];
        st.phase = 1.0;
        // starts 1 into the 4-dash: 3 on, 2 off, then the 1 left of the dash
        assert_eq!(
            b.dash_xml(&st),
            "<a:custDash><a:ds d=\"300000\" sp=\"200000\"/><a:ds d=\"100000\" sp=\"0\"/></a:custDash>"
        );
        assert!(b.warnings.is_empty());
        st.phase = 5.0; // inside the gap
        st.cap = LineCap::Round;
        let x = b.dash_xml(&st);
        assert!(
            x.starts_with("<a:custDash><a:ds d=\"0\" sp=\"100000\"/>"),
            "{x}"
        );
        assert_eq!(b.warnings.len(), 1);
    }

    #[test]
    fn overlapping_subpaths_are_normalised_disjoint_ones_kept() {
        let mut pb = PathBuilder::new();
        pb.push_rect(tiny_skia::Rect::from_xywh(0.0, 0.0, 10.0, 10.0).unwrap());
        pb.push_rect(tiny_skia::Rect::from_xywh(20.0, 0.0, 10.0, 10.0).unwrap());
        let dp = DevPath::from_path(&pb.finish().unwrap(), Transform::identity());
        let n0 = dp.segs.len();
        assert_eq!(normalize_fill(dp, FillRule::EvenOdd).segs.len(), n0);
        // two overlapping squares under even-odd: the overlap is a hole
        let mut pb = PathBuilder::new();
        pb.push_rect(tiny_skia::Rect::from_xywh(0.0, 0.0, 10.0, 10.0).unwrap());
        pb.push_rect(tiny_skia::Rect::from_xywh(5.0, 0.0, 10.0, 10.0).unwrap());
        let dp = DevPath::from_path(&pb.finish().unwrap(), Transform::identity());
        let out = normalize_fill(dp, FillRule::EvenOdd);
        let rings = out.flatten();
        assert_eq!(rings.len(), 2, "{rings:?}");
    }

    #[test]
    fn circles_become_preset_ellipses() {
        let mut b = DmlBackend::new(
            100,
            100,
            96.0,
            Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            },
            0,
            0,
            false,
        );
        let mut pb = PathBuilder::new();
        pb.push_circle(0.0, 0.0, 1.0);
        let t = Transform::from_row(5.0, 0.0, 0.0, 5.0, 50.0, 50.0);
        b.fill_and_stroke_path(
            &pb.finish().unwrap(),
            t,
            &ResolvedPaint::Solid(RED),
            FillRule::Winding,
            Rgba::BLACK,
            &pen(1.0),
            &clip0(),
        );
        let (xml, _, _) = b.finish();
        assert_eq!(xml.matches("<p:sp>").count(), 1, "{xml}");
        assert!(xml.contains("prst=\"ellipse\""), "{xml}");
        assert!(
            xml.contains("<a:off x=\"428625\" y=\"428625\"/><a:ext cx=\"95250\" cy=\"95250\"/>"),
            "{xml}"
        );
        // the 1 px pen scales with the transform
        assert!(xml.contains("<a:ln w=\"47625\""), "{xml}");
    }

    #[test]
    fn media_tokens_resolve_and_dedupe() {
        let mut b = DmlBackend::new(10, 10, 96.0, Rgba::WHITE, 0, 0, false);
        let px = [255u8, 0, 0, 255];
        for _ in 0..2 {
            b.draw_image(
                &px,
                1,
                1,
                5.0,
                5.0,
                4.0,
                4.0,
                true,
                Transform::identity(),
                &clip0(),
            );
        }
        let (xml, media, _) = b.finish();
        assert_eq!(media.len(), 1);
        let out = resolve_media(&xml, |i| format!("rId{}", i + 7));
        assert_eq!(out.matches("r:embed=\"rId7\"").count(), 2, "{out}");
        assert!(!out.contains(MEDIA_TOKEN));
    }

    #[test]
    fn face_flags_read_bold_italic_and_weights() {
        assert_eq!(face_flags("plain"), (false, false));
        assert_eq!(face_flags("bold.italic"), (true, true));
        assert_eq!(face_flags("italic@300"), (false, true));
        assert_eq!(face_flags("plain@700"), (true, false));
    }

    #[test]
    fn rotated_bounds_grow_with_rotation() {
        assert_eq!(rotated_bounds(0, 0, 10, 2, 0.0), [0, 0, 10, 2]);
        let b = rotated_bounds(0, 0, 10, 2, 90.0);
        assert_eq!(b, [4, -4, 6, 6]);
    }

    #[test]
    fn control_characters_are_dropped_from_xml_text() {
        assert_eq!(
            dml_escape("a\u{1}b\tc\u{B}d & <e>\u{FFFF}"),
            "ab\tcd &amp; &lt;e&gt;"
        );
    }

    #[test]
    fn far_coordinates_stay_in_range_and_off_page_shapes_drop() {
        let mut b = DmlBackend::new(
            100,
            100,
            96.0,
            Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            },
            0,
            0,
            false,
        );
        let paint = ResolvedPaint::Solid(RED);
        // wholly off the page: dropped
        let far = rect_path(1e9, 0.0, 1e9, 10.0).unwrap();
        b.fill_path(
            &far,
            Transform::identity(),
            &paint,
            FillRule::Winding,
            &clip0(),
        );
        // from the page to 1e12, with a pen 1e9 px wide: kept, cut to the
        // page (VR-44); a pen that wide is drawn as its filled outline
        let mut pb = PathBuilder::new();
        pb.move_to(10.0, 10.0);
        pb.line_to(1e12, 50.0);
        b.stroke_path(
            &pb.finish().unwrap(),
            Transform::identity(),
            RED,
            &pen(1e9),
            &clip0(),
        );
        let (xml, _, _) = b.finish();
        assert_eq!(xml.matches("<p:sp>").count(), 1, "{xml}");
        let nums: Vec<i64> = xml
            .split('"')
            .filter_map(|t| t.parse::<i64>().ok())
            .collect();
        assert!(nums.iter().all(|v| v.abs() <= 10_000_000), "{xml}");
        assert!(
            xml.contains("<a:solidFill><a:srgbClr val=\"FF0000\"/>"),
            "{xml}"
        );
    }

    #[test]
    fn a_phase_rounding_to_a_whole_cycle_does_not_panic() {
        let mut b = DmlBackend::new(10, 10, 96.0, Rgba::WHITE, 0, 0, false);
        let mut st = pen(1.0);
        st.dash = vec![1.0, 3.0];
        st.phase = -1e-17;
        assert_eq!(
            b.dash_xml(&st),
            "<a:custDash><a:ds d=\"100000\" sp=\"300000\"/></a:custDash>"
        );
    }

    fn panel() -> [ClipShape; 1] {
        [ClipShape::Rect {
            w: 50.0,
            h: 50.0,
            transform: Transform::from_translate(10.0, 10.0),
        }]
    }

    #[test]
    fn fills_are_cut_to_a_rect_clip_and_dropped_outside_it() {
        let shapes = panel();
        let clip = Clip {
            id: 1,
            shapes: &shapes,
        };
        let mut b = DmlBackend::new(
            100,
            100,
            96.0,
            Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            },
            0,
            0,
            false,
        );
        let paint = ResolvedPaint::Solid(RED);
        // straddles the right edge (x = 60): cut to 40..60
        let p = rect_path(40.0, 20.0, 40.0, 10.0).unwrap();
        b.fill_path(&p, Transform::identity(), &paint, FillRule::Winding, &clip);
        // wholly outside: dropped
        let q = rect_path(70.0, 70.0, 5.0, 5.0).unwrap();
        b.fill_path(&q, Transform::identity(), &paint, FillRule::Winding, &clip);
        let (xml, _, warns) = b.finish();
        assert!(warns.is_empty(), "{warns:?}");
        assert_eq!(xml.matches("<p:sp>").count(), 1, "{xml}");
        // 40 px wide in, 20 px left: x 40..60 = 381000..571500 EMU
        assert!(
            xml.contains("<a:off x=\"381000\" y=\"190500\"/><a:ext cx=\"190500\" cy=\"95250\"/>"),
            "{xml}"
        );
        assert!(
            xml.contains("prst=\"rect\""),
            "a cut rectangle stays a rectangle: {xml}"
        );
    }

    #[test]
    fn strokes_are_cut_at_the_clip_edge() {
        let shapes = panel();
        let clip = Clip {
            id: 1,
            shapes: &shapes,
        };
        let mut b = DmlBackend::new(
            100,
            100,
            96.0,
            Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            },
            0,
            0,
            false,
        );
        let mut pb = PathBuilder::new();
        pb.move_to(0.0, 30.0);
        pb.line_to(100.0, 30.0);
        b.stroke_path(
            &pb.finish().unwrap(),
            Transform::identity(),
            RED,
            &pen(1.0),
            &clip,
        );
        let (xml, _, _) = b.finish();
        assert!(
            xml.contains("<a:off x=\"95250\" y=\"285750\"/><a:ext cx=\"476250\""),
            "{xml}"
        );
    }

    #[test]
    fn a_path_clip_cuts_fills_to_its_shape() {
        let mut pb = PathBuilder::new();
        pb.push_circle(50.0, 50.0, 20.0);
        let shapes = [ClipShape::Path {
            path: pb.finish().unwrap(),
            evenodd: false,
            transform: Transform::identity(),
        }];
        let clip = Clip {
            id: 2,
            shapes: &shapes,
        };
        let mut b = DmlBackend::new(
            100,
            100,
            96.0,
            Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            },
            0,
            0,
            false,
        );
        let p = rect_path(0.0, 0.0, 100.0, 50.0).unwrap();
        b.fill_path(
            &p,
            Transform::identity(),
            &ResolvedPaint::Solid(RED),
            FillRule::Winding,
            &clip,
        );
        let (xml, _, _) = b.finish();
        // the top half disc: 40 px wide, 20 px tall
        assert!(xml.contains("<a:custGeom>"), "{xml}");
        assert!(
            xml.contains("<a:ext cx=\"381000\" cy=\"190500\"/>"),
            "{xml}"
        );
    }

    #[test]
    fn an_upright_raster_is_cropped_to_a_rect_clip() {
        let shapes = panel();
        let clip = Clip {
            id: 1,
            shapes: &shapes,
        };
        let mut b = DmlBackend::new(
            100,
            100,
            96.0,
            Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            },
            0,
            0,
            false,
        );
        let px = [255u8; 16];
        // a 40 x 40 cell centred at (60, 60): its top-left quarter is visible
        b.draw_image(
            &px,
            2,
            2,
            60.0,
            60.0,
            40.0,
            40.0,
            true,
            Transform::identity(),
            &clip,
        );
        let (xml, media, warns) = b.finish();
        assert_eq!(media.len(), 1);
        assert!(warns.is_empty());
        assert!(
            xml.contains("<a:srcRect l=\"0\" t=\"0\" r=\"50000\" b=\"50000\"/>"),
            "{xml}"
        );
        assert!(
            xml.contains("<a:off x=\"381000\" y=\"381000\"/><a:ext cx=\"190500\" cy=\"190500\"/>"),
            "{xml}"
        );
    }

    #[test]
    fn a_linear_gradient_maps_onto_the_shape_box() {
        let mut b = DmlBackend::new(
            100,
            100,
            96.0,
            Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            },
            0,
            0,
            false,
        );
        let stops = vec![
            Stop {
                offset: 0.0,
                color: RED,
            },
            Stop {
                offset: 1.0,
                color: Rgba::BLACK,
            },
        ];
        // the gradient line spans the middle half of a 0..100 box
        let paint = ResolvedPaint::Linear {
            x1: 25.0,
            y1: 0.0,
            x2: 75.0,
            y2: 0.0,
            stops,
            extend: Extend::Pad,
        };
        let x = b.fill_xml(&paint, Transform::identity(), Some([0.0, 0.0, 100.0, 50.0]));
        assert!(x.contains("<a:lin ang=\"0\" scaled=\"0\"/>"), "{x}");
        // padded ends, the stops at 25% and 75%
        assert!(x.contains("<a:gs pos=\"0\"><a:srgbClr val=\"FF0000\"/></a:gs><a:gs pos=\"25000\"><a:srgbClr val=\"FF0000\"/></a:gs>"), "{x}");
        assert!(x.contains("<a:gs pos=\"75000\"><a:srgbClr val=\"000000\"/></a:gs><a:gs pos=\"100000\"><a:srgbClr val=\"000000\"/></a:gs>"), "{x}");
        // a vertical gradient points down: 90 degrees clockwise
        let down = ResolvedPaint::Linear {
            x1: 0.0,
            y1: 0.0,
            x2: 0.0,
            y2: 50.0,
            stops: vec![
                Stop {
                    offset: 0.0,
                    color: RED,
                },
                Stop {
                    offset: 1.0,
                    color: Rgba::BLACK,
                },
            ],
            extend: Extend::Pad,
        };
        let y = b.fill_xml(&down, Transform::identity(), Some([0.0, 0.0, 100.0, 50.0]));
        assert!(y.contains("ang=\"5400000\""), "{y}");
        assert_eq!(y.matches("<a:gs ").count(), 2, "{y}");
    }

    #[test]
    fn fold_alpha_scales_every_colour_and_picture() {
        let xml = "<a:srgbClr val=\"FF0000\"/><a:srgbClr val=\"00FF00\"><a:alpha val=\"50000\"/></a:srgbClr><a:blip r:embed=\"x\"/>";
        let out = fold_alpha(xml, 0.5);
        assert_eq!(
            out,
            "<a:srgbClr val=\"FF0000\"><a:alpha val=\"50000\"/></a:srgbClr><a:srgbClr val=\"00FF00\"><a:alpha val=\"25000\"/></a:srgbClr><a:blip r:embed=\"x\"><a:alphaModFix amt=\"50000\"/></a:blip>"
        );
    }

    #[test]
    fn group_opacity_folds_over_disjoint_shapes_and_rasterises_overlaps() {
        let run = |second_x: f64| {
            let mut b = DmlBackend::new(
                100,
                100,
                96.0,
                Rgba {
                    r: 0,
                    g: 0,
                    b: 0,
                    a: 0,
                },
                0,
                0,
                false,
            );
            b.begin_group(None, 0.5, BlendKind::Normal, GroupEffect::default());
            for x in [10.0, second_x] {
                let p = rect_path(x, 10.0, 20.0, 20.0).unwrap();
                b.fill_path(
                    &p,
                    Transform::identity(),
                    &ResolvedPaint::Solid(RED),
                    FillRule::Winding,
                    &clip0(),
                );
            }
            b.end_group();
            b.finish()
        };
        let (xml, media, warns) = run(50.0);
        assert!(media.is_empty() && warns.is_empty(), "{warns:?}");
        assert_eq!(xml.matches("<a:alpha val=\"50000\"/>").count(), 2, "{xml}");
        let (xml, media, warns) = run(20.0);
        assert_eq!(media.len(), 1);
        assert_eq!(warns.len(), 1);
        assert!(xml.contains("<p:pic>") && !xml.contains("<p:sp>"), "{xml}");
    }

    fn blank(w: u32, h: u32) -> DmlBackend {
        DmlBackend::new(
            w,
            h,
            96.0,
            Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            },
            0,
            0,
            false,
        )
    }

    #[test]
    fn point_levels_keep_overlapping_marks_in_order() {
        // Disjoint boxes (touching edges included) share level 0.
        let disjoint = [
            [0.0, 0.0, 1.0, 1.0],
            [1.0, 0.0, 2.0, 1.0],
            [5.0, 5.0, 6.0, 6.0],
        ];
        assert_eq!(point_levels(&disjoint), vec![0, 0, 0]);
        // A chain of overlaps climbs a level per step; a box overlapping
        // only the first goes just above it.
        let chain = [
            [0.0, 0.0, 2.0, 2.0],
            [1.0, 1.0, 3.0, 3.0],
            [2.5, 2.5, 4.0, 4.0],
            [-1.0, -1.0, 0.5, 0.5],
        ];
        assert_eq!(point_levels(&chain), vec![0, 1, 2, 1]);
        // A wide box (many grid cells) still sees every box it covers.
        let mut wide = vec![[0.0, 0.0, 1.0, 1.0]; 1];
        wide.push([3.0, 0.0, 4.0, 1.0]);
        wide.push([-100.0, -100.0, 100.0, 100.0]);
        wide.push([50.0, 50.0, 51.0, 51.0]);
        assert_eq!(point_levels(&wide), vec![0, 0, 1, 2]);
    }

    #[test]
    fn point_levels_match_the_pairwise_definition() {
        // A deterministic scatter, dense in the middle, of mixed sizes.
        let mut seed = 12345u64;
        let mut rnd = || {
            seed = seed
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (seed >> 11) as f64 / (1u64 << 53) as f64
        };
        let boxes: Vec<[f64; 4]> = (0..3000)
            .map(|_| {
                let (x, y) = (rnd() * rnd() * 300.0, rnd() * rnd() * 200.0);
                let r = if rnd() < 0.05 {
                    30.0
                } else {
                    1.0 + rnd() * 4.0
                };
                [x - r, y - r, x + r, y + r]
            })
            .collect();
        let got = point_levels(&boxes);
        let ov =
            |a: &[f64; 4], b: &[f64; 4]| a[0] < b[2] && b[0] < a[2] && a[1] < b[3] && b[1] < a[3];
        let mut want = vec![0usize; boxes.len()];
        for i in 0..boxes.len() {
            for j in 0..i {
                if ov(&boxes[i], &boxes[j]) {
                    want[i] = want[i].max(want[j] + 1);
                }
            }
        }
        assert_eq!(got, want);
    }

    #[test]
    fn touching_merged_marks_still_fold_a_group_opacity() {
        // Two squares sharing an edge merge into one shape; a group opacity
        // over them folds into the shape instead of becoming a picture.
        let mut b = blank(200, 100);
        let red = ResolvedPaint::Solid(RED);
        b.begin_group(None, 0.5, BlendKind::Normal, GroupEffect::default());
        for x in [10.0, 20.0] {
            b.set_element_key(None);
            b.begin_marker(1, x + 5.0, 45.0, 5.0, Transform::identity(), &clip0());
            let sq = rect_path(x, 40.0, 10.0, 10.0).unwrap();
            b.fill_path(
                &sq,
                Transform::identity(),
                &red,
                FillRule::Winding,
                &clip0(),
            );
        }
        b.end_group();
        let (xml, media, warns) = b.finish();
        assert!(media.is_empty() && warns.is_empty(), "{warns:?}");
        assert_eq!(xml.matches("<p:sp>").count(), 1, "{xml}");
        assert!(xml.contains("<a:alpha val=\"50000\"/>"), "{xml}");
    }

    #[test]
    fn a_square_cap_reaches_a_half_width_diagonal() {
        let mut st = pen(10.0);
        st.join = LineJoin::Round;
        assert!((stroke_reach(&st, 1.0) - 5.0).abs() < 1e-9);
        st.cap = LineCap::Square;
        assert!((stroke_reach(&st, 1.0) - 5.0 * std::f64::consts::SQRT_2).abs() < 1e-9);
        st.join = LineJoin::Mitre;
        assert!((stroke_reach(&st, 1.0) - 50.0).abs() < 1e-9);
    }

    #[test]
    fn a_circle_batch_merges_disjoint_points_into_one_shape() {
        let mut b = blank(200, 100);
        let red = ResolvedPaint::Solid(RED);
        // Three disjoint discs, then one overlapping the first.
        b.draw_circles(
            &[20.0, 60.0, 100.0, 25.0],
            &[50.0, 50.0, 50.0, 50.0],
            &[5.0, 5.0, 5.0, 5.0],
            Some(&red),
            None,
            Transform::identity(),
            &clip0(),
            &[],
        );
        let (xml, _, _) = b.finish();
        assert_eq!(xml.matches("<p:sp>").count(), 2, "{xml}");
        // The merged shape comes first: three paths, each two half arcs.
        let merged = xml.find("name=\"Points").expect("merged shape");
        let single = xml.find("prst=\"ellipse\"").expect("single disc");
        assert!(merged < single, "{xml}");
        assert_eq!(xml.matches("<a:path ").count(), 3);
        assert_eq!(xml.matches("<a:arcTo ").count(), 6);
        // The shape is the three discs' box: 15..105 px by 45..55 px.
        assert!(
            xml.contains("<a:off x=\"142875\" y=\"428625\"/><a:ext cx=\"857250\" cy=\"95250\"/>"),
            "{xml}"
        );
    }

    #[test]
    fn outlines_keep_marks_apart_by_their_reach() {
        // Discs 12 px apart edge to edge: disjoint as geometry, but a 30 px
        // outline makes them overlap, so they are not merged.
        let mut b = blank(200, 100);
        let red = ResolvedPaint::Solid(RED);
        b.draw_circles(
            &[20.0, 42.0],
            &[50.0, 50.0],
            &[5.0, 5.0],
            Some(&red),
            Some((RED, pen(30.0))),
            Transform::identity(),
            &clip0(),
            &[],
        );
        let (xml, _, _) = b.finish();
        assert_eq!(xml.matches("<p:sp>").count(), 2, "{xml}");
        assert!(!xml.contains("Points"), "{xml}");
        let mut b = blank(200, 100);
        b.draw_circles(
            &[20.0, 60.0],
            &[50.0, 50.0],
            &[5.0, 5.0],
            Some(&red),
            Some((RED, pen(2.0))),
            Transform::identity(),
            &clip0(),
            &[],
        );
        let (xml, _, _) = b.finish();
        assert_eq!(xml.matches("<p:sp>").count(), 1, "{xml}");
        assert!(xml.contains("Points") && xml.contains("<a:ln w="), "{xml}");
    }

    #[test]
    fn only_marker_shapes_are_merged() {
        let mut b = blank(200, 100);
        let red = ResolvedPaint::Solid(RED);
        let sq = |x: f64| rect_path(x, 40.0, 10.0, 10.0).unwrap();
        // Two markers merge...
        for x in [10.0, 40.0] {
            b.set_element_key(None);
            b.begin_marker(
                1,
                x as f64 + 5.0,
                45.0,
                5.0,
                Transform::identity(),
                &clip0(),
            );
            b.fill_path(
                &sq(x),
                Transform::identity(),
                &red,
                FillRule::Winding,
                &clip0(),
            );
        }
        // ...but the next node's rects (no `begin_marker`) stay apart.
        for x in [100.0, 130.0] {
            b.set_element_key(None);
            b.fill_path(
                &sq(x),
                Transform::identity(),
                &red,
                FillRule::Winding,
                &clip0(),
            );
        }
        let (xml, _, _) = b.finish();
        assert_eq!(xml.matches("<p:sp>").count(), 3, "{xml}");
        assert_eq!(xml.matches("name=\"Points").count(), 1, "{xml}");
        assert_eq!(xml.matches("prst=\"rect\"").count(), 2, "{xml}");
    }

    #[test]
    fn gradient_marks_are_not_merged() {
        let mut b = blank(200, 100);
        let grad = ResolvedPaint::Linear {
            x1: 0.0,
            y1: 0.0,
            x2: 100.0,
            y2: 0.0,
            stops: vec![
                Stop {
                    offset: 0.0,
                    color: RED,
                },
                Stop {
                    offset: 1.0,
                    color: Rgba {
                        r: 0,
                        g: 0,
                        b: 255,
                        a: 255,
                    },
                },
            ],
            extend: Extend::Pad,
        };
        b.draw_circles(
            &[20.0, 60.0],
            &[50.0, 50.0],
            &[5.0, 5.0],
            Some(&grad),
            None,
            Transform::identity(),
            &clip0(),
            &[],
        );
        let (xml, _, _) = b.finish();
        assert_eq!(xml.matches("<p:sp>").count(), 2, "{xml}");
        assert!(!xml.contains("Points"), "{xml}");
    }

    fn span(text: &str, face: &str, size: f64, dy: f64, glyphs: usize) -> TextSpan {
        TextSpan {
            text: text.to_string(),
            face: face.to_string(),
            size,
            dy,
            glyphs,
            brk: false,
        }
    }

    #[test]
    fn rich_runs_need_spans_covering_every_glyph() {
        let spans = vec![
            span("R", "plain", 10.0, 0.0, 1),
            span("2", "plain", 7.0, 3.5, 1),
            TextSpan {
                brk: true,
                ..TextSpan::default()
            },
            span("ab", "bold", 10.0, 0.0, 2),
        ];
        let gid = [1, 2, 3, 4];
        let g = [0.0; 4];
        let names: Vec<String> = vec![String::new(); 4];
        let cols = [RED; 4];
        let mut run = TextRun {
            ax: 0.0,
            ay: 0.0,
            w: 10.0,
            h: 10.0,
            hjust: 0.5,
            vjust: 0.5,
            rot: 0.0,
            color: RED,
            gid: &gid,
            gx: &g,
            gy: &g,
            gsize: &g,
            gpath: &names,
            gface: &[0, 0, 0, 0],
            gcolor: &cols,
            rules: &[],
            gtext: "",
            spans: &spans,
            halo: None,
            label: "R2\nab",
            family: "sans",
            face: "plain",
            size: 10.0,
            dpi: 96.0,
        };
        let paras = rich_paras(&run).expect("native runs");
        assert_eq!(paras.len(), 2);
        assert_eq!(paras[0].len(), 2);
        assert_eq!(paras[1][0].text, "ab");
        // A superscript: the size around it, its baseline raised 35%.
        let rpr = span_rpr(&run, paras[0][1], 1, 1.0, RED);
        assert!(
            rpr.starts_with("<a:rPr sz=\"1000\" baseline=\"35000\""),
            "{rpr}"
        );
        let rpr = span_rpr(&run, paras[1][0], 2, 1.0, RED);
        assert!(rpr.starts_with("<a:rPr sz=\"1000\" b=\"1\" dirty"), "{rpr}");
        // Spans that miss a glyph, or a label with math, stay outlines.
        let short = &spans[..3];
        run.spans = short;
        assert!(rich_paras(&run).is_none());
        run.spans = &spans;
        run.gtext = "R2ab";
        assert!(rich_paras(&run).is_none());
    }
}
