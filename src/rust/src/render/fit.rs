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

/// Does `path` under `t`, grown by `reach` px, reach past the PDF backend's
/// coordinate cap (or is it not finite)? Such a mark is skipped on PDF
/// (`pdf::drawable`), so the raster backend skips it too.
pub(super) fn beyond_cap(path: &Path, t: Transform, reach: f64) -> bool {
    let cap = super::pdf::MAX_COORD as f64;
    let b = device_bounds(path, &t);
    !(t.is_finite() && b.iter().all(|v| v.is_finite() && v.abs() + reach <= cap))
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
    match clip_to_box(path, &t, [-m, -m, w as f64 + m, h as f64 + m]) {
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
    // A pen wider than the safe range itself cannot be drawn safely however the
    // centreline is cut.
    if !b.iter().all(|v| v.is_finite()) || reach > SAFE / 8.0 {
        return Fit::Skip;
    }
    let m = w.max(h) as f64 + reach + 4.0;
    let Some(dev) = clip_to_box(path, &t, [-m, -m, w as f64 + m, h as f64 + m]) else {
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
fn clip_to_box(path: &Path, t: &Transform, r: [f64; 4]) -> Option<Path> {
    let mut c = Clamper {
        r,
        pb: PathBuilder::new(),
        last: None,
    };
    let mut start: Pt = (0.0, 0.0);
    let mut cur: Pt = (0.0, 0.0);
    for seg in path.segments() {
        match seg {
            PathSegment::MoveTo(p) => {
                cur = map(t, p.x, p.y);
                start = cur;
                c.move_to(cur);
            }
            PathSegment::LineTo(p) => {
                let q = map(t, p.x, p.y);
                c.line(cur, q);
                cur = q;
            }
            PathSegment::QuadTo(p1, p) => {
                let q = map(t, p.x, p.y);
                c.curve(&[cur, map(t, p1.x, p1.y), q], 0);
                cur = q;
            }
            PathSegment::CubicTo(p1, p2, p) => {
                let q = map(t, p.x, p.y);
                c.curve(&[cur, map(t, p1.x, p1.y), map(t, p2.x, p2.y), q], 0);
                cur = q;
            }
            PathSegment::Close => {
                c.line(cur, start);
                c.pb.close();
                c.last = None;
                cur = start;
            }
        }
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
pub(super) fn fitted_fill<'a>(
    path: &'a Path,
    t: Transform,
    w: u32,
    h: u32,
) -> Option<(Cow<'a, Path>, Transform)> {
    match fit_fill(path, t, w, h) {
        Fit::Keep(p) => Some((Cow::Borrowed(p), t)),
        Fit::Clipped(p) => Some((Cow::Owned(p), Transform::identity())),
        Fit::Skip => None,
    }
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
            Fit::Skip => {}
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
        assert!(!fit_cap(&p, at(1e12), 0.0));
        assert!(fit_cap(&p, at(1e16), 0.0));
        assert!(fit_cap(&p, at(1e12), 1e16));
        assert!(fit_cap(&p, at(f32::NAN), 0.0));
    }

    fn fit_cap(p: &Path, t: Transform, reach: f64) -> bool {
        beyond_cap(p, t, reach)
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
}
