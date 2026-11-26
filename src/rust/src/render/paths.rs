//! Backend-independent path geometry: shape builders shared by the scene walk
//! and the backends, ring flattening, and hatch-line generation.

use super::*;

/// Flatten a path into closed rings of points (device-local px), so a scanline
/// algorithm can work on straight edges. Curves are subdivided by chord length.
pub fn flatten_rings(path: &Path) -> Vec<Vec<(f32, f32)>> {
    let mut rings: Vec<Vec<(f32, f32)>> = Vec::new();
    let mut cur: Vec<(f32, f32)> = Vec::new();
    let steps = |a: (f32, f32), b: (f32, f32)| {
        let d = ((b.0 - a.0).powi(2) + (b.1 - a.1).powi(2)).sqrt();
        (d.ceil() as usize).clamp(2, 24)
    };
    for seg in path.segments() {
        use tiny_skia::PathSegment::*;
        match seg {
            MoveTo(p) => {
                if cur.len() >= 3 {
                    rings.push(std::mem::take(&mut cur));
                } else {
                    cur.clear();
                }
                cur.push((p.x, p.y));
            }
            LineTo(p) => cur.push((p.x, p.y)),
            QuadTo(c, p) => {
                let a = *cur.last().unwrap_or(&(c.x, c.y));
                let n = steps(a, (p.x, p.y));
                for i in 1..=n {
                    let t = i as f32 / n as f32;
                    let mt = 1.0 - t;
                    cur.push((
                        mt * mt * a.0 + 2.0 * mt * t * c.x + t * t * p.x,
                        mt * mt * a.1 + 2.0 * mt * t * c.y + t * t * p.y,
                    ));
                }
            }
            CubicTo(c1, c2, p) => {
                let a = *cur.last().unwrap_or(&(c1.x, c1.y));
                let n = steps(a, (p.x, p.y));
                for i in 1..=n {
                    let t = i as f32 / n as f32;
                    let mt = 1.0 - t;
                    cur.push((
                        mt * mt * mt * a.0
                            + 3.0 * mt * mt * t * c1.x
                            + 3.0 * mt * t * t * c2.x
                            + t * t * t * p.x,
                        mt * mt * mt * a.1
                            + 3.0 * mt * mt * t * c1.y
                            + 3.0 * mt * t * t * c2.y
                            + t * t * t * p.y,
                    ));
                }
            }
            Close => {
                if cur.len() >= 3 {
                    rings.push(std::mem::take(&mut cur));
                } else {
                    cur.clear();
                }
            }
        }
    }
    if cur.len() >= 3 {
        rings.push(cur);
    }
    rings
}

/// Build the hatch lines for a shape: the parts of a family of parallel lines
/// that fall *inside* it, as a stroke-ready path.
///
/// Computed by scanline crossing rather than by clipping. Clipping would mean a
/// page-sized mask per hatched shape (and the raster clip cache is keyed on the
/// viewport id, so an ad-hoc clip would collide with it), whereas this emits only
/// the spans that are actually drawn -- which is also far less SVG.
///
/// `angle` is in degrees counter-clockwise, `spacing` in device px. Spans are
/// paired even-odd, the standard rule for hatching.
pub fn hatch_path(path: &Path, angle: f64, spacing: f64) -> Option<Path> {
    if !(spacing > 0.0) {
        return None;
    }
    let rings = flatten_rings(path);
    if rings.is_empty() {
        return None;
    }
    // Rotate into a frame where the hatch lines are horizontal, scan, rotate back.
    let th = -(angle.to_radians()) as f32;
    let (c, s) = (th.cos(), th.sin());
    let fwd = |p: (f32, f32)| (p.0 * c - p.1 * s, p.0 * s + p.1 * c);
    let inv = |p: (f32, f32)| (p.0 * c + p.1 * s, -p.0 * s + p.1 * c);

    let rot: Vec<Vec<(f32, f32)>> = rings
        .iter()
        .map(|r| r.iter().map(|&p| fwd(p)).collect())
        .collect();
    let (mut lo, mut hi) = (f32::INFINITY, f32::NEG_INFINITY);
    for r in &rot {
        for p in r {
            lo = lo.min(p.1);
            hi = hi.max(p.1);
        }
    }
    if !lo.is_finite() || !hi.is_finite() || hi <= lo {
        return None;
    }
    // Anchor the ladder to a global grid, so abutting shapes hatch in register
    // instead of each starting from its own top edge.
    let sp = spacing as f32;
    let start = (lo / sp).ceil() * sp;
    let mut pb = PathBuilder::new();
    let mut xs: Vec<f32> = Vec::new();
    let mut y = start;
    // Guard against a pathological spacing producing millions of lines.
    let max_lines = 20_000;
    let mut drawn = 0;
    while y <= hi && drawn < max_lines {
        xs.clear();
        for r in &rot {
            let n = r.len();
            for i in 0..n {
                let (x1, y1) = r[i];
                let (x2, y2) = r[(i + 1) % n];
                // Half-open in y so a vertex on the scanline counts once.
                if (y1 <= y && y2 > y) || (y2 <= y && y1 > y) {
                    let t = (y - y1) / (y2 - y1);
                    xs.push(x1 + t * (x2 - x1));
                }
            }
        }
        if xs.len() >= 2 {
            xs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
            for pair in xs.chunks_exact(2) {
                let (a, b) = (inv((pair[0], y)), inv((pair[1], y)));
                pb.move_to(a.0, a.1);
                pb.line_to(b.0, b.1);
            }
        }
        y += sp;
        drawn += 1;
    }
    pb.finish()
}

pub fn rect_path(x: f64, y: f64, w: f64, h: f64) -> Option<Path> {
    let near = |v: f64| v.abs() <= crate::units::PRECISE_PX;
    if !(near(x) && near(y) && near(w) && near(h)) && [x, y, w, h].iter().all(|v| v.is_finite()) {
        // Far from the origin, the far edge is placed in f64 before narrowing:
        // a rect from -2e7 px, 2e7 px wide, ends on the page, not a pixel off
        // it (VR-45).
        return tiny_skia::Rect::from_ltrb(x as f32, y as f32, (x + w) as f32, (y + h) as f32)
            .map(PathBuilder::from_rect);
    }
    tiny_skia::Rect::from_xywh(x as f32, y as f32, w as f32, h as f32).map(PathBuilder::from_rect)
}

/// Append a circle to `pb`. Within [`crate::units::PRECISE_PX`] it is exactly
/// tiny-skia's `push_circle`. Further out its points are placed in f64 before
/// narrowing, so a huge circle whose edge crosses the page keeps that edge
/// where it is (VR-45). Its outline is chords that follow the circle within
/// [`FAR_ARC_TOL`] near the page ([`far_arc`]), from the east point and turning
/// the same way: four cubic quarter arcs miss a circle by 2.7e-4 of its radius
/// between their ends, 27 px for a radius of 1e5 px (VR-47).
pub fn push_circle_precise(pb: &mut PathBuilder, cx: f64, cy: f64, r: f64) {
    let lim = crate::units::PRECISE_PX;
    if (cx.abs() + r <= lim && cy.abs() + r <= lim)
        || !(cx.is_finite() && cy.is_finite() && r.is_finite())
    {
        pb.push_circle(cx as f32, cy as f32, r as f32);
        return;
    }
    if r <= 0.0 {
        return;
    }
    let mut pts = vec![(cx + r, cy)];
    far_arc(&mut pts, cx, cy, r, 0.0, -std::f64::consts::TAU);
    pts.pop(); // back at the start
    for (k, &(x, y)) in pts.iter().enumerate() {
        if k == 0 {
            pb.move_to(x as f32, y as f32);
        } else {
            pb.line_to(x as f32, y as f32);
        }
    }
    pb.close();
}

/// A rounded rectangle (top-left `(x, y)`, size `w`×`h`, corner radius `r` in the
/// same px units). `r` is clamped to half the shorter side; `r == 0` degrades to
/// a plain rect. Corners are cubic-Bézier quarter-circle approximations.
pub fn roundrect_path(x: f64, y: f64, w: f64, h: f64, r: f64) -> Option<Path> {
    if w <= 0.0 || h <= 0.0 {
        return None;
    }
    let r = r.max(0.0).min(w / 2.0).min(h / 2.0);
    if r <= 0.0 {
        return rect_path(x, y, w, h);
    }
    let kr = (r * 0.552_284_749_830_793_6) as f32; // control-point offset for a 90° arc
    let r = r as f32;
    let (x0, y0, x1, y1) = (x as f32, y as f32, (x + w) as f32, (y + h) as f32);
    let mut pb = PathBuilder::new();
    pb.move_to(x0 + r, y0);
    pb.line_to(x1 - r, y0);
    pb.cubic_to(x1 - r + kr, y0, x1, y0 + r - kr, x1, y0 + r);
    pb.line_to(x1, y1 - r);
    pb.cubic_to(x1, y1 - r + kr, x1 - r + kr, y1, x1 - r, y1);
    pb.line_to(x0 + r, y1);
    pb.cubic_to(x0 + r - kr, y1, x0, y1 - r + kr, x0, y1 - r);
    pb.line_to(x0, y0 + r);
    pb.cubic_to(x0, y0 + r - kr, x0 + r - kr, y0, x0 + r, y0);
    pb.close();
    pb.finish()
}

/// A regular hexagon centred at `(cx, cy)` with circumradius `r` (centre→vertex).
/// `flat` selects orientation: flat-top (a horizontal top/bottom edge) when true,
/// pointy-top (a vertex up/down) when false. `r <= 0` → `None`. A thin wrapper over
/// [`hexagon_path_xy`] with the regular relation between the two half-extents.
pub fn hexagon_path(cx: f64, cy: f64, r: f64, flat: bool) -> Option<Path> {
    if r <= 0.0 {
        return None;
    }
    let s = r * (3.0_f64).sqrt() * 0.5; // the short half-extent of a regular hex
    if flat {
        hexagon_path_xy(cx, cy, r, s, true)
    } else {
        hexagon_path_xy(cx, cy, s, r, false)
    }
}

/// A hexagon centred at `(cx, cy)` with independent horizontal half-extent `hx`
/// and vertical half-extent `hy` (each measured centre→edge along its own axis,
/// so the full width is `2*hx` and the full height is `2*hy`). `flat` selects
/// flat-top — vertices left/right at `(±hx, 0)`, horizontal edges at `±hy` — vs
/// pointy-top — vertices top/bottom at `(0, ±hy)`, vertical edges at `±hx`. A
/// regular hexagon is the special case `hy == hx*sqrt(3)/2` (flat) resp.
/// `hx == hy*sqrt(3)/2` (pointy). Non-positive or non-finite extents → `None`.
pub fn hexagon_path_xy(cx: f64, cy: f64, hx: f64, hy: f64, flat: bool) -> Option<Path> {
    if hx <= 0.0 || hy <= 0.0 || !cx.is_finite() || !cy.is_finite() {
        return None;
    }
    let corners: [(f64, f64); 6] = if flat {
        [
            (hx, 0.0),
            (hx * 0.5, hy),
            (-hx * 0.5, hy),
            (-hx, 0.0),
            (-hx * 0.5, -hy),
            (hx * 0.5, -hy),
        ]
    } else {
        [
            (0.0, hy),
            (hx, hy * 0.5),
            (hx, -hy * 0.5),
            (0.0, -hy),
            (-hx, -hy * 0.5),
            (-hx, hy * 0.5),
        ]
    };
    let mut pb = PathBuilder::new();
    for (k, (dx, dy)) in corners.iter().enumerate() {
        let (px, py) = ((cx + dx) as f32, (cy + dy) as f32);
        if k == 0 {
            pb.move_to(px, py);
        } else {
            pb.line_to(px, py);
        }
    }
    pb.close();
    pb.finish()
}

/// A sector's signed angular sweep, limited to one full turn. Anything past a
/// turn retraces the same ring, and sampling a sweep of thousands of turns with a
/// capped segment count joined points hundreds of radians apart: a star polygon
/// whose outline (and so the recorded box `scene_model()` reports) bore no
/// relation to the disc.
pub fn clamp_sweep(dtheta: f64) -> f64 {
    let tau = std::f64::consts::TAU;
    if dtheta.abs() > tau {
        tau.copysign(dtheta)
    } else {
        dtheta
    }
}

/// An annular sector centred at `(cx, cy)` spanning `theta0..theta1` (radians, CCW,
/// 0 at 3 o'clock) between inner radius `r0` and outer radius `r1`. The arc is
/// densified into line segments (~4° each). `r0 <= 0` collapses the inner edge to
/// the centre (a pie slice); `r0 == r1` yields a zero-area path (an arc outline when
/// stroked). Returns `None` for a zero angular span or non-positive outer radius.
pub fn sector_path(cx: f64, cy: f64, r0: f64, r1: f64, theta0: f64, theta1: f64) -> Option<Path> {
    let r_out = r1.max(0.0);
    let r_in = r0.max(0.0);
    let dtheta = clamp_sweep(theta1 - theta0);
    if r_out <= 0.0 || dtheta == 0.0 || !dtheta.is_finite() || !cx.is_finite() || !cy.is_finite() {
        return None;
    }
    let theta1 = theta0 + dtheta;
    let lim = crate::units::PRECISE_PX;
    if cx.abs() + r_out > lim || cy.abs() + r_out > lim {
        return far_sector_path(cx, cy, r_in, r_out, theta0, theta1);
    }
    // ~4 degrees per segment, at least 2 segments across the span. Cap the count so
    // an extreme span (should already be rejected R-side as non-finite/huge, but be
    // defensive) can't blow up the allocation / loop.
    const MAX_SECTOR_SEGS: usize = 4096;
    let segs = ((dtheta.abs() / (std::f64::consts::PI / 45.0))
        .ceil()
        .max(2.0) as usize)
        .min(MAX_SECTOR_SEGS);
    // `(cx, cy)` is already in the y-down device frame (via `y_pos`), while `a` is a
    // y-up angle (0 at 3 o'clock, CCW, per the R contract). Negate the sin term to map
    // the y-up angle onto the device offset — the same sign flip `y_pos`/`rotation_about` apply.
    let pt = |r: f64, a: f64| ((cx + r * a.cos()) as f32, (cy - r * a.sin()) as f32);
    let mut pb = PathBuilder::new();
    // Outer arc, theta0 -> theta1.
    let (sx, sy) = pt(r_out, theta0);
    pb.move_to(sx, sy);
    for k in 1..=segs {
        let a = theta0 + dtheta * (k as f64) / (segs as f64);
        let (px, py) = pt(r_out, a);
        pb.line_to(px, py);
    }
    // Inner arc back, theta1 -> theta0 (collapses to the centre when r_in == 0).
    for k in 0..=segs {
        let a = theta1 - dtheta * (k as f64) / (segs as f64);
        let (px, py) = pt(r_in, a);
        pb.line_to(px, py);
    }
    pb.close();
    pb.finish()
}

/// Local px around the origin where a far shape's outline is kept exact: four
/// times [`crate::units::PRECISE_PX`] either way. A viewport placed within
/// `PRECISE_PX` of the page, or rebased onto it, puts every page in this box.
const FAR_WINDOW: f64 = 4.0 * crate::units::PRECISE_PX;

/// The largest gap (local px) between a far arc and the chords drawn for it,
/// where it passes [`FAR_WINDOW`].
const FAR_ARC_TOL: f64 = 1.0 / 32.0;

/// Append the arc of radius `r` about `(cx, cy)` from `a0` to `a1` (radians,
/// y-up as in [`sector_path`]) to `pts`, not including its start point. Each
/// ~4 degree chord that passes near [`FAR_WINDOW`] is split until it lies
/// within [`FAR_ARC_TOL`] of the arc: for a radius of 1e9 px a 4 degree chord
/// misses the arc by 6e5 px. Chords away from the window stay as they are.
fn far_arc(pts: &mut Vec<(f64, f64)>, cx: f64, cy: f64, r: f64, a0: f64, a1: f64) {
    let pt = |a: f64| (cx + r * a.cos(), cy - r * a.sin());
    fn piece(
        pts: &mut Vec<(f64, f64)>,
        pt: &dyn Fn(f64) -> (f64, f64),
        r: f64,
        a0: f64,
        a1: f64,
        depth: u32,
    ) {
        let (p, q) = (pt(a0), pt(a1));
        // The arc lies within its chord's box grown by the sagitta.
        let sag = r * (1.0 - (0.5 * (a1 - a0)).cos());
        let near = p.0.min(q.0) - sag <= FAR_WINDOW
            && p.0.max(q.0) + sag >= -FAR_WINDOW
            && p.1.min(q.1) - sag <= FAR_WINDOW
            && p.1.max(q.1) + sag >= -FAR_WINDOW;
        if !near || sag <= FAR_ARC_TOL || depth >= 64 || pts.len() >= 1 << 20 {
            pts.push(q);
            return;
        }
        let m = 0.5 * (a0 + a1);
        piece(pts, pt, r, a0, m, depth + 1);
        piece(pts, pt, r, m, a1, depth + 1);
    }
    let segs = (((a1 - a0).abs() / (std::f64::consts::PI / 45.0))
        .ceil()
        .max(2.0) as usize)
        .min(4096);
    for k in 0..segs {
        let b0 = a0 + (a1 - a0) * (k as f64) / (segs as f64);
        let b1 = a0 + (a1 - a0) * ((k + 1) as f64) / (segs as f64);
        piece(pts, &pt, r, b0, b1, 0);
    }
}

/// [`sector_path`] for a sector reaching past [`crate::units::PRECISE_PX`]
/// (VR-47): its arcs follow the circle within [`FAR_ARC_TOL`] wherever they
/// pass near the page, and every point is placed in f64 before narrowing.
fn far_sector_path(
    cx: f64,
    cy: f64,
    r_in: f64,
    r_out: f64,
    theta0: f64,
    theta1: f64,
) -> Option<Path> {
    let pt = |r: f64, a: f64| (cx + r * a.cos(), cy - r * a.sin());
    let mut pts = vec![pt(r_out, theta0)];
    far_arc(&mut pts, cx, cy, r_out, theta0, theta1);
    if r_in > 0.0 {
        pts.push(pt(r_in, theta1));
        far_arc(&mut pts, cx, cy, r_in, theta1, theta0);
    } else {
        pts.push((cx, cy));
    }
    let mut pb = PathBuilder::new();
    for (k, &(x, y)) in pts.iter().enumerate() {
        if k == 0 {
            pb.move_to(x as f32, y as f32);
        } else {
            pb.line_to(x as f32, y as f32);
        }
    }
    pb.close();
    pb.finish()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn near_rects_and_circles_are_built_as_before() {
        let a = rect_path(10.3, 20.7, 30.1, 5.5).unwrap();
        let b = PathBuilder::from_rect(tiny_skia::Rect::from_xywh(10.3, 20.7, 30.1, 5.5).unwrap());
        assert_eq!(format!("{a:?}"), format!("{b:?}"));
        let mut pa = PathBuilder::new();
        push_circle_precise(&mut pa, 53.75, 285.9, 3.78);
        let mut pb = PathBuilder::new();
        pb.push_circle(53.75, 285.9, 3.78);
        assert_eq!(format!("{:?}", pa.finish()), format!("{:?}", pb.finish()));
    }

    #[test]
    fn a_far_rect_keeps_its_near_edge_exact() {
        // from -2e7 px, 2e7 + 50.3 wide: the right edge is at 50.3 px, which
        // an f32 sum would round to 50 (VR-45)
        let p = rect_path(-2e7, 0.0, 2e7 + 50.3, 10.0).unwrap();
        assert_eq!(p.bounds().right(), 50.3f32);
    }

    #[test]
    fn a_far_circle_keeps_its_near_edge_exact() {
        let mut pb = PathBuilder::new();
        push_circle_precise(&mut pb, 1e9 + 100.0, 50.0, 1e9);
        let p = pb.finish().unwrap();
        assert_eq!(p.bounds().left(), 100.0f32);
        // within 1/64 px of the true circle near its west point
        let mut pb = PathBuilder::new();
        push_circle_precise(&mut pb, 1e9 + 100.25, 50.0, 1e9);
        assert_eq!(pb.finish().unwrap().bounds().left(), 100.25f32);
    }

    // x where the outline of `p` crosses height `y`, nearest `near`.
    fn crossing(p: &Path, y: f64, near: f64) -> f64 {
        let ring = &flatten_rings(p)[0];
        let mut best = f64::INFINITY;
        for k in 0..ring.len() {
            let (a, b) = (ring[k], ring[(k + 1) % ring.len()]);
            let (ay, by) = (a.1 as f64, b.1 as f64);
            if (ay - y) * (by - y) <= 0.0 && ay != by {
                let x = a.0 as f64 + (y - ay) / (by - ay) * (b.0 as f64 - a.0 as f64);
                if (x - near).abs() < (best - near).abs() {
                    best = x;
                }
            }
        }
        best
    }

    #[test]
    fn a_far_sector_follows_its_arc_across_the_page() {
        // The left half of a disc of radius 1e9 whose west point is at
        // 100.25 px. 4 degree chords missed the arc by 6e5 px (VR-47).
        let (cx, cy, r) = (1e9 + 100.25, 50.0, 1e9);
        let half = std::f64::consts::FRAC_PI_2;
        for (r0, (t0, t1)) in [(0.0, (half, 3.0 * half)), (r - 10.0, (3.0 * half, half))] {
            let p = sector_path(cx, cy, r0, r, t0, t1).unwrap();
            for y in [0.0, 50.0, 100.0] {
                let want = cx - (r * r - (y - cy) * (y - cy)).sqrt();
                assert!((crossing(&p, y, want) - want).abs() < 0.05, "y = {y}");
            }
        }
        // and within PRECISE_PX it is built as before (~4 degree chords)
        let near = sector_path(100.0, 100.0, 0.0, 50.0, 0.0, half).unwrap();
        // (23 chords out, 24 points back, the start)
        assert_eq!(near.len(), 1 + 23 + 24 + 1);
    }

    #[test]
    fn a_far_circle_follows_its_arc_between_the_compass_points() {
        // Crossing the page 22.5 degrees round from its east point, where
        // cubic quarter arcs missed it by 27 px at a radius of 1e5 (VR-47).
        let a = std::f64::consts::PI / 8.0;
        for r in [1e5, 1e7, 1e9] {
            let (cx, cy) = (72.0 - r * a.cos(), 72.0 + r * a.sin());
            let mut pb = PathBuilder::new();
            push_circle_precise(&mut pb, cx, cy, r);
            let p = pb.finish().unwrap();
            for y in [50.0, 72.0, 100.0] {
                let want = cx + (r * r - (y - cy) * (y - cy)).sqrt();
                assert!(
                    (crossing(&p, y, want) - want).abs() < 0.05,
                    "r = {r}, y = {y}"
                );
            }
        }
    }
}
