//! Colours and graphical parameters (with inheritance).
//!
//! Colour *names* are resolved on the R side (via `grDevices::col2rgb`), so the
//! backend only ever sees RGBA bytes. This keeps R's full colour vocabulary
//! without reimplementing it here.
//!
//! Graphical parameters inherit down the viewport/node tree. Each viewport and
//! node carries a [`PartialGpar`] whose fields are either inherited or set; the
//! effective value is found by folding from the root. `alpha` is special: it is
//! NOT baked into a colour at construction (that would double-apply down the
//! chain); instead it accumulates multiplicatively and is applied once when the
//! gpar is resolved for drawing.

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
    pub const BLACK: Rgba = Rgba { r: 0, g: 0, b: 0, a: 255 };

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
/// `c(r, g, b, a)` becomes a colour, anything else becomes `None` ("no paint").
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

/// A graphical parameter that is either inherited from an ancestor or set here.
#[derive(Clone, Copy, Debug)]
pub enum Inh<T> {
    Inherit,
    Set(T),
}

/// A possibly-partial set of graphical parameters, as attached to a viewport or
/// a primitive. Built from R, where the encoding is:
///   * colour: `NULL` -> Inherit, length-4 int -> Set(colour), else -> Set(none)
///   * lwd/alpha: `NULL`/`NA` -> Inherit, finite number -> Set
#[derive(Clone, Copy, Debug)]
pub struct PartialGpar {
    pub fill: Inh<Option<Rgba>>,
    pub col: Inh<Option<Rgba>>,
    pub lwd: Inh<f64>,
    pub alpha: Inh<f64>,
}

impl PartialGpar {
    pub fn from_robj(fill: &Robj, col: &Robj, lwd: &Robj, alpha: &Robj) -> Self {
        PartialGpar {
            fill: inh_color(fill),
            col: inh_color(col),
            lwd: inh_f64(lwd),
            alpha: inh_f64(alpha),
        }
    }
}

fn inh_color(obj: &Robj) -> Inh<Option<Rgba>> {
    if obj.is_null() {
        Inh::Inherit
    } else {
        // length-4 int -> a colour; anything else present -> explicit "no paint"
        Inh::Set(opt_color(obj))
    }
}

fn inh_f64(obj: &Robj) -> Inh<f64> {
    match obj.as_real() {
        Some(v) if v.is_finite() => Inh::Set(v),
        _ => Inh::Inherit,
    }
}

/// Accumulated graphical parameters while folding down the tree. `alpha` is the
/// running product; colours are not yet alpha-adjusted.
#[derive(Clone, Copy, Debug)]
pub struct GparAcc {
    pub fill: Option<Rgba>,
    pub col: Option<Rgba>,
    pub lwd: f64,
    pub alpha: f64,
}

impl GparAcc {
    /// Root defaults: no fill, black stroke, lwd 1, fully opaque.
    pub fn root_default() -> Self {
        GparAcc {
            fill: None,
            col: Some(Rgba::BLACK),
            lwd: 1.0,
            alpha: 1.0,
        }
    }

    /// Fold a partial gpar onto this accumulator (more-specific overrides).
    pub fn apply(self, p: &PartialGpar) -> Self {
        GparAcc {
            fill: match p.fill {
                Inh::Set(v) => v,
                Inh::Inherit => self.fill,
            },
            col: match p.col {
                Inh::Set(v) => v,
                Inh::Inherit => self.col,
            },
            lwd: match p.lwd {
                Inh::Set(v) => v,
                Inh::Inherit => self.lwd,
            },
            alpha: match p.alpha {
                Inh::Set(v) => self.alpha * v,
                Inh::Inherit => self.alpha,
            },
        }
    }

    /// Resolve to concrete drawing parameters, applying the accumulated alpha.
    pub fn resolve(self) -> Gpar {
        Gpar {
            fill: self.fill.map(|c| c.with_alpha(self.alpha)),
            col: self.col.map(|c| c.with_alpha(self.alpha)),
            lwd: self.lwd,
        }
    }
}

/// Effective graphical parameters for a single primitive (alpha already applied).
#[derive(Clone, Copy, Debug)]
pub struct Gpar {
    pub fill: Option<Rgba>,
    pub col: Option<Rgba>,
    /// Line width in R "lwd" units (1 == 1/96 inch).
    pub lwd: f64,
}

impl Gpar {
    /// Stroke width in device pixels.
    pub fn lwd_px(&self, dpi: f64) -> f32 {
        (self.lwd * dpi / 96.0) as f32
    }
}
