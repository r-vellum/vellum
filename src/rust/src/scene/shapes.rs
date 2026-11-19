//! Pure geometry helpers: unit shapes, ring builders, polyline construction
//! and simplification, end caps and perpendicular offsets.

use super::*;

/// Resolve a node's coordinate arrays to viewport-LOCAL px.
///
/// Local, not device: the renderer draws with the viewport's transform already
/// on the canvas, so local is what it wants. Anything that *reports* coordinates
/// to R must push them through the viewport transform first (`dev_bbox()`, or
/// the geometry recorder in `geom.rs`).
pub(super) fn resolve_pts(
    vp: &Vp,
    x: &[f64],
    y: &[f64],
    xu: &[Unit],
    yu: &[Unit],
) -> Vec<(f64, f64)> {
    let n = x.len().min(y.len());
    (0..n)
        .map(|i| {
            let ux = xu.get(i).copied().unwrap_or(Unit::from_code_off(0, 0.0));
            let uy = yu.get(i).copied().unwrap_or(Unit::from_code_off(0, 0.0));
            (vp.x_pos(x[i], ux), vp.y_pos(y[i], uy))
        })
        .collect()
}

/// A unit rect centred at the origin (`-0.5..0.5`), scaled per element in the
/// batched-rect solid fast path.
pub(super) fn unit_rect() -> tiny_skia::Path {
    rect_path(-0.5, -0.5, 1.0, 1.0).expect("unit rect path")
}

/// A unit marker fill-shape centred at the origin with half-extent 1, scaled by the
/// per-element radius and placed by an affine transform in the Markers solid-fill
/// fast path (mirrors `unit_rect`). `shape`: 1=square, 2=triangle, 3=diamond,
/// 6=triangle_down, 7=star, else circle. Line glyphs (plus/cross = 4/5) are
/// stroke-only and built per element. Coords are y-down (−y is up).
pub(super) fn unit_marker(shape: u32) -> tiny_skia::Path {
    let mut pb = PathBuilder::new();
    match shape {
        1 => {
            pb.move_to(-1.0, -1.0);
            pb.line_to(1.0, -1.0);
            pb.line_to(1.0, 1.0);
            pb.line_to(-1.0, 1.0);
            pb.close();
        }
        2 => {
            pb.move_to(0.0, -1.0);
            pb.line_to(0.866, 0.5);
            pb.line_to(-0.866, 0.5);
            pb.close();
        }
        3 => {
            pb.move_to(0.0, -1.0);
            pb.line_to(1.0, 0.0);
            pb.line_to(0.0, 1.0);
            pb.line_to(-1.0, 0.0);
            pb.close();
        }
        6 => {
            // triangle_down: the up-triangle mirrored in y.
            pb.move_to(0.0, 1.0);
            pb.line_to(0.866, -0.5);
            pb.line_to(-0.866, -0.5);
            pb.close();
        }
        7 => {
            star_path(&mut pb, 0.0, 0.0, 1.0);
        }
        _ => {
            pb.push_circle(0.0, 0.0, 1.0);
        }
    }
    pb.finish().expect("unit marker path")
}

/// Append a 5-pointed star to `pb`, centred at `(cx, cy)` with outer radius `r`.
/// Ten alternating outer/inner vertices, first at the top `(cx, cy − r)` in the
/// y-down frame; the inner radius is the regular-pentagram ratio (≈ 0.382).
pub(super) fn star_path(pb: &mut PathBuilder, cx: f32, cy: f32, r: f32) {
    const INNER: f32 = 0.382;
    for k in 0..10 {
        let ang = -std::f32::consts::FRAC_PI_2 + k as f32 * std::f32::consts::PI / 5.0;
        let rad = if k % 2 == 0 { r } else { r * INNER };
        let (px, py) = (cx + rad * ang.cos(), cy + rad * ang.sin());
        if k == 0 {
            pb.move_to(px, py);
        } else {
            pb.line_to(px, py);
        }
    }
    pb.close();
}

/// Build a multi-subpath device path: `nper[k]` consecutive points form one
/// closed sub-path (so even-odd/winding rules give holes).
pub(super) fn build_subpaths(
    x: &[f64],
    y: &[f64],
    xu: &[Unit],
    yu: &[Unit],
    nper: &[usize],
    vp: &Vp,
) -> Option<tiny_skia::Path> {
    let mut pb = PathBuilder::new();
    let mut i = 0usize;
    for &cnt in nper {
        let end = i + cnt;
        if cnt >= 2 && end <= x.len() && end <= y.len() && end <= xu.len() && end <= yu.len() {
            pb.move_to(vp.x_pos(x[i], xu[i]) as f32, vp.y_pos(y[i], yu[i]) as f32);
            for k in (i + 1)..end {
                pb.line_to(vp.x_pos(x[k], xu[k]) as f32, vp.y_pos(y[k], yu[k]) as f32);
            }
            pb.close();
        }
        i = end;
    }
    pb.finish()
}

/// Sample `n` points along an arc in the local (y-down) frame, inclusive of both
/// ends. Angles wind clockwise on screen (0 at 3 o'clock) — this is the raw
/// device-space form used by `roundrect_ring`, whose corner arcs are specified
/// directly in the y-down frame. For a y-up sector arc, use `sector_arc_pts`.
fn arc_pts(cx: f64, cy: f64, r: f64, t0: f64, t1: f64, n: usize) -> Vec<(f64, f64)> {
    let n = n.max(2);
    (0..=n)
        .map(|k| {
            let a = t0 + (t1 - t0) * (k as f64 / n as f64);
            (cx + r * a.cos(), cy + r * a.sin())
        })
        .collect()
}

/// Sample `n` points along a sector arc (0 at 3 o'clock, CCW — the y-up angle
/// contract), inclusive of both ends. `(cx, cy)` is in the y-down device frame,
/// so the y term is negated to match `sector_path` (keeping the sketched wedge
/// aligned with the crisp fill).
fn sector_arc_pts(cx: f64, cy: f64, r: f64, t0: f64, t1: f64, n: usize) -> Vec<(f64, f64)> {
    let n = n.max(2);
    (0..=n)
        .map(|k| {
            let a = t0 + (t1 - t0) * (k as f64 / n as f64);
            (cx + r * a.cos(), cy - r * a.sin())
        })
        .collect()
}

/// The closed outline of an annular sector as a point ring (local px): outer arc
/// forward, then the inner arc back — or the centre for a pie slice (`r0 == 0`).
pub(super) fn wedge_ring(cx: f64, cy: f64, r0: f64, r1: f64, t0: f64, t1: f64) -> Vec<(f64, f64)> {
    // At most one turn (see `clamp_sweep`); sample density scales with the arc
    // span (≥ ~8 points, ~1 per 6°).
    let t1 = t0 + crate::render::clamp_sweep(t1 - t0);
    let span = (t1 - t0).abs();
    let n = ((span / (std::f64::consts::PI / 30.0)).ceil() as usize).clamp(8, 180);
    let mut ring = sector_arc_pts(cx, cy, r1, t0, t1, n);
    if r0 > 0.0 {
        ring.extend(sector_arc_pts(cx, cy, r0, t1, t0, n));
    } else {
        ring.push((cx, cy));
    }
    ring
}

/// The closed outline of a rounded rectangle as a point ring (local px): straight
/// edges (as their endpoints) joined by sampled quarter-circle corners. Fed to
/// `closed_curve`, so straight runs stay straight and corners stay round.
pub(super) fn roundrect_ring(x0: f64, y0: f64, w: f64, h: f64, r: f64) -> Vec<(f64, f64)> {
    let r = r.min(w / 2.0).min(h / 2.0).max(0.0);
    let (x1, y1) = (x0 + w, y0 + h);
    if r <= 0.0 {
        return vec![(x0, y0), (x1, y0), (x1, y1), (x0, y1)];
    }
    let c = 5usize; // points per corner
    let mut ring = Vec::new();
    // Corners centre + angle range (y grows downward in local px). Go clockwise.
    // top-left corner arc (from 180° to 270°)
    let pi = std::f64::consts::PI;
    ring.extend(arc_pts(x0 + r, y0 + r, r, pi, 1.5 * pi, c));
    ring.extend(arc_pts(x1 - r, y0 + r, r, 1.5 * pi, 2.0 * pi, c)); // top-right
    ring.extend(arc_pts(x1 - r, y1 - r, r, 0.0, 0.5 * pi, c)); // bottom-right
    ring.extend(arc_pts(x0 + r, y1 - r, r, 0.5 * pi, pi, c)); // bottom-left
    ring
}

pub(super) fn build_poly(
    x: &[f64],
    y: &[f64],
    xu: &[Unit],
    yu: &[Unit],
    vp: &Vp,
    close: bool,
) -> Option<tiny_skia::Path> {
    let n = x.len().min(y.len()).min(xu.len()).min(yu.len());
    if n < 2 {
        return None;
    }
    let pts: Vec<(f32, f32)> = (0..n)
        .map(|i| (vp.x_pos(x[i], xu[i]) as f32, vp.y_pos(y[i], yu[i]) as f32))
        .collect();
    build_poly_px(&pts, close)
}

thread_local! {
    /// Douglas-Peucker tolerance in device px for polyline/polygon simplification,
    /// set from R per render. `0` disables it.
    static SIMPLIFY_TOL: std::cell::Cell<f32> = const { std::cell::Cell::new(0.0) };
}

/// Set the path-simplification tolerance (device px) for subsequent renders.
pub fn set_simplify_tol(tol: f64) {
    SIMPLIFY_TOL.with(|c| c.set(tol.max(0.0) as f32));
}

fn simplify_tol() -> f32 {
    SIMPLIFY_TOL.with(|c| c.get())
}

/// Below this many points a path is passed through untouched.
///
/// Deliberately high. Simplification is not free -- it is a *fidelity* trade, the
/// same kind as the marker-sprite and glyph-bitmap fast paths, and like those it
/// should only engage where the win is real and the input is already too dense to
/// scrutinise vertex by vertex. A hand-placed polygon, a spline, an arrow head:
/// every vertex was chosen, the saving would be nil, and they stay byte-identical.
/// A coastline or a long time series: thousands of vertices land inside one pixel
/// of a neighbour, and dropping them is the whole point.
const SIMPLIFY_MIN_PTS: usize = 1000;

/// Douglas-Peucker on points already in device pixels, which is what makes the
/// tolerance meaningful: a vertex that moves the outline by less than `tol` of a
/// pixel cannot change what is rasterised, so dropping it is free.
///
/// This is where an `sf` polygon's 100k vertices meet an 800 px canvas. Almost all
/// of them land inside one pixel of a neighbour.
///
/// Iterative rather than recursive — a degenerate path (a spiral, a coastline)
/// can otherwise recurse thousands deep.
fn douglas_peucker(pts: &[(f32, f32)], tol: f32) -> Vec<(f32, f32)> {
    let n = pts.len();
    if n < 3 {
        return pts.to_vec();
    }
    let mut keep = vec![false; n];
    keep[0] = true;
    keep[n - 1] = true;
    let tol2 = tol * tol;
    let mut stack = vec![(0usize, n - 1)];
    while let Some((lo, hi)) = stack.pop() {
        if hi <= lo + 1 {
            continue;
        }
        let (ax, ay) = pts[lo];
        let (bx, by) = pts[hi];
        let (dx, dy) = (bx - ax, by - ay);
        let len2 = dx * dx + dy * dy;
        let mut worst = 0.0f32;
        let mut worst_i = lo;
        for i in (lo + 1)..hi {
            let (px, py) = pts[i];
            // Squared perpendicular distance to the segment; for a degenerate
            // segment (endpoints coincide) fall back to distance from the point.
            let d2 = if len2 <= f32::EPSILON {
                let (ex, ey) = (px - ax, py - ay);
                ex * ex + ey * ey
            } else {
                let cross = dx * (py - ay) - dy * (px - ax);
                cross * cross / len2
            };
            if d2 > worst {
                worst = d2;
                worst_i = i;
            }
        }
        if worst > tol2 {
            keep[worst_i] = true;
            stack.push((lo, worst_i));
            stack.push((worst_i, hi));
        }
    }
    pts.iter()
        .zip(keep)
        .filter(|(_, k)| *k)
        .map(|(p, _)| *p)
        .collect()
}

/// Simplify each run of finite points, leaving the `NA` breaks in place so the
/// sub-path structure (and grid's NA-as-gap semantics) is preserved exactly.
fn simplify_runs(pts: &[(f32, f32)], tol: f32) -> Vec<(f32, f32)> {
    let mut out = Vec::with_capacity(pts.len());
    let mut run: Vec<(f32, f32)> = Vec::new();
    let flush = |run: &mut Vec<(f32, f32)>, out: &mut Vec<(f32, f32)>| {
        if run.len() >= SIMPLIFY_MIN_PTS {
            out.extend(douglas_peucker(run, tol));
        } else {
            out.extend(run.iter().copied());
        }
        run.clear();
    };
    for &p in pts {
        if p.0.is_finite() && p.1.is_finite() {
            run.push(p);
        } else {
            flush(&mut run, &mut out);
            out.push(p);
        }
    }
    flush(&mut run, &mut out);
    out
}

/// Build a polyline/polygon path from points already resolved to local pixels.
/// A non-finite point (an R `NA`/`NaN`) breaks the line, matching grid: the
/// polyline splits into independent sub-paths, and for a polygon each run of
/// finite points becomes its own closed sub-polygon.
pub(super) fn build_poly_px(pts: &[(f32, f32)], close: bool) -> Option<tiny_skia::Path> {
    let tol = simplify_tol();
    let simplified;
    let pts = if tol > 0.0 && pts.len() >= SIMPLIFY_MIN_PTS {
        simplified = simplify_runs(pts, tol);
        &simplified[..]
    } else {
        pts
    };
    let mut pb = PathBuilder::new();
    let mut open = false; // a sub-path is currently being built
    let mut run = 0; // points in the current sub-path
    for &(px, py) in pts {
        if px.is_finite() && py.is_finite() {
            if open {
                pb.line_to(px, py);
            } else {
                pb.move_to(px, py);
                open = true;
            }
            run += 1;
        } else {
            if open && close && run >= 2 {
                pb.close();
            }
            open = false;
            run = 0;
        }
    }
    if open && close && run >= 2 {
        pb.close();
    }
    pb.finish()
}

/// Resolve an absolute-length cap (validated absolute on the R side) to a device
/// length in local pixels — the same resolution `size`/`r` use, so the gap is
/// exact for any dpi/page size. A negative value clamps to 0.
pub(super) fn cap_len_px(cap: &[f64], capu: &[Unit], i: usize, vp: &Vp) -> f64 {
    if cap.is_empty() {
        return 0.0;
    }
    let idx = if i < cap.len() { i } else { cap.len() - 1 };
    let u = capu.get(idx).copied().unwrap_or(Unit::plain(UnitKind::Mm));
    vp.x_len(cap[idx].max(0.0), u)
}

/// Shorten a segment inward from each end by `sc`/`ec` device pixels. Returns the
/// capped endpoints, or `None` when the segment should not be drawn: a zero-
/// length segment (direction undefined) or a cap that consumes the whole length
/// (clamp to nothing rather than inverting the direction).
pub(super) fn cap_segment(
    sx: f32,
    sy: f32,
    ex: f32,
    ey: f32,
    sc: f64,
    ec: f64,
) -> Option<(f32, f32, f32, f32)> {
    let dx = (ex - sx) as f64;
    let dy = (ey - sy) as f64;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-9 || sc + ec >= len {
        return None;
    }
    let (ux, uy) = (dx / len, dy / len);
    Some((
        sx + (sc * ux) as f32,
        sy + (sc * uy) as f32,
        ex - (ec * ux) as f32,
        ey - (ec * uy) as f32,
    ))
}

/// Move point `from` toward `toward` by `cap` device pixels, clamped so it never
/// overshoots `toward`. `None` when the two points coincide (no direction).
fn move_toward(from: (f32, f32), toward: (f32, f32), cap: f64) -> Option<(f32, f32)> {
    let dx = (toward.0 - from.0) as f64;
    let dy = (toward.1 - from.1) as f64;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-9 {
        return None;
    }
    let d = cap.min(len);
    Some((
        from.0 + (d * dx / len) as f32,
        from.1 + (d * dy / len) as f32,
    ))
}

/// Trim the whole-polyline ends (first/last finite vertices) inward by the given
/// caps, along the direction of the first/last segment. Interior vertices and
/// NA-split sub-path joins are untouched. Mutates `pts` (already in local px).
pub(super) fn trim_poly_ends(pts: &mut [(f32, f32)], sc: f64, ec: f64) {
    let finite = |q: (f32, f32)| q.0.is_finite() && q.1.is_finite();
    if sc > 0.0 {
        if let Some(a) = pts.iter().position(|&q| finite(q)) {
            if let Some(b) = (a + 1..pts.len()).find(|&j| finite(pts[j])) {
                if let Some(np) = move_toward(pts[a], pts[b], sc) {
                    pts[a] = np;
                }
            }
        }
    }
    if ec > 0.0 {
        if let Some(z) = pts.iter().rposition(|&q| finite(q)) {
            if let Some(w) = (0..z).rev().find(|&j| finite(pts[j])) {
                if let Some(np) = move_toward(pts[z], pts[w], ec) {
                    pts[z] = np;
                }
            }
        }
    }
}

/// Resolve a signed perpendicular offset (absolute unit) to a device length in
/// local px. Unlike `cap_len_px` this keeps the sign — it selects the side.
pub(super) fn off_len_px(off: &[f64], offu: &[Unit], i: usize, vp: &Vp) -> f64 {
    if off.is_empty() {
        return 0.0;
    }
    let idx = if i < off.len() { i } else { off.len() - 1 };
    let u = offu.get(idx).copied().unwrap_or(Unit::plain(UnitKind::Mm));
    vp.x_len(off[idx], u) // signed; do NOT clamp
}

/// Shift a segment sideways by `o` device px along its left normal `n̂ = (-û_y, û_x)`.
/// A zero-length segment has no direction, so it is returned unchanged.
pub(super) fn offset_segment(sx: f32, sy: f32, ex: f32, ey: f32, o: f64) -> (f32, f32, f32, f32) {
    let dx = (ex - sx) as f64;
    let dy = (ey - sy) as f64;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-9 {
        return (sx, sy, ex, ey);
    }
    let (ox, oy) = ((o * -dy / len) as f32, (o * dx / len) as f32);
    (sx + ox, sy + oy, ex + ox, ey + oy)
}

/// Rigidly translate a whole polyline sideways by `o` device px along the normal of
/// its chord (first finite → last finite vertex). Non-finite points are left as-is
/// (they act as NA breaks). No-ops when the chord has no direction.
pub(super) fn offset_polyline(pts: &mut [(f32, f32)], o: f64) {
    let finite = |q: (f32, f32)| q.0.is_finite() && q.1.is_finite();
    let a = match pts.iter().position(|&q| finite(q)) {
        Some(a) => a,
        None => return,
    };
    let z = pts.iter().rposition(|&q| finite(q)).unwrap_or(a);
    let dx = (pts[z].0 - pts[a].0) as f64;
    let dy = (pts[z].1 - pts[a].1) as f64;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 1e-9 {
        return;
    }
    let (ox, oy) = ((o * -dy / len) as f32, (o * dx / len) as f32);
    for p in pts.iter_mut() {
        if finite(*p) {
            p.0 += ox;
            p.1 += oy;
        }
    }
}

/// The four device-px control points of a self-loop's cubic-Bézier teardrop
/// (igraph's `loop()` shape): it leaves and re-enters the vertex `(cx, cy)`,
/// bulging out to extent `s` along `angle` (radians), with the two feet placed on
/// the node boundary at radius `foot` (0 = both at the vertex). `width` scales only
/// the lateral (perpendicular) component of the lobes, narrowing the petal's waist
/// without changing its length (`width = 1` is the full teardrop). Control points in
/// the local frame (axis = +x) — feet along the ±lobe direction, lobes at igraph's
/// `(0.4s, ±0.2s·width)` — are rotated by `angle` about the vertex and translated to it.
pub(super) fn loop_control_points(
    cx: f64,
    cy: f64,
    s: f64,
    foot: f64,
    angle: f64,
    width: f64,
) -> [(f32, f32); 4] {
    // Unit direction of the lobe (0.4, 0.2): the feet sit on the boundary there.
    let inv = 1.0 / (0.4f64 * 0.4 + 0.2 * 0.2).sqrt();
    let (fdx, fdy) = (0.4 * inv, 0.2 * inv);
    let local = [
        (foot * fdx, foot * fdy),    // P0 — leaving foot
        (0.4 * s, 0.2 * s * width),  // P1 — lateral offset scaled by width
        (0.4 * s, -0.2 * s * width), // P2
        (foot * fdx, -foot * fdy),   // P3 — returning foot
    ];
    // `angle` is a y-up angle (0 at 3 o'clock, CCW). `(cx, cy)` is already y-down, so
    // negate the angle to rotate into the device frame — the same sign flip
    // `sector_path` applies. (The teardrop is symmetric about its +x axis, so this is a
    // pure rotation to the correct screen orientation, not a reflection of the shape.)
    let (ca, sa) = (angle.cos(), (-angle).sin());
    let mut out = [(0.0f32, 0.0f32); 4];
    for (k, &(px, py)) in local.iter().enumerate() {
        out[k] = (
            (cx + px * ca - py * sa) as f32,
            (cy + px * sa + py * ca) as f32,
        );
    }
    out
}
