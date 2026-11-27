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
/// tiny-skia's `push_circle`, built at its own radius: up to 16 quads a
/// quarter, within 0.06 px of the circle at any radius in that range (VR-48).
/// Further out its points are placed in f64 before
/// narrowing, so a huge circle whose edge crosses the page keeps that edge
/// where it is (VR-45). Its outline is chords from the east point, turning
/// the same way, that follow the circle within the window's tolerance where
/// they pass the window ([`far_arc`]) and stay coarse elsewhere: four cubic
/// quarter arcs miss a circle by 2.7e-4 of its radius between their ends,
/// 27 px for a radius of 1e5 px (VR-47).
pub fn push_circle_precise(pb: &mut PathBuilder, cx: f64, cy: f64, r: f64, win: &FarWin) {
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
    far_arc(&mut pts, cx, cy, r, 0.0, -std::f64::consts::TAU, win);
    pts.pop(); // back at the start
    push_far_poly(pb, &pts, true, win);
}

/// A rounded rectangle (top-left `(x, y)`, size `w`×`h`, corner radius `r` in the
/// same px units). `r` is clamped to half the shorter side; `r == 0` degrades to
/// a plain rect. Corners are cubic-Bézier quarter-circle approximations, which
/// stray up to 2.7e-4 r from the circle. A corner where that passes
/// [`ARC_KEEP_TOL`] device px (r past ~920 px), or a rect reaching past
/// [`crate::units::PRECISE_PX`], is built as chords in f64 instead, within the
/// window's tolerance over `win` (VR-48).
pub fn roundrect_path(x: f64, y: f64, w: f64, h: f64, r: f64, win: &FarWin) -> Option<Path> {
    if w <= 0.0 || h <= 0.0 {
        return None;
    }
    let r = r.max(0.0).min(w / 2.0).min(h / 2.0);
    if r <= 0.0 {
        return rect_path(x, y, w, h);
    }
    let lim = crate::units::PRECISE_PX;
    let far = [x, y, x + w, y + h].iter().any(|v| v.abs() > lim);
    if (far || !win.keeps(CUBIC_ARC_ERR * r)) && [x, y, w, h, r].iter().all(|v| v.is_finite()) {
        let win = if far { *win } else { win.in_range() };
        return precise_roundrect_path(x, y, w, h, r, &win);
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

/// [`roundrect_path`] with chord corners ([`far_arc`]) and every point placed
/// in f64: the same outline, starting at the top edge's left end and turning
/// the same way.
fn precise_roundrect_path(x: f64, y: f64, w: f64, h: f64, r: f64, win: &FarWin) -> Option<Path> {
    let pts = precise_roundrect_pts(x, y, w, h, r, win);
    let mut pb = PathBuilder::new();
    push_far_poly(&mut pb, &pts, true, win);
    pb.finish()
}

/// The f64 outline [`precise_roundrect_path`] draws, before it is cut at the
/// window.
fn precise_roundrect_pts(x: f64, y: f64, w: f64, h: f64, r: f64, win: &FarWin) -> Vec<(f64, f64)> {
    use std::f64::consts::{FRAC_PI_2, PI};
    let (x1, y1) = (x + w, y + h);
    let mut pts = vec![(x + r, y), (x1 - r, y)];
    // y-up angles about each corner's centre, as `far_arc` takes them
    far_arc(&mut pts, x1 - r, y + r, r, FRAC_PI_2, 0.0, win);
    pts.push((x1, y1 - r));
    far_arc(&mut pts, x1 - r, y1 - r, r, 0.0, -FRAC_PI_2, win);
    pts.push((x + r, y1));
    far_arc(&mut pts, x + r, y1 - r, r, -FRAC_PI_2, -PI, win);
    pts.push((x, y + r));
    far_arc(&mut pts, x + r, y + r, r, PI, FRAC_PI_2, win);
    pts.pop(); // back at the start
    pts
}

/// The outline [`roundrect_path`] draws, as an f64 ring for picking (VR-55):
/// the chord corners of a large or far one, or its cubic corners sampled
/// within [`IN_RANGE_ARC_TOL`] device px. `None` where nothing is drawn.
pub fn roundrect_ring_in(
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    r: f64,
    win: &FarWin,
) -> Option<Vec<(f64, f64)>> {
    if w <= 0.0 || h <= 0.0 || ![x, y, w, h].iter().all(|v| v.is_finite()) {
        return None;
    }
    let (x1, y1) = (x + w, y + h);
    let r = r.max(0.0).min(w / 2.0).min(h / 2.0);
    if r <= 0.0 || !r.is_finite() {
        return Some(vec![(x, y), (x1, y), (x1, y1), (x, y1)]);
    }
    let lim = crate::units::PRECISE_PX;
    let far = [x, y, x1, y1].iter().any(|v| v.abs() > lim);
    if far || !win.keeps(CUBIC_ARC_ERR * r) {
        let win = if far { *win } else { win.in_range() };
        return Some(precise_roundrect_pts(x, y, w, h, r, &win));
    }
    // Chords of `k` steps per cubic corner stray about r (pi / 4k)^2 / 2.
    let tol = win.in_range().tol;
    let k =
        ((std::f64::consts::FRAC_PI_4 * (r / (2.0 * tol)).sqrt()).ceil() as usize).clamp(2, 256);
    let kr = r * 0.552_284_749_830_793_6;
    // Each corner as in `roundrect_path`: start, two control points, end.
    let corners = [
        [(x1 - r, y), (x1 - r + kr, y), (x1, y + r - kr), (x1, y + r)],
        [
            (x1, y1 - r),
            (x1, y1 - r + kr),
            (x1 - r + kr, y1),
            (x1 - r, y1),
        ],
        [(x + r, y1), (x + r - kr, y1), (x, y1 - r + kr), (x, y1 - r)],
        [(x, y + r), (x, y + r - kr), (x + r - kr, y), (x + r, y)],
    ];
    let mut pts = vec![(x + r, y)];
    for [p0, p1, p2, p3] in corners {
        pts.push(p0);
        for j in 1..=k {
            let t = j as f64 / k as f64;
            let u = 1.0 - t;
            let (a, b, c, d) = (u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t);
            pts.push((
                a * p0.0 + b * p1.0 + c * p2.0 + d * p3.0,
                a * p0.1 + b * p1.1 + c * p2.1 + d * p3.1,
            ));
        }
    }
    pts.pop(); // back at the start
    Some(pts)
}

/// A regular hexagon centred at `(cx, cy)` with circumradius `r` (centre→vertex).
/// `flat` selects orientation: flat-top (a horizontal top/bottom edge) when true,
/// pointy-top (a vertex up/down) when false. `r <= 0` → `None`. A thin wrapper over
/// [`hexagon_path_xy`] with the regular relation between the two half-extents.
pub fn hexagon_path(cx: f64, cy: f64, r: f64, flat: bool, win: &FarWin) -> Option<Path> {
    if r <= 0.0 {
        return None;
    }
    let s = r * (3.0_f64).sqrt() * 0.5; // the short half-extent of a regular hex
    if flat {
        hexagon_path_xy(cx, cy, r, s, true, win)
    } else {
        hexagon_path_xy(cx, cy, s, r, false, win)
    }
}

/// A hexagon centred at `(cx, cy)` with independent horizontal half-extent `hx`
/// and vertical half-extent `hy` (each measured centre→edge along its own axis,
/// so the full width is `2*hx` and the full height is `2*hy`). `flat` selects
/// flat-top — vertices left/right at `(±hx, 0)`, horizontal edges at `±hy` — vs
/// pointy-top — vertices top/bottom at `(0, ±hy)`, vertical edges at `±hx`. A
/// regular hexagon is the special case `hy == hx*sqrt(3)/2` (flat) resp.
/// `hx == hy*sqrt(3)/2` (pointy). Non-positive or non-finite extents → `None`.
/// A hexagon reaching past [`crate::units::PRECISE_PX`] has its edges cut at
/// `win`, the backend's [`FarWin`] (VR-47, VR-52).
pub fn hexagon_path_xy(
    cx: f64,
    cy: f64,
    hx: f64,
    hy: f64,
    flat: bool,
    win: &FarWin,
) -> Option<Path> {
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
    let lim = crate::units::PRECISE_PX;
    if cx.abs() + hx > lim || cy.abs() + hy > lim {
        // Far: edges cut at the window in f64 (VR-47).
        let pts: Vec<(f64, f64)> = corners.iter().map(|(dx, dy)| (cx + dx, cy + dy)).collect();
        push_far_poly(&mut pb, &pts, true, win);
        return pb.finish();
    }
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
/// densified into line segments (~4° each, finer for a large radius: see
/// [`sector_path_in`]). `r0 <= 0` collapses the inner edge to
/// the centre (a pie slice); `r0 == r1` yields a zero-area path (an arc outline when
/// stroked). Returns `None` for a zero angular span or non-positive outer radius.
pub fn sector_path(cx: f64, cy: f64, r0: f64, r1: f64, theta0: f64, theta1: f64) -> Option<Path> {
    sector_path_in(cx, cy, r0, r1, theta0, theta1, &FarWin::around_origin())
}

/// [`sector_path`], with a large or far sector's outline kept exact within
/// `win`.
pub fn sector_path_in(
    cx: f64,
    cy: f64,
    r0: f64,
    r1: f64,
    theta0: f64,
    theta1: f64,
    win: &FarWin,
) -> Option<Path> {
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
    // Those chords miss the arc by their sagitta: 6.1e-4 r, 6 px at r = 1e4.
    // Past ARC_KEEP_TOL device px (r past ~410 px) the outline is built as a
    // far one is, within IN_RANGE_ARC_TOL over the window (VR-48).
    let r_max = r_out.max(r_in);
    let sag = r_max * (1.0 - (0.5 * dtheta / segs as f64).cos());
    let lim = crate::units::PRECISE_PX;
    if cx.abs() + r_max > lim || cy.abs() + r_max > lim {
        return far_sector_path(cx, cy, r_in, r_out, theta0, theta1, win);
    }
    if !win.keeps(sag) {
        return far_sector_path(cx, cy, r_in, r_out, theta0, theta1, &win.in_range());
    }
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

/// Local px around the origin where a far shape's outline is kept exact when
/// the page is not known: four times [`crate::units::PRECISE_PX`] either way.
/// A viewport placed within `PRECISE_PX` of the page, or rebased onto it, puts
/// every page in this box.
const FAR_WINDOW: f64 = 4.0 * crate::units::PRECISE_PX;

/// The largest gap (device px) between a far arc and the chords drawn for it,
/// where it passes the window.
const FAR_ARC_TOL: f64 = 1.0 / 32.0;

/// The arc tolerance (device px) of an in-range arc that [`ARC_KEEP_TOL`]
/// sends to the far build. Coarser than [`FAR_ARC_TOL`], which is for arcs
/// that swing past the page at huge radii: half the point count, and still
/// well under the error of the builds kept below the threshold (VR-48).
const IN_RANGE_ARC_TOL: f64 = 1.0 / 8.0;

/// The largest outline error (device px) of an in-range arc build that is
/// kept as it is (VR-48): ~4 degree sector chords, tiny-skia's unit circle
/// scaled up, cubic round-rect corners. A larger sector or corner is built as
/// a far one is instead ([`far_arc`], within [`IN_RANGE_ARC_TOL`] over the
/// window), a larger circle as the fine unit circle. At 1/4 px
/// those builds stay as they were up to a sector radius of ~410 px, a scaled
/// unit circle of ~78 px and a round-rect corner of ~920 px, so ordinary plot
/// sizes keep their bytes (at 1/8 px, the outer rings of the default
/// sunburst and chord diagrams, ~220 px, would change).
const ARC_KEEP_TOL: f64 = 1.0 / 4.0;

/// How far tiny-skia's unit circle (eight quads) strays from the circle, as a
/// fraction of the radius (measured: 3.14e-3).
const UNIT_CIRCLE_ERR: f64 = 3.2e-3;

/// How far a cubic quarter arc (control points at 0.5523 r) strays from the
/// circle, as a fraction of the radius (2.73e-4).
const CUBIC_ARC_ERR: f64 = 2.73e-4;

/// Where a shape reaching past [`crate::units::PRECISE_PX`] is built exactly
/// (VR-47): a box in local px (the page, grown by a margin, mapped back
/// through the transform) and the arc tolerance there, in local px. Outside
/// the box nothing is visible, so arcs stay coarse there.
#[derive(Clone, Copy, Debug)]
pub struct FarWin {
    /// `[x0, y0, x1, y1]`, local px.
    pub b: [f64; 4],
    /// Arc tolerance, local px.
    pub tol: f64,
    /// Where `tol` holds, when it coarsens away from the page (VR-56): a box
    /// in local px and a length. A chord `d` local px outside the box is
    /// kept within `tol * (1 + d / len)`. `None`: `tol` everywhere.
    pub near: Option<([f64; 4], f64)>,
}

impl FarWin {
    /// The window when the page is not known: [`FAR_WINDOW`] about the origin.
    pub fn around_origin() -> Self {
        FarWin {
            b: [-FAR_WINDOW, -FAR_WINDOW, FAR_WINDOW, FAR_WINDOW],
            tol: FAR_ARC_TOL,
            near: None,
        }
    }

    /// The display list's window (VR-56): [`FarWin::around_origin`], so a mark
    /// the widget pans into view stays exact out to 4 x `PRECISE_PX`, but
    /// with the arc tolerance held only near the `w` x `h` px page drawn
    /// under `t` (the page grown by a page each way) and growing with the
    /// distance from it, in page lengths. A view that reaches a page length
    /// `k` past that box is zoomed out about `k` times (or panned there), so
    /// the error looks no larger than at the page; refining a huge arc's
    /// whole ring at the page's tolerance tripled the list.
    pub fn for_list(t: Transform, w: u32, h: u32) -> Self {
        let mut win = Self::around_origin();
        let det = (t.sx as f64 * t.sy as f64 - t.kx as f64 * t.ky as f64).abs();
        let len = w.max(h).max(1) as f64 / det.sqrt();
        if len.is_finite() && len > 0.0 {
            win.near = Some((Self::for_page(t, w, h).b, len));
        }
        win
    }

    /// The arc tolerance (local px) for a chord whose box is `[x0, y0, x1,
    /// y1]`: `tol`, coarsened with the distance from the page (`near`).
    fn tol_at(&self, x0: f64, y0: f64, x1: f64, y1: f64) -> f64 {
        let Some((b, len)) = self.near else {
            return self.tol;
        };
        let dx = (b[0] - x1).max(x0 - b[2]).max(0.0);
        let dy = (b[1] - y1).max(y0 - b[3]).max(0.0);
        let d = dx.max(dy);
        if d > 0.0 {
            self.tol * (1.0 + d / len)
        } else {
            self.tol
        }
    }

    /// The window for a `w` x `h` px page drawn under `t`: the page grown by
    /// the margin the far fits cut to (`fit_fill`), mapped back to local px.
    /// Falls back to [`FarWin::around_origin`] if `t` cannot be inverted.
    pub fn for_page(t: Transform, w: u32, h: u32) -> Self {
        let (a, b, c, d) = (t.sx as f64, t.ky as f64, t.kx as f64, t.sy as f64);
        let (e, f) = (t.tx as f64, t.ty as f64);
        let det = a * d - b * c;
        if !(det.is_finite() && det != 0.0 && e.is_finite() && f.is_finite()) {
            return Self::around_origin();
        }
        let m = w.max(h) as f64 + 4.0;
        let mut out = [
            f64::INFINITY,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
        ];
        for (x, y) in [
            (-m, -m),
            (w as f64 + m, -m),
            (w as f64 + m, h as f64 + m),
            (-m, h as f64 + m),
        ] {
            let (qx, qy) = (x - e, y - f);
            let (lx, ly) = ((d * qx - c * qy) / det, (a * qy - b * qx) / det);
            out[0] = out[0].min(lx);
            out[1] = out[1].min(ly);
            out[2] = out[2].max(lx);
            out[3] = out[3].max(ly);
        }
        let tol = FAR_ARC_TOL / det.abs().sqrt();
        if out.iter().all(|v| v.is_finite()) && tol.is_finite() && tol > 0.0 {
            FarWin {
                b: out,
                tol,
                near: None,
            }
        } else {
            Self::around_origin()
        }
    }

    /// Is an outline error of `err` local px small enough to keep an in-range
    /// arc build as it is (at most [`ARC_KEEP_TOL`] device px)?
    pub fn keeps(&self, err: f64) -> bool {
        err * (FAR_ARC_TOL / self.tol) <= ARC_KEEP_TOL
    }

    /// May a circle of radius `r` local px be drawn as tiny-skia's unit circle
    /// scaled up (VR-48)? Past ~78 device px it strays more than
    /// [`ARC_KEEP_TOL`]; it is then drawn from a finer circle
    /// ([`FarWin::circle_radius`]), and past [`crate::units::PRECISE_PX`]
    /// built in place ([`push_circle_precise`]).
    pub fn unit_circle_fits(&self, r: f64) -> bool {
        self.keeps(UNIT_CIRCLE_ERR * r)
    }

    /// The radius (px) at which to build the circle that is scaled to draw a
    /// circle of radius `r` local px (VR-48). tiny-skia's `push_circle` uses
    /// more quads for a larger radius: 8 at 1 px (3.1e-3 r off), 16 at 32 px
    /// (1.9e-4 r), 32 at 128 px (1.2e-5 r) and 64 at `PRECISE_PX` (8e-7 r).
    /// The unit circle while [`FarWin::unit_circle_fits`], else the fewest
    /// quads within [`IN_RANGE_ARC_TOL`] device px: few quads keep a PDF of
    /// many large circles small.
    pub fn circle_radius(&self, r: f64) -> f32 {
        if self.unit_circle_fits(r) {
            return 1.0;
        }
        let tol = self.tol * (IN_RANGE_ARC_TOL / FAR_ARC_TOL);
        if 1.9e-4 * r <= tol {
            32.0
        } else if 1.2e-5 * r <= tol {
            128.0
        } else {
            crate::units::PRECISE_PX as f32
        }
    }

    /// This window with the coarser [`IN_RANGE_ARC_TOL`], for an in-range
    /// arc rebuilt past [`ARC_KEEP_TOL`].
    pub fn in_range(&self) -> Self {
        FarWin {
            b: self.b,
            tol: self.tol * (IN_RANGE_ARC_TOL / FAR_ARC_TOL),
            near: self.near,
        }
    }

    /// Does the box `[x0, y0, x1, y1]` touch the window?
    fn touches(&self, x0: f64, y0: f64, x1: f64, y1: f64) -> bool {
        x0 <= self.b[2] && x1 >= self.b[0] && y0 <= self.b[3] && y1 >= self.b[1]
    }

    /// Where the segment `p` -> `q` enters and leaves the window, as
    /// parameters strictly inside `(0, 1)` (Liang-Barsky).
    fn crossings(&self, p: (f64, f64), q: (f64, f64)) -> [Option<f64>; 2] {
        let (dx, dy) = (q.0 - p.0, q.1 - p.1);
        let (mut t0, mut t1) = (0.0f64, 1.0f64);
        for (den, num) in [
            (-dx, p.0 - self.b[0]),
            (dx, self.b[2] - p.0),
            (-dy, p.1 - self.b[1]),
            (dy, self.b[3] - p.1),
        ] {
            if den == 0.0 {
                if num < 0.0 {
                    return [None, None];
                }
            } else {
                let r = num / den;
                if den < 0.0 {
                    t0 = t0.max(r);
                } else {
                    t1 = t1.min(r);
                }
            }
        }
        if !(t0 < t1) {
            return [None, None];
        }
        [(t0 > 0.0).then_some(t0), (t1 < 1.0).then_some(t1)]
    }
}

/// Append the polyline `pts` (f64, local px) to `pb`, closed if `close`.
/// Each edge is cut where it enters and leaves `win`, in f64, and those
/// points are added before narrowing: an edge crossing the page between two
/// vertices 1e9 px away would otherwise move with their f32 rounding, up to
/// 64 px (VR-47). Off the window, the narrowed edge does not matter.
pub fn push_far_poly(pb: &mut PathBuilder, pts: &[(f64, f64)], close: bool, win: &FarWin) {
    let Some(&first) = pts.first() else {
        return;
    };
    let f = |p: (f64, f64)| (p.0 as f32, p.1 as f32);
    let (x, y) = f(first);
    pb.move_to(x, y);
    let n = pts.len();
    let edges = if close { n } else { n - 1 };
    for k in 0..edges {
        let (p, q) = (pts[k], pts[(k + 1) % n]);
        for t in win.crossings(p, q).into_iter().flatten() {
            let (x, y) = f((p.0 + t * (q.0 - p.0), p.1 + t * (q.1 - p.1)));
            pb.line_to(x, y);
        }
        if k + 1 < n {
            let (x, y) = f(q);
            pb.line_to(x, y);
        }
    }
    if close {
        pb.close();
    }
}

/// Append the arc of radius `r` about `(cx, cy)` from `a0` to `a1` (radians,
/// y-up as in [`sector_path`]) to `pts`, not including its start point. Each
/// ~4 degree chord that passes near `win` is split until it lies within the
/// window's tolerance of the arc: for a radius of 1e9 px a 4 degree chord
/// misses the arc by 6e5 px. Chords away from the window stay as they are.
fn far_arc(pts: &mut Vec<(f64, f64)>, cx: f64, cy: f64, r: f64, a0: f64, a1: f64, win: &FarWin) {
    let pt = |a: f64| (cx + r * a.cos(), cy - r * a.sin());
    fn piece(
        pts: &mut Vec<(f64, f64)>,
        pt: &dyn Fn(f64) -> (f64, f64),
        win: &FarWin,
        r: f64,
        a0: f64,
        a1: f64,
        depth: u32,
    ) {
        let (p, q) = (pt(a0), pt(a1));
        // The arc lies within its chord's box grown by the sagitta.
        let sag = r * (1.0 - (0.5 * (a1 - a0)).cos());
        let bx = [
            p.0.min(q.0) - sag,
            p.1.min(q.1) - sag,
            p.0.max(q.0) + sag,
            p.1.max(q.1) + sag,
        ];
        let near = win.touches(bx[0], bx[1], bx[2], bx[3]);
        let tol = win.tol_at(bx[0], bx[1], bx[2], bx[3]);
        if !near || sag <= tol || depth >= 64 || pts.len() >= 1 << 20 {
            pts.push(q);
            return;
        }
        let m = 0.5 * (a0 + a1);
        piece(pts, pt, win, r, a0, m, depth + 1);
        piece(pts, pt, win, r, m, a1, depth + 1);
    }
    let segs = (((a1 - a0).abs() / (std::f64::consts::PI / 45.0))
        .ceil()
        .max(2.0) as usize)
        .min(4096);
    for k in 0..segs {
        let b0 = a0 + (a1 - a0) * (k as f64) / (segs as f64);
        let b1 = a0 + (a1 - a0) * ((k + 1) as f64) / (segs as f64);
        piece(pts, &pt, win, r, b0, b1, 0);
    }
}

/// [`sector_path`] for a sector reaching past [`crate::units::PRECISE_PX`]
/// (VR-47): its arcs follow the circle within the window's tolerance where
/// they pass `win`, and its edges are cut at the window in f64.
fn far_sector_path(
    cx: f64,
    cy: f64,
    r_in: f64,
    r_out: f64,
    theta0: f64,
    theta1: f64,
    win: &FarWin,
) -> Option<Path> {
    let pt = |r: f64, a: f64| (cx + r * a.cos(), cy - r * a.sin());
    let mut pts = vec![pt(r_out, theta0)];
    far_arc(&mut pts, cx, cy, r_out, theta0, theta1, win);
    if r_in > 0.0 {
        pts.push(pt(r_in, theta1));
        far_arc(&mut pts, cx, cy, r_in, theta1, theta0, win);
    } else {
        pts.push((cx, cy));
    }
    let mut pb = PathBuilder::new();
    push_far_poly(&mut pb, &pts, true, win);
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
        push_circle_precise(&mut pa, 53.75, 285.9, 3.78, &FarWin::around_origin());
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
        push_circle_precise(&mut pb, 1e9 + 100.0, 50.0, 1e9, &FarWin::around_origin());
        let p = pb.finish().unwrap();
        assert_eq!(p.bounds().left(), 100.0f32);
        // within 1/64 px of the true circle near its west point
        let mut pb = PathBuilder::new();
        push_circle_precise(&mut pb, 1e9 + 100.25, 50.0, 1e9, &FarWin::around_origin());
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
    fn a_far_hexagon_is_cut_at_the_window_it_is_given() {
        // A hexagon of half-extent 1e6 whose west vertex is on the page: its
        // edges are cut, in f64, where they leave the page window rather than
        // the origin box 4 x PRECISE_PX out (VR-52).
        let near = |p: &Path| {
            p.points()
                .iter()
                .filter(|q| q.x.abs() < 1e3 && q.y.abs() < 1e3)
                .count()
        };
        let win = FarWin::for_page(Transform::identity(), 144, 144);
        let p = hexagon_path_xy(1e6 + 50.0, 72.0, 1e6, 0.9e6, true, &win).unwrap();
        // the vertex and the two cuts at the window's edge
        assert_eq!(near(&p), 3);
        let on_edge = |v: f32, e: f64| (v as f64 - e).abs() < 0.01;
        let cuts = p
            .points()
            .iter()
            .filter(|q| on_edge(q.y, win.b[1]) || on_edge(q.y, win.b[3]));
        assert_eq!(cuts.count(), 2);
        let q = hexagon_path_xy(1e6 + 50.0, 72.0, 1e6, 0.9e6, true, &FarWin::around_origin());
        assert_eq!(near(&q.unwrap()), 1);
    }

    #[test]
    fn a_far_circle_follows_its_arc_between_the_compass_points() {
        // Crossing the page 22.5 degrees round from its east point, where
        // cubic quarter arcs missed it by 27 px at a radius of 1e5 (VR-47).
        let a = std::f64::consts::PI / 8.0;
        for r in [1e5, 1e7, 1e9] {
            let (cx, cy) = (72.0 - r * a.cos(), 72.0 + r * a.sin());
            let mut pb = PathBuilder::new();
            push_circle_precise(&mut pb, cx, cy, r, &FarWin::around_origin());
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

    #[test]
    fn a_far_edge_between_two_far_vertices_crosses_the_page_exactly() {
        // The line x + y = 144.3 between vertices 1e9 px either way: each
        // vertex alone rounds by up to 64 px in f32 (VR-47).
        let r = 1e9;
        let pts = [
            (72.15 - r, 72.15 + r),
            (72.15 + r, 72.15 - r),
            (72.15 + r, 72.15 + r),
        ];
        let mut pb = PathBuilder::new();
        push_far_poly(&mut pb, &pts, true, &FarWin::around_origin());
        let p = pb.finish().unwrap();
        for y in [0.0, 72.0, 144.0] {
            assert!(
                (crossing(&p, y, 144.3 - y) - (144.3 - y)).abs() < 0.02,
                "y = {y}"
            );
        }
        // and a sector's radial edge from a centre 1e9 px away
        let a: f64 = 0.3;
        let (cx, cy) = (72.0 - r * a.cos(), 72.0 + r * a.sin());
        let p = sector_path(cx, cy, 0.0, 2.0 * r, a, a + 0.5).unwrap();
        for y in [60.0, 72.0, 84.0] {
            let want = cx + (cy - y) / a.tan();
            assert!(
                (crossing(&p, y, want) - want).abs() < 0.02,
                "sector y = {y}"
            );
        }
    }

    #[test]
    fn a_far_circle_is_fine_only_over_the_page() {
        // r = 1e5 px, its edge through a 144 px page: chords fine only near
        // the page, ~4 degree ones elsewhere.
        let (r, a) = (1e5, std::f64::consts::PI / 8.0);
        let (cx, cy) = (72.0 - r * a.cos(), 72.0 + r * a.sin());
        let win = FarWin::for_page(Transform::identity(), 144, 144);
        let mut pb = PathBuilder::new();
        push_circle_precise(&mut pb, cx, cy, r, &win);
        let p = pb.finish().unwrap();
        assert!(p.len() < 200, "{} points", p.len());
        for y in [0.0, 72.0, 144.0] {
            let want = cx + (r * r - (y - cy) * (y - cy)).sqrt();
            assert!((crossing(&p, y, want) - want).abs() < 0.05, "y = {y}");
        }
    }
    #[test]
    fn a_large_in_range_sector_follows_its_arc() {
        // r = 1e4 px, inside PRECISE_PX, crossing the page in the middle of
        // its first ~4 degree chord, which missed the arc by 6 px (VR-48)
        let half = std::f64::consts::FRAC_PI_2;
        let phi = half / 23.0 / 2.0;
        let win = FarWin::for_page(Transform::identity(), 144, 144);
        for r in [1e3, 1e4, 6e4] {
            let (cx, cy) = (72.0 - r * phi.cos(), 72.0 + r * phi.sin());
            let p = sector_path_in(cx, cy, 0.0, r, 0.0, half, &win).unwrap();
            // within 1/8 px rebuilt in range, 1/32 px far (6e4 + 72 > PRECISE_PX)
            let tol = if r < 6e4 { 0.14 } else { 0.05 };
            for y in [50.0, 72.0, 100.0] {
                let want = cx + (r * r - (y - cy) * (y - cy)).sqrt();
                assert!(
                    (crossing(&p, y, want) - want).abs() < tol,
                    "r = {r}, y = {y}"
                );
            }
            // split finely only over the page
            assert!(p.len() < 400, "r = {r}: {} points", p.len());
        }
    }

    #[test]
    fn ordinary_sectors_and_round_rects_are_built_as_before() {
        // Up to ~410 px a sector keeps its ~4 degree chords (VR-48)
        let half = std::f64::consts::FRAC_PI_2;
        let win = FarWin::for_page(Transform::identity(), 1200, 1200);
        let p = sector_path_in(600.0, 600.0, 200.0, 400.0, 0.0, half, &win).unwrap();
        assert_eq!(p.len(), 1 + 23 + 24 + 1);
        // past it, split to 1/8 px: 2 degree chords (the 220 px inner arc too)
        let p = sector_path_in(600.0, 600.0, 220.0, 440.0, 0.0, half, &win).unwrap();
        assert_eq!(p.len(), 1 + 46 + 1 + 46 + 1);
        // and a round rect with corners up to ~920 px its cubic corners
        let cubics = |p: &Path| {
            p.segments()
                .filter(|s| matches!(s, tiny_skia::PathSegment::CubicTo(..)))
                .count()
        };
        let p = roundrect_path(10.0, 20.0, 2000.0, 2000.0, 900.0, &win).unwrap();
        assert_eq!(cubics(&p), 4);
        let p = roundrect_path(10.0, 20.0, 2000.0, 2000.0, 940.0, &win).unwrap();
        assert_eq!(cubics(&p), 0);
        // the unit circle is used up to ~78 px
        assert!(win.unit_circle_fits(77.0));
        assert!(!win.unit_circle_fits(79.0));
        // device px: a page drawn at twice the scale halves those radii
        let win2 = FarWin::for_page(Transform::from_scale(2.0, 2.0), 600, 600);
        assert!(!win2.unit_circle_fits(40.0));
    }

    #[test]
    fn a_large_round_rect_corner_follows_its_arc() {
        // The top-left corner of radius r crossing the page centre 22.5
        // degrees from its west end, where cubic corners stray 2.7e-4 r
        // (VR-48). Inside PRECISE_PX and past it.
        let a = std::f64::consts::PI / 8.0;
        let win = FarWin::for_page(Transform::identity(), 144, 144);
        for r in [1e4, 6e4, 1e7] {
            let (cx, cy) = (72.0 + r * a.cos(), 72.0 + r * a.sin());
            let p = roundrect_path(cx - r, cy - r, 2.0 * r, 2.0 * r, r, &win).unwrap();
            // within 1/8 px rebuilt in range (1e4), 1/32 px far
            let tol = if r < 6e4 { 0.14 } else { 0.05 };
            for y in [60.0, 72.0, 84.0] {
                let want = cx - (r * r - (y - cy) * (y - cy)).sqrt();
                assert!(
                    (crossing(&p, y, want) - want).abs() < tol,
                    "r = {r}, y = {y}"
                );
            }
            assert!(p.len() < 400, "r = {r}: {} points", p.len());
        }
    }

    #[test]
    fn a_large_circle_is_drawn_from_the_fewest_quads_that_fit() {
        // the build radius picks tiny-skia's quad count (VR-48)
        let win = FarWin::for_page(Transform::identity(), 144, 144);
        assert_eq!(win.circle_radius(50.0), 1.0);
        assert_eq!(win.circle_radius(100.0), 32.0);
        assert_eq!(win.circle_radius(1000.0), 128.0);
        assert_eq!(win.circle_radius(2e4), crate::units::PRECISE_PX as f32);
        let quads = |r: f32| {
            let mut pb = PathBuilder::new();
            pb.push_circle(0.0, 0.0, r);
            pb.finish().unwrap().len() - 2
        };
        assert_eq!(
            [1.0, 32.0, 128.0, crate::units::PRECISE_PX as f32].map(quads),
            [8, 16, 32, 64]
        );
    }
}
