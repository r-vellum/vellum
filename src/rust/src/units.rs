//! The unit system and its resolution to device pixels.
//!
//! A coordinate is a `(value, Unit)` pair. Resolution happens against a
//! resolved viewport (`Vp`) and the device DPI. The device coordinate space
//! used here is **top-left origin** (matching the raster backend); R's
//! bottom-left convention is handled by the y-resolvers, which flip.

/// Coordinate systems supported in M1.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Unit {
    /// Normalised parent coordinates: 0 = bottom/left, 1 = top/right.
    Npc,
    /// User coordinates relative to the viewport's `xscale`/`yscale`.
    Native,
    Mm,
    Inch,
    Pt,
}

impl Unit {
    /// Parse a unit string. Unknown strings fall back to `Npc`; callers should
    /// validate (we do, on the R side) so this is only a safety net.
    pub fn parse(s: &str) -> Unit {
        match s {
            "native" => Unit::Native,
            "mm" => Unit::Mm,
            "in" | "inch" | "inches" => Unit::Inch,
            "pt" | "points" => Unit::Pt,
            _ => Unit::Npc,
        }
    }

    /// Length of one absolute unit in device pixels, if absolute.
    fn abs_px(self, value: f64, dpi: f64) -> Option<f64> {
        match self {
            Unit::Mm => Some(value / 25.4 * dpi),
            Unit::Inch => Some(value * dpi),
            Unit::Pt => Some(value / 72.0 * dpi),
            _ => None,
        }
    }
}

/// A resolved viewport: a rectangle in device pixels (top-left origin) plus the
/// native scales that map user coordinates onto it.
#[derive(Clone, Copy, Debug)]
pub struct Vp {
    pub x0: f64,
    pub top: f64,
    pub w: f64,
    pub h: f64,
    pub xscale: (f64, f64),
    pub yscale: (f64, f64),
}

impl Vp {
    /// X position in device pixels.
    pub fn x_pos(&self, value: f64, u: Unit, dpi: f64) -> f64 {
        self.x0 + self.x_len(value, u, dpi)
    }

    /// Y position in device pixels (flips R's bottom-left convention).
    pub fn y_pos(&self, value: f64, u: Unit, dpi: f64) -> f64 {
        let from_bottom = self.y_len(value, u, dpi);
        self.top + self.h - from_bottom
    }

    /// Horizontal length in device pixels.
    pub fn x_len(&self, value: f64, u: Unit, dpi: f64) -> f64 {
        if let Some(px) = u.abs_px(value, dpi) {
            return px;
        }
        match u {
            Unit::Npc => value * self.w,
            Unit::Native => value / span(self.xscale) * self.w,
            _ => unreachable!("absolute handled above"),
        }
    }

    /// Vertical length in device pixels.
    pub fn y_len(&self, value: f64, u: Unit, dpi: f64) -> f64 {
        if let Some(px) = u.abs_px(value, dpi) {
            return px;
        }
        match u {
            Unit::Npc => value * self.h,
            Unit::Native => value / span(self.yscale) * self.h,
            _ => unreachable!("absolute handled above"),
        }
    }

    /// Radius-like length: npc is taken against the smaller viewport dimension
    /// (snpc-style), so circles stay round; native uses the x scale.
    pub fn r_len(&self, value: f64, u: Unit, dpi: f64) -> f64 {
        if let Some(px) = u.abs_px(value, dpi) {
            return px;
        }
        match u {
            Unit::Npc => value * self.w.min(self.h),
            Unit::Native => value / span(self.xscale) * self.w,
            _ => unreachable!("absolute handled above"),
        }
    }
}

fn span((lo, hi): (f64, f64)) -> f64 {
    let s = hi - lo;
    if s == 0.0 {
        1.0
    } else {
        s
    }
}
