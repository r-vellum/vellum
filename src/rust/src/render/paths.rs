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
/// where it is (VR-45): four cubic quarter arcs, from the east point and
/// turning the same way.
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
    const K: f64 = 0.552_284_749_830_793_4;
    let k = K * r;
    let f = |x: f64, y: f64| (x as f32, y as f32);
    let p = [f(cx + r, cy), f(cx, cy + r), f(cx - r, cy), f(cx, cy - r)];
    let c = [
        (f(cx + r, cy + k), f(cx + k, cy + r)),
        (f(cx - k, cy + r), f(cx - r, cy + k)),
        (f(cx - r, cy - k), f(cx - k, cy - r)),
        (f(cx + k, cy - r), f(cx + r, cy - k)),
    ];
    pb.move_to(p[0].0, p[0].1);
    for i in 0..4 {
        let ((a, b), e) = (c[i], p[(i + 1) % 4]);
        pb.cubic_to(a.0, a.1, b.0, b.1, e.0, e.1);
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
}
