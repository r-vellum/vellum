//! Geometry services for label placement (Phase 11).
//!
//! Three primitives that a layer above vellum would otherwise reimplement, and
//! that all reduce to "geometry over resolved boxes and points":
//!
//! * [`largest_empty_rect`] — where is there room to put something?
//! * [`convex_hull`] / [`concave_hull`] — what region does this group occupy?
//!
//! Repulsion itself stays on the R side: it runs over tens or hundreds of
//! boxes, not millions, and its cost is dominated by the single geometry
//! capture that feeds it.

/// The largest axis-aligned empty rectangle inside `region`, avoiding `boxes`.
///
/// Occupancy is rasterised onto an `nx` × `ny` grid and the answer found with
/// the standard largest-rectangle-in-a-histogram scan, which is O(nx·ny) and
/// exact *on the grid*. That approximation is deliberate: the exact maximal
/// empty rectangle over n boxes is superquadratic, and a legend is not placed to
/// sub-pixel tolerance. Raise `nx`/`ny` to trade time for precision.
///
/// `boxes` is a flat `[x0, y0, x1, y1, ...]`; `region` is one such quadruple.
/// Returns `[x0, y0, x1, y1]` in the same coordinates, or all-zero if the region
/// is degenerate or entirely covered.
pub fn largest_empty_rect(
    boxes: &[f64], region: [f64; 4], nx: usize, ny: usize,
) -> [f64; 4] {
    let (rx0, ry0, rx1, ry1) = (region[0], region[1], region[2], region[3]);
    let (rw, rh) = (rx1 - rx0, ry1 - ry0);
    if !(rw > 0.0) || !(rh > 0.0) || nx == 0 || ny == 0 {
        return [0.0; 4];
    }
    let (cw, ch) = (rw / nx as f64, rh / ny as f64);
    // free[r][c]: no obstacle overlaps this cell.
    let mut free = vec![true; nx * ny];
    for b in boxes.chunks_exact(4) {
        let (bx0, by0, bx1, by1) = (b[0].min(b[2]), b[1].min(b[3]), b[0].max(b[2]), b[1].max(b[3]));
        if bx1 <= rx0 || bx0 >= rx1 || by1 <= ry0 || by0 >= ry1 {
            continue;
        }
        // Any cell the box touches at all is occupied -- rounding outward keeps
        // the answer conservative, which is the right bias for "is there room".
        let c0 = (((bx0 - rx0) / cw).floor().max(0.0)) as usize;
        let c1 = (((bx1 - rx0) / cw).ceil().min(nx as f64)) as usize;
        let r0 = (((by0 - ry0) / ch).floor().max(0.0)) as usize;
        let r1 = (((by1 - ry0) / ch).ceil().min(ny as f64)) as usize;
        for r in r0..r1 {
            for c in c0..c1 {
                free[r * nx + c] = false;
            }
        }
    }
    // Row-by-row histogram of consecutive free cells above, then the stack scan.
    let mut heights = vec![0usize; nx];
    let mut best = (0usize, 0usize, 0usize, 0usize, 0usize); // area, r_end, c0, c1, height
    for r in 0..ny {
        for c in 0..nx {
            heights[c] = if free[r * nx + c] { heights[c] + 1 } else { 0 };
        }
        // Monotonic stack of (start column, height).
        let mut stack: Vec<(usize, usize)> = Vec::with_capacity(nx + 1);
        for c in 0..=nx {
            let h = if c == nx { 0 } else { heights[c] };
            let mut start = c;
            while let Some(&(s, sh)) = stack.last() {
                if sh <= h {
                    break;
                }
                stack.pop();
                let area = sh * (c - s);
                if area > best.0 {
                    best = (area, r, s, c, sh);
                }
                start = s;
            }
            if stack.last().map_or(true, |&(_, sh)| sh < h) {
                stack.push((start, h));
            }
        }
    }
    if best.0 == 0 {
        return [0.0; 4];
    }
    let (_, r_end, c0, c1, h) = best;
    [
        rx0 + c0 as f64 * cw,
        ry0 + (r_end + 1 - h) as f64 * ch,
        rx0 + c1 as f64 * cw,
        ry0 + (r_end + 1) as f64 * ch,
    ]
}

/// Convex hull by Andrew's monotone chain, returning point indices in
/// counter-clockwise order. Collinear points are dropped.
pub fn convex_hull(x: &[f64], y: &[f64]) -> Vec<usize> {
    let n = x.len().min(y.len());
    if n < 3 {
        return (0..n).collect();
    }
    let mut idx: Vec<usize> = (0..n).filter(|&i| x[i].is_finite() && y[i].is_finite()).collect();
    idx.sort_by(|&a, &b| {
        x[a].partial_cmp(&x[b])
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(y[a].partial_cmp(&y[b]).unwrap_or(std::cmp::Ordering::Equal))
    });
    if idx.len() < 3 {
        return idx;
    }
    let cross = |o: usize, a: usize, b: usize| {
        (x[a] - x[o]) * (y[b] - y[o]) - (y[a] - y[o]) * (x[b] - x[o])
    };
    let mut lower: Vec<usize> = Vec::with_capacity(idx.len());
    for &p in &idx {
        while lower.len() >= 2 && cross(lower[lower.len() - 2], lower[lower.len() - 1], p) <= 0.0 {
            lower.pop();
        }
        lower.push(p);
    }
    let mut upper: Vec<usize> = Vec::with_capacity(idx.len());
    for &p in idx.iter().rev() {
        while upper.len() >= 2 && cross(upper[upper.len() - 2], upper[upper.len() - 1], p) <= 0.0 {
            upper.pop();
        }
        upper.push(p);
    }
    lower.pop();
    upper.pop();
    lower.extend(upper);
    lower
}

/// Squared distance from point `p` to segment `a`-`b`.
fn seg_dist2(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    let (dx, dy) = (bx - ax, by - ay);
    let len2 = dx * dx + dy * dy;
    let t = if len2 > 0.0 { (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0) } else { 0.0 };
    let (qx, qy) = (ax + t * dx, ay + t * dy);
    (px - qx).powi(2) + (py - qy).powi(2)
}

/// Concave hull, by digging into the convex hull (the "concaveman" approach).
///
/// Starts from the convex hull and repeatedly replaces an edge with two edges
/// through the nearest unused point, whenever that edge is long relative to how
/// close the point is. `concavity` is the threshold: large values (or infinity)
/// give the convex hull, ~1–3 gives a tight outline, and small values risk a
/// self-intersecting boundary — which is inherent to the method, not a bug to
/// be fixed here.
///
/// Returns point indices in order.
pub fn concave_hull(x: &[f64], y: &[f64], concavity: f64) -> Vec<usize> {
    let hull = convex_hull(x, y);
    if !concavity.is_finite() || concavity <= 0.0 || hull.len() < 3 {
        return hull;
    }
    let n = x.len().min(y.len());
    let mut used = vec![false; n];
    for &h in &hull {
        used[h] = true;
    }
    let mut ring = hull;
    // Each pass digs every edge at most once; without a bound a pathological
    // input could cycle, and a partly-dug hull is a better failure than a hang.
    let max_passes = 64;
    for _ in 0..max_passes {
        let mut changed = false;
        let mut out: Vec<usize> = Vec::with_capacity(ring.len() * 2);
        for k in 0..ring.len() {
            let a = ring[k];
            let b = ring[(k + 1) % ring.len()];
            out.push(a);
            let elen2 = (x[b] - x[a]).powi(2) + (y[b] - y[a]).powi(2);
            if elen2 <= 0.0 {
                continue;
            }
            // Nearest unused point to this edge.
            let mut best: Option<(f64, usize)> = None;
            for i in 0..n {
                if used[i] || !x[i].is_finite() || !y[i].is_finite() {
                    continue;
                }
                let d2 = seg_dist2(x[i], y[i], x[a], y[a], x[b], y[b]);
                if best.map_or(true, |(bd, _)| d2 < bd) {
                    best = Some((d2, i));
                }
            }
            if let Some((d2, i)) = best {
                // Dig in when the edge is long compared with the detour.
                if elen2.sqrt() > concavity * d2.sqrt() && d2 > 0.0 {
                    out.push(i);
                    used[i] = true;
                    changed = true;
                }
            }
        }
        ring = out;
        if !changed {
            break;
        }
    }
    ring
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_rect_finds_the_gap() {
        // Two blocks with a clear vertical corridor between them.
        let boxes = [0.0, 0.0, 40.0, 100.0, 60.0, 0.0, 100.0, 100.0];
        let r = largest_empty_rect(&boxes, [0.0, 0.0, 100.0, 100.0], 100, 100);
        assert!(r[0] >= 39.0 && r[2] <= 61.0, "corridor x: {:?}", r);
        assert!(r[3] - r[1] > 95.0, "corridor is full height: {:?}", r);
    }

    #[test]
    fn empty_rect_is_zero_when_covered() {
        let boxes = [0.0, 0.0, 100.0, 100.0];
        assert_eq!(largest_empty_rect(&boxes, [0.0, 0.0, 100.0, 100.0], 32, 32), [0.0; 4]);
    }

    #[test]
    fn empty_rect_takes_the_whole_region_when_free() {
        let r = largest_empty_rect(&[], [0.0, 0.0, 10.0, 10.0], 10, 10);
        assert_eq!(r, [0.0, 0.0, 10.0, 10.0]);
    }

    #[test]
    fn hull_of_a_square_with_an_interior_point() {
        let x = [0.0, 1.0, 1.0, 0.0, 0.5];
        let y = [0.0, 0.0, 1.0, 1.0, 0.5];
        let h = convex_hull(&x, &y);
        assert_eq!(h.len(), 4, "interior point is excluded: {:?}", h);
    }

    #[test]
    fn concave_hull_digs_into_a_notch() {
        // A square with a deep notch of points pushed into the top edge.
        let mut x = vec![0.0, 10.0, 10.0, 0.0];
        let mut y = vec![0.0, 0.0, 10.0, 10.0];
        for i in 0..9 {
            x.push(1.0 + i as f64);
            y.push(5.0);
        }
        let convex = convex_hull(&x, &y);
        let concave = concave_hull(&x, &y, 1.0);
        assert!(concave.len() > convex.len(), "concave picks up notch points");
    }

    #[test]
    fn infinite_concavity_is_the_convex_hull() {
        let x = [0.0, 1.0, 1.0, 0.0, 0.5];
        let y = [0.0, 0.0, 1.0, 1.0, 0.4];
        assert_eq!(concave_hull(&x, &y, f64::INFINITY), convex_hull(&x, &y));
    }
}
