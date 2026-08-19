//! Variable-width stroke expansion: the outline of a stroke whose width varies
//! along it.
//!
//! At constant width, `stroke_to_path()` uses tiny-skia's own stroker -- the one
//! the rasterizer uses -- so the outline is exactly the region that would have
//! been inked. `tiny_skia::Stroke` carries a single scalar `width` and has no
//! width-profile hook, so a varying width cannot come from it, and this module
//! generates the geometry itself.
//!
//! # The construction
//!
//! The region a round nib of linearly varying radius sweeps along a segment
//! `a -> b` with half-widths `h_a`, `h_b` is exactly the convex hull of the two
//! end discs, whose boundary is the two **external tangent lines** plus two
//! arcs. So the whole stroke is
//!
//! ```text
//! U segments (tangent trapezoid)  U  U vertices (join)  U  caps
//! ```
//!
//! cleaned by one self-union. Every piece is small and locally verifiable, and
//! the hard topology -- self-intersection on a tight turn, the inner side of a
//! join, a taper that pinches the stroke in two -- is resolved by the union
//! rather than by case analysis.
//!
//! External tangents rather than perpendicular offsets is not pedantry. With
//! unequal end widths the boundary is not parallel to the centreline, so
//! offsetting a vertex along its normal makes the sides *chords* of the end
//! disc: a taper to zero comes out waisted, pinched inward by up to
//! `h * (1 - cos asin(h/L))`, which is badly visible exactly when `h` is
//! comparable to the final segment's length. Tapering to a point is the main
//! thing this feature is for, so the tangent construction is load-bearing.
//!
//! # Winding
//!
//! `FillRule::NonZero` over a bag of contours only unions them if they are all
//! wound the same way, so every contour goes through `push_ccw`. Getting that
//! wrong punches holes through the middle of the stroke. Holes in the *result*
//! come from topology and arrive wound opposite their outer contour, which is
//! what a path grob's `"winding"` rule wants.

use i_overlay::core::fill_rule::FillRule;
use i_overlay::float::simplify::SimplifyShape;

/// Coincident-point tolerance, in device px. Matches the dedupe threshold the
/// text-on-a-path parameterisation uses.
const EPS_PT: f64 = 1e-9;
/// Half-widths at or below this contribute no disc and no cap.
const EPS_H: f64 = 1e-9;
/// Slack on the "one disc contains the other" test, so `sqrt(1 - k*k)` is never
/// handed a negative.
const EPS_CONTAIN: f64 = 1e-12;
/// Contours below this area (px^2) are slivers, not shapes. `i_overlay`'s
/// `min_output_area` defaults to 0, and for f64 over the i32 engine its
/// `clean_result` is false, so this filtering is ours to do.
const MIN_AREA: f64 = 1e-6;

/// Line-end style. Codes are part of the R<->Rust ABI and must match
/// `.lineend_codes` in `R/paint.R`.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Cap {
    Round,
    Butt,
    Square,
}

impl Cap {
    pub fn from_code(code: i32) -> Cap {
        match code {
            1 => Cap::Butt,
            2 => Cap::Square,
            _ => Cap::Round,
        }
    }
}

/// Corner style. Codes must match `.linejoin_codes` in `R/paint.R`.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Join {
    Round,
    Miter,
    Bevel,
}

impl Join {
    pub fn from_code(code: i32) -> Join {
        match code {
            1 => Join::Miter,
            2 => Join::Bevel,
            _ => Join::Round,
        }
    }
}

/// The pen: how ends and corners are shaped, and how finely arcs are flattened.
#[derive(Clone, Debug)]
pub struct Nib {
    pub cap: Cap,
    pub join: Join,
    pub miter: f64,
    /// Points per full circle; `0` means auto (about one point per pixel of arc,
    /// the convention `curve_steps` follows for the constant-width path).
    pub arc: usize,
}

impl Default for Nib {
    fn default() -> Self {
        Nib {
            cap: Cap::Round,
            join: Join::Round,
            miter: 10.0,
            arc: 0,
        }
    }
}

type Pt = [f64; 2];
type Contour = Vec<Pt>;

/// Twice the signed area (the shoelace sum). Positive is counter-clockwise.
pub(crate) fn area2(c: &[Pt]) -> f64 {
    let n = c.len();
    let mut s = 0.0;
    for i in 0..n {
        let j = (i + 1) % n;
        s += c[i][0] * c[j][1] - c[j][0] * c[i][1];
    }
    s
}

/// Push a contour, normalised counter-clockwise, dropping slivers.
///
/// The normalisation is what makes the non-zero self-union a union rather than a
/// symmetric difference; see the module docs.
fn push_ccw(out: &mut Vec<Contour>, mut c: Contour) {
    if c.len() < 3 {
        return;
    }
    let a2 = area2(&c);
    if a2.abs() * 0.5 < MIN_AREA {
        return;
    }
    if a2 < 0.0 {
        c.reverse();
    }
    out.push(c);
}

/// A disc as an inscribed polygon. Inscribed rather than circumscribed, so it
/// under-covers the way the constant-width path's curve flattening does and the
/// two stay area-comparable.
fn disc(c: Pt, r: f64, arc: usize) -> Contour {
    let steps = if arc > 0 {
        arc.clamp(3, 4096)
    } else {
        ((2.0 * std::f64::consts::PI * r).ceil() as usize).clamp(8, 96)
    };
    (0..steps)
        .map(|i| {
            let t = 2.0 * std::f64::consts::PI * (i as f64) / (steps as f64);
            [c[0] + r * t.cos(), c[1] + r * t.sin()]
        })
        .collect()
}

/// One segment's tangent points: start-plus, end-plus, end-minus, start-minus.
struct Sweep {
    ap: Pt,
    bp: Pt,
    bm: Pt,
    am: Pt,
}

/// External-tangent quad for the sweep from `(a, ha)` to `(b, hb)`.
///
/// `None` when one end disc contains the other, in which case the discs alone
/// already cover the sweep.
fn sweep(a: Pt, b: Pt, ha: f64, hb: f64) -> Option<Sweep> {
    let (dx, dy) = (b[0] - a[0], b[1] - a[1]);
    let l = (dx * dx + dy * dy).sqrt();
    let dh = hb - ha;
    if l <= dh.abs() + EPS_CONTAIN || l <= EPS_PT {
        return None;
    }
    let (ux, uy) = (dx / l, dy / l);
    let (nx, ny) = (-uy, ux);
    let k = dh / l;
    let c = (1.0 - k * k).max(0.0).sqrt();
    // `m` satisfies m.u == -k, so the line through a + ha*m and b + hb*m is
    // tangent to both discs: ((b + hb*m) - (a + ha*m)).m == L*(u.m) + dh == 0.
    let mp = [-k * ux + c * nx, -k * uy + c * ny];
    let mm = [-k * ux - c * nx, -k * uy - c * ny];
    Some(Sweep {
        ap: [a[0] + ha * mp[0], a[1] + ha * mp[1]],
        bp: [b[0] + hb * mp[0], b[1] + hb * mp[1]],
        bm: [b[0] + hb * mm[0], b[1] + hb * mm[1]],
        am: [a[0] + ha * mm[0], a[1] + ha * mm[1]],
    })
}

/// Shorter of the two segment lengths meeting at vertex `i`.
fn seg_len(p: &[Pt], i: usize, n: usize) -> f64 {
    let d = |a: Pt, b: Pt| ((b[0] - a[0]).powi(2) + (b[1] - a[1]).powi(2)).sqrt();
    let before = p[if i == 0 { n - 1 } else { i - 1 }];
    let after = p[(i + 1) % n];
    d(before, p[i]).min(d(p[i], after))
}

/// Unit direction of the segment `a -> b`, or `(0, 0)` for a degenerate segment.
fn unit_dir(a: Pt, b: Pt) -> (f64, f64) {
    let (dx, dy) = (b[0] - a[0], b[1] - a[1]);
    let l = (dx * dx + dy * dy).sqrt();
    if l <= EPS_PT {
        return (0.0, 0.0);
    }
    (dx / l, dy / l)
}

/// Unit normal of the segment `a -> b`, or `(0, 0)` for a degenerate segment.
fn unit_normal(a: Pt, b: Pt) -> (f64, f64) {
    let (dx, dy) = (b[0] - a[0], b[1] - a[1]);
    let l = (dx * dx + dy * dy).sqrt();
    if l <= EPS_PT {
        return (0.0, 0.0);
    }
    (-dy / l, dx / l)
}

/// Where the lines `p0 + t*d0` and `p1 + s*d1` meet, if they do.
fn line_meet(p0: Pt, d0: Pt, p1: Pt, d1: Pt) -> Option<Pt> {
    let den = d0[0] * d1[1] - d0[1] * d1[0];
    if den.abs() < 1e-12 {
        return None;
    }
    let t = ((p1[0] - p0[0]) * d1[1] - (p1[1] - p0[1]) * d1[0]) / den;
    Some([p0[0] + t * d0[0], p0[1] + t * d0[1]])
}

/// Contours (device px) covering the variable-width stroke of one polyline.
///
/// The contours may overlap; the caller unions them. Every contour is wound
/// counter-clockwise. `hw` holds the **half**-width at each vertex.
pub fn ribbon_contours(
    px: &[f64],
    py: &[f64],
    hw: &[f64],
    closed: bool,
    nib: &Nib,
) -> Vec<Contour> {
    // Dedupe coincident points, keeping the larger half-width: the disc there
    // still has to cover what both vertices asked for. A non-finite coordinate
    // is dropped, the way a drawn polyline breaks at one.
    let n0 = px.len().min(py.len()).min(hw.len());
    let mut p: Vec<Pt> = Vec::with_capacity(n0);
    let mut h: Vec<f64> = Vec::with_capacity(n0);
    for i in 0..n0 {
        let (x, y) = (px[i], py[i]);
        if !x.is_finite() || !y.is_finite() {
            continue;
        }
        let hi = if hw[i].is_finite() { hw[i].max(0.0) } else { 0.0 };
        let mut merged = false;
        if let (Some(&last), Some(lh)) = (p.last(), h.last_mut()) {
            if (x - last[0]).abs() < EPS_PT && (y - last[1]).abs() < EPS_PT {
                *lh = lh.max(hi);
                merged = true;
            }
        }
        if !merged {
            p.push([x, y]);
            h.push(hi);
        }
    }
    // On a ring, a repeated final point is the same vertex as the first.
    if closed && p.len() > 1 {
        let (f, l) = (p[0], p[p.len() - 1]);
        if (f[0] - l[0]).abs() < EPS_PT && (f[1] - l[1]).abs() < EPS_PT {
            let hl = h.pop().unwrap_or(0.0);
            p.pop();
            h[0] = h[0].max(hl);
        }
    }
    let n = p.len();
    if n < 2 || h.iter().all(|&v| v <= EPS_H) {
        return Vec::new();
    }

    let nseg = if closed { n } else { n - 1 };
    let mut out: Vec<Contour> = Vec::new();
    let mut sweeps: Vec<Option<Sweep>> = Vec::with_capacity(nseg);

    for i in 0..nseg {
        let j = (i + 1) % n;
        let mut s = sweep(p[i], p[j], h[i], h[j]);
        // A flat cap ends on the perpendicular chord through the end vertex. The
        // tangent chord is tilted and sits *inside* the end disc whenever the
        // width varies, so without this a tapering stroke would start short of
        // its own first vertex. At constant width the two coincide.
        if !closed && nib.cap != Cap::Round {
            if let Some(sw) = s.as_mut() {
                let (nx, ny) = unit_normal(p[i], p[j]);
                if i == 0 {
                    sw.ap = [p[i][0] + h[i] * nx, p[i][1] + h[i] * ny];
                    sw.am = [p[i][0] - h[i] * nx, p[i][1] - h[i] * ny];
                }
                if i == nseg - 1 {
                    sw.bp = [p[j][0] + h[j] * nx, p[j][1] + h[j] * ny];
                    sw.bm = [p[j][0] - h[j] * nx, p[j][1] - h[j] * ny];
                }
            }
        }
        if let Some(sw) = &s {
            push_ccw(&mut out, vec![sw.ap, sw.bp, sw.bm, sw.am]);
        }
        sweeps.push(s);
    }

    // Joins: every interior vertex of an open polyline, every vertex of a ring.
    let joins: Vec<usize> = if closed {
        (0..n).collect()
    } else if n > 2 {
        (1..n - 1).collect()
    } else {
        Vec::new()
    };
    for &i in &joins {
        if h[i] <= EPS_H {
            continue;
        }
        match nib.join {
            Join::Round => push_ccw(&mut out, disc(p[i], h[i], nib.arc)),
            Join::Bevel | Join::Miter => {
                let prev = if i == 0 { nseg - 1 } else { i - 1 };
                let (a, b) = (&sweeps[prev], &sweeps[i]);
                if let (Some(a), Some(b)) = (a, b) {
                    // Which side the corner opens on. `n = (-uy, ux)` is the left
                    // normal, so a left turn (cross > 0) puts the convex side on
                    // the minus side.
                    let (ux0, uy0) =
                        unit_dir(p[if i == 0 { n - 1 } else { i - 1 }], p[i]);
                    let (ux1, uy1) = unit_dir(p[i], p[(i + 1) % n]);
                    let cross = ux0 * uy1 - uy0 * ux1;

                    // Sides to stitch, as (start-tangent, end-tangent) pairs.
                    // Only the convex side has a notch: on the concave side the
                    // two trapezoids' inner edges cross, so the union already
                    // covers it, and a triangle there would poke out through the
                    // outer boundary once the turn exceeds a right angle.
                    // A collinear vertex (a width change on a straight run) opens
                    // a notch on *both* sides, because the tangent tilt changes
                    // symmetrically.
                    let plus = (a.ap, a.bp, b.ap, b.bp);
                    let minus = (a.am, a.bm, b.am, b.bm);
                    let sides: &[(Pt, Pt, Pt, Pt)] = if cross.abs() <= EPS_PT {
                        &[plus, minus]
                    } else if cross < 0.0 {
                        &[plus]
                    } else {
                        &[minus]
                    };

                    // How far back along each segment the wedge reaches. A
                    // wedge with its apex exactly on the vertex would touch the
                    // two trapezoids edge-on rather than overlapping them, and
                    // edge-on contact does not survive the overlay's integer
                    // grid: it bridges the pieces with a zero-width spur instead
                    // of merging them. Reaching back inside both guarantees a
                    // positive-area overlap.
                    let back = (0.25 * h[i])
                        .min(0.25 * seg_len(&p, i, n))
                        .max(EPS_H);
                    let cprev = [p[i][0] - back * ux0, p[i][1] - back * uy0];
                    let cnext = [p[i][0] + back * ux1, p[i][1] + back * uy1];

                    for &(a0, a1, b0, b1) in sides {
                        // The bevel: closes the notch between the two
                        // trapezoids, as two overlapping triangles rather than
                        // one that merely touches.
                        push_ccw(&mut out, vec![a1, b0, cprev]);
                        push_ccw(&mut out, vec![a1, b0, cnext]);
                        if nib.join == Join::Miter {
                            let din = [a1[0] - a0[0], a1[1] - a0[1]];
                            let dout = [b1[0] - b0[0], b1[1] - b0[1]];
                            if let Some(apex) = line_meet(a0, din, b0, dout) {
                                let d = ((apex[0] - p[i][0]).powi(2)
                                    + (apex[1] - p[i][1]).powi(2))
                                .sqrt();
                                if d / h[i] <= nib.miter {
                                    push_ccw(&mut out, vec![a1, apex, b0]);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Caps, only on an open polyline. `Butt` needs no contour of its own -- the
    // perpendicular override above already ended the terminal trapezoid exactly
    // on the end vertex.
    if !closed {
        for end in [0usize, n - 1] {
            if h[end] <= EPS_H {
                continue;
            }
            match nib.cap {
                Cap::Round => push_ccw(&mut out, disc(p[end], h[end], nib.arc)),
                Cap::Butt => {}
                Cap::Square => {
                    let other = if end == 0 { 1 } else { n - 2 };
                    let (dx, dy) = (p[end][0] - p[other][0], p[end][1] - p[other][1]);
                    let l = (dx * dx + dy * dy).sqrt();
                    if l <= EPS_PT {
                        continue;
                    }
                    let (ux, uy) = (dx / l, dy / l);
                    let (nx, ny) = (-uy, ux);
                    let hh = h[end];
                    let base = p[end];
                    let tip = [base[0] + hh * ux, base[1] + hh * uy];
                    push_ccw(
                        &mut out,
                        vec![
                            [base[0] + hh * nx, base[1] + hh * ny],
                            [tip[0] + hh * nx, tip[1] + hh * ny],
                            [tip[0] - hh * nx, tip[1] - hh * ny],
                            [base[0] - hh * nx, base[1] - hh * ny],
                        ],
                    );
                }
            }
        }
    }

    out
}

/// Clean outline of a whole multi-sub-path variable-width stroke.
///
/// `nper` gives the point count of each sub-path in `x`/`y`; `hw` is parallel to
/// them and holds half-widths in device px. Returns `(x, y, nper)` in the same
/// shape [`crate::booleans::path_op`] does.
pub fn variable_stroke(
    x: &[f64],
    y: &[f64],
    nper: &[i32],
    hw: &[f64],
    closed: bool,
    nib: &Nib,
) -> (Vec<f64>, Vec<f64>, Vec<i32>) {
    let n = x.len().min(y.len()).min(hw.len());
    let mut contours: Vec<Contour> = Vec::new();
    let mut at = 0usize;
    for &cnt in nper {
        let cnt = cnt.max(0) as usize;
        let hi = (at + cnt).min(n);
        if cnt >= 2 && at < hi {
            contours.extend(ribbon_contours(
                &x[at..hi],
                &y[at..hi],
                &hw[at..hi],
                closed,
                nib,
            ));
        }
        at += cnt;
    }
    let empty = (Vec::new(), Vec::new(), Vec::new());
    if contours.is_empty() {
        return empty;
    }
    let shapes = contours.simplify_shape(FillRule::NonZero);
    let (ox, oy, onper) = crate::booleans::flatten_shapes(shapes);
    if onper.is_empty() {
        return empty;
    }
    // Drop sliver contours the overlay leaves behind (see MIN_AREA).
    let (mut kx, mut ky, mut knper) = (Vec::new(), Vec::new(), Vec::new());
    let mut off = 0usize;
    for &len in &onper {
        let len = len as usize;
        let c: Contour = (0..len).map(|i| [ox[off + i], oy[off + i]]).collect();
        if area2(&c).abs() * 0.5 >= MIN_AREA {
            knper.push(len as i32);
            for pt in &c {
                kx.push(pt[0]);
                ky.push(pt[1]);
            }
        }
        off += len;
    }
    if knper.is_empty() {
        return empty;
    }
    (kx, ky, knper)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Net area of a flat `(x, y, nper)` result.
    ///
    /// Signed, then absolute at the end: holes come back wound opposite their
    /// outer contour, so they must subtract. Summing `|area|` per contour would
    /// make a ring's hole *add* to its area.
    fn total_area(x: &[f64], y: &[f64], nper: &[i32]) -> f64 {
        let mut at = 0usize;
        let mut t = 0.0;
        for &len in nper {
            let len = len as usize;
            let c: Vec<Pt> = (0..len).map(|i| [x[at + i], y[at + i]]).collect();
            t += area2(&c) * 0.5;
            at += len;
        }
        t.abs()
    }

    fn horiz(l: f64, ha: f64, hb: f64, nib: &Nib) -> (Vec<f64>, Vec<f64>, Vec<i32>) {
        variable_stroke(&[0.0, l], &[0.0, 0.0], &[2], &[ha, hb], false, nib)
    }

    fn butt_bevel() -> Nib {
        Nib { cap: Cap::Butt, join: Join::Bevel, miter: 10.0, arc: 0 }
    }

    #[test]
    fn constant_width_is_a_rectangle() {
        let (x, y, n) = horiz(20.0, 3.0, 3.0, &butt_bevel());
        assert_eq!(n.len(), 1);
        let a = total_area(&x, &y, &n);
        assert!((a - 120.0).abs() < 1e-6, "area {a}");
        let (lo, hi) = (
            y.iter().cloned().fold(f64::INFINITY, f64::min),
            y.iter().cloned().fold(f64::NEG_INFINITY, f64::max),
        );
        assert!((lo + 3.0).abs() < 1e-9 && (hi - 3.0).abs() < 1e-9);
    }

    #[test]
    fn taper_to_a_point_reaches_the_endpoint() {
        // The tangent construction puts the tip exactly at the endpoint. A
        // perpendicular-offset implementation lands short of it, so this test is
        // what pins the construction.
        let (l, h) = (20.0, 4.0);
        let (x, y, n) = horiz(l, h, 0.0, &butt_bevel());
        let max_x = x.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        assert!((max_x - l).abs() < 1e-6, "tip at {max_x}, want {l}");
        // A butt cap ends on the perpendicular chord, so this is the clean
        // triangle: base 2h at the start, apex at the far vertex.
        let want = h * l;
        let got = total_area(&x, &y, &n);
        assert!((got - want).abs() / want < 0.005, "area {got}, want {want}");
    }

    #[test]
    fn steep_taper_is_not_pinched() {
        // h comparable to L is where perpendicular offsets waist the needle.
        let (x, y, n) = horiz(6.0, 5.0, 0.0, &butt_bevel());
        assert!(!n.is_empty());
        let at_start: Vec<f64> = x
            .iter()
            .zip(y.iter())
            .filter(|(px, _)| px.abs() < 1e-9)
            .map(|(_, py)| *py)
            .collect();
        assert_eq!(at_start.len(), 2, "want both sides at x = 0");
        let w = (at_start[0] - at_start[1]).abs();
        assert!((w - 10.0).abs() < 1e-9, "width at the butt end is {w}, want 10");
    }

    #[test]
    fn no_point_escapes_the_true_hull() {
        let n = 20usize;
        let px: Vec<f64> = (0..n).map(|i| i as f64 * 5.0).collect();
        let py: Vec<f64> = (0..n).map(|i| (i as f64 * 0.4).sin() * 8.0).collect();
        let hw: Vec<f64> = (0..n).map(|i| 6.0 * (1.0 - i as f64 / n as f64)).collect();
        let (x, y, nper) = variable_stroke(&px, &py, &[n as i32], &hw, false, &Nib::default());
        assert!(!nper.is_empty());
        for (ox, oy) in x.iter().zip(y.iter()) {
            // Distance to the swept region: minimise |q - c(t)| - h(t) over the
            // whole segment. Sampling only the perpendicular projection would
            // under-estimate coverage, because the envelope touches each disc at
            // a point rotated back from the normal by asin(k).
            let mut best = f64::INFINITY;
            for i in 0..n - 1 {
                let (ax, ay, bx, by) = (px[i], py[i], px[i + 1], py[i + 1]);
                for k in 0..=200 {
                    let t = k as f64 / 200.0;
                    let (cx, cy) = (ax + t * (bx - ax), ay + t * (by - ay));
                    let d = ((ox - cx).powi(2) + (oy - cy).powi(2)).sqrt();
                    let h = hw[i] + t * (hw[i + 1] - hw[i]);
                    best = best.min(d - h);
                }
            }
            // Tolerance covers the sampling step and the inscribed-disc chord.
            assert!(best <= 0.05, "point escapes the swept region by {best}");
        }
    }

    #[test]
    fn the_tangent_line_touches_both_end_discs() {
        // This is what pins the construction. A tangent line is at distance
        // exactly h_a from a and h_b from b. The perpendicular-offset line
        // through a + h_a*n and b + h_b*n is not: when the width varies it is
        // tilted, so its distance from a is h_a/sqrt(1 + k^2) < h_a -- it cuts
        // into the end disc, which is what waists a taper.
        let (a, b) = ([0.0, 0.0], [20.0, 0.0]);
        let (ha, hb) = (4.0, 1.0);
        let sw = sweep(a, b, ha, hb).expect("segment is longer than the width step");

        // Distance from a point to the line through u and v.
        let dist = |q: Pt, u: Pt, v: Pt| {
            let (dx, dy) = (v[0] - u[0], v[1] - u[1]);
            let l = (dx * dx + dy * dy).sqrt();
            ((q[0] - u[0]) * dy - (q[1] - u[1]) * dx).abs() / l
        };

        for (u, v) in [(sw.ap, sw.bp), (sw.am, sw.bm)] {
            assert!((dist(a, u, v) - ha).abs() < 1e-12, "start: {}", dist(a, u, v));
            assert!((dist(b, u, v) - hb).abs() < 1e-12, "end: {}", dist(b, u, v));
        }

        // And the perpendicular construction genuinely differs, so the test is
        // not vacuous.
        let k = (hb - ha) / 20.0;
        let perp = ha / (1.0 + k * k).sqrt();
        assert!(perp < ha - 1e-6, "perpendicular offset should undershoot");
    }

    #[test]
    fn zero_length_segment_is_dropped() {
        let plain = horiz(20.0, 3.0, 3.0, &butt_bevel());
        let dup = variable_stroke(
            &[0.0, 10.0, 10.0, 20.0],
            &[0.0, 0.0, 0.0, 0.0],
            &[4],
            &[3.0, 3.0, 3.0, 3.0],
            false,
            &butt_bevel(),
        );
        let (a, b) = (
            total_area(&plain.0, &plain.1, &plain.2),
            total_area(&dup.0, &dup.1, &dup.2),
        );
        assert!((a - b).abs() < 1e-9, "{a} vs {b}");
    }

    #[test]
    fn single_point_polyline_is_empty() {
        let (x, y, n) = variable_stroke(&[1.0], &[1.0], &[1], &[4.0], false, &Nib::default());
        assert!(x.is_empty() && y.is_empty() && n.is_empty());
    }

    #[test]
    fn concave_turn_makes_one_solid() {
        // A sharp V with a half-width close to the leg length: the union must
        // close it into a single solid, with no hole and no double-counting.
        let (x, y, n) = variable_stroke(
            &[0.0, 10.0, 20.0],
            &[0.0, 2.0, 0.0],
            &[3],
            &[6.0, 6.0, 6.0],
            false,
            &Nib::default(),
        );
        assert_eq!(n.len(), 1, "want one contour, got {}", n.len());
        assert!(total_area(&x, &y, &n) > 0.0);
    }

    #[test]
    fn closed_ring_has_a_hole() {
        let (x, y, n) = variable_stroke(
            &[0.0, 40.0, 40.0, 0.0],
            &[0.0, 0.0, 40.0, 40.0],
            &[4],
            &[2.0, 2.0, 2.0, 2.0],
            true,
            &butt_bevel(),
        );
        assert_eq!(n.len(), 2, "want an outer contour and a hole");
        // The two contours are wound oppositely, which is what "winding" wants.
        let mut signs = Vec::new();
        let mut at = 0usize;
        for &len in &n {
            let len = len as usize;
            let c: Vec<Pt> = (0..len).map(|i| [x[at + i], y[at + i]]).collect();
            signs.push(area2(&c).signum());
            at += len;
        }
        assert!(signs[0] * signs[1] < 0.0, "contours wound the same way");
        // Ring area ~ perimeter * 2h.
        let a = total_area(&x, &y, &n);
        let want = 160.0 * 4.0;
        assert!((a - want).abs() / want < 0.05, "area {a}, want ~{want}");
    }

    #[test]
    fn zero_in_the_middle_splits_the_stroke() {
        let (x, y, n) = variable_stroke(
            &[0.0, 30.0, 60.0],
            &[0.0, 0.0, 0.0],
            &[3],
            &[5.0, 0.0, 5.0],
            false,
            &butt_bevel(),
        );
        assert_eq!(n.len(), 2, "a pinch to zero splits the ribbon");
        assert!(total_area(&x, &y, &n) > 0.0);
    }

    #[test]
    fn orientation_of_the_input_does_not_matter() {
        let px = [0.0, 10.0, 22.0, 30.0];
        let py = [0.0, 9.0, -4.0, 3.0];
        let hw = [5.0, 4.0, 3.0, 1.0];
        let fwd = variable_stroke(&px, &py, &[4], &hw, false, &Nib::default());
        let rpx: Vec<f64> = px.iter().rev().cloned().collect();
        let rpy: Vec<f64> = py.iter().rev().cloned().collect();
        let rhw: Vec<f64> = hw.iter().rev().cloned().collect();
        let rev = variable_stroke(&rpx, &rpy, &[4], &rhw, false, &Nib::default());
        let (a, b) = (
            total_area(&fwd.0, &fwd.1, &fwd.2),
            total_area(&rev.0, &rev.1, &rev.2),
        );
        assert!((a - b).abs() < 1e-9, "{a} vs {b}");
    }

    #[test]
    fn bad_widths_are_clamped() {
        let (x, y, n) = variable_stroke(
            &[0.0, 10.0, 20.0, 30.0],
            &[0.0, 0.0, 0.0, 0.0],
            &[4],
            &[4.0, -1.0, f64::NAN, f64::INFINITY],
            false,
            &Nib::default(),
        );
        assert!(x.iter().all(|v| v.is_finite()));
        assert!(y.iter().all(|v| v.is_finite()));
        let _ = total_area(&x, &y, &n);
    }

    #[test]
    fn caps_change_the_extent() {
        let mk = |cap| {
            let nib = Nib { cap, join: Join::Bevel, miter: 10.0, arc: 0 };
            horiz(20.0, 3.0, 3.0, &nib)
        };
        let (bx, by, bn) = mk(Cap::Butt);
        let (rx, ry, rn) = mk(Cap::Round);
        let (sx, sy, sn) = mk(Cap::Square);
        let min_x = |v: &Vec<f64>| v.iter().cloned().fold(f64::INFINITY, f64::min);
        assert!(min_x(&bx).abs() < 1e-9, "butt should start at 0");
        assert!((min_x(&sx) + 3.0).abs() < 1e-9, "square should reach -3");
        assert!(min_x(&rx) < -2.9, "round should reach about -3");
        let (a, b, c) = (
            total_area(&bx, &by, &bn),
            total_area(&rx, &ry, &rn),
            total_area(&sx, &sy, &sn),
        );
        assert!(a < b && b < c, "butt {a} < round {b} < square {c}");
    }

    #[test]
    fn mitre_limit_falls_back_to_bevel() {
        let go = |join, miter| {
            let nib = Nib { cap: Cap::Butt, join, miter, arc: 0 };
            let r = variable_stroke(
                &[0.0, 20.0, 22.0],
                &[0.0, 0.0, 14.0],
                &[3],
                &[4.0, 4.0, 4.0],
                false,
                &nib,
            );
            total_area(&r.0, &r.1, &r.2)
        };
        let bevel = go(Join::Bevel, 10.0);
        let tight = go(Join::Miter, 1.0);
        let loose = go(Join::Miter, 10.0);
        assert!((tight - bevel).abs() < 1e-9, "tight mitre {tight} != bevel {bevel}");
        assert!(loose > bevel + 1e-6, "loose mitre {loose} should exceed bevel {bevel}");
    }

    #[test]
    fn joins_leave_no_notch() {
        // A taper along a finely subdivided straight line: the tangent tilt
        // changes at every vertex, so without the stitch triangles a hairline
        // notch opens at each one. Area must match the analytic integral of 2h.
        let n = 60usize;
        let l = 120.0;
        let px: Vec<f64> = (0..n).map(|i| l * i as f64 / (n - 1) as f64).collect();
        let py = vec![0.0; n];
        let hw: Vec<f64> = (0..n)
            .map(|i| 1.0 + 7.0 * (i as f64 / (n - 1) as f64))
            .collect();
        let nib = Nib { cap: Cap::Butt, join: Join::Bevel, miter: 10.0, arc: 0 };
        let (x, y, nper) = variable_stroke(&px, &py, &[n as i32], &hw, false, &nib);
        assert_eq!(nper.len(), 1, "a notch would split or hole the ribbon");
        let got = total_area(&x, &y, &nper);
        let want = l * (1.0 + 8.0); // trapezoid: L * (h_a + h_b)
        assert!((got - want).abs() / want < 0.005, "area {got}, want {want}");
    }

    #[test]
    fn a_tapered_join_leaves_no_spur() {
        // Regression: the join wedge used to have its apex exactly on both
        // trapezoids' end chords, so it touched them edge-on. Edge-on contact
        // does not survive the overlay's integer grid -- the union bridged the
        // pieces with a zero-width spur that ran from the outer corner all the
        // way in to the centreline vertex and back. Caught by eye in a render,
        // not by any area or contour-count assertion, so it is pinned here.
        //
        // The invariant: with a positive half-width everywhere, no boundary point
        // may come near the centreline.
        for join in [Join::Bevel, Join::Miter] {
            let nib = Nib { cap: Cap::Butt, join, miter: 10.0, arc: 0 };
            let p = [[38.4, 326.4], [307.2, 192.0], [115.2, 46.1]];
            let hw = [30.0, 18.35, 9.0];
            let (x, y, nper) =
                variable_stroke(&[p[0][0], p[1][0], p[2][0]], &[p[0][1], p[1][1], p[2][1]],
                                &[3], &hw, false, &nib);
            assert_eq!(nper.len(), 1, "{join:?}: want one contour");
            let mut nearest = f64::INFINITY;
            for (ox, oy) in x.iter().zip(y.iter()) {
                let d = ((ox - p[1][0]).powi(2) + (oy - p[1][1]).powi(2)).sqrt();
                nearest = nearest.min(d);
            }
            assert!(
                nearest > 0.5 * hw[1],
                "{join:?}: boundary reaches {nearest:.2} from the corner vertex, \
                 within half its {} half-width -- that is the spur",
                hw[1]
            );
            // A duplicated vertex is the other signature of the same bug.
            for w in x.windows(2).zip(y.windows(2)) {
                let (xs, ys) = w;
                assert!(
                    (xs[0] - xs[1]).abs() > 1e-9 || (ys[0] - ys[1]).abs() > 1e-9,
                    "{join:?}: duplicated boundary vertex"
                );
            }
        }
    }

    #[test]
    fn output_is_well_formed() {
        let n = 500usize;
        let px: Vec<f64> = (0..n).map(|i| i as f64 * 0.8).collect();
        let py: Vec<f64> = (0..n).map(|i| (i as f64 * 0.05).sin() * 30.0).collect();
        let hw: Vec<f64> = (0..n)
            .map(|i| 0.5 + 5.0 * (1.0 - i as f64 / n as f64))
            .collect();
        let (x, y, nper) = variable_stroke(&px, &py, &[n as i32], &hw, false, &Nib::default());
        assert!(!nper.is_empty());
        assert!(nper.iter().all(|&l| l >= 3));
        assert_eq!(x.len(), y.len());
        assert_eq!(x.len(), nper.iter().map(|&l| l as usize).sum::<usize>());
        assert!(x.iter().chain(y.iter()).all(|v| v.is_finite()));
    }

    #[test]
    fn code_tables_match_the_r_side() {
        assert_eq!(Cap::from_code(0), Cap::Round);
        assert_eq!(Cap::from_code(1), Cap::Butt);
        assert_eq!(Cap::from_code(2), Cap::Square);
        assert_eq!(Join::from_code(0), Join::Round);
        assert_eq!(Join::from_code(1), Join::Miter);
        assert_eq!(Join::from_code(2), Join::Bevel);
    }
}

