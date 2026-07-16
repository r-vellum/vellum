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
    /// Interpolate perceptually in Oklab's rectangular `(L, a, b)` form
    /// (pre-sampled to sRGB stops).
    Oklab,
    /// Interpolate perceptually in Oklab's polar `(L, C, h)` form — hue and
    /// chroma move independently, so a ramp between two saturated colours keeps
    /// its chroma through the middle instead of dipping toward grey the way a
    /// straight line in `(a, b)` can. The CSS `oklch` interpolation space.
    Oklch,
}

impl Interp {
    pub fn parse(s: &str) -> Interp {
        match s {
            "oklab" => Interp::Oklab,
            "oklch" => Interp::Oklch,
            _ => Interp::Srgb,
        }
    }
}

/// Samples per author-stop segment when pre-sampling in a perceptual space.
const SAMPLES_PER_SEGMENT: usize = 32;
/// Soft budget for the total emitted stops: the per-segment sample count is
/// `MAX_STOPS/nseg` (clamped), so the true total is `~nseg*k + 1` — near this for
/// many segments, and up to `SAMPLES_PER_SEGMENT*nseg + 1` for a few. Bounds the
/// `<defs>` / shading size without being an exact ceiling.
const MAX_STOPS: usize = 256;

/// Return the stops a backend should interpolate linearly in sRGB to realise
/// `interp`. `Srgb` is the identity (author stops unchanged). `Oklab`/`Oklch`
/// expand each adjacent-stop segment into densely pre-sampled sRGB stops walked
/// in the requested perceptual space, so the backends' sRGB interpolation
/// between adjacent samples reproduces the perceptual curve. `Oklab` walks the
/// rectangular `(L, a, b)`; `Oklch` walks the polar `(L, C, h)`. **Every author
/// stop** (not just the first/last) is emitted exactly — only the interior
/// samples between them are the Oklab-computed round-trips — so author colours
/// never drift by the sRGB8 round-trip's ±1/channel.
pub fn interpolate_stops(stops: &[Stop], interp: Interp) -> Vec<Stop> {
    if interp == Interp::Srgb || stops.len() < 2 {
        return stops.to_vec();
    }
    let nseg = stops.len() - 1;
    // Keep the total bounded: fewer samples per segment when there are many.
    let k = (MAX_STOPS / nseg).clamp(2, SAMPLES_PER_SEGMENT);
    // Convert each author stop to Oklab once; interior stops are shared by two
    // segments, so this halves the conversions vs recomputing per segment.
    let labs: Vec<([f32; 3], f32)> = stops.iter().map(|s| rgba_to_oklab(s.color)).collect();
    let mut out = Vec::with_capacity(nseg * k + 1);
    out.push(stops[0]);
    for seg in 0..nseg {
        let (s0, s1) = (stops[seg], stops[seg + 1]);
        let (lab0, a0) = labs[seg];
        let (lab1, a1) = labs[seg + 1];
        let span = s1.offset - s0.offset;
        // For Oklch, pre-resolve the polar endpoints and the shortest-arc hue
        // delta once per segment; Oklab lerps the rectangular channels directly.
        let polar = (interp == Interp::Oklch).then(|| LchSeg::prep(lab0, lab1));
        // Interior samples only (1..k); the segment endpoint is the author stop
        // `s1`, pushed exactly below (which also seeds the next segment's start).
        for j in 1..k {
            let t = j as f32 / k as f32;
            let lab = match &polar {
                Some(p) => p.sample(t),
                None => [
                    lerp(lab0[0], lab1[0], t),
                    lerp(lab0[1], lab1[1], t),
                    lerp(lab0[2], lab1[2], t),
                ],
            };
            out.push(Stop {
                offset: s0.offset + span * t,
                color: oklab_to_rgba(lab, lerp(a0, a1, t)),
            });
        }
        out.push(s1);
    }
    out
}

/// One stop segment's endpoints in Oklab polar form `(L, C, h)`, plus the
/// shortest-arc hue delta `dh` (radians) from start to end. Precomputed once per
/// segment; [`LchSeg::sample`] evaluates the interpolant at `t`.
struct LchSeg {
    l0: f32,
    c0: f32,
    h0: f32,
    l1: f32,
    c1: f32,
    dh: f32,
}

/// Chroma below this counts as achromatic (grey/black/white): its hue is
/// undefined, so it borrows the other endpoint's hue (matching CSS `oklch`).
const CHROMA_EPS: f32 = 1e-4;

impl LchSeg {
    fn prep(lab0: [f32; 3], lab1: [f32; 3]) -> LchSeg {
        let (l0, c0, mut h0) = lab_to_lch(lab0);
        let (l1, c1, mut h1) = lab_to_lch(lab1);
        // An achromatic endpoint has no meaningful hue: adopt the other end's so
        // the ramp doesn't flash through an arbitrary hue near grey/white/black.
        if c0 < CHROMA_EPS {
            h0 = h1;
        }
        if c1 < CHROMA_EPS {
            h1 = h0;
        }
        // Shortest arc: wrap the hue delta into (-PI, PI].
        let mut dh = h1 - h0;
        let tau = 2.0 * std::f32::consts::PI;
        while dh > std::f32::consts::PI {
            dh -= tau;
        }
        while dh <= -std::f32::consts::PI {
            dh += tau;
        }
        LchSeg { l0, c0, h0, l1, c1, dh }
    }

    /// Interpolated Oklab `(L, a, b)` at `t` in `0..=1`: L and C move linearly,
    /// hue rotates along the shortest arc.
    fn sample(&self, t: f32) -> [f32; 3] {
        let l = lerp(self.l0, self.l1, t);
        let c = lerp(self.c0, self.c1, t);
        let h = self.h0 + self.dh * t;
        [l, c * h.cos(), c * h.sin()]
    }
}

/// Oklab rectangular `(L, a, b)` -> polar `(L, C, h)` with hue in radians.
fn lab_to_lch(lab: [f32; 3]) -> (f32, f32, f32) {
    let c = (lab[1] * lab[1] + lab[2] * lab[2]).sqrt();
    let h = lab[2].atan2(lab[1]);
    (lab[0], c, h)
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

/// Linear-light [0, 1] -> one sRGB channel byte.
///
/// Out-of-[0,1] channels (an interpolated Oklab/Oklch sample outside the sRGB
/// gamut) are clamped **per channel**. This is a deliberate simplification, not a
/// true gamut map: a proper map (CSS Color 4) reduces chroma toward the L axis to
/// stay in gamut, whereas per-channel clamping can shift the sample's hue and
/// lightness. It is chosen for simplicity and stability (no dependence on a
/// gamut-mapping iteration); the visible effect is confined to highly-saturated
/// out-of-gamut mid-ramp samples.
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

/// Oklab `[L, a, b]` + linear alpha -> sRGB colour. Out-of-gamut channels are
/// clamped per channel (a deliberate simplification; see [`linear_to_srgb`]).
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
    fn oklab_preserves_interior_author_stops_exactly() {
        // Every author stop — not just the endpoints — must appear byte-exact in
        // the expansion (no Oklab->sRGB8 round-trip drift at author offsets).
        let author = vec![stop(0.0, 0, 0, 0), stop(0.5, 12, 200, 77), stop(1.0, 255, 255, 255)];
        for interp in [Interp::Oklab, Interp::Oklch] {
            let out = interpolate_stops(&author, interp);
            for a in &author {
                assert!(
                    out.iter().any(|s| s.color == a.color && (s.offset - a.offset).abs() < 1e-6),
                    "author stop {:?} missing from {interp:?} expansion",
                    a.color
                );
            }
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

    #[test]
    fn parse_oklch() {
        assert_eq!(Interp::parse("oklch"), Interp::Oklch);
        assert_eq!(Interp::parse("oklab"), Interp::Oklab);
        assert_eq!(Interp::parse("srgb"), Interp::Srgb);
        assert_eq!(Interp::parse("weird"), Interp::Srgb);
    }

    /// Chroma (radial distance in the Oklab a/b plane) of an sRGB colour.
    fn chroma(c: Rgba) -> f32 {
        let (lab, _) = rgba_to_oklab(c);
        (lab[1] * lab[1] + lab[2] * lab[2]).sqrt()
    }

    /// The stop nearest a given offset.
    fn nearest(out: &[Stop], off: f32) -> Stop {
        *out.iter()
            .min_by(|a, b| (a.offset - off).abs().partial_cmp(&(b.offset - off).abs()).unwrap())
            .unwrap()
    }

    #[test]
    fn oklch_keeps_chroma_where_oklab_dips() {
        // Blue -> yellow are near-complementary: the straight line in Oklab (a, b)
        // passes close to the neutral axis, so its midpoint desaturates. Oklch
        // rotates the hue at held chroma instead, staying vivid through the middle.
        let author = vec![stop(0.0, 0, 0, 255), stop(1.0, 255, 255, 0)];
        let lab = interpolate_stops(&author, Interp::Oklab);
        let lch = interpolate_stops(&author, Interp::Oklch);
        let c_lab = chroma(nearest(&lab, 0.5).color);
        let c_lch = chroma(nearest(&lch, 0.5).color);
        assert!(
            c_lch > c_lab + 0.02,
            "oklch midpoint chroma {c_lch} should exceed oklab's {c_lab}"
        );
    }

    #[test]
    fn oklch_achromatic_endpoint_does_not_flash_hue() {
        // White is achromatic (undefined hue); ramping to blue must hold blue's
        // hue the whole way (chroma rises from 0), never veering to another hue.
        let author = vec![stop(0.0, 255, 255, 255), stop(1.0, 0, 0, 255)];
        let out = interpolate_stops(&author, Interp::Oklch);
        let (blue_lab, _) = rgba_to_oklab(Rgba { r: 0, g: 0, b: 255, a: 255 });
        let blue_h = blue_lab[2].atan2(blue_lab[1]);
        for s in &out {
            let (lab, _) = rgba_to_oklab(s.color);
            let c = (lab[1] * lab[1] + lab[2] * lab[2]).sqrt();
            // Only check samples with enough chroma for hue to be meaningful:
            // near-white the chroma is tiny and the sRGB8 round-trip makes the hue
            // angle numerically noisy (in exact Oklab it is constant = blue's hue).
            if c > 0.05 {
                let h = lab[2].atan2(lab[1]);
                let mut dh = (h - blue_h).abs();
                if dh > std::f32::consts::PI {
                    dh = 2.0 * std::f32::consts::PI - dh;
                }
                // 0.15 rad (~9°) comfortably separates "hue held" from a real flash
                // (which would be radians of swing) while tolerating sRGB8 rounding.
                assert!(dh < 0.15, "hue drift {dh} rad at offset {} (expected ~blue)", s.offset);
            }
        }
    }

    #[test]
    fn oklch_expands_and_preserves_endpoints() {
        let author = vec![stop(0.0, 0, 0, 255), stop(1.0, 255, 255, 0)];
        let out = interpolate_stops(&author, Interp::Oklch);
        assert!(out.len() > author.len());
        assert_eq!(out.first().unwrap().color, author[0].color);
        assert!((out.last().unwrap().color.r as i16 - 255).abs() <= 1);
        assert!((out.last().unwrap().color.g as i16 - 255).abs() <= 1);
        assert!(out.last().unwrap().color.b <= 1);
        // offsets non-decreasing within [0, 1]
        for w in out.windows(2) {
            assert!(w[1].offset >= w[0].offset);
            assert!(w[0].offset >= 0.0 && w[1].offset <= 1.0001);
        }
    }
}
