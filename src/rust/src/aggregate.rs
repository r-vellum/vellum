//! Datashader-style aggregation: bin a (potentially enormous) point cloud into a
//! fixed canvas grid in one O(N) pass, decoupling cost from point count and from
//! overplotting. The R side then shades the returned grid (eq_hist/log/…) and
//! draws it as a single raster — far cheaper than emitting N markers when N ≫
//! pixels, and overplotting-honest (the grid records true density).

use extendr_api::prelude::*;

// Bin points `(x, y)` into an `nx` x `ny` grid over `[x0, x1] x [y0, y1]`,
// returning the grid row-major, top-left origin (row 0 = `y1`, the top), so it
// maps directly onto a raster image. Each in-range point adds its weight (`w`,
// recycled / defaulting to 1) to its cell. Points outside the bounds, or with
// non-finite coordinates, are skipped. The max edges (`x1`, `y1`) fall into the
// last column / top row rather than spilling out. Internal — see `datashade()`.
// (Plain `//` not `///`: keep this out of the generated R wrappers / Rd.)
#[extendr]
fn rs_aggregate_2d(x: &[f64], y: &[f64], w: Robj, nx: i32, ny: i32, x0: f64, x1: f64, y0: f64, y1: f64) -> Vec<f64> {
    let nx = nx.max(1) as usize;
    let ny = ny.max(1) as usize;
    let n = x.len().min(y.len());
    let mut grid = vec![0.0f64; nx * ny];

    let dx = x1 - x0;
    let dy = y1 - y0;
    if !(dx.is_finite() && dy.is_finite()) || dx == 0.0 || dy == 0.0 {
        return grid;
    }
    let sx = nx as f64 / dx;
    let sy = ny as f64 / dy;

    // Optional per-point weights: a real vector of matching length, else all 1.0.
    let weights: Option<&[f64]> = w.as_real_slice().filter(|s| s.len() == n);

    for i in 0..n {
        let (px, py) = (x[i], y[i]);
        if !(px.is_finite() && py.is_finite()) {
            continue;
        }
        // Column from x (left->right), row from y (top = y1).
        let cf = (px - x0) * sx;
        let rf = (y1 - py) * sy;
        if cf < 0.0 || rf < 0.0 {
            continue;
        }
        let mut col = cf as usize;
        let mut row = rf as usize;
        if col >= nx {
            if px <= x1 {
                col = nx - 1; // include the max edge
            } else {
                continue;
            }
        }
        if row >= ny {
            if py >= y0 {
                row = ny - 1;
            } else {
                continue;
            }
        }
        let wt = weights.map_or(1.0, |s| s[i]);
        grid[row * nx + col] += wt;
    }
    grid
}

// Iterate a strange-attractor map `n` steps from `(x0, y0)`, returning the orbit
// as a flat `[x0..xn, y0..yn]` vector (length `2n`; the R side splits it). The
// per-step recurrence is sequential (each point depends on the last), so this
// tight Rust loop is the analog of datashader's Numba kernel — it makes 10M-point
// attractors practical to feed `datashade()`. `kind` selects the family; unknown
// kinds fall back to Clifford. Internal (used by inst/examples/attractors.R).
#[extendr]
#[allow(clippy::many_single_char_names)]
fn rs_attractor(kind: &str, n: i32, a: f64, b: f64, c: f64, d: f64, x0: f64, y0: f64) -> Vec<f64> {
    let n = n.max(0) as usize;
    let mut out = vec![0.0f64; 2 * n];
    let (mut x, mut y) = (x0, y0);
    for i in 0..n {
        let (nx, ny) = match kind {
            "dejong" => ((a * y).sin() - (b * x).cos(), (c * x).sin() - (d * y).cos()),
            "svensson" => (d * (a * x).sin() - (b * y).sin(), c * (a * x).cos() + (b * y).cos()),
            "bedhead" => ((x * y / b).sin() * y + (a * x - y).cos(), x + (y).sin() / b),
            // clifford (default)
            _ => ((a * y).sin() + c * (a * x).cos(), (b * x).sin() + d * (b * y).cos()),
        };
        x = nx;
        y = ny;
        out[i] = x;
        out[n + i] = y;
    }
    out
}

extendr_module! {
    mod aggregate;
    fn rs_aggregate_2d;
    fn rs_attractor;
}
