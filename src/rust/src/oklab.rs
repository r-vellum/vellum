//! Perceptual gradient interpolation via Oklab.
//!
//! sRGB (gamma-encoded 8-bit) is the wrong space to interpolate colour in: a ramp
//! mixed there passes through muddy, over-dark midtones and can drift in hue.
//! **Oklab** (Björn Ottosson, 2020) is a perceptually-uniform space, so a straight
//! line between two colours in it stays even and vivid — the same reason CSS made
//! `oklab` a gradient interpolation space.
//!
//! No backend (tiny-skia 0.11, the SVG serializer, krilla) exposes an
//! interpolation-space control, so we do the colour science here and hand every
//! backend what it already understands: **densely pre-sampled sRGB stops**. When a
//! gradient asks for `oklab`, each author-stop segment is sampled at several points
//! computed in Oklab and converted back to sRGB8; the backend's residual sRGB
//! interpolation between two adjacent dense samples is then imperceptible. This is
//! uniform and correct across raster/SVG/PDF, and `Interp::Srgb` returns the author
//! stops untouched (byte-for-byte unchanged output).
//!
//! The conversion is the small, stable, well-specified Oklab transform (a ~40-line
//! matrix pair), so it is implemented directly rather than pulling in a colour crate
//! — keeping the vendored-crate budget and MSRV unchanged.

use crate::color::{Rgba, Stop};

/// Colour space a gradient interpolates its stops in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Interp {
    /// Interpolate in gamma-encoded sRGB (the backends' native behaviour).
    Srgb,
    /// Interpolate perceptually in Oklab (pre-sampled to sRGB stops).
    Oklab,
}

impl Interp {
    pub fn parse(s: &str) -> Interp {
        match s {
            "oklab" => Interp::Oklab,
            _ => Interp::Srgb,
        }
    }
}

/// Samples per author-stop segment when pre-sampling in a perceptual space, and a
/// cap on the total so a many-stop gradient can't explode the `<defs>` / shading.
const SAMPLES_PER_SEGMENT: usize = 32;
const MAX_STOPS: usize = 256;

/// Return the stops a backend should interpolate linearly in sRGB to realise
/// `interp`. `Srgb` is the identity (author stops unchanged). `Oklab` expands each
/// adjacent-stop segment into densely pre-sampled sRGB stops walked in Oklab, so
/// the backends' sRGB interpolation between adjacent samples reproduces the
/// perceptual curve. Endpoints are preserved exactly.
pub fn interpolate_stops(stops: &[Stop], interp: Interp) -> Vec<Stop> {
    if interp == Interp::Srgb || stops.len() < 2 {
        return stops.to_vec();
    }
    let nseg = stops.len() - 1;
    // Keep the total bounded: fewer samples per segment when there are many.
    let k = (MAX_STOPS / nseg).clamp(2, SAMPLES_PER_SEGMENT);
    let mut out = Vec::with_capacity(nseg * k + 1);
    out.push(stops[0]);
    for pair in stops.windows(2) {
        let (s0, s1) = (pair[0], pair[1]);
        let (lab0, a0) = rgba_to_oklab(s0.color);
        let (lab1, a1) = rgba_to_oklab(s1.color);
        let span = s1.offset - s0.offset;
        for j in 1..=k {
            let t = j as f32 / k as f32;
            let lab = [
                lerp(lab0[0], lab1[0], t),
                lerp(lab0[1], lab1[1], t),
                lerp(lab0[2], lab1[2], t),
            ];
            out.push(Stop {
                offset: s0.offset + span * t,
                color: oklab_to_rgba(lab, lerp(a0, a1, t)),
            });
        }
    }
    out
}

#[inline]
fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

/// One sRGB channel byte -> linear-light [0, 1].
#[inline]
fn srgb_to_linear(c: u8) -> f32 {
    let c = c as f32 / 255.0;
    if c <= 0.04045 {
        c / 12.92
    } else {
        ((c + 0.055) / 1.055).powf(2.4)
    }
}

/// Linear-light [0, 1] -> one sRGB channel byte (clamped, gamut-safe).
#[inline]
fn linear_to_srgb(c: f32) -> u8 {
    let c = c.clamp(0.0, 1.0);
    let v = if c <= 0.0031308 {
        c * 12.92
    } else {
        1.055 * c.powf(1.0 / 2.4) - 0.055
    };
    (v * 255.0).round().clamp(0.0, 255.0) as u8
}

/// sRGB colour -> `([L, a, b], alpha)` in Oklab (alpha kept linear in 0..=1).
fn rgba_to_oklab(c: Rgba) -> ([f32; 3], f32) {
    let r = srgb_to_linear(c.r);
    let g = srgb_to_linear(c.g);
    let b = srgb_to_linear(c.b);
    let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
    let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
    let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
    let l_ = l.cbrt();
    let m_ = m.cbrt();
    let s_ = s.cbrt();
    (
        [
            0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
            1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
            0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
        ],
        c.a as f32 / 255.0,
    )
}

/// Oklab `[L, a, b]` + linear alpha -> sRGB colour (out-of-gamut channels clamped).
fn oklab_to_rgba(lab: [f32; 3], alpha: f32) -> Rgba {
    let (ll, aa, bb) = (lab[0], lab[1], lab[2]);
    let l_ = ll + 0.3963377774 * aa + 0.2158037573 * bb;
    let m_ = ll - 0.1055613458 * aa - 0.0638541728 * bb;
    let s_ = ll - 0.0894841775 * aa - 1.2914855480 * bb;
    let l = l_ * l_ * l_;
    let m = m_ * m_ * m_;
    let s = s_ * s_ * s_;
    Rgba {
        r: linear_to_srgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
        g: linear_to_srgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
        b: linear_to_srgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
        a: (alpha.clamp(0.0, 1.0) * 255.0).round() as u8,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stop(off: f32, r: u8, g: u8, b: u8) -> Stop {
        Stop { offset: off, color: Rgba { r, g, b, a: 255 } }
    }

    #[test]
    fn white_maps_to_oklab_l1() {
        let (lab, _) = rgba_to_oklab(Rgba { r: 255, g: 255, b: 255, a: 255 });
        assert!((lab[0] - 1.0).abs() < 1e-3, "L={}", lab[0]);
        assert!(lab[1].abs() < 1e-3 && lab[2].abs() < 1e-3);
    }

    #[test]
    fn srgb_red_reference() {
        // Ottosson's reference: sRGB #ff0000 -> Oklab ~ (0.6280, 0.2249, 0.1258).
        let (lab, _) = rgba_to_oklab(Rgba { r: 255, g: 0, b: 0, a: 255 });
        assert!((lab[0] - 0.6280).abs() < 2e-3, "L={}", lab[0]);
        assert!((lab[1] - 0.2249).abs() < 2e-3, "a={}", lab[1]);
        assert!((lab[2] - 0.1258).abs() < 2e-3, "b={}", lab[2]);
    }

    #[test]
    fn round_trip_is_stable() {
        for c in [(0, 0, 0), (255, 255, 255), (12, 200, 77), (255, 0, 0), (30, 60, 90)] {
            let orig = Rgba { r: c.0, g: c.1, b: c.2, a: 200 };
            let (lab, a) = rgba_to_oklab(orig);
            let back = oklab_to_rgba(lab, a);
            assert!((back.r as i16 - orig.r as i16).abs() <= 1, "r {} vs {}", back.r, orig.r);
            assert!((back.g as i16 - orig.g as i16).abs() <= 1);
            assert!((back.b as i16 - orig.b as i16).abs() <= 1);
            assert_eq!(back.a, orig.a);
        }
    }

    #[test]
    fn srgb_interp_is_identity() {
        let author = vec![stop(0.0, 0, 0, 0), stop(0.5, 255, 0, 0), stop(1.0, 255, 255, 255)];
        assert_eq!(interpolate_stops(&author, Interp::Srgb), author);
    }

    #[test]
    fn oklab_expands_and_preserves_endpoints() {
        let author = vec![stop(0.0, 0, 0, 0), stop(1.0, 255, 255, 255)];
        let out = interpolate_stops(&author, Interp::Oklab);
        assert!(out.len() > author.len());
        // endpoints preserved
        assert_eq!(out.first().unwrap().color, author[0].color);
        assert_eq!(out.last().unwrap().offset, 1.0);
        assert!((out.last().unwrap().color.r as i16 - 255).abs() <= 1);
        // offsets are non-decreasing within [0, 1]
        for w in out.windows(2) {
            assert!(w[1].offset >= w[0].offset);
            assert!(w[0].offset >= 0.0 && w[1].offset <= 1.0001);
        }
    }

    #[test]
    fn oklab_midpoint_is_perceptual_not_code_midpoint() {
        // The black->white midpoint in sRGB is code ~127; in Oklab (perceptually
        // 50% lightness) it is clearly darker (~99), which is the whole point.
        let author = vec![stop(0.0, 0, 0, 0), stop(1.0, 255, 255, 255)];
        let out = interpolate_stops(&author, Interp::Oklab);
        // the stop nearest offset 0.5
        let mid = out.iter().min_by(|a, b| {
            (a.offset - 0.5).abs().partial_cmp(&(b.offset - 0.5).abs()).unwrap()
        }).unwrap();
        assert!(mid.color.r < 115, "oklab midpoint {} should be darker than the sRGB 127", mid.color.r);
        assert!(mid.color.r > 85, "oklab midpoint {} unexpectedly dark", mid.color.r);
    }
}
