use extendr_api::prelude::*;

/// Backend identity and build info.
///
/// A trivial call to confirm the R -> Rust path is wired up. As the backend
/// grows this will report enabled render targets and engine version.
/// @export
#[extendr]
fn rs_backend_info() -> String {
    format!("rsplot Rust backend v{}", env!("CARGO_PKG_VERSION"))
}

/// Axis-aligned bounding box of a set of points.
///
/// Takes parallel `x`/`y` coordinate vectors and returns
/// `c(xmin, xmax, ymin, ymax)`. Representative of the kind of geometry work the
/// scene/layout engine will do; exercises borrowing R numeric vectors as slices
/// and returning a vector, with no copy on the way in.
///
/// @param x,y Parallel numeric vectors of point coordinates.
/// @return Numeric vector `c(xmin, xmax, ymin, ymax)`, or `NULL` if empty.
/// @export
#[extendr]
fn rs_bbox(x: &[f64], y: &[f64]) -> Robj {
    if x.len() != y.len() {
        throw_r_error("`x` and `y` must have the same length");
    }
    if x.is_empty() {
        return r!(NULL);
    }

    let (mut xmin, mut xmax) = (f64::INFINITY, f64::NEG_INFINITY);
    let (mut ymin, mut ymax) = (f64::INFINITY, f64::NEG_INFINITY);
    for (&xi, &yi) in x.iter().zip(y.iter()) {
        if xi < xmin {
            xmin = xi;
        }
        if xi > xmax {
            xmax = xi;
        }
        if yi < ymin {
            ymin = yi;
        }
        if yi > ymax {
            ymax = yi;
        }
    }

    r!([xmin, xmax, ymin, ymax])
}

// Macro to generate exports.
// This ensures exported functions are registered with R.
// See corresponding C code in `entrypoint.c`.
extendr_module! {
    mod rsplot;
    fn rs_backend_info;
    fn rs_bbox;
}
