use extendr_api::prelude::*;

mod aggregate;
mod booleans;
mod cache;
mod contour;
mod cvd;
mod color;
mod font;
mod oklab;
mod place;
mod render;
mod scene;
mod sketch;
mod svgpath;
mod units;

/// Backend identity and build info (internal diagnostic).
/// @keywords internal
#[extendr]
fn rs_backend_info() -> String {
    format!("vellum Rust backend v{}", env!("CARGO_PKG_VERSION"))
}

/// Empty the persistent glyph-outline cache (font bytes + extracted outlines).
/// @keywords internal
#[extendr]
fn rs_clear_glyph_cache() {
    font::clear_glyph_cache();
}

/// Empty the repaint-boundary sub-raster cache (FW4c) and reset its counters.
/// @keywords internal
#[extendr]
fn rs_clear_subraster_cache() {
    scene::clear_subraster_cache();
}

/// Set the glyph-bitmap cache mode.
/// @param mode Integer: 0 = off, 1 = auto (threshold), 2 = on.
/// @keywords internal
#[extendr]
fn rs_set_glyph_bitmap_mode(mode: i32) {
    font::set_glyph_bitmap_mode(mode);
}

/// Glyph sprite cache stats: `c(hits, misses, resident)` (tests/diagnostics).
/// @keywords internal
#[extendr]
fn rs_glyph_sprite_stats() -> Vec<i32> {
    let (h, m, n) = font::glyph_sprite_stats();
    vec![h as i32, m as i32, n as i32]
}

/// Sub-raster cache stats: `c(hits, misses, resident_entries)` (tests/diagnostics).
/// @keywords internal
#[extendr]
fn rs_subraster_stats() -> Vec<i32> {
    scene::subraster_stats().into_iter().map(|v| v as i32).collect()
}

/// Set colour-vision-deficiency simulation for subsequent renders.
///
/// @param kind One of "protanopia", "deuteranopia", "tritanopia",
///   "achromatopsia", or "" to disable.
/// @keywords internal
#[extendr]
fn rs_set_cvd_mode(kind: &str) {
    let mode = if kind.is_empty() {
        None
    } else {
        match crate::cvd::Cvd::from_name(kind) {
            Some(k) => Some(k),
            None => throw_r_error(format!("unknown cvd kind '{kind}'")),
        }
    };
    scene::set_cvd_mode(mode);
}

/// Arm or disarm per-node render timing on this thread.
/// @param on Logical.
/// @keywords internal
#[extendr]
fn rs_set_profiling(on: bool) {
    scene::set_profiling(on);
}

/// Take the per-node render times (seconds) collected since the last take.
/// @keywords internal
#[extendr]
fn rs_take_node_times() -> Vec<f64> {
    scene::take_node_times()
}

/// Set the path-simplification tolerance in device pixels (0 disables).
/// @param tol Tolerance in device px.
/// @keywords internal
#[extendr]
fn rs_set_simplify_tol(tol: f64) {
    scene::set_simplify_tol(tol);
}

/// Expand a stroked polyline into the outline of the stroke, as a fillable path.
///
/// Input and output are device pixels. `nper` gives the point count of each
/// sub-path in `x`/`y`. Returns `c(n_subpaths, len1, len2, ..., x..., y...)`:
/// the sub-path lengths followed by the flattened coordinates.
///
/// tiny-skia already ships the stroker the rasterizer uses, so this is the exact
/// same expansion that drawing performs -- not a reimplementation that could
/// drift from it.
///
/// @keywords internal
#[extendr]
fn rs_stroke_to_path(
    x: &[f64], y: &[f64], nper: &[i32], closed: bool,
    width: f64, cap: i32, join: i32, miter: f64,
) -> Vec<f64> {
    use tiny_skia::{LineCap, LineJoin, PathBuilder, Stroke};
    let mut pb = PathBuilder::new();
    let mut at = 0usize;
    for &cnt in nper {
        let cnt = cnt.max(0) as usize;
        if at + cnt > x.len().min(y.len()) || cnt < 2 {
            at += cnt;
            continue;
        }
        pb.move_to(x[at] as f32, y[at] as f32);
        for k in 1..cnt {
            pb.line_to(x[at + k] as f32, y[at + k] as f32);
        }
        if closed {
            pb.close();
        }
        at += cnt;
    }
    let path = match pb.finish() {
        Some(p) => p,
        None => return Vec::new(),
    };
    let stroke = Stroke {
        width: width as f32,
        miter_limit: miter as f32,
        line_cap: match cap {
            1 => LineCap::Butt,
            2 => LineCap::Square,
            _ => LineCap::Round,
        },
        line_join: match join {
            1 => LineJoin::Miter,
            2 => LineJoin::Bevel,
            _ => LineJoin::Round,
        },
        ..Stroke::default()
    };
    let outline = match path.stroke(&stroke, 1.0) {
        Some(o) => o,
        None => return Vec::new(),
    };
    // Flatten to polylines: the caller wants coordinates, and a fillable outline
    // of a polyline stroke is straight segments plus arcs, which flatten cleanly.
    let mut subs: Vec<Vec<(f64, f64)>> = Vec::new();
    let mut cur: Vec<(f64, f64)> = Vec::new();
    for seg in outline.segments() {
        use tiny_skia::PathSegment::*;
        match seg {
            MoveTo(p) => {
                if cur.len() >= 2 { subs.push(std::mem::take(&mut cur)); } else { cur.clear(); }
                cur.push((p.x as f64, p.y as f64));
            }
            LineTo(p) => cur.push((p.x as f64, p.y as f64)),
            QuadTo(c, p) => flatten_quad(&mut cur, c, p),
            CubicTo(c1, c2, p) => flatten_cubic(&mut cur, c1, c2, p),
            Close => {
                if let Some(&first) = cur.first() {
                    cur.push(first);
                }
                if cur.len() >= 2 { subs.push(std::mem::take(&mut cur)); } else { cur.clear(); }
            }
        }
    }
    if cur.len() >= 2 {
        subs.push(cur);
    }
    let mut out = Vec::with_capacity(1 + subs.len() + subs.iter().map(|s| s.len() * 2).sum::<usize>());
    out.push(subs.len() as f64);
    for sp in &subs {
        out.push(sp.len() as f64);
    }
    for sp in &subs {
        for p in sp {
            out.push(p.0);
        }
    }
    for sp in &subs {
        for p in sp {
            out.push(p.1);
        }
    }
    out
}

/// Flatten a quadratic segment into line segments at roughly pixel accuracy.
fn flatten_quad(out: &mut Vec<(f64, f64)>, c: tiny_skia::Point, p: tiny_skia::Point) {
    let a = *out.last().unwrap_or(&(c.x as f64, c.y as f64));
    let steps = curve_steps(a, (p.x as f64, p.y as f64));
    for i in 1..=steps {
        let t = i as f64 / steps as f64;
        let mt = 1.0 - t;
        out.push((
            mt * mt * a.0 + 2.0 * mt * t * c.x as f64 + t * t * p.x as f64,
            mt * mt * a.1 + 2.0 * mt * t * c.y as f64 + t * t * p.y as f64,
        ));
    }
}

/// Flatten a cubic segment into line segments at roughly pixel accuracy.
fn flatten_cubic(out: &mut Vec<(f64, f64)>, c1: tiny_skia::Point, c2: tiny_skia::Point, p: tiny_skia::Point) {
    let a = *out.last().unwrap_or(&(c1.x as f64, c1.y as f64));
    let steps = curve_steps(a, (p.x as f64, p.y as f64));
    for i in 1..=steps {
        let t = i as f64 / steps as f64;
        let mt = 1.0 - t;
        out.push((
            mt * mt * mt * a.0 + 3.0 * mt * mt * t * c1.x as f64
                + 3.0 * mt * t * t * c2.x as f64 + t * t * t * p.x as f64,
            mt * mt * mt * a.1 + 3.0 * mt * mt * t * c1.y as f64
                + 3.0 * mt * t * t * c2.y as f64 + t * t * t * p.y as f64,
        ));
    }
}

/// Segment count for flattening: proportional to the chord, clamped so a tiny
/// join does not cost 24 points and a long sweep is still smooth.
fn curve_steps(a: (f64, f64), b: (f64, f64)) -> usize {
    let d = ((b.0 - a.0).powi(2) + (b.1 - a.1).powi(2)).sqrt();
    (d.ceil() as usize).clamp(2, 24)
}

/// Decode a PNG file to straight (un-premultiplied) RGBA.
///
/// Returns `c(width, height, r, g, b, a, r, g, b, a, ...)` -- the two dimensions
/// followed by the pixels in row-major order, top-left first. The `png` crate is
/// already vendored for the encode path, so this needs no new dependency and no
/// R-side image package.
///
/// @param path Path to a PNG file.
/// @keywords internal
#[extendr]
fn rs_read_png(path: &str) -> Vec<i32> {
    let file = match std::fs::File::open(path) {
        Ok(f) => f,
        Err(e) => throw_r_error(format!("cannot open '{path}': {e}")),
    };
    let decoder = png::Decoder::new(std::io::BufReader::new(file));
    let mut reader = match decoder.read_info() {
        Ok(r) => r,
        Err(e) => throw_r_error(format!("not a readable PNG: {e}")),
    };
    let mut buf = vec![0u8; reader.output_buffer_size().unwrap_or(0)];
    let info = match reader.next_frame(&mut buf) {
        Ok(i) => i,
        Err(e) => throw_r_error(format!("cannot decode PNG: {e}")),
    };

    let (w, h) = (info.width as usize, info.height as usize);
    let src = &buf[..info.buffer_size()];
    // Normalise whatever the file stored (gray / gray+alpha / RGB / RGBA, 8- or
    // 16-bit) to straight 8-bit RGBA. 16-bit samples take the high byte.
    let step = match info.bit_depth {
        png::BitDepth::Sixteen => 2usize,
        _ => 1usize,
    };
    let chans = info.color_type.samples();
    let mut out = Vec::with_capacity(2 + w * h * 4);
    out.push(w as i32);
    out.push(h as i32);
    for px in 0..(w * h) {
        let at = px * chans * step;
        if at + (chans - 1) * step >= src.len() {
            throw_r_error("truncated PNG pixel data");
        }
        let s = |c: usize| src[at + c * step] as i32;
        let (r, g, b, a) = match chans {
            1 => (s(0), s(0), s(0), 255),
            2 => (s(0), s(0), s(0), s(1)),
            3 => (s(0), s(1), s(2), 255),
            _ => (s(0), s(1), s(2), s(3)),
        };
        out.extend_from_slice(&[r, g, b, a]);
    }
    out
}

// Macro to generate exports.
// This ensures exported functions are registered with R.
// See corresponding C code in `entrypoint.c`.
/// Largest axis-aligned empty rectangle in `region`, avoiding `boxes`.
///
/// @param boxes Flat numeric `c(x0, y0, x1, y1, ...)` of obstacles.
/// @param region Numeric `c(x0, y0, x1, y1)` to search within.
/// @param nx,ny Grid resolution; the answer is exact on this grid.
/// @return Numeric `c(x0, y0, x1, y1)`, all zero if there is no room.
/// @keywords internal
#[extendr]
fn rs_largest_empty_rect(boxes: &[f64], region: &[f64], nx: i32, ny: i32) -> Vec<f64> {
    if region.len() < 4 {
        return vec![0.0; 4];
    }
    let r = [region[0], region[1], region[2], region[3]];
    place::largest_empty_rect(boxes, r, nx.max(1) as usize, ny.max(1) as usize).to_vec()
}

/// Convex or concave hull of a point set, as 1-based point indices in order.
///
/// @param x,y Point coordinates.
/// @param concavity Threshold; non-finite or non-positive gives the convex hull.
/// @return Integer vector of 1-based indices.
/// @keywords internal
#[extendr]
fn rs_hull(x: &[f64], y: &[f64], concavity: f64) -> Vec<i32> {
    let idx = if concavity.is_finite() && concavity > 0.0 {
        place::concave_hull(x, y, concavity)
    } else {
        place::convex_hull(x, y)
    };
    idx.into_iter().map(|i| i as i32 + 1).collect()
}

/// Boolean operation over two sets of closed rings.
///
/// @param ax,ay,anper,bx,by,bnper Flat ring coordinates and per-ring lengths.
/// @param op 0 union, 1 intersect, 2 difference, 3 xor.
/// @param even_odd Interpret the inputs with the even-odd rule.
/// @return List of `x`, `y`, `nper`.
/// @keywords internal
#[extendr]
fn rs_path_op(
    ax: &[f64], ay: &[f64], anper: &[i32],
    bx: &[f64], by: &[f64], bnper: &[i32],
    op: i32, even_odd: bool,
) -> List {
    let (x, y, nper) = booleans::path_op(
        ax, ay, anper, bx, by, bnper, booleans::Op::from_code(op), even_odd,
    );
    list!(x = x, y = y, nper = nper)
}

/// Marching-squares contour segments at one level.
///
/// @param z Row-major grid values, `nx` wide by `ny` tall.
/// @param nx,ny Grid dimensions.
/// @param level Contour level.
/// @return Flat `c(x0, y0, x1, y1, ...)` in grid coordinates.
/// @keywords internal
#[extendr]
fn rs_contour(z: &[f64], nx: i32, ny: i32, level: f64) -> Vec<f64> {
    contour::marching_squares(z, nx.max(0) as usize, ny.max(0) as usize, level).coords
}

/// Marching-squares contours at one level, chained into polylines.
///
/// @param z Row-major grid values, `nx` wide by `ny` tall.
/// @param nx,ny Grid dimensions.
/// @param level Contour level.
/// @return List of `x`, `y`, `nper`, `closed` in grid coordinates.
/// @keywords internal
#[extendr]
fn rs_contour_lines(z: &[f64], nx: i32, ny: i32, level: f64) -> List {
    let segs = contour::marching_squares(z, nx.max(0) as usize, ny.max(0) as usize, level);
    let (x, y, nper, closed) = contour::chain(&segs.coords);
    list!(x = x, y = y, nper = nper, closed = closed)
}

/// Parse SVG path data into flattened rings.
///
/// @param d The `d` attribute of an SVG `<path>`.
/// @return List of `x`, `y`, `nper`, `closed`.
/// @keywords internal
#[extendr]
fn rs_svg_path(d: &str) -> List {
    let p = svgpath::parse(d);
    list!(x = p.x, y = p.y, nper = p.nper, closed = p.closed)
}

/// Write several scenes as the pages of one PDF.
///
/// @param scenes A list of compiled scenes.
/// @param path Output file.
/// @return Degradation warnings, de-duplicated across pages.
/// @keywords internal
#[extendr]
fn rs_pdf_pages(scenes: List, path: &str) -> Vec<String> {
    scene::pdf_pages(scenes, Some(path)).0
}

/// Several scenes as the pages of one PDF, returned as raw bytes.
///
/// @param scenes A list of compiled scenes.
/// @return A list of `bytes` and `warnings`.
/// @keywords internal
#[extendr]
fn rs_pdf_pages_raw(scenes: List) -> List {
    let (warnings, bytes) = scene::pdf_pages(scenes, None);
    list!(bytes = bytes, warnings = warnings)
}

extendr_module! {
    mod vellum;
    fn rs_backend_info;
    fn rs_clear_glyph_cache;
    fn rs_clear_subraster_cache;
    fn rs_subraster_stats;
    fn rs_set_glyph_bitmap_mode;
    fn rs_glyph_sprite_stats;
    fn rs_read_png;
    fn rs_set_cvd_mode;
    fn rs_set_simplify_tol;
    fn rs_stroke_to_path;
    fn rs_set_profiling;
    fn rs_take_node_times;
    fn rs_largest_empty_rect;
    fn rs_hull;
    fn rs_path_op;
    fn rs_contour;
    fn rs_contour_lines;
    fn rs_svg_path;
    fn rs_pdf_pages;
    fn rs_pdf_pages_raw;
    use scene;
    use aggregate;
}
