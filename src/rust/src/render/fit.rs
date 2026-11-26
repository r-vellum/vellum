//! Keep geometry inside the range tiny-skia rasterises safely (VR-43).
//!
//! tiny-skia clips a path to the pixmap in `f32`, then rasterises it in fixed
//! point. A shape that straddles the page with coordinates far beyond it (a
//! circle of radius 2e9 px, a rect 1e10 px wide) loses enough precision in that
//! clip for the anti-aliasing blitter to index past its run buffer, and it
//! panics (`alpha_runs.rs`: an `unwrap` on `None`). A shape wholly off the page,
//! or one drawn without anti-aliasing, is fine.
//!
//! So before a path reaches tiny-skia, its device bounds are checked. Anything
//! within [`SAFE`] px of the origin passes through untouched, which keeps every
//! ordinary render byte-identical. Anything further is clipped here, in `f64`,
//! to a box a margin wider than the page, and the clipped path is drawn instead.
//! The visible result is the same shape, cut where nobody can see it.
//!
//! Geometry reaching beyond the PDF backend's coordinate cap
//! ([`super::pdf::MAX_COORD`], 1e15 px) is not drawn at all, as PDF does not
//! draw it either ([`beyond_cap`]); clipping alone keeps tiny-skia from
//! panicking, the cap keeps PNG and PDF agreeing on what is drawn.

use std::borrow::Cow;

use tiny_skia::{Path, PathBuilder, PathSegment, Pixmap, Transform};

/// Device coordinates (px) within which a path is handed to tiny-skia as is.
/// tiny-skia's anti-aliased fill first fails near 2e9 px; this leaves three
/// orders of magnitude of headroom, and no real plot comes close to it.
pub(super) const SAFE: f64 = 1e6;

/// Subdivision depth cap for a curve that straddles the clip box. Device
/// coordinates are at most ~1e77 (an `f32` point under an `f32` scale), and each
/// split halves a curve, so this is enough to bring any curve down to pixels.
const MAX_DEPTH: u32 = 300;

/// A curve piece this small (px) that still straddles the clip box is replaced
/// by its chord. The box edge lies a page-width outside the page, so the
/// difference is never visible.
const CHORD_PX: f64 = 16.0;

/// What to draw for a path after fitting it into the safe range.
pub(super) enum Fit<'a> {
    /// Draw the path as given, under the given transform.
    Keep(&'a Path),
    /// Draw this path instead. For a fill it is in device px (draw it under the
    /// identity, with the paint's shader moved to device space); for a stroke it
    /// is in the original local space (draw it under the original transform).
    Clipped(Path),
    /// Stroke the path to its outline and fill that through [`fit_fill`]: the
    /// pen itself reaches past the safe range (a stroke millions of px wide),
    /// so no cut of the centreline would bring its outline into range.
    Outline,
    /// Nothing can be drawn: the geometry is not finite, or not invertible.
    Skip,
}

type Pt = (f64, f64);

fn map(t: &Transform, x: f32, y: f32) -> Pt {
    let (x, y) = (x as f64, y as f64);
    (
        t.sx as f64 * x + t.kx as f64 * y + t.tx as f64,
        t.ky as f64 * x + t.sy as f64 * y + t.ty as f64,
    )
}

/// Device bounds `[x0, y0, x1, y1]` of `path` under `t`, from its local bounds
/// (a superset of the exact bounds, which is all the range check needs).
fn device_bounds(path: &Path, t: &Transform) -> [f64; 4] {
    let b = path.bounds();
    let c = [
        map(t, b.left(), b.top()),
        map(t, b.right(), b.top()),
        map(t, b.right(), b.bottom()),
        map(t, b.left(), b.bottom()),
    ];
    let mut out = [
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    ];
    for (x, y) in c {
        out[0] = out[0].min(x);
        out[1] = out[1].min(y);
        out[2] = out[2].max(x);
        out[3] = out[3].max(y);
    }
    out
}

/// Is every edge of `b`, grown by `reach`, finite and within [`SAFE`]?
fn within(b: [f64; 4], reach: f64) -> bool {
    b.iter().all(|v| v.is_finite()) && b.iter().all(|v| v.abs() + reach <= SAFE)
}

/// Does `path` under `t` reach past the PDF backend's coordinate cap (or is it
/// not finite)? Such a mark is skipped on PDF (`pdf::drawable`), so the raster
/// backend skips it too. As on PDF, the path's own box is checked, not its pen.
/// PDF also checks the box in points under the page scale, so at under 72 dpi
/// it skips a mark up to 72/dpi times nearer the cap than PNG does; both are
/// beyond any page.
pub(super) fn beyond_cap(path: &Path, t: Transform) -> bool {
    let cap = super::pdf::MAX_COORD as f64;
    let b = device_bounds(path, &t);
    !(t.is_finite() && b.iter().all(|v| v.is_finite() && v.abs() <= cap))
}

/// Fit a filled path. [`Fit::Clipped`] holds device-px geometry.
pub(super) fn fit_fill<'a>(path: &'a Path, t: Transform, w: u32, h: u32) -> Fit<'a> {
    if !t.is_finite() {
        return Fit::Skip;
    }
    let b = device_bounds(path, &t);
    if within(b, 0.0) {
        return Fit::Keep(path);
    }
    if !b.iter().all(|v| v.is_finite()) {
        return Fit::Skip;
    }
    let m = w.max(h) as f64 + 4.0;
    match clip_to_box(path, &t, [-m, -m, w as f64 + m, h as f64 + m], true) {
        Some(p) => Fit::Clipped(p),
        None => Fit::Skip,
    }
}

/// Fit a stroked path whose pen reaches `reach` device px from the centreline.
/// The centreline is clipped to a box a margin (page plus pen) outside the page,
/// so the pieces that now run along the box edge are stroked out of sight, then
/// mapped back to local space so the pen keeps its shape under `t`.
/// [`Fit::Clipped`] holds local geometry.
pub(super) fn fit_stroke<'a>(path: &'a Path, t: Transform, reach: f64, w: u32, h: u32) -> Fit<'a> {
    if !t.is_finite() || !reach.is_finite() {
        return Fit::Skip;
    }
    let b = device_bounds(path, &t);
    if within(b, reach) {
        return Fit::Keep(path);
    }
    if !b.iter().all(|v| v.is_finite()) {
        return Fit::Skip;
    }
    // A pen wider than the safe range itself: however the centreline is cut,
    // its outline is not in range, so the outline is cut instead.
    if reach > SAFE / 8.0 {
        return Fit::Outline;
    }
    let m = w.max(h) as f64 + reach + 4.0;
    let Some(dev) = clip_to_box(path, &t, [-m, -m, w as f64 + m, h as f64 + m], false) else {
        return Fit::Skip;
    };
    let Some(local) = invert(&t).and_then(|inv| dev.transform(inv)) else {
        return Fit::Skip;
    };
    // Mapping back can lose what precision the transform has (a huge offset
    // cancelled by huge local coordinates); never hand tiny-skia the result
    // unless it is back in range.
    if within(device_bounds(&local, &t), reach) {
        Fit::Clipped(local)
    } else {
        Fit::Skip
    }
}

/// What to draw for a dashed stroke after fitting it into the safe range.
pub(super) enum DashFit<'a> {
    /// Draw the path as given, dashed as given.
    Keep(&'a Path),
    /// Draw each visible run (local geometry, under the original transform),
    /// dashed from its own offset into the pattern.
    Runs(Vec<(Path, f32)>),
    /// Stroke to an outline and fill it (see [`Fit::Outline`]).
    Outline,
    /// Nothing can be drawn.
    Skip,
}

/// Fit a dashed stroke. Clamping the centreline, as [`fit_stroke`] does, would
/// change its length, and tiny-skia dashes from a contour's start, so the
/// pattern on the page would shift (VR-43 review). Instead the pieces of each
/// contour inside the clip box are kept as separate runs, each starting its
/// dash pattern where the whole contour would be at that point: the dash
/// `phase` plus the arc length cut off before it, measured in local units (in
/// which tiny-skia dashes) and in `f64`, reduced modulo the pattern. A closed
/// contour whose start lies inside the box keeps its first and last runs as
/// one, so the join there is not lost.
pub(super) fn fit_dashed<'a>(
    path: &'a Path,
    t: Transform,
    reach: f64,
    w: u32,
    h: u32,
    intervals: &[f32],
    phase: f32,
) -> DashFit<'a> {
    let period: f64 = intervals.iter().map(|&v| v as f64).sum();
    match fit_stroke(path, t, reach, w, h) {
        Fit::Keep(p) => return DashFit::Keep(p),
        Fit::Outline => return DashFit::Outline,
        Fit::Skip => return DashFit::Skip,
        Fit::Clipped(_) => {}
    }
    if !(period > 0.0 && period.is_finite()) {
        return DashFit::Skip;
    }
    let m = w.max(h) as f64 + reach + 4.0;
    let mut d = Dasher {
        t,
        r: [-m, -m, w as f64 + m, h as f64 + m],
        period,
        phase: phase as f64,
        s: 0.0,
        run: None,
        runs: Vec::new(),
        contour_first: 0,
    };
    let lp = |p: tiny_skia::Point| (p.x as f64, p.y as f64);
    let mut start: Pt = (0.0, 0.0);
    let mut cur: Pt = (0.0, 0.0);
    for seg in path.segments() {
        match seg {
            PathSegment::MoveTo(p) => {
                d.end_contour(false);
                cur = lp(p);
                start = cur;
            }
            PathSegment::LineTo(p) => {
                let q = lp(p);
                d.line(cur, q, None);
                cur = q;
            }
            PathSegment::QuadTo(p1, p) => {
                let q = lp(p);
                d.curve(&[cur, lp(p1), q], 0);
                cur = q;
            }
            PathSegment::CubicTo(p1, p2, p) => {
                let q = lp(p);
                d.curve(&[cur, lp(p1), lp(p2), q], 0);
                cur = q;
            }
            PathSegment::Close => {
                d.line(cur, start, None);
                cur = start;
                d.end_contour(true);
            }
        }
    }
    d.end_contour(false);
    let runs = d
        .runs
        .into_iter()
        .filter_map(|r| {
            let mut pb = PathBuilder::new();
            let f = |p: Pt| (p.0 as f32, p.1 as f32);
            let s0 = f(r.start);
            pb.move_to(s0.0, s0.1);
            for g in &r.segs {
                match g {
                    Seg::Line(p) => {
                        let p = f(*p);
                        pb.line_to(p.0, p.1);
                    }
                    Seg::Quad(c, p) => {
                        let (c, p) = (f(*c), f(*p));
                        pb.quad_to(c.0, c.1, p.0, p.1);
                    }
                    Seg::Cubic(c1, c2, p) => {
                        let (c1, c2, p) = (f(*c1), f(*c2), f(*p));
                        pb.cubic_to(c1.0, c1.1, c2.0, c2.1, p.0, p.1);
                    }
                }
            }
            let p = pb.finish()?;
            // As in `fit_stroke`: never hand tiny-skia a run that the transform's
            // precision put back out of range.
            within(device_bounds(&p, &t), reach).then_some((p, r.offset as f32))
        })
        .collect();
    DashFit::Runs(runs)
}

/// A segment of a dash run, in local coordinates (the start is implicit).
enum Seg {
    Line(Pt),
    Quad(Pt, Pt),
    Cubic(Pt, Pt, Pt),
}

struct Run {
    start: Pt,
    segs: Vec<Seg>,
    /// Offset into the dash pattern at `start`, in `[0, period)`.
    offset: f64,
    /// Starts at its contour's start (arc length 0).
    at_start: bool,
}

struct Dasher {
    t: Transform,
    /// The clip box, in device px.
    r: [f64; 4],
    period: f64,
    phase: f64,
    /// Arc length so far along the current contour (local units).
    s: f64,
    run: Option<Run>,
    runs: Vec<Run>,
    /// Index in `runs` of the current contour's first run.
    contour_first: usize,
}

impl Dasher {
    fn offset(&self, s: f64) -> f64 {
        (self.phase + s).rem_euclid(self.period)
    }

    fn end_run(&mut self) {
        if let Some(r) = self.run.take() {
            self.runs.push(r);
        }
    }

    fn end_contour(&mut self, closed: bool) {
        let open = self.run.take();
        // A closed contour that starts and ends inside the box: its last run
        // continues into its first.
        if let Some(mut last) = open {
            let first = self.contour_first;
            if closed && first < self.runs.len() && self.runs[first].at_start {
                let head = self.runs.remove(first);
                last.segs.extend(head.segs);
            }
            self.runs.push(last);
        }
        self.s = 0.0;
        self.contour_first = self.runs.len();
    }

    fn begin_run(&mut self, p: Pt, s: f64) {
        self.end_run();
        self.run = Some(Run {
            start: p,
            segs: Vec::new(),
            offset: self.offset(s),
            at_start: s == 0.0,
        });
    }

    /// The local line `a`-`b` (`len`: its arc length when it stands in for a
    /// curve).
    fn line(&mut self, a: Pt, b: Pt, len: Option<f64>) {
        let len = len.unwrap_or_else(|| (b.0 - a.0).hypot(b.1 - a.1));
        let (da, db) = (map_f64(&self.t, a), map_f64(&self.t, b));
        // Liang-Barsky: the parameter interval of the device segment inside
        // the (convex) box.
        let (mut t0, mut t1) = (0.0f64, 1.0f64);
        let (dx, dy) = (db.0 - da.0, db.1 - da.1);
        for (p, q) in [
            (-dx, da.0 - self.r[0]),
            (dx, self.r[2] - da.0),
            (-dy, da.1 - self.r[1]),
            (dy, self.r[3] - da.1),
        ] {
            if p == 0.0 {
                if q < 0.0 {
                    t0 = 1.0;
                    t1 = 0.0;
                }
            } else {
                let u = q / p;
                if p < 0.0 {
                    t0 = t0.max(u);
                } else {
                    t1 = t1.min(u);
                }
            }
        }
        let lerp = |u: f64| (a.0 + u * (b.0 - a.0), a.1 + u * (b.1 - a.1));
        if t0 > t1 {
            self.end_run();
        } else {
            if t0 > 0.0 || self.run.is_none() {
                self.begin_run(lerp(t0), self.s + t0 * len);
            }
            let end = if t1 < 1.0 { lerp(t1) } else { b };
            if let Some(r) = self.run.as_mut() {
                r.segs.push(Seg::Line(end));
            }
            if t1 < 1.0 {
                self.end_run();
            }
        }
        self.s += len;
    }

    fn curve(&mut self, pts: &[Pt], depth: u32) {
        let dev: Vec<Pt> = pts.iter().map(|&p| map_f64(&self.t, p)).collect();
        let (mut x0, mut y0, mut x1, mut y1) = (
            f64::INFINITY,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
        );
        for p in &dev {
            x0 = x0.min(p.0);
            y0 = y0.min(p.1);
            x1 = x1.max(p.0);
            y1 = y1.max(p.1);
        }
        let r = self.r;
        let end = pts[pts.len() - 1];
        let len = curve_len(pts, 0);
        if x0 >= r[0] && y0 >= r[1] && x1 <= r[2] && y1 <= r[3] {
            if self.run.is_none() {
                self.begin_run(pts[0], self.s);
            }
            if let Some(run) = self.run.as_mut() {
                run.segs.push(if pts.len() == 3 {
                    Seg::Quad(pts[1], end)
                } else {
                    Seg::Cubic(pts[1], pts[2], end)
                });
            }
            self.s += len;
            return;
        }
        let outside = x1 < r[0] || x0 > r[2] || y1 < r[1] || y0 > r[3];
        if outside {
            self.end_run();
            self.s += len;
            return;
        }
        let small = (x1 - x0).max(y1 - y0) <= CHORD_PX;
        if small || depth >= MAX_DEPTH {
            self.line(pts[0], end, Some(len));
            return;
        }
        let (a, b) = split(pts);
        self.curve(&a, depth + 1);
        self.curve(&b, depth + 1);
    }
}

fn map_f64(t: &Transform, p: Pt) -> Pt {
    (
        t.sx as f64 * p.0 + t.kx as f64 * p.1 + t.tx as f64,
        t.ky as f64 * p.0 + t.sy as f64 * p.1 + t.ty as f64,
    )
}

/// Arc length of a quad or cubic (local units): the mean of its chord and
/// control-polygon lengths, refined by splitting until they agree.
fn curve_len(p: &[Pt], depth: u32) -> f64 {
    let d = |a: Pt, b: Pt| (b.0 - a.0).hypot(b.1 - a.1);
    let chord = d(p[0], p[p.len() - 1]);
    let poly: f64 = p.windows(2).map(|w| d(w[0], w[1])).sum();
    if poly - chord <= 1e-9 * poly || depth >= 24 {
        return 0.5 * (chord + poly);
    }
    let (a, b) = split(p);
    curve_len(&a, depth + 1) + curve_len(&b, depth + 1)
}

/// The inverse of `t`, computed in `f64`.
fn invert(t: &Transform) -> Option<Transform> {
    let (a, b, c, d) = (t.sx as f64, t.ky as f64, t.kx as f64, t.sy as f64);
    let (e, f) = (t.tx as f64, t.ty as f64);
    let det = a * d - b * c;
    if det == 0.0 || !det.is_finite() {
        return None;
    }
    let (ia, ib, ic, id) = (d / det, -b / det, -c / det, a / det);
    let ie = -(ia * e + ic * f);
    let iff = -(ib * e + id * f);
    let inv = Transform::from_row(
        ia as f32, ib as f32, ic as f32, id as f32, ie as f32, iff as f32,
    );
    inv.is_finite().then_some(inv)
}

/// Pixel size of a pixmap target, for the clip box.
pub(super) fn dims(pm: &Pixmap) -> (u32, u32) {
    (pm.width(), pm.height())
}

/// Clip `path` (under `t`) to the box `r = [x0, y0, x1, y1]` in device px.
///
/// Lines are split where they cross the box's edge lines and each piece is
/// clamped into the box: a piece outside collapses onto the edge, which leaves
/// the winding number of every point inside the box unchanged, so a fill (either
/// rule) covers the box exactly as before. A curve wholly inside the box is kept;
/// one wholly to one side of it is replaced by its chord (the region between
/// them lies on that side too); one that straddles the edge is split until it
/// is one or the other, or small enough that its chord is as good.
///
/// With `close_open` (a fill), an open contour is closed here, in `f64`, as a
/// fill closes it implicitly: left to tiny-skia, the closing edge would join the
/// clamped ends instead of following the true one.
fn clip_to_box(path: &Path, t: &Transform, r: [f64; 4], close_open: bool) -> Option<Path> {
    let mut c = Clamper {
        r,
        pb: PathBuilder::new(),
        last: None,
    };
    let mut start: Pt = (0.0, 0.0);
    let mut cur: Pt = (0.0, 0.0);
    let mut open = false;
    let close = |c: &mut Clamper, cur: Pt, start: Pt| {
        c.line(cur, start);
        c.pb.close();
        c.last = None;
    };
    for seg in path.segments() {
        match seg {
            PathSegment::MoveTo(p) => {
                if close_open && open {
                    close(&mut c, cur, start);
                }
                open = false;
                cur = map(t, p.x, p.y);
                start = cur;
                c.move_to(cur);
            }
            PathSegment::LineTo(p) => {
                let q = map(t, p.x, p.y);
                c.line(cur, q);
                cur = q;
                open = true;
            }
            PathSegment::QuadTo(p1, p) => {
                let q = map(t, p.x, p.y);
                c.curve(&[cur, map(t, p1.x, p1.y), q], 0);
                cur = q;
                open = true;
            }
            PathSegment::CubicTo(p1, p2, p) => {
                let q = map(t, p.x, p.y);
                c.curve(&[cur, map(t, p1.x, p1.y), map(t, p2.x, p2.y), q], 0);
                cur = q;
                open = true;
            }
            PathSegment::Close => {
                close(&mut c, cur, start);
                cur = start;
                open = false;
            }
        }
    }
    if close_open && open {
        close(&mut c, cur, start);
    }
    c.pb.finish()
}

struct Clamper {
    r: [f64; 4],
    pb: PathBuilder,
    /// The last point emitted on the current contour (to skip repeats).
    last: Option<Pt>,
}

impl Clamper {
    fn clamp(&self, p: Pt) -> Pt {
        (
            p.0.clamp(self.r[0], self.r[2]),
            p.1.clamp(self.r[1], self.r[3]),
        )
    }

    fn move_to(&mut self, p: Pt) {
        let q = self.clamp(p);
        self.pb.move_to(q.0 as f32, q.1 as f32);
        self.last = Some(q);
    }

    fn line_to_clamped(&mut self, q: Pt) {
        if self.last == Some(q) {
            return;
        }
        self.pb.line_to(q.0 as f32, q.1 as f32);
        self.last = Some(q);
    }

    /// Emit the clipped line from `a` (the current point) to `b`.
    fn line(&mut self, a: Pt, b: Pt) {
        let mut ts = [0.0f64; 4];
        let mut n = 0;
        let (dx, dy) = (b.0 - a.0, b.1 - a.1);
        for (v, lo, d) in [
            (self.r[0], a.0, dx),
            (self.r[2], a.0, dx),
            (self.r[1], a.1, dy),
            (self.r[3], a.1, dy),
        ] {
            if d != 0.0 {
                let s = (v - lo) / d;
                if s > 0.0 && s < 1.0 {
                    ts[n] = s;
                    n += 1;
                }
            }
        }
        let ts = &mut ts[..n];
        ts.sort_by(|x, y| x.total_cmp(y));
        for &s in ts.iter() {
            let q = self.clamp((a.0 + s * dx, a.1 + s * dy));
            self.line_to_clamped(q);
        }
        let q = self.clamp(b);
        self.line_to_clamped(q);
    }

    /// Emit the clipped quad (3 points) or cubic (4 points) starting at the
    /// current point `pts[0]`.
    fn curve(&mut self, pts: &[Pt], depth: u32) {
        let (mut x0, mut y0, mut x1, mut y1) = (
            f64::INFINITY,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
        );
        for p in pts {
            x0 = x0.min(p.0);
            y0 = y0.min(p.1);
            x1 = x1.max(p.0);
            y1 = y1.max(p.1);
        }
        let r = self.r;
        let end = pts[pts.len() - 1];
        if x0 >= r[0] && y0 >= r[1] && x1 <= r[2] && y1 <= r[3] {
            // Wholly inside: the current point is pts[0] itself.
            let f = |p: Pt| (p.0 as f32, p.1 as f32);
            let (a, b) = (f(pts[1]), f(end));
            if pts.len() == 3 {
                self.pb.quad_to(a.0, a.1, b.0, b.1);
            } else {
                let c = f(pts[2]);
                self.pb.cubic_to(a.0, a.1, c.0, c.1, b.0, b.1);
            }
            self.last = Some(end);
            return;
        }
        let outside = x1 < r[0] || x0 > r[2] || y1 < r[1] || y0 > r[3];
        let small = (x1 - x0).max(y1 - y0) <= CHORD_PX;
        if outside || small || depth >= MAX_DEPTH {
            self.line(pts[0], end);
            return;
        }
        let (a, b) = split(pts);
        self.curve(&a, depth + 1);
        self.curve(&b, depth + 1);
    }
}

/// Split a quad or cubic at t = 1/2 (de Casteljau).
fn split(p: &[Pt]) -> (Vec<Pt>, Vec<Pt>) {
    let mid = |a: Pt, b: Pt| ((a.0 + b.0) * 0.5, (a.1 + b.1) * 0.5);
    if p.len() == 3 {
        let (p01, p12) = (mid(p[0], p[1]), mid(p[1], p[2]));
        let m = mid(p01, p12);
        (vec![p[0], p01, m], vec![m, p12, p[2]])
    } else {
        let (p01, p12, p23) = (mid(p[0], p[1]), mid(p[1], p[2]), mid(p[2], p[3]));
        let (a, b) = (mid(p01, p12), mid(p12, p23));
        let m = mid(a, b);
        (vec![p[0], p01, a, m], vec![m, b, p23, p[3]])
    }
}

/// `path` as given, or fitted, borrowed or owned, for callers that just need a
/// path to hand on (no transform change): used for clip masks in device px.
pub(crate) fn fitted_fill<'a>(
    path: &'a Path,
    t: Transform,
    w: u32,
    h: u32,
) -> Option<(Cow<'a, Path>, Transform)> {
    match fit_fill(path, t, w, h) {
        Fit::Keep(p) => Some((Cow::Borrowed(p), t)),
        Fit::Clipped(p) => Some((Cow::Owned(p), Transform::identity())),
        Fit::Outline | Fit::Skip => None,
    }
}

// --- vector backends (VR-44) -------------------------------------------------
//
// SVG and PDF never panic on far geometry, but their viewers fail on it the
// way tiny-skia did: librsvg, poppler and browsers draw nothing for a circle of
// radius 1e10 px or a line from -1e12 to 1e12, where PNG (fitted above) draws
// the visible part. So the vector backends fit far geometry the same way, with
// the same threshold, and still write every ordinary path exactly as before.

/// What a vector backend draws for a filled path.
pub(super) enum VecFill {
    /// The path as given, under its own transform: in range (or not finite,
    /// which each backend already handles as before).
    Keep,
    /// This path under this transform instead.
    Draw(Path, Transform),
    /// Nothing: beyond the PDF coordinate cap, or cut away entirely.
    Skip,
}

/// Is `path` under `t` finite, and is every coordinate of it and its pen
/// (`reach`) within [`SAFE`]? Such geometry is written untouched.
fn vector_untouched(path: &Path, t: &Transform, reach: f64) -> bool {
    if !t.is_finite() {
        return true;
    }
    let b = device_bounds(path, t);
    !b.iter().all(|v| v.is_finite()) || within(b, reach)
}

/// Fit a filled path for a vector backend drawing a `w` x `h` px page.
/// `device_ok`: the paint looks the same in device space (a solid colour), so
/// the cut path is drawn in device px under the identity. A gradient or pattern
/// is laid out in local px, so the cut is mapped back to local space and keeps
/// the transform, as long as that mapping stays in range.
pub(super) fn vector_fill(path: &Path, t: Transform, w: u32, h: u32, device_ok: bool) -> VecFill {
    if vector_untouched(path, &t, 0.0) {
        return VecFill::Keep;
    }
    if beyond_cap(path, t) {
        return VecFill::Skip;
    }
    let dev = match fit_fill(path, t, w, h) {
        Fit::Keep(_) => return VecFill::Keep,
        Fit::Clipped(dev) => dev,
        Fit::Outline | Fit::Skip => return VecFill::Skip,
    };
    if device_ok {
        return VecFill::Draw(dev, Transform::identity());
    }
    match invert(&t).and_then(|inv| dev.transform(inv)) {
        Some(local) if within(device_bounds(&local, &t), 0.0) => VecFill::Draw(local, t),
        _ => VecFill::Skip,
    }
}

/// What a vector backend draws for a stroked path.
pub(super) enum VecStroke {
    /// The path as given (see [`VecFill::Keep`]).
    Keep,
    /// These pieces instead, in local space under the original transform, each
    /// with the dash phase it starts at (the original phase for a solid stroke).
    Runs(Vec<(Path, f32)>),
    /// The pen alone reaches past the safe range: stroke the path to its
    /// outline and fill that (see [`Fit::Outline`]).
    Outline,
    /// Nothing.
    Skip,
}

/// Fit a stroked path whose pen reaches `reach` device px, for a vector
/// backend drawing a `w` x `h` px page. `dash` is a valid dash pattern and
/// phase, kept on the page as on PNG ([`fit_dashed`]); `phase` is the stroke's
/// phase, carried on an undashed run.
pub(super) fn vector_stroke(
    path: &Path,
    t: Transform,
    reach: f64,
    w: u32,
    h: u32,
    dash: Option<(&[f32], f32)>,
    phase: f32,
) -> VecStroke {
    if !reach.is_finite() || vector_untouched(path, &t, reach) {
        return VecStroke::Keep;
    }
    if beyond_cap(path, t) {
        return VecStroke::Skip;
    }
    if let Some((intervals, ph)) = dash {
        return match fit_dashed(path, t, reach, w, h, intervals, ph) {
            DashFit::Keep(_) => VecStroke::Keep,
            DashFit::Runs(runs) => VecStroke::Runs(runs),
            DashFit::Outline => VecStroke::Outline,
            DashFit::Skip => VecStroke::Skip,
        };
    }
    match fit_stroke(path, t, reach, w, h) {
        Fit::Keep(_) => VecStroke::Keep,
        Fit::Clipped(local) => VecStroke::Runs(vec![(local, phase)]),
        Fit::Outline => VecStroke::Outline,
        Fit::Skip => VecStroke::Skip,
    }
}

/// [`vector_stroke`] for a backend stroke, with the pen reach and dash taken
/// from the style as the raster backend takes them.
pub(super) fn vector_stroke_style(
    path: &Path,
    t: Transform,
    stroke: &super::StrokeStyle,
    w: u32,
    h: u32,
) -> VecStroke {
    let sk = super::raster::skia_stroke(stroke);
    let reach = super::raster::pen_reach(&sk, &t);
    let dash = sk
        .dash
        .is_some()
        .then_some((stroke.dash.as_slice(), stroke.phase));
    vector_stroke(path, t, reach, w, h, dash, stroke.phase)
}

/// The outline of `path` stroked with `stroke` under `t` (dashed first, at
/// tiny-skia's resolution scale), local px: what [`VecStroke::Outline`] fills.
pub(super) fn stroke_outline_path(
    path: &Path,
    t: Transform,
    stroke: &super::StrokeStyle,
) -> Option<Path> {
    let sk = super::raster::skia_stroke(stroke);
    let res = tiny_skia::PathStroker::compute_resolution_scale(&t);
    let dashed = match &sk.dash {
        Some(d) => Some(path.dash(d, res)?),
        None => None,
    };
    let solid = tiny_skia::Stroke { dash: None, ..sk };
    dashed.as_ref().unwrap_or(path).stroke(&solid, res)
}

/// Fit a clip region's path (local, under `t`) for a vector backend: `None`
/// keeps it as is, `Some(dev)` is the region cut to the page in device px
/// (`Some(None)`: nothing of it can be drawn, so it admits nothing).
pub(super) fn vector_clip(path: &Path, t: Transform, w: u32, h: u32) -> Option<Option<Path>> {
    if vector_untouched(path, &t, 0.0) {
        return None;
    }
    match fit_fill(path, t, w, h) {
        Fit::Keep(_) => None,
        Fit::Clipped(dev) => Some(Some(dev)),
        Fit::Outline | Fit::Skip => Some(None),
    }
}

/// Is a clip rect's device geometry within the safe range (written as is)?
pub(super) fn rect_corners_near(c: &[(f64, f64); 4]) -> bool {
    c.iter()
        .all(|p| !(p.0.is_finite() && p.1.is_finite()) || p.0.abs().max(p.1.abs()) <= SAFE)
}

// --- far images (VR-46) ------------------------------------------------------
//
// An image cell is placed by its own matrix, which SVG, PDF and DrawingML write
// as given. poppler draws nothing for a cell millions of px wide, so a far
// image is cut to the part over the page first, as a path is, and placed at
// sane coordinates.

/// A replacement image for [`vector_image`]: straight RGBA, `iw` x `ih`, in
/// the local cell centred at `(x, y)`, `w` x `h` px.
pub(super) struct FitImage {
    pub rgba: Vec<u8>,
    pub iw: u32,
    pub ih: u32,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub interpolate: bool,
}

/// What a vector backend draws for an image.
pub(super) enum VecImage {
    /// The image as given: in range (or not finite or empty, which each
    /// backend already handles).
    Keep,
    /// This image instead, under the original transform.
    Draw(FitImage),
    /// Nothing: beyond the PDF coordinate cap, or wholly off the page.
    Skip,
}

/// Source px whose device size (along one axis) is at most this are kept as
/// they are: a far image is cropped to whole source px around the page.
/// Larger ones are resampled at twice the device resolution over the page
/// instead, as a crop to whole px would still reach far past it.
const CROP_PX: f64 = 64.0;

/// Output budget (px) for a resampled far image.
const RESAMPLE_BUDGET: f64 = 4_000_000.0;

/// Fit an `iw` x `ih` image in the local cell centred at `(x, y)`, `w` x `h`
/// px, under `t`, for a vector backend drawing a `pw` x `ph` px page. A cell
/// within [`SAFE`] is kept. A farther one is cut to the part within a margin
/// of the page (the box [`fit_fill`] cuts paths to): cropped to whole source
/// px when they are small on the page, else resampled over that part, nearest
/// or bilinear as `interpolate` asks. Beyond the PDF cap, nothing is drawn
/// (as PNG and PDF already skip it).
#[allow(clippy::too_many_arguments)]
pub(super) fn vector_image(
    rgba: &[u8],
    iw: u32,
    ih: u32,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    interpolate: bool,
    t: Transform,
    pw: u32,
    ph: u32,
) -> VecImage {
    let n = (iw as usize).saturating_mul(ih as usize);
    if iw == 0 || ih == 0 || rgba.len() < n.saturating_mul(4) || !t.is_finite() {
        return VecImage::Keep;
    }
    let (x0, y0) = (x - w / 2.0, y - h / 2.0);
    let corners = [(x0, y0), (x0 + w, y0), (x0 + w, y0 + h), (x0, y0 + h)].map(|p| map_f64(&t, p));
    let mut b = [
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    ];
    for (cx, cy) in corners {
        b[0] = b[0].min(cx);
        b[1] = b[1].min(cy);
        b[2] = b[2].max(cx);
        b[3] = b[3].max(cy);
    }
    if !b.iter().all(|v| v.is_finite()) || within(b, 0.0) {
        return VecImage::Keep;
    }
    let cap = super::pdf::MAX_COORD as f64;
    if b.iter().any(|v| v.abs() > cap) {
        return VecImage::Skip;
    }
    // Source px (u, v) -> device: columns per source px, then the origin.
    let (du, dv) = (w / iw as f64, h / ih as f64);
    let (a, c) = (t.sx as f64 * du, t.ky as f64 * du);
    let (bb, d) = (t.kx as f64 * dv, t.sy as f64 * dv);
    let (e, f) = corners[0];
    let det = a * d - bb * c;
    if det == 0.0 || !det.is_finite() {
        return VecImage::Skip;
    }
    let inv = |px: f64, py: f64| {
        let (qx, qy) = (px - e, py - f);
        ((d * qx - bb * qy) / det, (a * qy - c * qx) / det)
    };
    // The page box, grown as fit_fill grows it, in source px.
    let m = pw.max(ph) as f64 + 4.0;
    let (mut u0, mut v0, mut u1, mut v1) = (
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    );
    for (px, py) in [
        (-m, -m),
        (pw as f64 + m, -m),
        (pw as f64 + m, ph as f64 + m),
        (-m, ph as f64 + m),
    ] {
        let (u, v) = inv(px, py);
        u0 = u0.min(u);
        u1 = u1.max(u);
        v0 = v0.min(v);
        v1 = v1.max(v);
    }
    let (u0, u1) = (u0.max(0.0), u1.min(iw as f64));
    let (v0, v1) = (v0.max(0.0), v1.min(ih as f64));
    if !(u1 > u0 && v1 > v0) {
        return VecImage::Skip;
    }
    // Per axis: source px small on the page are kept whole (the window
    // snapped out to whole px, one more each side for the bilinear filter,
    // sampled once per px, so each is copied as is); larger ones are
    // resampled at about two output px per device px.
    let axis = |lo: f64, hi: f64, n: u32, s: f64| {
        if s <= CROP_PX {
            let a = (lo.floor() - 1.0).max(0.0);
            let b = (hi.ceil() + 1.0).min(n as f64);
            (a, b, b - a)
        } else {
            (lo, hi, ((hi - lo) * 2.0 * s).ceil().max(1.0))
        }
    };
    let (u0, u1, mut nu) = axis(u0, u1, iw, a.hypot(c));
    let (v0, v1, mut nv) = axis(v0, v1, ih, bb.hypot(d));
    if nu * nv > RESAMPLE_BUDGET {
        let k = (RESAMPLE_BUDGET / (nu * nv)).sqrt();
        nu = (nu * k).floor().max(1.0);
        nv = (nv * k).floor().max(1.0);
    }
    let (nu, nv) = (nu as usize, nv as usize);
    let src = |i: usize, j: usize| {
        let k = 4 * (j * iw as usize + i);
        [rgba[k], rgba[k + 1], rgba[k + 2], rgba[k + 3]]
    };
    let (stu, stv) = ((u1 - u0) / nu as f64, (v1 - v0) / nv as f64);
    let (iwz, ihz) = (iw as usize, ih as usize);
    let mut out = Vec::with_capacity(nu * nv * 4);
    for j in 0..nv {
        let v = v0 + (j as f64 + 0.5) * stv;
        for i in 0..nu {
            let u = u0 + (i as f64 + 0.5) * stu;
            if !interpolate {
                let (si, sj) = ((u as usize).min(iwz - 1), (v as usize).min(ihz - 1));
                out.extend_from_slice(&src(si, sj));
                continue;
            }
            // Bilinear between texel centres, edges padded; mixed
            // premultiplied, so a transparent texel lends no colour.
            let (fu, fv) = ((u - 0.5).max(0.0), (v - 0.5).max(0.0));
            let (ia, ja) = ((fu as usize).min(iwz - 1), (fv as usize).min(ihz - 1));
            let (ib, jb) = ((ia + 1).min(iwz - 1), (ja + 1).min(ihz - 1));
            let (tu, tv) = (fu - ia as f64, fv - ja as f64);
            let mut acc = [0.0f64; 4];
            for (si, sj, wgt) in [
                (ia, ja, (1.0 - tu) * (1.0 - tv)),
                (ib, ja, tu * (1.0 - tv)),
                (ia, jb, (1.0 - tu) * tv),
                (ib, jb, tu * tv),
            ] {
                let p = src(si, sj);
                let al = p[3] as f64 * wgt;
                acc[0] += p[0] as f64 * al;
                acc[1] += p[1] as f64 * al;
                acc[2] += p[2] as f64 * al;
                acc[3] += al;
            }
            let px = if acc[3] > 0.0 {
                [
                    (acc[0] / acc[3]).round() as u8,
                    (acc[1] / acc[3]).round() as u8,
                    (acc[2] / acc[3]).round() as u8,
                    acc[3].round() as u8,
                ]
            } else {
                [0, 0, 0, 0]
            };
            out.extend_from_slice(&px);
        }
    }
    let (nw, nh) = ((u1 - u0) * du, (v1 - v0) * dv);
    VecImage::Draw(FitImage {
        rgba: out,
        iw: nu as u32,
        ih: nv as u32,
        x: x0 + u0 * du + nw / 2.0,
        y: y0 + v0 * dv + nh / 2.0,
        w: nw,
        h: nh,
        interpolate,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tiny_skia::{FillRule, Paint, Rect, Stroke};

    fn red() -> Paint<'static> {
        let mut p = Paint::default();
        p.set_color_rgba8(255, 0, 0, 255);
        p.anti_alias = true;
        p
    }

    fn fill(pm: &mut Pixmap, path: &Path, t: Transform) {
        let (w, h) = dims(pm);
        match fit_fill(path, t, w, h) {
            Fit::Keep(p) => pm.fill_path(p, &red(), FillRule::Winding, t, None),
            Fit::Clipped(p) => {
                pm.fill_path(&p, &red(), FillRule::Winding, Transform::identity(), None)
            }
            Fit::Outline | Fit::Skip => {}
        }
    }

    fn red_px(pm: &Pixmap) -> usize {
        pm.pixels()
            .iter()
            .filter(|c| c.red() > 200 && c.alpha() == 255)
            .count()
    }

    #[test]
    fn ordinary_paths_pass_through_untouched() {
        let p = PathBuilder::from_circle(50.0, 50.0, 20.0).unwrap();
        assert!(matches!(
            fit_fill(&p, Transform::identity(), 100, 100),
            Fit::Keep(_)
        ));
        let s = fit_stroke(&p, Transform::from_scale(3.0, 3.0), 10.0, 100, 100);
        assert!(matches!(s, Fit::Keep(_)));
    }

    #[test]
    fn huge_shapes_straddling_the_page_fill_it_without_panicking() {
        // tiny-skia alone panics on each of these.
        for e in [9, 10, 15, 20, 30, 37] {
            let s = 10f32.powi(e);
            let mut shapes = vec![PathBuilder::from_rect(
                Rect::from_xywh(50.0 - s / 2.0, -s / 2.0, s, s).unwrap(),
            )];
            // Beyond ~1e15 tiny-skia cannot even build the circle (it collapses
            // to a point); the scaled unit circle below covers those sizes.
            if e <= 15 {
                shapes.push(PathBuilder::from_circle(50.0, 50.0, s).unwrap());
            }
            for p in &shapes {
                let mut pm = Pixmap::new(100, 100).unwrap();
                fill(&mut pm, p, Transform::identity());
                assert_eq!(red_px(&pm), 100 * 100, "1e{e}");
            }
            // A unit circle scaled up by the transform (a marker of huge size).
            let unit = PathBuilder::from_circle(0.0, 0.0, 1.0).unwrap();
            let mut pm = Pixmap::new(100, 100).unwrap();
            fill(
                &mut pm,
                &unit,
                Transform::from_row(s, 0.0, 0.0, s, 50.0, 50.0),
            );
            assert_eq!(red_px(&pm), 100 * 100, "scaled 1e{e}");
        }
    }

    #[test]
    fn a_huge_shape_with_an_edge_on_the_page_keeps_that_edge() {
        // The left half of the page is covered, the right half is not.
        let s = 1e12f32;
        let p = PathBuilder::from_rect(Rect::from_ltrb(-s, -s, 50.0, s).unwrap());
        let mut pm = Pixmap::new(100, 100).unwrap();
        fill(&mut pm, &p, Transform::identity());
        assert_eq!(red_px(&pm), 50 * 100);
        // The same through the exact (in-range) path.
        let q = PathBuilder::from_rect(Rect::from_ltrb(-10.0, -10.0, 50.0, 110.0).unwrap());
        let mut pq = Pixmap::new(100, 100).unwrap();
        pq.fill_path(&q, &red(), FillRule::Winding, Transform::identity(), None);
        assert_eq!(pm.data(), pq.data());
    }

    #[test]
    fn an_even_odd_hole_survives_the_clip() {
        // A huge square with an on-page square hole.
        let s = 1e12f32;
        let mut pb = PathBuilder::new();
        pb.push_rect(Rect::from_ltrb(-s, -s, s, s).unwrap());
        pb.push_rect(Rect::from_ltrb(25.0, 25.0, 75.0, 75.0).unwrap());
        let p = pb.finish().unwrap();
        let (w, h) = (100, 100);
        let Fit::Clipped(c) = fit_fill(&p, Transform::identity(), w, h) else {
            panic!("expected a clipped path");
        };
        let mut pm = Pixmap::new(w, h).unwrap();
        pm.fill_path(&c, &red(), FillRule::EvenOdd, Transform::identity(), None);
        assert_eq!(red_px(&pm), 100 * 100 - 50 * 50);
    }

    #[test]
    fn a_long_stroke_across_the_page_draws_its_visible_part() {
        // A horizontal line from -1e12 to 1e12 px through the middle.
        let mut pb = PathBuilder::new();
        pb.move_to(-1e12, 50.0);
        pb.line_to(1e12, 50.0);
        let p = pb.finish().unwrap();
        let t = Transform::identity();
        let Fit::Clipped(c) = fit_stroke(&p, t, 2.0, 100, 100) else {
            panic!("expected a clipped path");
        };
        let mut pm = Pixmap::new(100, 100).unwrap();
        let stroke = Stroke {
            width: 4.0,
            ..Stroke::default()
        };
        pm.stroke_path(&c, &red(), &stroke, t, None);
        assert_eq!(red_px(&pm), 100 * 4);
    }

    #[test]
    fn the_pdf_coordinate_cap_marks_what_is_not_drawn() {
        let p = PathBuilder::from_circle(0.0, 0.0, 1.0).unwrap();
        let at = |s: f32| Transform::from_row(s, 0.0, 0.0, s, 50.0, 50.0);
        assert!(!beyond_cap(&p, at(1e12)));
        assert!(beyond_cap(&p, at(1e16)));
        assert!(beyond_cap(&p, at(f32::NAN)));
    }

    /// Stroke `path` dashed `[4, 4]` from `phase`, as the raster backend does.
    fn dashed(path: &Path, t: Transform, width: f32, phase: f32) -> Pixmap {
        let mut pm = Pixmap::new(100, 100).unwrap();
        let sk = Stroke {
            width,
            line_cap: tiny_skia::LineCap::Butt,
            dash: tiny_skia::StrokeDash::new(vec![4.0, 4.0], phase),
            ..Stroke::default()
        };
        let reach = width as f64 * 0.5 + 2.0;
        match fit_dashed(path, t, reach, 100, 100, &[4.0, 4.0], phase) {
            DashFit::Keep(p) => pm.stroke_path(p, &red(), &sk, t, None),
            DashFit::Runs(runs) => {
                for (run, off) in runs {
                    let mut sk = sk.clone();
                    sk.dash = tiny_skia::StrokeDash::new(vec![4.0, 4.0], off);
                    pm.stroke_path(&run, &red(), &sk, t, None);
                }
            }
            DashFit::Outline | DashFit::Skip => panic!("expected runs"),
        }
        pm
    }

    fn hline(l: f32) -> Path {
        let mut pb = PathBuilder::new();
        pb.move_to(-l, 50.0);
        pb.line_to(100.0 + l, 50.0);
        pb.finish().unwrap()
    }

    #[test]
    fn a_fitted_dashed_stroke_keeps_its_phase() {
        let t = Transform::identity();
        // In range (drawn as given) vs far past it, with the same phase on the
        // page ((x + l) mod 8): the far one is cut, yet dashes alike.
        for (near, far) in [
            (1e5f32, 3e6f32),
            (1e5 + 4.0, 3e6 + 4.0),
            (1e5 + 2.0, 1.5e6 + 2.0),
        ] {
            let a = dashed(&hline(near), t, 2.0, 0.0);
            let b = dashed(&hline(far), t, 2.0, 0.0);
            assert_eq!(a.data(), b.data(), "{near} vs {far}");
        }
        // A phase given with the stroke carries through too.
        let a = dashed(&hline(1e5), t, 2.0, 3.0);
        let b = dashed(&hline(2e6), t, 2.0, 3.0);
        assert_eq!(a.data(), b.data());
        // ... and a phase shift does show.
        let c = dashed(&hline(2e6 + 4.0), t, 2.0, 3.0);
        assert_ne!(a.data(), c.data());
        // Under a scale the pattern is measured in local units.
        let s = Transform::from_row(2.0, 0.0, 0.0, 2.0, -50.0, -50.0);
        let a = dashed(&hline(1e5), s, 1.0, 0.0);
        let b = dashed(&hline(3e6), s, 1.0, 0.0);
        assert_eq!(a.data(), b.data());
    }

    #[test]
    fn a_closed_dashed_contour_through_the_page_is_one_run_there() {
        // A huge square whose start (and end) corner is on the page.
        let l = 1e9f32;
        let mut pb = PathBuilder::new();
        pb.move_to(50.0, 50.0);
        pb.line_to(50.0 + l, 50.0);
        pb.line_to(50.0 + l, 50.0 + l);
        pb.line_to(50.0, 50.0 + l);
        pb.close();
        let p = pb.finish().unwrap();
        let DashFit::Runs(runs) =
            fit_dashed(&p, Transform::identity(), 3.0, 100, 100, &[4.0, 4.0], 0.0)
        else {
            panic!("expected runs");
        };
        // Leaving and re-entering the box: the last run continues into the first.
        assert_eq!(runs.len(), 1);
    }

    #[test]
    fn a_pen_wider_than_the_safe_range_is_outlined_not_dropped() {
        let p = hline(10.0);
        assert!(matches!(
            fit_stroke(&p, Transform::identity(), 1.1e6, 100, 100),
            Fit::Outline
        ));
    }

    #[test]
    fn an_open_fill_contour_is_closed_along_its_true_edge() {
        // Open: implicitly closed from (100 + l, 60) back to (-l, 40).
        let open = |l: f32| {
            let mut pb = PathBuilder::new();
            pb.move_to(-l, 40.0);
            pb.line_to(0.0, -l);
            pb.line_to(100.0 + l, 60.0);
            pb.finish().unwrap()
        };
        let mut a = Pixmap::new(100, 100).unwrap();
        fill(&mut a, &open(1e5), Transform::identity());
        let mut b = Pixmap::new(100, 100).unwrap();
        fill(&mut b, &open(1e12), Transform::identity());
        let differ = a
            .data()
            .iter()
            .zip(b.data())
            .filter(|(x, y)| x != y)
            .count();
        assert!(differ < 100 * 4, "{differ} bytes differ");
    }

    #[test]
    fn non_finite_geometry_is_skipped() {
        let p = PathBuilder::from_circle(0.0, 0.0, 1.0).unwrap();
        let t = Transform::from_row(f32::NAN, 0.0, 0.0, 1.0, 0.0, 0.0);
        assert!(matches!(fit_fill(&p, t, 10, 10), Fit::Skip));
        assert!(matches!(fit_stroke(&p, t, 1.0, 10, 10), Fit::Skip));
        let inf = Transform::from_row(f32::MAX, 0.0, 0.0, f32::MAX, f32::MAX, 0.0);
        let mut pm = Pixmap::new(10, 10).unwrap();
        fill(&mut pm, &p, inf);
    }

    // --- vector backends (VR-44) ---

    fn max_coord(p: &Path, t: Transform) -> f64 {
        let b = device_bounds(p, &t);
        b.iter().fold(0.0f64, |m, v| m.max(v.abs()))
    }

    #[test]
    fn vector_fits_leave_ordinary_geometry_alone() {
        let p = PathBuilder::from_circle(50.0, 50.0, 20.0).unwrap();
        let t = Transform::from_translate(3.0, 4.0);
        assert!(matches!(vector_fill(&p, t, 100, 100, true), VecFill::Keep));
        assert!(matches!(vector_fill(&p, t, 100, 100, false), VecFill::Keep));
        assert!(matches!(
            vector_stroke(&p, t, 5.0, 100, 100, Some((&[4.0, 2.0], 1.0)), 1.0),
            VecStroke::Keep
        ));
        assert!(vector_clip(&p, t, 100, 100).is_none());
        // so is geometry each backend already handles on its own
        let nan = Transform::from_row(f32::NAN, 0.0, 0.0, 1.0, 0.0, 0.0);
        assert!(matches!(
            vector_fill(&p, nan, 100, 100, true),
            VecFill::Keep
        ));
    }

    #[test]
    fn a_far_solid_fill_is_cut_to_the_page_in_device_px() {
        let p = PathBuilder::from_circle(50.0, 50.0, 1e10).unwrap();
        match vector_fill(&p, Transform::identity(), 100, 100, true) {
            VecFill::Draw(d, t) => {
                assert_eq!(t, Transform::identity());
                assert!(max_coord(&d, t) <= 205.0);
            }
            _ => panic!("expected a fitted path"),
        }
    }

    #[test]
    fn a_far_gradient_fill_keeps_its_transform() {
        // Local px under a scale: the cut maps back to local space, so a
        // gradient laid out there still lines up.
        let p = PathBuilder::from_rect(Rect::from_xywh(-1e9, 0.0, 2e9, 10.0).unwrap());
        let t = Transform::from_scale(2.0, 2.0);
        match vector_fill(&p, t, 100, 100, false) {
            VecFill::Draw(d, t2) => {
                assert_eq!(t2, t);
                assert!(max_coord(&d, t) <= 205.0);
                // the visible part is still covered: the page's width at y = 10
                let b = d.bounds();
                assert!(b.left() <= 0.0 && b.right() >= 50.0);
            }
            _ => panic!("expected a fitted path"),
        }
    }

    #[test]
    fn far_geometry_beyond_the_pdf_cap_is_skipped_on_vector_backends_too() {
        let p = PathBuilder::from_circle(0.0, 0.0, 1e16).unwrap();
        assert!(matches!(
            vector_fill(&p, Transform::identity(), 10, 10, true),
            VecFill::Skip
        ));
        assert!(matches!(
            vector_stroke(&p, Transform::identity(), 1.0, 10, 10, None, 0.0),
            VecStroke::Skip
        ));
    }

    #[test]
    fn a_far_stroke_becomes_local_runs_with_their_phase() {
        let mut pb = PathBuilder::new();
        pb.move_to(-1e9, 50.0);
        pb.line_to(1e9, 50.0);
        let p = pb.finish().unwrap();
        let t = Transform::identity();
        match vector_stroke(&p, t, 3.0, 100, 100, None, 0.5) {
            VecStroke::Runs(runs) => {
                assert_eq!(runs.len(), 1);
                assert_eq!(runs[0].1, 0.5);
                assert!(max_coord(&runs[0].0, t) < 300.0);
            }
            _ => panic!("expected runs"),
        }
        // dashed: the pattern offset at the cut, as on PNG
        match vector_stroke(&p, t, 3.0, 100, 100, Some((&[6.0, 4.0], 0.0)), 0.0) {
            VecStroke::Runs(runs) => {
                assert_eq!(runs.len(), 1);
                let start = runs[0].0.bounds().left() as f64;
                let want = (start + 1e9).rem_euclid(10.0) as f32;
                assert!((runs[0].1 - want).abs() < 1e-3, "{} vs {want}", runs[0].1);
            }
            _ => panic!("expected runs"),
        }
    }

    #[test]
    fn a_far_clip_is_cut_to_the_page_and_one_off_it_admits_nothing() {
        let big = PathBuilder::from_rect(Rect::from_xywh(-1e12, -1e12, 2e12, 2e12).unwrap());
        match vector_clip(&big, Transform::identity(), 100, 100) {
            Some(Some(d)) => assert!(max_coord(&d, Transform::identity()) <= 205.0),
            _ => panic!("expected a fitted clip"),
        }
        let off = PathBuilder::from_rect(Rect::from_xywh(1e12, 1e12, 10.0, 10.0).unwrap());
        match vector_clip(&off, Transform::identity(), 100, 100) {
            Some(Some(d)) => {
                let b = d.bounds();
                assert!(b.width() == 0.0 || b.height() == 0.0);
            }
            Some(None) => {}
            None => panic!("a far clip must be fitted"),
        }
    }

    // A 2 x 1 image, red then blue, `w` px wide, centred on a 100 px page.
    fn red_blue(w: f64, interpolate: bool, t: Transform) -> VecImage {
        let px = [255, 0, 0, 255, 0, 0, 255, 255];
        vector_image(&px, 2, 1, 50.0, 50.0, w, 20.0, interpolate, t, 100, 100)
    }

    #[test]
    fn an_image_in_range_is_kept() {
        assert!(matches!(
            red_blue(1e5, false, Transform::identity()),
            VecImage::Keep
        ));
    }

    #[test]
    fn a_far_image_is_cut_to_the_page_with_its_seam_in_place() {
        for w in [1e7, 1e10, 1e14] {
            for interpolate in [false, true] {
                let VecImage::Draw(f) = red_blue(w, interpolate, Transform::identity()) else {
                    panic!("expected a fitted image at {w}");
                };
                // the cell now lies around the page
                let (x0, x1) = (f.x - f.w / 2.0, f.x + f.w / 2.0);
                assert!(x0 >= -300.0 && x1 <= 400.0, "{x0} {x1}");
                // the source px each side of the centre seam
                let col = |x: f64| {
                    let i = ((x - x0) / f.w * f.iw as f64) as usize;
                    f.rgba[4 * i]
                };
                if interpolate {
                    // texel centres millions of px apart: an even mix here
                    assert!((col(50.0) as i32 - 128).abs() <= 1, "{w}");
                } else {
                    assert_eq!(col(49.5), 255, "{w}");
                    assert_eq!(col(50.5), 0, "{w}");
                }
            }
        }
    }

    #[test]
    fn a_far_image_with_small_px_is_cropped_to_whole_px() {
        // 1e6 px wide, 10 device px per source px: a crop, copied as is.
        let n = 1_000_000usize;
        let px: Vec<u8> = (0..n).flat_map(|i| [(i % 251) as u8, 0, 0, 255]).collect();
        let VecImage::Draw(f) = vector_image(
            &px,
            n as u32,
            1,
            50.0,
            50.0,
            1e7,
            20.0,
            false,
            Transform::identity(),
            100,
            100,
        ) else {
            panic!("expected a fitted image");
        };
        assert!(f.iw < 100);
        assert_eq!(f.w, f.iw as f64 * 10.0);
        let first = ((f.x - f.w / 2.0 + 5e6 - 50.0) / 10.0).round() as usize;
        for i in 0..f.iw as usize {
            assert_eq!(f.rgba[4 * i], ((first + i) % 251) as u8);
        }
    }

    #[test]
    fn a_far_image_off_the_page_or_past_the_cap_is_skipped() {
        let px = [255u8, 0, 0, 255];
        let t = Transform::identity();
        let off = vector_image(&px, 1, 1, 1e9, 50.0, 1e7, 20.0, false, t, 100, 100);
        assert!(matches!(off, VecImage::Skip));
        assert!(matches!(red_blue(1e16, false, t), VecImage::Skip));
    }
}
