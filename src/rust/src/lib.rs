use extendr_api::prelude::*;

mod aggregate;
mod color;
mod font;
mod render;
mod scene;
mod units;

/// Backend identity and build info (internal diagnostic).
#[extendr]
fn rs_backend_info() -> String {
    format!("vellum Rust backend v{}", env!("CARGO_PKG_VERSION"))
}

/// Empty the persistent glyph-outline cache (font bytes + extracted outlines).
#[extendr]
fn rs_clear_glyph_cache() {
    font::clear_glyph_cache();
}

/// Empty the repaint-boundary sub-raster cache (FW4c) and reset its counters.
#[extendr]
fn rs_clear_subraster_cache() {
    scene::clear_subraster_cache();
}

/// Sub-raster cache stats: `c(hits, misses, resident_entries)` (tests/diagnostics).
#[extendr]
fn rs_subraster_stats() -> Vec<i32> {
    scene::subraster_stats().into_iter().map(|v| v as i32).collect()
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
    use scene;
    use aggregate;
}
