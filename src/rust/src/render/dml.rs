//! The DrawingML backend: a scene as editable PowerPoint shapes.
//!
//! The output is one `<p:grpSp>` holding a `p:sp` per path (`a:custGeom`), a
//! text box per label, a `p:pic` per raster and a nested `p:grpSp` per panel,
//! which officer's `ph_with()` or the standalone `.pptx` writer places on a
//! slide.
//!
//! DrawingML's `a:xfrm` carries only an offset, an extent, a rotation and flips:
//! there is no general affine transform. So, as the SVG backend does for solid
//! fills, every path is baked into slide coordinates (EMU, 914400 per inch) and
//! written relative to its own bounding box: `a:off`/`a:ext` are the box, and the
//! `a:path` coordinate space is the box size, so one path unit is one EMU.
//!
//! Text is native (an editable `a:t` run in a box sized to vellum's measured
//! extents, aligned from `hjust`/`vjust` so a substituted font grows away from
//! the anchor). Labels a text run cannot express -- rich `md()` labels, `tex()`
//! labels, halos, text set on a path -- become glyph outlines, as in SVG.

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
    if let (Some(p), Some(f)) = (run.gpath.first(), run.gface.first()) {
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
}

/// What a `begin_group` turned into, so `end_group` can close it.
enum GroupKind {
    /// A plain compositing group means nothing in DrawingML: its children are
    /// written straight into the enclosing frame.
    Plain,
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
            frames: vec![Frame {
                body: String::new(),
                bbox: None,
                name: "vellum".to_string(),
            }],
            groups: Vec::new(),
            next_id: 2,
            media: Vec::new(),
            media_index: HashMap::new(),
            warnings: Vec::new(),
        };
        if bg.a > 0 {
            if let Some(p) = rect_path(0.0, 0.0, w as f64, h as f64) {
                let dp = DevPath::from_path(&p, Transform::identity());
                let fill = solid_fill(bg, 1.0);
                b.emit_geom("Background", &[dp], &fill, "", true);
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

    /// Device px to slide EMU.
    fn ex(&self, x: f64) -> i64 {
        self.left + (x * self.k).round() as i64
    }
    fn ey(&self, y: f64) -> i64 {
        self.top + (y * self.k).round() as i64
    }
    /// A device-px length in EMU.
    fn len(&self, v: f64) -> i64 {
        (v * self.k).round() as i64
    }

    fn out(&mut self) -> &mut Frame {
        self.frames.last_mut().expect("root frame")
    }

    /// Append a finished element covering `b` to the current frame.
    fn push(&mut self, xml: &str, b: Bounds) {
        let f = self.out();
        f.body.push_str(xml);
        f.bbox = Some(union(f.bbox, b));
    }

    /// The `a:custGeom` for `paths` (one `a:path` each) in the box at
    /// `(x0, y0)` of size `w` x `h` (EMU). `open` marks a stroke-only shape whose
    /// paths must not be filled.
    fn cust_geom(&self, paths: &[DevPath], x0: i64, y0: i64, w: i64, h: i64, open: bool) -> String {
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
    /// `filled` false marks open, stroke-only geometry. Returns false when there
    /// was nothing to draw.
    pub(super) fn emit_geom(
        &mut self,
        name: &str,
        paths: &[DevPath],
        fill: &str,
        ln: &str,
        filled: bool,
    ) -> bool {
        let mut bb: Option<[f64; 4]> = None;
        for p in paths {
            if let Some(b) = p.bounds() {
                bb = Some(match bb {
                    None => b,
                    Some(a) => [
                        a[0].min(b[0]),
                        a[1].min(b[1]),
                        a[2].max(b[2]),
                        a[3].max(b[3]),
                    ],
                });
            }
        }
        let Some(bb) = bb else { return false };
        let (x0, y0, w, h) = self.emu_box(bb);
        let geom = match (paths, rect_of(paths)) {
            // An axis-aligned rectangle stays a real rectangle when edited.
            ([_], Some(_)) if filled => prst("rect"),
            ([p], _) if filled && is_ellipse(p) => prst("ellipse"),
            _ => self.cust_geom(paths, x0, y0, w, h, !filled),
        };
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
        self.push(&xml, [x0, y0, x0 + w, y0 + h]);
        true
    }

    /// The fill XML for a paint (empty for no fill).
    fn fill_xml(&mut self, paint: &ResolvedPaint) -> String {
        match paint {
            ResolvedPaint::Solid(c) => solid_fill(*c, 1.0),
            ResolvedPaint::Hatch { .. } => String::new(),
            ResolvedPaint::Linear { stops, .. } | ResolvedPaint::Radial { stops, .. } => {
                self.warn("gradient fills are drawn in their middle colour");
                match stops.get(stops.len() / 2) {
                    Some(s) => solid_fill(s.color, 1.0),
                    None => String::new(),
                }
            }
            ResolvedPaint::Pattern { .. } => {
                self.warn("pattern fills are not drawn");
                String::new()
            }
        }
    }

    /// The `a:ln` for a stroke whose lengths scale by `scale` into device px.
    fn ln_xml(&mut self, color: Rgba, st: &StrokeStyle, scale: f64) -> String {
        let w = self.len(st.width as f64 * scale).max(1);
        let cap = match st.cap {
            LineCap::Butt => "flat",
            LineCap::Round => "rnd",
            LineCap::Square => "sq",
        };
        let fill = match &st.paint {
            None => solid_fill(color, 1.0),
            Some(p) => {
                let f = self.fill_xml(p);
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
        if phase > 0.0 && phase.is_finite() {
            // Rotate the cycle so it starts `phase` in: entries alternate
            // dash/gap, so keep the parity by padding with zero-length entries.
            let mut rot: Vec<f64> = Vec::with_capacity(cyc.len() + 2);
            let mut i = 0;
            while phase >= cyc[i] {
                phase -= cyc[i];
                i += 1;
            }
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

    /// Warn when a clip region would cut this geometry (clipping is not applied).
    fn note_clip(&mut self, bounds: Option<[f64; 4]>, clip: &Clip) {
        if clip.shapes.is_empty() {
            return;
        }
        let Some(b) = bounds else { return };
        if let Some(c) = clip_bounds(clip) {
            let eps = 0.5;
            if b[0] < c[0] - eps || b[1] < c[1] - eps || b[2] > c[2] + eps || b[3] > c[3] + eps {
                self.warn("clip regions are not applied");
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
        self.fill_path(&outline, t, &paint, FillRule::Winding, clip);
    }

    /// Text that has to be drawn as glyph outlines: one shape per colour (each
    /// glyph its own `a:path`, so overlapping glyphs never punch holes), the
    /// halo as an outlined shape underneath, `tex()` rules as rectangles.
    fn text_outlines(&mut self, run: &TextRun, transform: Transform) {
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
        if all.is_empty() {
            return;
        }
        self.frames.push(Frame {
            body: String::new(),
            bbox: None,
            name: format!("Text: {}", run.label),
        });
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
                let ln = self.ln_xml(hcol, &st, scale);
                self.emit_geom("Halo", &all, "", &ln, true);
            }
        }
        for (c, paths) in by_col {
            if c.a == 0 {
                continue;
            }
            let fill = solid_fill(c, 1.0);
            self.emit_geom("Glyphs", &paths, &fill, "", true);
        }
        self.close_frame(true);
    }

    /// Pop the innermost frame into its parent: a named `p:grpSp`, or, when it
    /// holds a single element and `unwrap` is set, that element itself.
    fn close_frame(&mut self, unwrap: bool) {
        let f = self.frames.pop().expect("frame");
        let Some(b) = f.bbox else { return };
        let single = f.body.matches("<p:cNvPr ").count() == 1;
        if unwrap && single {
            self.push(&f.body, b);
            return;
        }
        let id = self.id();
        let xml = format!(
            "<p:grpSp><p:nvGrpSpPr><p:cNvPr id=\"{id}\" name=\"{name}\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
             <p:grpSpPr><a:xfrm><a:off x=\"{x}\" y=\"{y}\"/><a:ext cx=\"{w}\" cy=\"{h}\"/>\
             <a:chOff x=\"{x}\" y=\"{y}\"/><a:chExt cx=\"{w}\" cy=\"{h}\"/></a:xfrm></p:grpSpPr>{body}</p:grpSp>",
            name = xml_escape(&truncate(&f.name, 200)),
            x = b[0],
            y = b[1],
            w = (b[2] - b[0]).max(1),
            h = (b[3] - b[1]).max(1),
            body = f.body,
        );
        self.push(&xml, b);
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
            "<p:grpSp {DML_NS}><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"{name}\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
             <p:grpSpPr><a:xfrm><a:off x=\"{x}\" y=\"{y}\"/><a:ext cx=\"{w}\" cy=\"{h}\"/>\
             <a:chOff x=\"{x}\" y=\"{y}\"/><a:chExt cx=\"{w}\" cy=\"{h}\"/></a:xfrm></p:grpSpPr>{body}</p:grpSp>",
            name = xml_escape(&root.name),
            body = root.body,
        );
        (xml, self.media, self.warnings)
    }

    /// Name the root group (the scene title, when it has one).
    pub fn set_name(&mut self, name: &str) {
        if !name.is_empty() {
            self.frames[0].name = name.to_string();
        }
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

impl RenderBackend for DmlBackend {
    fn fill_path(
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
        let dp = DevPath::from_path(path, transform);
        self.note_clip(dp.bounds(), clip);
        let dp = normalize_fill(dp, rule);
        if dp.is_empty() {
            return;
        }
        let fill = self.fill_xml(paint);
        if fill.is_empty() {
            return;
        }
        self.emit_geom("Freeform", &[dp], &fill, "", true);
    }

    fn stroke_path(
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
        let Some(scale) = uniform_scale(transform) else {
            self.stroke_outline(path, transform, color, stroke, clip);
            return;
        };
        let dp = DevPath::from_path(path, transform);
        self.note_clip(dp.bounds(), clip);
        if dp.is_empty() {
            return;
        }
        let ln = self.ln_xml(color, stroke, scale);
        let closed = dp_all_closed(&dp);
        self.emit_geom("Line", &[dp], "", &ln, closed);
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
        // One shape with both a fill and an outline, as a user would draw it,
        // when the outline can be a DrawingML line: the geometry must not need
        // rewriting for the fill rule (that would change where the outline runs)
        // and the pen must scale uniformly.
        let scale = uniform_scale(transform);
        let dp = DevPath::from_path(path, transform);
        let boxes = dp.subpath_bounds();
        let plain = boxes.len() <= 1 || !any_overlap(&boxes);
        if scale.is_none()
            || !plain
            || matches!(paint, ResolvedPaint::Hatch { .. })
            || stroke.width <= 0.0
        {
            self.fill_path(path, transform, paint, rule, clip);
            self.stroke_path(path, transform, color, stroke, clip);
            return;
        }
        self.note_clip(dp.bounds(), clip);
        if dp.is_empty() {
            return;
        }
        let fill = self.fill_xml(paint);
        let ln = self.ln_xml(color, stroke, scale.unwrap_or(1.0));
        self.emit_geom("Freeform", &[dp], &fill, &ln, true);
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        if run.label.is_empty() && run.rules.is_empty() {
            return;
        }
        let lines = line_runs(run);
        let label_lines: Vec<&str> = run.label.split('\n').collect();
        let scale = uniform_scale(transform);
        let reflected = (transform.sx as f64 * transform.sy as f64
            - transform.kx as f64 * transform.ky as f64)
            < 0.0;
        let outline = self.outline_text
            || !run.gcolor.is_empty()
            || !run.rules.is_empty()
            || run.halo.is_some()
            || run.w <= 0.0
            || run.color.a == 0
            || scale.is_none()
            || reflected
            || (lines.len() > 1 && lines.len() != label_lines.len());
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
            self.note_clip(Some(b), clip);
        }
        if outline {
            self.text_outlines(run, transform);
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
        let face = xml_escape(&typeface(run)).into_owned();
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
            let pitch_px = (run.gy[a] - run.gy[b]).abs() * s;
            let pitch_pt = pitch_px * 72.0 / (EMU_PER_INCH / self.k);
            format!(
                "<a:lnSpc><a:spcPts val=\"{}\"/></a:lnSpc>",
                (pitch_pt * 100.0).round() as i64
            )
        } else {
            String::new()
        };
        let paras: Vec<&str> = if lines.len() > 1 {
            label_lines
        } else {
            vec![run.label]
        };
        let mut body = String::new();
        for line in paras {
            body.push_str(&format!("<a:p><a:pPr algn=\"{algn}\">{ln_spc}</a:pPr>"));
            if line.is_empty() {
                body.push_str(&format!("<a:endParaRPr sz=\"{sz}\" dirty=\"0\"/>"));
            } else {
                body.push_str(&format!("<a:r>{rpr}<a:t>{}</a:t></a:r>", xml_escape(line)));
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

    fn begin_group(
        &mut self,
        mask: Option<MaskLayer>,
        alpha: f32,
        blend: BlendKind,
        effect: GroupEffect,
    ) {
        if mask.is_some() {
            self.warn("masks are not applied");
        }
        if alpha < 1.0 {
            self.warn("group opacity is not applied");
        }
        if blend != BlendKind::Normal {
            self.warn("blend modes are not applied");
        }
        if !effect.is_none() {
            self.warn("blur and shadow effects are not applied");
        }
        self.groups.push(GroupKind::Plain);
    }

    fn end_group(&mut self) {
        match self.groups.pop() {
            Some(GroupKind::Plain) | None => {}
        }
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
        if iw == 0 || ih == 0 {
            return;
        }
        let t = transform;
        let (sx, ky, kx, sy) = (t.sx as f64, t.ky as f64, t.kx as f64, t.sy as f64);
        let (ax, ay) = (sx.hypot(ky), kx.hypot(sy));
        if (sx * kx + ky * sy).abs() > 1e-6 * ax.max(ay) * ax.max(ay) {
            self.warn("a skewed raster is drawn unskewed");
        }
        let (cx, cy) = map_pt(t, tiny_skia::Point::from_xy(x as f32, y as f32));
        let (dw, dh) = ((w * ax).abs(), (h * ay).abs());
        {
            let hw = dw.max(dh);
            self.note_clip(Some([cx - hw, cy - hw, cx + hw, cy + hw]), clip);
        }
        let rot = ky.atan2(sx).to_degrees().rem_euclid(360.0);
        let flip = sx * sy - kx * ky < 0.0;
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
        self.emit_picture(png, cx, cy, dw, dh, rot, flip, None);
    }

    fn begin_panel(&mut self, name: &str, _pannable: bool) {
        self.frames.push(Frame {
            body: String::new(),
            bbox: None,
            name: name.to_string(),
        });
    }

    fn end_panel(&mut self) {
        if self.frames.len() > 1 {
            self.close_frame(false);
        }
    }

    fn take_warnings(&mut self) -> Vec<String> {
        self.warnings.clone()
    }
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
}
