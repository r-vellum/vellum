//! True-geometry hit-testing (Phase 15).
//!
//! `scene_model()` reports each element's *bounding box*, which is all a host
//! needs for a rectangular brush and is wrong for anything diagonal or thin. A
//! segment's bbox is the whole rectangle spanned by its endpoints, so a
//! bbox-distance "nearest" snaps to it from anywhere inside that rectangle —
//! which is why `vellumwidget` excludes graph edges from open-space hover
//! entirely (`srcts/index.ts:1316-1321`).
//!
//! This module supplies the geometry the box was standing in for.

/// Squared distance from a point to a segment.
pub fn seg_dist2(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) -> f64 {
    let (dx, dy) = (bx - ax, by - ay);
    let len2 = dx * dx + dy * dy;
    let t = if len2 > 0.0 {
        (((px - ax) * dx + (py - ay) * dy) / len2).clamp(0.0, 1.0)
    } else {
        0.0
    };
    let (qx, qy) = (ax + t * dx, ay + t * dy);
    (px - qx).powi(2) + (py - qy).powi(2)
}

/// Is a point inside a ring? Even-odd crossing test.
pub fn point_in_ring(px: f64, py: f64, xs: &[f64], ys: &[f64]) -> bool {
    let n = xs.len().min(ys.len());
    if n < 3 {
        return false;
    }
    let mut inside = false;
    let mut j = n - 1;
    for i in 0..n {
        if (ys[i] > py) != (ys[j] > py) {
            let t = (py - ys[i]) / (ys[j] - ys[i]);
            if px < xs[i] + t * (xs[j] - xs[i]) {
                inside = !inside;
            }
        }
        j = i;
    }
    inside
}

/// Distance from a point to a polyline or ring, in the same units as the
/// coordinates.
///
/// `closed` treats the geometry as a ring: the last vertex joins the first, and
/// a point *inside* is at distance zero. That distinction is what makes a
/// filled polygon behave like a region rather than an outline — clicking the
/// middle of a country on a choropleth should hit it.
pub fn poly_dist(px: f64, py: f64, xs: &[f64], ys: &[f64], closed: bool) -> f64 {
    let n = xs.len().min(ys.len());
    if n == 0 {
        return f64::INFINITY;
    }
    if n == 1 {
        return ((px - xs[0]).powi(2) + (py - ys[0]).powi(2)).sqrt();
    }
    if closed && point_in_ring(px, py, xs, ys) {
        return 0.0;
    }
    let mut best = f64::INFINITY;
    for i in 0..n - 1 {
        best = best.min(seg_dist2(px, py, xs[i], ys[i], xs[i + 1], ys[i + 1]));
    }
    if closed {
        best = best.min(seg_dist2(px, py, xs[n - 1], ys[n - 1], xs[0], ys[0]));
    }
    best.sqrt()
}

/// Distance from a point to an axis-aligned rectangle; zero inside.
pub fn rect_dist(px: f64, py: f64, x0: f64, y0: f64, x1: f64, y1: f64) -> f64 {
    let (lo_x, hi_x) = (x0.min(x1), x0.max(x1));
    let (lo_y, hi_y) = (y0.min(y1), y0.max(y1));
    let dx = (lo_x - px).max(0.0).max(px - hi_x);
    let dy = (lo_y - py).max(0.0).max(py - hi_y);
    (dx * dx + dy * dy).sqrt()
}

/// Distance from a point to a circle's disc; zero inside.
pub fn circle_dist(px: f64, py: f64, cx: f64, cy: f64, r: f64) -> f64 {
    (((px - cx).powi(2) + (py - cy).powi(2)).sqrt() - r.abs()).max(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segment_distance_is_perpendicular_not_bbox() {
        // The case that motivates the module: a point near the *corner* of a
        // diagonal's bbox is far from the diagonal itself. A bbox test would
        // report zero.
        let d = poly_dist(0.0, 10.0, &[0.0, 10.0], &[0.0, 10.0], false);
        assert!((d - (50.0f64).sqrt()).abs() < 1e-9, "got {d}");
        assert_eq!(rect_dist(0.0, 10.0, 0.0, 0.0, 10.0, 10.0), 0.0, "bbox says inside");
    }

    #[test]
    fn a_point_on_the_segment_is_at_zero() {
        assert!(poly_dist(5.0, 5.0, &[0.0, 10.0], &[0.0, 10.0], false) < 1e-12);
    }

    #[test]
    fn distance_clamps_to_the_endpoints() {
        // Beyond the end, the nearest point is the endpoint, not the infinite line.
        let d = poly_dist(-3.0, 0.0, &[0.0, 10.0], &[0.0, 0.0], false);
        assert!((d - 3.0).abs() < 1e-9, "got {d}");
    }

    #[test]
    fn a_filled_ring_contains_its_interior() {
        let xs = [0.0, 10.0, 10.0, 0.0];
        let ys = [0.0, 0.0, 10.0, 10.0];
        assert_eq!(poly_dist(5.0, 5.0, &xs, &ys, true), 0.0);
        // Open, the same point is 5 from the nearest edge.
        assert!((poly_dist(5.0, 5.0, &xs, &ys, false) - 5.0).abs() < 1e-9);
        // Outside is the same either way.
        assert!((poly_dist(15.0, 5.0, &xs, &ys, true) - 5.0).abs() < 1e-9);
    }

    #[test]
    fn point_in_ring_handles_a_concave_shape() {
        // An L: the notch is outside even though it is inside the bbox.
        let xs = [0.0, 10.0, 10.0, 4.0, 4.0, 0.0];
        let ys = [0.0, 0.0, 4.0, 4.0, 10.0, 10.0];
        assert!(point_in_ring(2.0, 2.0, &xs, &ys));
        assert!(!point_in_ring(8.0, 8.0, &xs, &ys), "the notch is outside");
    }

    #[test]
    fn circle_distance_is_to_the_disc() {
        assert_eq!(circle_dist(0.0, 0.0, 0.0, 0.0, 5.0), 0.0);
        assert!((circle_dist(10.0, 0.0, 0.0, 0.0, 5.0) - 5.0).abs() < 1e-9);
    }

    #[test]
    fn rect_distance_is_zero_inside_and_euclidean_outside() {
        assert_eq!(rect_dist(5.0, 5.0, 0.0, 0.0, 10.0, 10.0), 0.0);
        assert!((rect_dist(13.0, 14.0, 0.0, 0.0, 10.0, 10.0) - 5.0).abs() < 1e-9);
    }

    #[test]
    fn degenerate_geometry_does_not_panic() {
        assert!(poly_dist(0.0, 0.0, &[], &[], false).is_infinite());
        assert_eq!(poly_dist(3.0, 4.0, &[0.0], &[0.0], false), 5.0);
        assert!(!point_in_ring(0.0, 0.0, &[0.0, 1.0], &[0.0, 1.0]));
    }
}
