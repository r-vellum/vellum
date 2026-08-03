//! Colour-vision-deficiency simulation.
//!
//! Applied as a post-pass over the finished raster, so it costs nothing until
//! asked for and needs no cooperation from the drawing code. This is a *checking*
//! tool -- render a plot as a viewer with a given deficiency would see it -- which
//! is why it lives on the raster path only: the answer you want is an image to
//! look at, not a vector document.
//!
//! Method: Brettel/Viénot-style simulation via the Machado, Oliveira & Fernandes
//! (2009) severity-1.0 matrices, which are the ones most tools (Chrome DevTools,
//! Sim Daltonism, colorspace's `simulate_cvd`) ship. The matrices act on
//! **linear-light** RGB, so each pixel is de-gamma'd, transformed and re-gamma'd
//! rather than mangled in sRGB space -- doing it in sRGB is the common shortcut
//! and it visibly shifts lightness.
//!
//! Achromatopsia is the exception: total colour blindness is a luminance
//! projection, and the standard is to use Rec. 709 luma weights on linear light.

use tiny_skia::Pixmap;

/// Which deficiency to simulate.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cvd {
    /// Red-blind (~1% of men).
    Protanopia,
    /// Green-blind (~1% of men). The most common form, and the one that breaks
    /// red/green encodings.
    Deuteranopia,
    /// Blue-blind (rare, ~0.001%).
    Tritanopia,
    /// Total colour blindness -- also a decent proxy for "will this survive
    /// greyscale printing?".
    Achromatopsia,
}

impl Cvd {
    /// Parse the R-side name. Returns `None` for anything unrecognised, which the
    /// caller turns into an R error listing the valid values.
    pub fn from_name(s: &str) -> Option<Cvd> {
        match s {
            "protanopia" => Some(Cvd::Protanopia),
            "deuteranopia" => Some(Cvd::Deuteranopia),
            "tritanopia" => Some(Cvd::Tritanopia),
            "achromatopsia" => Some(Cvd::Achromatopsia),
            _ => None,
        }
    }

    /// Row-major 3x3 matrix acting on linear-light RGB.
    fn matrix(self) -> [f32; 9] {
        match self {
            Cvd::Protanopia => [
                0.152286, 1.052583, -0.204868, 0.114503, 0.786281, 0.099216, -0.003882,
                -0.048116, 1.051998,
            ],
            Cvd::Deuteranopia => [
                0.367322, 0.860646, -0.227968, 0.280085, 0.672501, 0.047413, -0.011820,
                0.042940, 0.968881,
            ],
            Cvd::Tritanopia => [
                1.255528, -0.076749, -0.178779, -0.078411, 0.930809, 0.147602, 0.004733,
                0.691367, 0.303900,
            ],
            // Rec. 709 luma, replicated across the three channels.
            Cvd::Achromatopsia => [
                0.2126, 0.7152, 0.0722, 0.2126, 0.7152, 0.0722, 0.2126, 0.7152, 0.0722,
            ],
        }
    }
}

#[inline]
fn to_linear(c: f32) -> f32 {
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

#[inline]
fn to_srgb(c: f32) -> f32 {
    let c = c.clamp(0.0, 1.0);
    if c <= 0.0031308 {
        c * 12.92
    } else {
        1.055 * c.powf(1.0 / 2.4) - 0.055
    }
}

/// Simulate `kind` for a single sRGB colour.
///
/// The same matrices and the same linear-light path as [`apply()`], so a linter
/// asking "would a viewer see these two fills as one colour" gets the answer the
/// rendered image would actually show rather than a second, drifting
/// approximation of it. Alpha is carried through untouched.
pub fn simulate(c: crate::color::Rgba, kind: Cvd) -> crate::color::Rgba {
    let m = kind.matrix();
    let r = to_linear(c.r as f32 / 255.0);
    let g = to_linear(c.g as f32 / 255.0);
    let b = to_linear(c.b as f32 / 255.0);
    let q = |v: f32| (to_srgb(v) * 255.0).round().clamp(0.0, 255.0) as u8;
    crate::color::Rgba {
        r: q(m[0] * r + m[1] * g + m[2] * b),
        g: q(m[3] * r + m[4] * g + m[5] * b),
        b: q(m[6] * r + m[7] * g + m[8] * b),
        a: c.a,
    }
}

/// Simulate `kind` over a finished pixmap, in place.
///
/// The pixmap is **premultiplied**, so each pixel is un-premultiplied first,
/// transformed, and re-premultiplied -- transforming premultiplied values would
/// tint translucent pixels toward black in proportion to their transparency.
/// Fully transparent pixels are left alone (they have no colour to simulate).
pub fn apply(pm: &mut Pixmap, kind: Cvd) {
    let m = kind.matrix();
    // 8-bit input means only 256 distinct values per channel, so the expensive
    // part (the sRGB transfer function) can be tabulated once per call.
    let lut: [f32; 256] = std::array::from_fn(|i| to_linear(i as f32 / 255.0));

    for px in pm.pixels_mut() {
        let a = px.alpha();
        if a == 0 {
            continue;
        }
        let d = px.demultiply();
        let (r, g, b) = (lut[d.red() as usize], lut[d.green() as usize], lut[d.blue() as usize]);
        let nr = to_srgb(m[0] * r + m[1] * g + m[2] * b);
        let ng = to_srgb(m[3] * r + m[4] * g + m[5] * b);
        let nb = to_srgb(m[6] * r + m[7] * g + m[8] * b);
        let q = |v: f32| (v * 255.0).round().clamp(0.0, 255.0) as u8;
        // `from_rgba8` premultiplies for us, so hand it straight (un-premultiplied)
        // channels plus the original alpha.
        *px = tiny_skia::ColorU8::from_rgba(q(nr), q(ng), q(nb), a).premultiply();
    }
}
