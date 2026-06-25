//! Colours and graphical parameters.
//!
//! Colour *names* are resolved on the R side (via `grDevices::col2rgb`), so the
//! backend only ever sees RGBA bytes. This keeps R's full colour vocabulary
//! without reimplementing it here.

use extendr_api::prelude::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rgba {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl Rgba {
    pub const WHITE: Rgba = Rgba { r: 255, g: 255, b: 255, a: 255 };

    /// Apply a multiplicative alpha (gpar `alpha`, in 0..=1) to this colour.
    pub fn with_alpha(self, alpha: f64) -> Rgba {
        let a = (self.a as f64 * alpha.clamp(0.0, 1.0)).round() as u8;
        Rgba { a, ..self }
    }

    pub fn to_skia(self) -> tiny_skia::Color {
        tiny_skia::Color::from_rgba8(self.r, self.g, self.b, self.a)
    }
}

/// Parse an optional colour from an R object: a length-4 integer vector
/// `c(r, g, b, a)` becomes a colour, anything else (`NULL`, `NA`) becomes
/// `None`, meaning "do not paint" (no fill / no stroke).
pub fn opt_color(obj: &Robj) -> Option<Rgba> {
    let s = obj.as_integer_slice()?;
    if s.len() < 4 {
        return None;
    }
    Some(Rgba {
        r: s[0].clamp(0, 255) as u8,
        g: s[1].clamp(0, 255) as u8,
        b: s[2].clamp(0, 255) as u8,
        a: s[3].clamp(0, 255) as u8,
    })
}

/// Resolved graphical parameters for a single primitive.
#[derive(Clone, Copy, Debug)]
pub struct Gpar {
    pub fill: Option<Rgba>,
    pub col: Option<Rgba>,
    /// Line width in R "lwd" units (1 == 1/96 inch).
    pub lwd: f64,
}

impl Gpar {
    pub fn new(fill: &Robj, col: &Robj, lwd: f64, alpha: f64) -> Self {
        Gpar {
            fill: opt_color(fill).map(|c| c.with_alpha(alpha)),
            col: opt_color(col).map(|c| c.with_alpha(alpha)),
            lwd,
        }
    }

    /// Stroke width in device pixels.
    pub fn lwd_px(&self, dpi: f64) -> f32 {
        (self.lwd * dpi / 96.0) as f32
    }
}
