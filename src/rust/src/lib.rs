use extendr_api::prelude::*;

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

// Macro to generate exports.
// This ensures exported functions are registered with R.
// See corresponding C code in `entrypoint.c`.
extendr_module! {
    mod vellum;
    fn rs_backend_info;
    use scene;
}
