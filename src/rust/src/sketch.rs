//! Hand-drawn ("sketch") geometry generation.
//!
//! A lean, dependency-free port of the [Rough.js](https://roughjs.com) algorithm
//! (MIT, © Preet Shihn) — the wobbly-outline / hachure-fill look — emitting
//! straight into `tiny_skia::Path`. See `_docs/DESIGN-ROUGHR.md` §7 for the
//! design and why we build this in-house rather than vendoring `roughr`.
//!
//! The only source of randomness is a small seeded PRNG (`Rng`), so output is a
//! pure function of `(geometry, options, seed)` and identical on every platform
//! — the determinism vellum promises, guaranteed by construction.

use tiny_skia::{Path, PathBuilder};

type Pt = (f64, f64);

/// Fill styles (mirrors the R `sketch(fill_style=)` vocabulary).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum FillStyle {
    Solid,
    Hachure,
    CrossHatch,
    ZigZag,
    Dots,
}

impl FillStyle {
    /// Decode the integer code sent from R (see `.sketch_fill_codes` in grob.R).
    pub fn from_code(c: u32) -> FillStyle {
        match c {
            1 => FillStyle::Hachure,
            2 => FillStyle::CrossHatch,
            3 => FillStyle::ZigZag,
            4 => FillStyle::Dots,
            _ => FillStyle::Solid,
        }
    }
}

/// Resolved sketch options, already in device/local pixels where relevant.
#[derive(Clone, Debug)]
pub struct SketchOpts {
    pub roughness: f64,
    pub bowing: f64,
    pub fill_style: FillStyle,
    /// Stroke width (px) for hachure/fill lines. `<= 0` => derive from `lwd`.
    pub fill_weight: f64,
    /// Hachure angle in degrees.
    pub hachure_angle: f64,
    /// Gap between hachure lines (px). `<= 0` => derive from `fill_weight`.
    pub hachure_gap: f64,
    pub curve_tightness: f64,
    pub curve_step_count: f64,
    pub disable_multi_stroke: bool,
    pub preserve_vertices: bool,
    /// Baseline randomness amplitude in px (Rough.js `maxRandomnessOffset`, def 2).
    pub max_offset: f64,
    pub seed: u64,
}

impl Default for SketchOpts {
    fn default() -> Self {
        SketchOpts {
            roughness: 1.0,
            bowing: 1.0,
            fill_style: FillStyle::Hachure,
            fill_weight: -1.0,
            hachure_angle: -41.0,
            hachure_gap: -1.0,
            curve_tightness: 0.0,
            curve_step_count: 9.0,
            disable_multi_stroke: false,
            preserve_vertices: false,
            max_offset: 2.0,
            seed: 1,
        }
    }
}

/// The generated sketch geometry, bucketed by how the caller paints each set.
pub struct Sketched {
    /// The wobbly outline — stroke with `col`/`lwd`.
    pub stroke: Vec<Path>,
    /// Hachure / zigzag / dot fill lines — stroke with the fill colour and
    /// `fill_weight`. Empty for a solid fill style (or a non-fillable shape).
    pub fill_sketch: Vec<Path>,
    /// The crisp fill region (a multi-subpath path over the closed rings) — fill
    /// with the resolved paint. `None` when the shape has no closed ring.
    pub fill_solid: Option<Path>,
}

// ---------------------------------------------------------------------------
// PRNG — Mulberry32. ~deterministic, cross-platform, no OS entropy.
// ---------------------------------------------------------------------------

struct Rng {
    state: u32,
}

impl Rng {
    fn new(seed: u64) -> Rng {
        // Fold the 64-bit seed and avoid the zero fixed point.
        let s = (seed ^ (seed >> 32)) as u32;
        Rng {
            state: s ^ 0x9E37_79B9,
        }
    }

    fn next_u32(&mut self) -> u32 {
        self.state = self.state.wrapping_add(0x6D2B_79F5);
        let mut z = self.state;
        z = (z ^ (z >> 15)).wrapping_mul(z | 1);
        z ^= z.wrapping_add((z ^ (z >> 7)).wrapping_mul(z | 61));
        z ^ (z >> 14)
    }

    /// Uniform in `[0, 1)`.
    fn unit(&mut self) -> f64 {
        self.next_u32() as f64 / 4_294_967_296.0
    }

    /// Rough.js `_offset(min, max)`: `roughness * gain * (unit*(max-min) + min)`.
    fn offset(&mut self, min: f64, max: f64, roughness: f64, gain: f64) -> f64 {
        roughness * gain * (self.unit() * (max - min) + min)
    }

    /// Rough.js `_offsetOpt(x)` == `_offset(-x, x)`.
    fn offset_sym(&mut self, x: f64, roughness: f64, gain: f64) -> f64 {
        self.offset(-x, x, roughness, gain)
    }
}

// ---------------------------------------------------------------------------
// The atom: a single hand-drawn line (Rough.js `_line` / `_doubleLine`).
// Appends one or two "move + cubic" subpaths to `pb`.
// ---------------------------------------------------------------------------

fn roughness_gain(length: f64) -> f64 {
    if length < 200.0 {
        1.0
    } else if length > 500.0 {
        0.4
    } else {
        -0.0016668 * length + 1.233334
    }
}

/// A hand-drawn line between `a` and `b`, appended to `pb`. Draws one or two
/// overlaid strokes depending on `disable_multi_stroke`.
fn double_line(pb: &mut PathBuilder, rng: &mut Rng, a: Pt, b: Pt, o: &SketchOpts) {
    line_pass(pb, rng, a, b, o, false);
    if !o.disable_multi_stroke {
        line_pass(pb, rng, a, b, o, true);
    }
}

fn line_pass(pb: &mut PathBuilder, rng: &mut Rng, a: Pt, b: Pt, o: &SketchOpts, overlay: bool) {
    let (x1, y1) = a;
    let (x2, y2) = b;
    let len_sq = (x1 - x2).powi(2) + (y1 - y2).powi(2);
    let length = len_sq.sqrt();
    let gain = roughness_gain(length);

    let mut offset = o.max_offset;
    if offset * offset * 100.0 > len_sq {
        offset = length / 10.0;
    }
    let half = offset / 2.0;
    let diverge = 0.2 + rng.unit() * 0.2;

    let mut mid_x = o.bowing * o.max_offset * (y2 - y1) / 200.0;
    let mut mid_y = o.bowing * o.max_offset * (x1 - x2) / 200.0;
    mid_x = rng.offset_sym(mid_x, o.roughness, gain);
    mid_y = rng.offset_sym(mid_y, o.roughness, gain);

    let r = o.roughness;
    let mag = if overlay { half } else { offset };
    let pv = o.preserve_vertices;

    // Start point.
    let sx = x1 + if pv { 0.0 } else { rng.offset_sym(mag, r, gain) };
    let sy = y1 + if pv { 0.0 } else { rng.offset_sym(mag, r, gain) };
    pb.move_to(sx as f32, sy as f32);

    // Cubic through two jittered interior points to a jittered end.
    let c1x = mid_x + x1 + (x2 - x1) * diverge + rng.offset_sym(mag, r, gain);
    let c1y = mid_y + y1 + (y2 - y1) * diverge + rng.offset_sym(mag, r, gain);
    let c2x = mid_x + x1 + 2.0 * (x2 - x1) * diverge + rng.offset_sym(mag, r, gain);
    let c2y = mid_y + y1 + 2.0 * (y2 - y1) * diverge + rng.offset_sym(mag, r, gain);
    let ex = x2 + if pv { 0.0 } else { rng.offset_sym(mag, r, gain) };
    let ey = y2 + if pv { 0.0 } else { rng.offset_sym(mag, r, gain) };
    pb.cubic_to(
        c1x as f32, c1y as f32, c2x as f32, c2y as f32, ex as f32, ey as f32,
    );
}

// ---------------------------------------------------------------------------
// Public generators
// ---------------------------------------------------------------------------

/// One open polyline (e.g. `lines`). Outline strokes only, no fill.
pub fn polyline(pts: &[Pt], o: &SketchOpts) -> Sketched {
    let mut rng = Rng::new(o.seed);
    let mut pb = PathBuilder::new();
    for w in pts.windows(2) {
        double_line(&mut pb, &mut rng, w[0], w[1], o);
    }
    Sketched {
        stroke: pb.finish().into_iter().collect(),
        fill_sketch: Vec::new(),
        fill_solid: None,
    }
}

/// Closed rings (polygon, rect, path). Produces the wobbly outline plus, when
/// `want_fill`, either hachure fill lines (non-solid styles) or the crisp fill
/// region (solid style). The caller decides which bucket to paint.
pub fn rings(input: &[Vec<Pt>], o: &SketchOpts, want_fill: bool) -> Sketched {
    let mut rng = Rng::new(o.seed);

    // Outline: double-line every edge of every ring, closing each ring.
    let mut pb = PathBuilder::new();
    for ring in input {
        if ring.len() < 2 {
            continue;
        }
        for w in ring.windows(2) {
            double_line(&mut pb, &mut rng, w[0], w[1], o);
        }
        // close
        double_line(&mut pb, &mut rng, ring[ring.len() - 1], ring[0], o);
    }
    let stroke: Vec<Path> = pb.finish().into_iter().collect();

    let (fill_sketch, fill_solid) = if want_fill {
        fill_for(input, o, &mut rng)
    } else {
        (Vec::new(), None)
    };

    Sketched {
        stroke,
        fill_sketch,
        fill_solid,
    }
}

/// Build the fill for one or more closed rings: the stroked hachure-family line
/// set (empty for a solid style) and the crisp region path (for solid or the
/// gradient/pattern fallback). Shared by [`rings`] and [`ellipse`].
fn fill_for(input: &[Vec<Pt>], o: &SketchOpts, rng: &mut Rng) -> (Vec<Path>, Option<Path>) {
    let fill_solid = crisp_region(input);
    let fill_sketch = match o.fill_style {
        FillStyle::Solid => Vec::new(),
        FillStyle::Hachure => hachure_paths(input, o, rng, o.hachure_angle, false),
        FillStyle::CrossHatch => {
            let mut a = hachure_paths(input, o, rng, o.hachure_angle, false);
            let mut b = hachure_paths(input, o, rng, o.hachure_angle + 90.0, false);
            a.append(&mut b);
            a
        }
        FillStyle::ZigZag => hachure_paths(input, o, rng, o.hachure_angle, true),
        FillStyle::Dots => dot_paths(input, o, rng),
    };
    (fill_sketch, fill_solid)
}

// ---------------------------------------------------------------------------
// Curves: circle / ellipse via a jittered point loop + Catmull-Rom fit (SK2).
// ---------------------------------------------------------------------------

/// Fit a closed cubic-Bézier curve through `pts` (Catmull-Rom with tension
/// `curve_tightness`, matching Rough.js `_curve`). Indices wrap for closure.
fn curve_path_closed(pts: &[Pt], tightness: f64) -> Option<Path> {
    let n = pts.len();
    if n < 3 {
        return None;
    }
    let s = 1.0 - tightness;
    let mut pb = PathBuilder::new();
    pb.move_to(pts[0].0 as f32, pts[0].1 as f32);
    for i in 0..n {
        let p0 = pts[(i + n - 1) % n];
        let p1 = pts[i];
        let p2 = pts[(i + 1) % n];
        let p3 = pts[(i + 2) % n];
        let b1 = (
            p1.0 + (s * p2.0 - s * p0.0) / 6.0,
            p1.1 + (s * p2.1 - s * p0.1) / 6.0,
        );
        let b2 = (
            p2.0 + (s * p1.0 - s * p3.0) / 6.0,
            p2.1 + (s * p1.1 - s * p3.1) / 6.0,
        );
        pb.cubic_to(
            b1.0 as f32, b1.1 as f32, b2.0 as f32, b2.1 as f32, p2.0 as f32, p2.1 as f32,
        );
    }
    pb.close();
    pb.finish()
}

/// A jittered loop of points around an ellipse (one hand-drawn pass).
fn ellipse_points(cx: f64, cy: f64, rx: f64, ry: f64, o: &SketchOpts, rng: &mut Rng) -> Vec<Pt> {
    let steps = o.curve_step_count.max(6.0);
    let n = steps as usize;
    let incr = std::f64::consts::TAU / steps;
    let amp = o.max_offset;
    let start = rng.offset_sym(incr * 0.5, o.roughness, 1.0);
    (0..n)
        .map(|k| {
            let a = start + incr * k as f64 + rng.offset_sym(incr * 0.5, o.roughness, 1.0);
            let dx = rx + rng.offset_sym(amp, o.roughness, 1.0);
            let dy = ry + rng.offset_sym(amp, o.roughness, 1.0);
            (cx + dx * a.cos(), cy + dy * a.sin())
        })
        .collect()
}

/// A crisp fine polygon approximating an ellipse — the fill region / hachure clip.
fn ellipse_ring(cx: f64, cy: f64, rx: f64, ry: f64, n: usize) -> Vec<Pt> {
    let incr = std::f64::consts::TAU / n as f64;
    (0..n)
        .map(|k| {
            let a = incr * k as f64;
            (cx + rx * a.cos(), cy + ry * a.sin())
        })
        .collect()
}

/// A hand-drawn ellipse (circle when `w == h`). Full width/height `w`/`h`.
pub fn ellipse(cx: f64, cy: f64, w: f64, h: f64, o: &SketchOpts, want_fill: bool) -> Sketched {
    let mut rng = Rng::new(o.seed);
    let rx = (w * 0.5).abs();
    let ry = (h * 0.5).abs();

    let mut stroke = Vec::new();
    let p1 = ellipse_points(cx, cy, rx, ry, o, &mut rng);
    if let Some(path) = curve_path_closed(&p1, o.curve_tightness) {
        stroke.push(path);
    }
    if !o.disable_multi_stroke {
        let p2 = ellipse_points(cx, cy, rx, ry, o, &mut rng);
        if let Some(path) = curve_path_closed(&p2, o.curve_tightness) {
            stroke.push(path);
        }
    }

    let (fill_sketch, fill_solid) = if want_fill {
        let ring = ellipse_ring(cx, cy, rx, ry, 64);
        fill_for(&[ring], o, &mut rng)
    } else {
        (Vec::new(), None)
    };

    Sketched {
        stroke,
        fill_sketch,
        fill_solid,
    }
}

/// Build the crisp closed region (one multi-subpath path) for solid fill.
fn crisp_region(input: &[Vec<Pt>]) -> Option<Path> {
    let mut pb = PathBuilder::new();
    let mut any = false;
    for ring in input {
        if ring.len() < 3 {
            continue;
        }
        pb.move_to(ring[0].0 as f32, ring[0].1 as f32);
        for p in &ring[1..] {
            pb.line_to(p.0 as f32, p.1 as f32);
        }
        pb.close();
        any = true;
    }
    if any {
        pb.finish()
    } else {
        None
    }
}

// ---------------------------------------------------------------------------
// Hachure (scanline) fill — the core of SK3.
// ---------------------------------------------------------------------------

/// Effective gap / weight defaults (Rough.js: gap = weight*4, weight = strokeW/2).
fn fill_params(o: &SketchOpts) -> (f64, f64) {
    let weight = if o.fill_weight > 0.0 {
        o.fill_weight
    } else {
        1.0
    };
    let gap = if o.hachure_gap > 0.0 {
        o.hachure_gap
    } else {
        (weight * 4.0).max(0.1)
    };
    (weight, gap)
}

/// Parallel interior spans across all rings at `angle_deg`, even-odd paired.
/// Returns segments as (start, end) point pairs in the original (unrotated) frame.
fn hachure_segments(input: &[Vec<Pt>], angle_deg: f64, gap: f64) -> Vec<(Pt, Pt)> {
    // Collect edges rotated by -angle so hachure lines are horizontal.
    let ang = angle_deg.to_radians();
    let (s, c) = ang.sin_cos();
    let rot = |p: Pt| -> Pt { (p.0 * c + p.1 * s, -p.0 * s + p.1 * c) };
    let unrot = |p: Pt| -> Pt { (p.0 * c - p.1 * s, p.0 * s + p.1 * c) };

    let mut edges: Vec<(Pt, Pt)> = Vec::new();
    let (mut ymin, mut ymax) = (f64::INFINITY, f64::NEG_INFINITY);
    for ring in input {
        if ring.len() < 3 {
            continue;
        }
        let r: Vec<Pt> = ring.iter().map(|&p| rot(p)).collect();
        for i in 0..r.len() {
            let a = r[i];
            let b = r[(i + 1) % r.len()];
            ymin = ymin.min(a.1).min(b.1);
            ymax = ymax.max(a.1).max(b.1);
            edges.push((a, b));
        }
    }
    if !ymin.is_finite() || gap <= 0.0 {
        return Vec::new();
    }

    let mut out = Vec::new();
    // Start half a gap in so the first line isn't flush with the edge.
    let mut y = ymin + gap * 0.5;
    while y < ymax {
        let mut xs: Vec<f64> = Vec::new();
        for &(a, b) in &edges {
            let (y0, y1) = (a.1, b.1);
            // Half-open interval avoids double-counting shared vertices.
            let hit = (y0 <= y && y < y1) || (y1 <= y && y < y0);
            if hit {
                let t = (y - y0) / (y1 - y0);
                xs.push(a.0 + t * (b.0 - a.0));
            }
        }
        xs.sort_by(|p, q| p.partial_cmp(q).unwrap());
        let mut i = 0;
        while i + 1 < xs.len() {
            let p0 = unrot((xs[i], y));
            let p1 = unrot((xs[i + 1], y));
            out.push((p0, p1));
            i += 2;
        }
        y += gap;
    }
    out
}

/// Hachure fill as rough (single-pass) lines. `zigzag` connects consecutive
/// spans on a scanline into a continuous zig instead of separate segments.
fn hachure_paths(
    input: &[Vec<Pt>],
    o: &SketchOpts,
    rng: &mut Rng,
    angle_deg: f64,
    zigzag: bool,
) -> Vec<Path> {
    let (_, gap) = fill_params(o);
    let segs = hachure_segments(input, angle_deg, gap);
    if segs.is_empty() {
        return Vec::new();
    }
    // Single-pass rough lines keep hachure light. Reuse `line_pass` (no overlay)
    // by temporarily forcing a single stroke.
    let mut single = o.clone();
    single.disable_multi_stroke = true;
    let mut pb = PathBuilder::new();
    if zigzag {
        // Zig along each span: amplitude ~half the gap, one zig every ~2 gaps so
        // the teeth stay legible rather than collapsing into a solid band.
        let zz = gap * 0.5;
        let stride = (gap * 2.0).max(2.0);
        for (a, b) in segs {
            let dx = b.0 - a.0;
            let dy = b.1 - a.1;
            let len = (dx * dx + dy * dy).sqrt();
            if len < 1e-6 {
                continue;
            }
            let (nx, ny) = (-dy / len, dx / len); // unit normal
            let steps = (len / stride).ceil().max(1.0) as usize;
            let mut prev = a;
            for k in 1..=steps {
                let t = k as f64 / steps as f64;
                let base = (a.0 + dx * t, a.1 + dy * t);
                let sign = if k % 2 == 1 { 1.0 } else { -1.0 };
                let p = (base.0 + nx * zz * sign, base.1 + ny * zz * sign);
                double_line(&mut pb, rng, prev, p, &single);
                prev = p;
            }
        }
    } else {
        for (a, b) in segs {
            double_line(&mut pb, rng, a, b, &single);
        }
    }
    pb.finish().into_iter().collect()
}

/// Dots fill: small filled dots placed along the hachure spans.
fn dot_paths(input: &[Vec<Pt>], o: &SketchOpts, rng: &mut Rng) -> Vec<Path> {
    let (weight, gap) = fill_params(o);
    let segs = hachure_segments(input, o.hachure_angle, gap);
    let radius = (weight * 0.5).max(0.5);
    let mut pb = PathBuilder::new();
    for (a, b) in segs {
        let dx = b.0 - a.0;
        let dy = b.1 - a.1;
        let len = (dx * dx + dy * dy).sqrt();
        let n = (len / gap).floor().max(0.0) as usize;
        for k in 0..=n {
            let t = if n == 0 { 0.0 } else { k as f64 / n as f64 };
            let jx = rng.offset_sym(gap * 0.15, o.roughness, 1.0);
            let jy = rng.offset_sym(gap * 0.15, o.roughness, 1.0);
            let cx = a.0 + dx * t + jx;
            let cy = a.1 + dy * t + jy;
            pb.push_circle(cx as f32, cy as f32, radius as f32);
        }
    }
    pb.finish().into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prng_is_deterministic() {
        let mut a = Rng::new(42);
        let mut b = Rng::new(42);
        for _ in 0..100 {
            assert_eq!(a.next_u32(), b.next_u32());
        }
        let mut c = Rng::new(43);
        // Different seed => different stream (with overwhelming probability).
        assert_ne!(Rng::new(42).next_u32(), c.next_u32());
    }

    #[test]
    fn polyline_produces_strokes() {
        let o = SketchOpts::default();
        let s = polyline(&[(0.0, 0.0), (100.0, 0.0), (100.0, 100.0)], &o);
        assert!(!s.stroke.is_empty());
        assert!(s.fill_sketch.is_empty());
    }

    #[test]
    fn rings_hachure_fills() {
        let sq = vec![(0.0, 0.0), (100.0, 0.0), (100.0, 100.0), (0.0, 100.0)];
        let o = SketchOpts {
            fill_style: FillStyle::Hachure,
            hachure_gap: 10.0,
            ..SketchOpts::default()
        };
        let s = rings(&[sq], &o, true);
        assert!(!s.stroke.is_empty());
        assert!(!s.fill_sketch.is_empty(), "hachure should produce fill lines");
    }

    #[test]
    fn rings_solid_gives_region() {
        let sq = vec![(0.0, 0.0), (100.0, 0.0), (100.0, 100.0), (0.0, 100.0)];
        let o = SketchOpts {
            fill_style: FillStyle::Solid,
            ..SketchOpts::default()
        };
        let s = rings(&[sq], &o, true);
        assert!(s.fill_solid.is_some());
        assert!(s.fill_sketch.is_empty());
    }

    #[test]
    fn ellipse_produces_curved_stroke() {
        let o = SketchOpts::default();
        let s = ellipse(50.0, 50.0, 80.0, 60.0, &o, true);
        assert_eq!(s.stroke.len(), 2, "two hand-drawn passes by default");
        assert!(!s.fill_sketch.is_empty(), "default hachure fill");
        let o1 = SketchOpts { disable_multi_stroke: true, ..SketchOpts::default() };
        let s1 = ellipse(50.0, 50.0, 80.0, 60.0, &o1, false);
        assert_eq!(s1.stroke.len(), 1, "single pass when multi-stroke disabled");
    }

    #[test]
    fn same_seed_same_geometry() {
        let sq = vec![(0.0, 0.0), (50.0, 0.0), (50.0, 50.0)];
        let o = SketchOpts::default();
        let a = polyline(&sq, &o);
        let b = polyline(&sq, &o);
        assert_eq!(a.stroke.len(), b.stroke.len());
        // Path equality via bounds as a cheap proxy.
        let ba = a.stroke[0].bounds();
        let bb = b.stroke[0].bounds();
        assert_eq!(ba.left(), bb.left());
        assert_eq!(ba.top(), bb.top());
    }
}
