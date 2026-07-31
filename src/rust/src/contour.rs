//! Contour extraction by marching squares (Phase 12, H4).
//!
//! The input is the canvas-sized grid `datashade()` already produces — the
//! fixed-size intermediate the aggregate-then-shade design is built around — so
//! isolines over a density surface reuse work that has already been done rather
//! than adding a pass.

/// One contour level's worth of line segments, as flat `[x0, y0, x1, y1, ...]`
/// in grid coordinates (column, row), where an integer lands on a cell centre.
pub struct Segments {
    pub coords: Vec<f64>,
}

/// Linear interpolation of the crossing point between two corner values.
fn cross(v0: f64, v1: f64, level: f64) -> f64 {
    let d = v1 - v0;
    if d.abs() < f64::EPSILON {
        0.5
    } else {
        ((level - v0) / d).clamp(0.0, 1.0)
    }
}

/// Marching squares over `z` (row-major, `nx` wide by `ny` tall) at one level.
///
/// Cells with a non-finite corner are skipped entirely, so a contour breaks around
/// missing data rather than being drawn through it. (Substituting a sentinel
/// "very low" value instead would be worse in two ways: it invents a crossing
/// position inside the gap, and an infinite sentinel makes the interpolation
/// itself `NaN`.)
///
/// Saddle cells (two opposite corners above the level, two below) are resolved
/// using the mean of the four corners, so a saddle is joined the way the local
/// surface actually bends rather than by a fixed arbitrary choice.
pub fn marching_squares(z: &[f64], nx: usize, ny: usize, level: f64) -> Segments {
    let mut coords: Vec<f64> = Vec::new();
    if nx < 2 || ny < 2 || z.len() < nx * ny {
        return Segments { coords };
    }
    let at = |r: usize, c: usize| -> f64 { z[r * nx + c] };
    for r in 0..ny - 1 {
        for c in 0..nx - 1 {
            // Corners, counter-clockwise from bottom-left in grid space.
            let bl = at(r, c);
            let br = at(r, c + 1);
            let tr = at(r + 1, c + 1);
            let tl = at(r + 1, c);
            if !(bl.is_finite() && br.is_finite() && tr.is_finite() && tl.is_finite()) {
                continue; // missing data: leave a gap, do not interpolate across it
            }
            let above = |v: f64| v > level;
            let idx = (above(bl) as u8) | ((above(br) as u8) << 1)
                | ((above(tr) as u8) << 2) | ((above(tl) as u8) << 3);
            if idx == 0 || idx == 15 {
                continue;
            }
            // Crossing points on each edge, in grid coordinates.
            let (x, y) = (c as f64, r as f64);
            let bottom = [x + cross(bl, br, level), y];
            let right = [x + 1.0, y + cross(br, tr, level)];
            let top = [x + cross(tl, tr, level), y + 1.0];
            let left = [x, y + cross(bl, tl, level)];

            let mut push = |a: [f64; 2], b: [f64; 2]| {
                coords.extend_from_slice(&[a[0], a[1], b[0], b[1]]);
            };
            match idx {
                1 | 14 => push(left, bottom),
                2 | 13 => push(bottom, right),
                3 | 12 => push(left, right),
                4 | 11 => push(right, top),
                6 | 9 => push(bottom, top),
                7 | 8 => push(left, top),
                // Saddles: the centre value decides which pair of corners is
                // connected. Guessing instead produces contours that cross.
                5 | 10 => {
                    let centre = (bl + br + tr + tl) / 4.0;
                    let centre_above = centre > level;
                    if (idx == 5) == centre_above {
                        push(left, top);
                        push(bottom, right);
                    } else {
                        push(left, bottom);
                        push(right, top);
                    }
                }
                _ => {}
            }
        }
    }
    Segments { coords }
}

/// Chain marching-squares segments into polylines.
///
/// Marching squares emits one short segment per cell, in no useful order. Drawn
/// as segments that looks the same for a solid stroke and wrong for everything
/// else: a dash pattern restarts on every cell, and nothing downstream can
/// simplify, measure or close the line. Chaining is what turns the output into
/// actual isolines.
///
/// Endpoints are matched on a quantised key. The crossing points shared by two
/// adjacent cells are computed from the same two corner values by the same
/// expression, so they agree bit-for-bit; the quantisation is belt-and-braces.
///
/// Returns `(x, y, nper, closed)`.
pub fn chain(coords: &[f64]) -> (Vec<f64>, Vec<f64>, Vec<i32>, Vec<bool>) {
    use std::collections::HashMap;
    let key = |x: f64, y: f64| ((x * 1e7).round() as i64, (y * 1e7).round() as i64);
    // Endpoint -> indices of the segments touching it.
    let mut ends: HashMap<(i64, i64), Vec<usize>> = HashMap::new();
    let nseg = coords.len() / 4;
    for s in 0..nseg {
        ends.entry(key(coords[s * 4], coords[s * 4 + 1])).or_default().push(s);
        ends.entry(key(coords[s * 4 + 2], coords[s * 4 + 3])).or_default().push(s);
    }
    let mut used = vec![false; nseg];
    let (mut ox, mut oy, mut nper, mut closed) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());

    // Walk from one endpoint of a segment as far as the chain goes.
    let step = |from: (f64, f64), seg: usize, used: &[bool]| -> Option<(usize, (f64, f64))> {
        let k = key(from.0, from.1);
        for &t in ends.get(&k)? {
            if used[t] {
                continue;
            }
            let (a, b) = (
                (coords[t * 4], coords[t * 4 + 1]),
                (coords[t * 4 + 2], coords[t * 4 + 3]),
            );
            if key(a.0, a.1) == k {
                return Some((t, b));
            }
            if key(b.0, b.1) == k {
                return Some((t, a));
            }
        }
        let _ = seg;
        None
    };

    for s in 0..nseg {
        if used[s] {
            continue;
        }
        used[s] = true;
        let start = (coords[s * 4], coords[s * 4 + 1]);
        let mut pts = vec![start, (coords[s * 4 + 2], coords[s * 4 + 3])];
        // Forward from the far end.
        let mut head = pts[1];
        while let Some((t, next)) = step(head, s, &used) {
            used[t] = true;
            pts.push(next);
            head = next;
        }
        // Then backward from the original start, prepending.
        let mut tail = start;
        while let Some((t, next)) = step(tail, s, &used) {
            used[t] = true;
            pts.insert(0, next);
            tail = next;
        }
        // A ring comes back to where it began; drop the duplicate point and mark
        // it closed, so it can be filled as well as stroked.
        let is_closed = pts.len() > 2
            && key(pts[0].0, pts[0].1) == key(pts[pts.len() - 1].0, pts[pts.len() - 1].1);
        if is_closed {
            pts.pop();
        }
        if pts.len() < 2 {
            continue;
        }
        nper.push(pts.len() as i32);
        closed.push(is_closed);
        for (x, y) in pts {
            ox.push(x);
            oy.push(y);
        }
    }
    (ox, oy, nper, closed)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A radially symmetric bump, so a contour is a circle of known radius.
    fn bump(n: usize) -> Vec<f64> {
        let mut z = vec![0.0; n * n];
        let c = (n - 1) as f64 / 2.0;
        for r in 0..n {
            for col in 0..n {
                let d = (((r as f64 - c).powi(2)) + ((col as f64 - c).powi(2))).sqrt();
                z[r * n + col] = (-d * d / 50.0).exp();
            }
        }
        z
    }

    #[test]
    fn a_flat_field_has_no_contours() {
        let z = vec![1.0; 100];
        assert!(marching_squares(&z, 10, 10, 0.5).coords.is_empty());
        assert!(marching_squares(&z, 10, 10, 2.0).coords.is_empty());
    }

    #[test]
    fn a_bump_contours_at_the_expected_radius() {
        let n = 41;
        let z = bump(n);
        // exp(-d^2/50) = 0.5  =>  d = sqrt(50 ln 2) ~ 5.887
        let level: f64 = 0.5;
        let s = marching_squares(&z, n, n, level);
        assert!(!s.coords.is_empty());
        let c = (n - 1) as f64 / 2.0;
        let want = (50.0 * (2.0f64).ln()).sqrt();
        for p in s.coords.chunks_exact(2) {
            let d = ((p[0] - c).powi(2) + (p[1] - c).powi(2)).sqrt();
            assert!((d - want).abs() < 0.2, "point at radius {d}, want {want}");
        }
    }

    #[test]
    fn the_contour_closes() {
        // Every crossing point should appear exactly twice: once as the end of
        // one segment and once as the start of the next. A closed ring has no
        // loose ends.
        let n = 31;
        let s = marching_squares(&bump(n), n, n, 0.5);
        let key = |x: f64, y: f64| (((x * 1e6) as i64), ((y * 1e6) as i64));
        let mut counts = std::collections::HashMap::new();
        for p in s.coords.chunks_exact(4) {
            *counts.entry(key(p[0], p[1])).or_insert(0) += 1;
            *counts.entry(key(p[2], p[3])).or_insert(0) += 1;
        }
        assert!(counts.values().all(|&v| v == 2), "contour has loose ends");
    }

    #[test]
    fn a_higher_level_gives_a_smaller_ring() {
        let n = 41;
        let z = bump(n);
        let c = (n - 1) as f64 / 2.0;
        let radius = |lvl: f64| {
            let s = marching_squares(&z, n, n, lvl);
            s.coords.chunks_exact(2)
                .map(|p| ((p[0] - c).powi(2) + (p[1] - c).powi(2)).sqrt())
                .fold(0.0f64, f64::max)
        };
        assert!(radius(0.8) < radius(0.3));
    }

    #[test]
    fn missing_data_breaks_the_contour_instead_of_crossing_it() {
        // A ramp, so there is a contour to break. Blanking a column must leave a
        // gap there, and every emitted coordinate must still be finite -- an
        // infinite sentinel would silently produce NaN coordinates.
        let n = 11;
        let mut z: Vec<f64> = (0..n * n).map(|i| (i % n) as f64 / (n - 1) as f64).collect();
        let full = marching_squares(&z, n, n, 0.5).coords.len();
        for r in 3..6 {
            z[r * n + 5] = f64::NAN;
        }
        let s = marching_squares(&z, n, n, 0.5);
        assert!(s.coords.iter().all(|v| v.is_finite()), "no NaN coordinates");
        assert!(s.coords.len() < full, "the gap removed segments");
        assert!(!s.coords.is_empty(), "the rest of the contour survives");
    }

    #[test]
    fn chaining_a_bump_gives_one_closed_ring() {
        let n = 41;
        let s = marching_squares(&bump(n), n, n, 0.5);
        let (x, y, nper, closed) = chain(&s.coords);
        assert_eq!(nper.len(), 1, "one contour, not {} pieces", nper.len());
        assert_eq!(closed, vec![true]);
        assert_eq!(x.len(), nper[0] as usize);
        // Every segment emitted is accounted for exactly once. A ring of k
        // points came from k segments.
        assert_eq!(nper[0] as usize, s.coords.len() / 4);
        // And it is still a circle of the right radius.
        let c = (n - 1) as f64 / 2.0;
        let want = (50.0 * (2.0f64).ln()).sqrt();
        for i in 0..x.len() {
            assert!((((x[i] - c).powi(2) + (y[i] - c).powi(2)).sqrt() - want).abs() < 0.2);
        }
    }

    #[test]
    fn chaining_keeps_consecutive_points_adjacent() {
        // The point of chaining: successive points must actually be neighbours,
        // not an arbitrary permutation that happens to have the right members.
        let n = 31;
        let s = marching_squares(&bump(n), n, n, 0.5);
        let (x, y, nper, _) = chain(&s.coords);
        let k = nper[0] as usize;
        for i in 0..k {
            let j = (i + 1) % k;
            let d = ((x[i] - x[j]).powi(2) + (y[i] - y[j]).powi(2)).sqrt();
            assert!(d < 2.0, "step {d} between consecutive points");
        }
    }

    #[test]
    fn two_separate_contours_chain_separately() {
        // Two bumps side by side: two rings, not one impossible ring joining them.
        let (w, h) = (60usize, 30usize);
        let mut z = vec![0.0; w * h];
        for r in 0..h {
            for c in 0..w {
                for cx in [15.0f64, 45.0] {
                    let d2 = (c as f64 - cx).powi(2) + (r as f64 - 15.0).powi(2);
                    z[r * w + c] += (-d2 / 50.0).exp();
                }
            }
        }
        let (_, _, nper, closed) = chain(&marching_squares(&z, w, h, 0.5).coords);
        assert_eq!(nper.len(), 2);
        assert_eq!(closed, vec![true, true]);
    }

    #[test]
    fn an_open_contour_chains_without_closing() {
        // A ramp: the contour runs off both edges of the grid, so it is a line
        // rather than a ring.
        let n = 11;
        let z: Vec<f64> = (0..n * n).map(|i| (i % n) as f64 / (n - 1) as f64).collect();
        let (_, _, nper, closed) = chain(&marching_squares(&z, n, n, 0.5).coords);
        assert_eq!(nper.len(), 1);
        assert_eq!(closed, vec![false]);
    }

    #[test]
    fn chaining_nothing_yields_nothing() {
        let (x, _, nper, _) = chain(&[]);
        assert!(x.is_empty() && nper.is_empty());
    }

    #[test]
    fn saddles_are_resolved_rather_than_guessed() {
        // A 2x2 field with two high corners on one diagonal: the classic
        // ambiguous case. It must produce two segments, not four or zero.
        let z = vec![1.0, 0.0, 0.0, 1.0];
        let s = marching_squares(&z, 2, 2, 0.5);
        assert_eq!(s.coords.len(), 8, "two segments");
    }
}
