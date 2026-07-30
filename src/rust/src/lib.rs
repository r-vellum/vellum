use extendr_api::prelude::*;

mod aggregate;
mod cache;
mod cvd;
mod color;
mod font;
mod oklab;
mod render;
mod scene;
mod sketch;
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
    fn rs_set_profiling;
    fn rs_take_node_times;
    use scene;
    use aggregate;
}
