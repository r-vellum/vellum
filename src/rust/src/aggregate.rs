//! Datashader-style aggregation: bin a (potentially enormous) point cloud into a
//! fixed canvas grid in one O(N) pass, decoupling cost from point count and from
//! overplotting. The R side then shades the returned grid (eq_hist/log/…) and
//! draws it as a single raster — far cheaper than emitting N markers when N ≫
//! pixels, and overplotting-honest (the grid records true density).

use extendr_api::prelude::*;

// Bin points `(x, y)` into an `nx` x `ny` grid over `[x0, x1] x [y0, y1]`,
// returning the grid row-major, top-left origin (row 0 = `y1`, the top), so it
// maps directly onto a raster image. Each in-range point adds its weight to its
// cell. `w` is either `NULL` (every point weighs 1) or a slice of length `n`
// (`datashade()` recycles a scalar and rejects any other length before calling);
// a slice of any other length is ignored defensively. Points outside the bounds,
// or with non-finite coordinates, are skipped. The max edges (`x1`, `y1`) fall
// into the last column / top row rather than spilling out. See `datashade()`.
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

    // Per-point weights, length-`n` (recycled/validated R-side), else all 1.0.
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

// Categorical (`count_cat`) binning: like `rs_aggregate_2d`, but keep a separate
// count grid per category in the same single O(N) pass. `cat` is a 0-based category
// index per point (points with `cat < 0` or `cat >= ncat` — e.g. an NA level — are
// skipped). The result is a flat **category-major** grid of length `ncat*nx*ny`:
// category `k`'s grid occupies `[k*nx*ny .. (k+1)*nx*ny)`, each laid out row-major
// top-left like `rs_aggregate_2d`, so the R side reshapes it to an `(nx*ny) x ncat`
// matrix with a single `matrix()` call. Binning/edge/skip rules match
// `rs_aggregate_2d` exactly. See `datashade(category=)`.
#[extendr]
fn rs_aggregate_2d_cat(x: &[f64], y: &[f64], cat: &[i32], ncat: i32, w: Robj, nx: i32, ny: i32, x0: f64, x1: f64, y0: f64, y1: f64) -> Vec<f64> {
    let nx = nx.max(1) as usize;
    let ny = ny.max(1) as usize;
    let ncat = ncat.max(0) as usize;
    let ncell = nx * ny;
    let n = x.len().min(y.len()).min(cat.len());
    let mut grid = vec![0.0f64; ncell * ncat];
    if ncat == 0 {
        return grid;
    }

    let dx = x1 - x0;
    let dy = y1 - y0;
    if !(dx.is_finite() && dy.is_finite()) || dx == 0.0 || dy == 0.0 {
        return grid;
    }
    let sx = nx as f64 / dx;
    let sy = ny as f64 / dy;

    // Per-point weights, length-`n` (recycled/validated R-side), else all 1.0.
    let weights: Option<&[f64]> = w.as_real_slice().filter(|s| s.len() == n);

    for i in 0..n {
        let k = cat[i];
        if k < 0 || (k as usize) >= ncat {
            continue; // NA / out-of-range category
        }
        let (px, py) = (x[i], y[i]);
        if !(px.is_finite() && py.is_finite()) {
            continue;
        }
        let cf = (px - x0) * sx;
        let rf = (y1 - py) * sy;
        if cf < 0.0 || rf < 0.0 {
            continue;
        }
        let mut col = cf as usize;
        let mut row = rf as usize;
        if col >= nx {
            if px <= x1 {
                col = nx - 1;
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
        grid[(k as usize) * ncell + row * nx + col] += wt;
    }
    grid
}

// ---- line / segment aggregation (anti-aliased, Wu) -------------------------
//
// Datashader's line path: rasterise many line segments into the *same* flat
// row-major top-left grid as `rs_aggregate_2d`, so the output flows through the
// identical R-side shading (`.ds_shade`/`.ds_scale`). Coverage is anti-aliased
// (Wu) and *summed*, so overlapping lines add — the density interpretation that
// makes a dense-timeseries bundle or a network hairball honest rather than a
// solid blob. A segment deposits ~`wt` per cell it spans; cells off the canvas
// are dropped (clipping). Pure `f64` arithmetic, no tiny-skia — same character
// as the point aggregator above.

// Add coverage `c` (already weight-scaled) to grid cell (`col`, `row`) if it is
// on the canvas; out-of-range cells are dropped, which clips the segment.
#[inline]
fn splat(grid: &mut [f64], nx: usize, ny: usize, col: i64, row: i64, c: f64) {
    if c > 0.0 && col >= 0 && row >= 0 {
        let (col, row) = (col as usize, row as usize);
        if col < nx && row < ny {
            grid[row * nx + col] += c;
        }
    }
}

#[inline]
fn fpart(x: f64) -> f64 {
    x - x.floor()
}
#[inline]
fn rfpart(x: f64) -> f64 {
    1.0 - fpart(x)
}

// Anti-aliased (Wu) accumulation of one segment given in *cell-centre* grid
// coordinates (cell `k`'s centre is at coordinate `k`; world->grid is therefore
// `(world - origin) * scale - 0.5`). Coverage sums to ~`wt` per major-axis step,
// so a line deposits ~`wt` per cell it spans and overlapping lines add.
fn wu_segment(grid: &mut [f64], nx: usize, ny: usize, gx0: f64, gy0: f64, gx1: f64, gy1: f64, wt: f64) {
    if wt == 0.0 || !(gx0.is_finite() && gy0.is_finite() && gx1.is_finite() && gy1.is_finite()) {
        return;
    }
    // Degenerate (zero-length) segment: deposit at its nearest cell.
    if gx0 == gx1 && gy0 == gy1 {
        splat(grid, nx, ny, (gx0 + 0.5).floor() as i64, (gy0 + 0.5).floor() as i64, wt);
        return;
    }

    let steep = (gy1 - gy0).abs() > (gx1 - gx0).abs();
    // Work along the major axis; un-swap when plotting steep segments.
    let (mut x0, mut y0, mut x1, mut y1) = if steep { (gy0, gx0, gy1, gx1) } else { (gx0, gy0, gx1, gy1) };
    if x0 > x1 {
        std::mem::swap(&mut x0, &mut x1);
        std::mem::swap(&mut y0, &mut y1);
    }
    let dx = x1 - x0;
    let dy = y1 - y0;
    let gradient = if dx == 0.0 { 1.0 } else { dy / dx };

    let plot = |grid: &mut [f64], major: i64, minor: i64, c: f64| {
        if steep {
            splat(grid, nx, ny, minor, major, c * wt);
        } else {
            splat(grid, nx, ny, major, minor, c * wt);
        }
    };

    // First endpoint.
    let xend = (x0 + 0.5).floor();
    let yend = y0 + gradient * (xend - x0);
    let xgap = rfpart(x0 + 0.5);
    let xpxl1 = xend as i64;
    let ypxl1 = yend.floor() as i64;
    plot(grid, xpxl1, ypxl1, rfpart(yend) * xgap);
    plot(grid, xpxl1, ypxl1 + 1, fpart(yend) * xgap);
    let mut intery = yend + gradient;

    // Second endpoint.
    let xend = (x1 + 0.5).floor();
    let yend = y1 + gradient * (xend - x1);
    let xgap = fpart(x1 + 0.5);
    let xpxl2 = xend as i64;
    let ypxl2 = yend.floor() as i64;
    plot(grid, xpxl2, ypxl2, rfpart(yend) * xgap);
    plot(grid, xpxl2, ypxl2 + 1, fpart(yend) * xgap);

    // Interior columns.
    let mut x = xpxl1 + 1;
    while x < xpxl2 {
        let iy = intery.floor() as i64;
        plot(grid, x, iy, rfpart(intery));
        plot(grid, x, iy + 1, fpart(intery));
        intery += gradient;
        x += 1;
    }
}

// Map a world-space segment to cell-centre grid coordinates and accumulate it.
#[allow(clippy::too_many_arguments)]
#[inline]
fn accumulate_segment(
    grid: &mut [f64], nx: usize, ny: usize, sx: f64, sy: f64, x0d: f64, y1d: f64,
     wx0: f64, wy0: f64, wx1: f64, wy1: f64, wt: f64,
) {
    let gx0 = (wx0 - x0d) * sx - 0.5;
    let gy0 = (y1d - wy0) * sy - 0.5; // top-left origin: row grows downward from y1
    let gx1 = (wx1 - x0d) * sx - 0.5;
    let gy1 = (y1d - wy1) * sy - 0.5;
    wu_segment(grid, nx, ny, gx0, gy0, gx1, gy1, wt);
}

// Bin a batch of independent line segments `(x0,y0)->(x1,y1)` into an `nx` x `ny`
// grid over `[x0d, x1d] x [y0d, y1d]`, anti-aliased and density-summed (see the
// section header). This is the network-edge / `mark_segment` case. `w` is either
// `NULL` (each segment weighs 1) or a length-`n` slice (validated R-side); a slice
// of any other length is ignored defensively. Non-finite endpoints are skipped.
// Row-major, top-left origin, identical to `rs_aggregate_2d`. See `datashade_segments()`.
#[extendr]
fn rs_aggregate_segments(
    x0: &[f64], y0: &[f64], x1: &[f64], y1: &[f64], w: Robj, nx: i32, ny: i32, x0d: f64, x1d: f64, y0d: f64, y1d: f64,
) -> Vec<f64> {
    let nx = nx.max(1) as usize;
    let ny = ny.max(1) as usize;
    let n = x0.len().min(y0.len()).min(x1.len()).min(y1.len());
    let mut grid = vec![0.0f64; nx * ny];

    let dx = x1d - x0d;
    let dy = y1d - y0d;
    if !(dx.is_finite() && dy.is_finite()) || dx == 0.0 || dy == 0.0 {
        return grid;
    }
    let sx = nx as f64 / dx;
    let sy = ny as f64 / dy;

    let weights: Option<&[f64]> = w.as_real_slice().filter(|s| s.len() == n);

    for i in 0..n {
        let wt = weights.map_or(1.0, |s| s[i]);
        accumulate_segment(&mut grid, nx, ny, sx, sy, x0d, y1d, x0[i], y0[i], x1[i], y1[i], wt);
    }
    grid
}

// Bin a connected polyline `(x[i], y[i])` into the same grid: draw a segment
// between each consecutive pair. `brk` is either `NULL` (one series) or a
// length-`n` integer group id per point — a segment is drawn only when its two
// endpoints share a group (so a change of id, like an NA gap, breaks the line),
// which is how multiple series / NA-separated timeseries are packed into one call.
// A segment's weight is the weight of its start vertex. Non-finite endpoints break
// the line. Layout matches `rs_aggregate_2d`. See `datashade_lines()`.
#[extendr]
fn rs_aggregate_lines(
    x: &[f64], y: &[f64], brk: Robj, w: Robj, nx: i32, ny: i32, x0d: f64, x1d: f64, y0d: f64, y1d: f64,
) -> Vec<f64> {
    let nx = nx.max(1) as usize;
    let ny = ny.max(1) as usize;
    let n = x.len().min(y.len());
    let mut grid = vec![0.0f64; nx * ny];

    let dx = x1d - x0d;
    let dy = y1d - y0d;
    if !(dx.is_finite() && dy.is_finite()) || dx == 0.0 || dy == 0.0 || n < 2 {
        return grid;
    }
    let sx = nx as f64 / dx;
    let sy = ny as f64 / dy;

    let ids: Option<&[i32]> = brk.as_integer_slice().filter(|s| s.len() == n);
    let weights: Option<&[f64]> = w.as_real_slice().filter(|s| s.len() == n);

    for i in 0..(n - 1) {
        if let Some(g) = ids {
            if g[i] != g[i + 1] {
                continue; // series break
            }
        }
        let (ax, ay, bx, by) = (x[i], y[i], x[i + 1], y[i + 1]);
        if !(ax.is_finite() && ay.is_finite() && bx.is_finite() && by.is_finite()) {
            continue; // NA gap
        }
        let wt = weights.map_or(1.0, |s| s[i]);
        accumulate_segment(&mut grid, nx, ny, sx, sy, x0d, y1d, ax, ay, bx, by, wt);
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
            "fractal_dream" => ((b * y).sin() + c * (b * x).sin(), (a * x).sin() + d * (a * y).sin()),
            "hopalong" => (y - x.signum() * (b * x - c).abs().sqrt(), a - x),
            "gumowski_mira" => {
                // g(t) = a*t + 2(1-a) t^2 / (1+t^2); x' = b*y + g(x); y' = -x + g(x')
                let g = |t: f64| a * t + 2.0 * (1.0 - a) * t * t / (1.0 + t * t);
                let px = b * y + g(x);
                (px, -x + g(px))
            }
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
    fn rs_aggregate_2d_cat;
    fn rs_aggregate_segments;
    fn rs_aggregate_lines;
    fn rs_attractor;
}
