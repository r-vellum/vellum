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

use std::rc::Rc;

use extendr_api::prelude::*;

use crate::units::Unit;

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

    /// Apply a multiplicative alpha (gpar `alpha`, in 0..=1) to this colour. A
    /// non-finite multiplier is ignored (alpha unchanged) rather than silently
    /// collapsing to 0 via a NaN cast — the fold path pre-filters non-finite
    /// values, so this guards only direct callers of this `pub` method.
    pub fn with_alpha(self, alpha: f64) -> Rgba {
        if !alpha.is_finite() {
            return self;
        }
        let a = (self.a as f64 * alpha.clamp(0.0, 1.0)).round() as u8;
        Rgba { a, ..self }
    }

    pub fn to_skia(self) -> tiny_skia::Color {
        tiny_skia::Color::from_rgba8(self.r, self.g, self.b, self.a)
    }
}

/// How a gradient extends beyond its [0, 1] stop range.
#[derive(Clone, Copy, Debug)]
pub enum Extend {
    Pad,
    Repeat,
    Reflect,
}

impl Extend {
    pub fn parse(s: &str) -> Extend {
        match s {
            "repeat" => Extend::Repeat,
            "reflect" => Extend::Reflect,
            _ => Extend::Pad,
        }
    }
}

/// A gradient colour stop (`offset` in 0..=1).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Stop {
    pub offset: f32,
    pub color: Rgba,
}

/// A tiling-pattern fill: a pre-rendered RGBA tile (straight alpha, top-left
/// origin, `tw` x `th` px) tiled across a cell of size `(w, h)` centred at
/// `(x, y)`. The cell geometry is in `(value, unit)` form and resolved against
/// the viewport at draw time; the tile pixels were rendered by R from a grob.
#[derive(Clone, Debug)]
pub struct PatternFill {
    pub tile: Rc<Vec<u8>>,
    pub tw: u32,
    pub th: u32,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub unit: Unit,
    pub extend: Extend,
    /// Multiplicative opacity from the gpar `alpha` fold (kept separate so the
    /// shared tile `Rc` is never cloned just to fade it).
    pub opacity: f64,
}

/// A fill paint. Gradient/pattern geometry is stored in `(value, Unit)` form and
/// resolved against the viewport at draw time (see `render_to`). `col`/stroke
/// stays solid.
#[derive(Clone, Debug)]
pub enum Paint {
    Solid(Rgba),
    Linear { x1: f64, y1: f64, x2: f64, y2: f64, unit: Unit, stops: Vec<Stop>, extend: Extend },
    /// A radial gradient between two circles: the focal/start circle
    /// `(fx, fy, fr)` at stop offset 0 and the outer/end circle `(cx, cy, r)` at
    /// offset 1. `fr == 0` with `(fx, fy) == (cx, cy)` is the ordinary concentric
    /// gradient; a non-zero focal offset places the highlight off-centre.
    Radial { cx: f64, cy: f64, r: f64, fx: f64, fy: f64, fr: f64, unit: Unit, stops: Vec<Stop>, extend: Extend },
    Pattern(PatternFill),
}

impl Paint {
    /// Fold a multiplicative gpar alpha into the paint (every stop / the solid).
    pub fn with_alpha(self, alpha: f64) -> Paint {
        let fade = |stops: Vec<Stop>| {
            stops.into_iter().map(|s| Stop { offset: s.offset, color: s.color.with_alpha(alpha) }).collect()
        };
        match self {
            Paint::Solid(c) => Paint::Solid(c.with_alpha(alpha)),
            Paint::Linear { x1, y1, x2, y2, unit, stops, extend } => {
                Paint::Linear { x1, y1, x2, y2, unit, stops: fade(stops), extend }
            }
            Paint::Radial { cx, cy, r, fx, fy, fr, unit, stops, extend } => {
                Paint::Radial { cx, cy, r, fx, fy, fr, unit, stops: fade(stops), extend }
            }
            Paint::Pattern(mut p) => {
                // Fold alpha into the opacity scalar; the tile `Rc` stays shared.
                p.opacity *= alpha.clamp(0.0, 1.0);
                Paint::Pattern(p)
            }
        }
    }
}

/// Parse a fill paint from R: a length-4 integer vector is a solid colour; a list
/// with a `kind` element is a gradient; anything else is `None` ("no fill").
pub fn parse_paint(obj: &Robj) -> Option<Paint> {
    // A gradient/pattern is a list with a `kind`; a solid is an integer RGBA
    // vector. Only `$`-index lists (atomic vectors error on `$`).
    if obj.is_list() {
        if let Ok(kind) = obj.dollar("kind") {
            let kind = kind.as_str().unwrap_or("");
            if kind == "pattern" {
                return parse_pattern(obj);
            }
            return parse_gradient(obj, kind);
        }
    }
    opt_color(obj).map(Paint::Solid)
}

fn parse_pattern(obj: &Robj) -> Option<Paint> {
    let tile_i = obj.dollar("tile").ok()?.as_integer_slice()?.to_vec();
    let tw = obj.dollar("tw").ok()?.as_integer()? as u32;
    let th = obj.dollar("th").ok()?.as_integer()? as u32;
    let coords = obj.dollar("coords").ok()?.as_real_slice()?.to_vec();
    if coords.len() < 4 || tw == 0 || th == 0 {
        return None;
    }
    if tile_i.len() != (tw as usize) * (th as usize) * 4 {
        return None;
    }
    let unit = Unit::parse(obj.dollar("units").ok().and_then(|u| u.as_str().map(String::from)).as_deref().unwrap_or("npc"));
    let extend = Extend::parse(obj.dollar("extend").ok().and_then(|e| e.as_str().map(String::from)).as_deref().unwrap_or("repeat"));
    let tile: Vec<u8> = tile_i.iter().map(|v| (*v).clamp(0, 255) as u8).collect();
    Some(Paint::Pattern(PatternFill {
        tile: Rc::new(tile),
        tw,
        th,
        x: coords[0],
        y: coords[1],
        w: coords[2],
        h: coords[3],
        unit,
        extend,
        opacity: 1.0,
    }))
}

fn parse_gradient(obj: &Robj, kind: &str) -> Option<Paint> {
    // Bind the R vectors so their borrowed slices live for the whole function
    // (no defensive `.to_vec()` copy of read-only data).
    let coords_obj = obj.dollar("coords").ok()?;
    let coords = coords_obj.as_real_slice()?;
    let unit = Unit::parse(obj.dollar("units").ok().and_then(|u| u.as_str().map(String::from)).as_deref().unwrap_or("npc"));
    let extend = Extend::parse(obj.dollar("extend").ok().and_then(|e| e.as_str().map(String::from)).as_deref().unwrap_or("pad"));
    let cols_obj = obj.dollar("col").ok()?;
    let cols = cols_obj.as_integer_slice()?;
    let offs_obj = obj.dollar("offset").ok()?;
    let offs = offs_obj.as_real_slice()?;
    let interp = crate::oklab::Interp::parse(
        obj.dollar("interpolation").ok().and_then(|s| s.as_str().map(String::from)).as_deref().unwrap_or("srgb"),
    );
    let n = offs.len().min(cols.len() / 4);
    if n == 0 {
        return None;
    }
    let mut author: Vec<Stop> = (0..n)
        .map(|i| Stop {
            // Guard a non-finite offset (an R `NA`/`Inf` would otherwise clamp to
            // NaN and corrupt sorting/shading); finite offsets clamp to [0, 1].
            offset: if offs[i].is_finite() { offs[i].clamp(0.0, 1.0) as f32 } else { 0.0 },
            color: Rgba {
                r: cols[4 * i].clamp(0, 255) as u8,
                g: cols[4 * i + 1].clamp(0, 255) as u8,
                b: cols[4 * i + 2].clamp(0, 255) as u8,
                a: cols[4 * i + 3].clamp(0, 255) as u8,
            },
        })
        .collect();
    // Backends assume monotonically non-decreasing offsets; sort (stable) so
    // unordered author offsets can't produce a non-monotonic stop list.
    author.sort_by(|p, q| p.offset.total_cmp(&q.offset));
    // Perceptual interpolation (Oklab) is realised by pre-sampling the author
    // stops into dense sRGB stops here; `srgb` leaves them untouched. See `oklab`.
    let stops = crate::oklab::interpolate_stops(&author, interp);
    match kind {
        "radial" if coords.len() >= 3 => {
            // coords are `[cx, cy, r, fx, fy, fr]`; the focal circle is optional
            // (a length-3 vector, or an older gradient, means concentric).
            let (fx, fy, fr) = if coords.len() >= 6 {
                (coords[3], coords[4], coords[5])
            } else {
                (coords[0], coords[1], 0.0)
            };
            Some(Paint::Radial { cx: coords[0], cy: coords[1], r: coords[2], fx, fy, fr, unit, stops, extend })
        }
        "linear" if coords.len() >= 4 => {
            Some(Paint::Linear { x1: coords[0], y1: coords[1], x2: coords[2], y2: coords[3], unit, stops, extend })
        }
        _ => None,
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

/// Stroke end cap. Codes mirror the R encoding: 0 round, 1 butt, 2 square.
#[derive(Clone, Copy, Debug)]
pub enum LineCap {
    Round,
    Butt,
    Square,
}

impl LineCap {
    pub fn from_code(c: i32) -> LineCap {
        match c {
            1 => LineCap::Butt,
            2 => LineCap::Square,
            _ => LineCap::Round,
        }
    }
}

/// Stroke corner join. Codes mirror R: 0 round, 1 mitre, 2 bevel.
#[derive(Clone, Copy, Debug)]
pub enum LineJoin {
    Round,
    Mitre,
    Bevel,
}

impl LineJoin {
    pub fn from_code(c: i32) -> LineJoin {
        match c {
            1 => LineJoin::Mitre,
            2 => LineJoin::Bevel,
            _ => LineJoin::Round,
        }
    }
}

/// A graphical parameter that is either inherited from an ancestor or set here.
#[derive(Clone, Copy, Debug)]
pub enum Inh<T> {
    Inherit,
    Set(T),
}

/// Line type: solid, blank (no line), or a dash pattern (on/off nibble lengths,
/// scaled by `lwd` at draw time).
#[derive(Clone, Debug)]
pub enum Lty {
    Solid,
    Blank,
    Dash(Vec<f32>),
}

/// A possibly-partial set of graphical parameters, as attached to a viewport or
/// a primitive. Built from R, where the encoding is:
///   * colour: `NULL` -> Inherit, length-4 int -> Set(colour), else -> Set(none)
///   * lwd/alpha: `NULL`/`NA` -> Inherit, finite number -> Set
#[derive(Clone, Debug)]
pub struct PartialGpar {
    pub fill: Inh<Option<Paint>>,
    pub col: Inh<Option<Rgba>>,
    pub lwd: Inh<f64>,
    pub alpha: Inh<f64>,
    /// Line type (`NULL` -> inherit; `numeric(0)` -> solid; `NA` -> blank; a
    /// numeric vector -> dash nibbles).
    pub lty: Inh<Lty>,
    pub lineend: Inh<LineCap>,
    pub linejoin: Inh<LineJoin>,
    pub linemitre: Inh<f64>,
}

impl PartialGpar {
    /// `stroke` is an R list with optional `lty`/`lineend`/`linejoin`/`linemitre`
    /// (each `NULL` = inherit), or `NULL` to inherit all of them.
    pub fn from_robj(fill: &Robj, col: &Robj, lwd: &Robj, alpha: &Robj, stroke: &Robj) -> Self {
        let field = |name: &str| stroke.dollar(name).unwrap_or_else(|_| ().into());
        let (lty, lineend, linejoin, linemitre) = if stroke.is_list() {
            (inh_lty(&field("lty")), inh_linecap(&field("lineend")), inh_linejoin(&field("linejoin")), inh_f64(&field("linemitre")))
        } else {
            (Inh::Inherit, Inh::Inherit, Inh::Inherit, Inh::Inherit)
        };
        PartialGpar {
            fill: inh_paint(fill),
            col: inh_color(col),
            lwd: inh_f64(lwd),
            alpha: inh_f64(alpha),
            lty,
            lineend,
            linejoin,
            linemitre,
        }
    }
}

fn inh_lty(obj: &Robj) -> Inh<Lty> {
    if obj.is_null() {
        return Inh::Inherit;
    }
    match obj.as_real_slice() {
        Some(s) if s.is_empty() => Inh::Set(Lty::Solid), // numeric(0) -> solid
        Some(s) if s.iter().any(|v| v.is_nan()) => Inh::Set(Lty::Blank), // NA -> no line
        Some(s) => Inh::Set(Lty::Dash(s.iter().map(|&v| v as f32).collect())),
        None => Inh::Inherit,
    }
}

fn inh_linecap(obj: &Robj) -> Inh<LineCap> {
    match obj.as_integer() {
        Some(c) => Inh::Set(LineCap::from_code(c)),
        None => Inh::Inherit,
    }
}

fn inh_linejoin(obj: &Robj) -> Inh<LineJoin> {
    match obj.as_integer() {
        Some(c) => Inh::Set(LineJoin::from_code(c)),
        None => Inh::Inherit,
    }
}

fn inh_paint(obj: &Robj) -> Inh<Option<Paint>> {
    if obj.is_null() {
        Inh::Inherit
    } else {
        Inh::Set(parse_paint(obj))
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
#[derive(Clone, Debug)]
pub struct GparAcc {
    pub fill: Option<Paint>,
    pub col: Option<Rgba>,
    pub lwd: f64,
    pub alpha: f64,
    pub lty: Lty,
    pub lineend: LineCap,
    pub linejoin: LineJoin,
    pub linemitre: f64,
}

impl GparAcc {
    /// Root defaults: no fill, black stroke, lwd 1, opaque, solid round-capped
    /// round-joined lines, mitre limit 10 (grid's defaults).
    pub fn root_default() -> Self {
        GparAcc {
            fill: None,
            col: Some(Rgba::BLACK),
            lwd: 1.0,
            alpha: 1.0,
            lty: Lty::Solid,
            lineend: LineCap::Round,
            linejoin: LineJoin::Round,
            linemitre: 10.0,
        }
    }

    /// Fold a partial gpar onto this accumulator (more-specific overrides).
    pub fn apply(&self, p: &PartialGpar) -> Self {
        GparAcc {
            fill: match &p.fill {
                Inh::Set(v) => v.clone(),
                Inh::Inherit => self.fill.clone(),
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
            lty: match &p.lty {
                Inh::Set(v) => v.clone(),
                Inh::Inherit => self.lty.clone(),
            },
            lineend: match p.lineend {
                Inh::Set(v) => v,
                Inh::Inherit => self.lineend,
            },
            linejoin: match p.linejoin {
                Inh::Set(v) => v,
                Inh::Inherit => self.linejoin,
            },
            linemitre: match p.linemitre {
                Inh::Set(v) => v,
                Inh::Inherit => self.linemitre,
            },
        }
    }

    /// Resolve to concrete drawing parameters, applying the accumulated alpha.
    pub fn resolve(&self) -> Gpar {
        Gpar {
            fill: self.fill.clone().map(|p| p.with_alpha(self.alpha)),
            col: self.col.map(|c| c.with_alpha(self.alpha)),
            lwd: self.lwd,
            lty: self.lty.clone(),
            lineend: self.lineend,
            linejoin: self.linejoin,
            linemitre: self.linemitre,
        }
    }

    /// A 64-bit fingerprint of this fully-folded accumulator. Used to key the
    /// repaint-boundary sub-raster cache: a boundary's cached pixels depend on the
    /// gpar it *inherits* (which the subtree's content-identity `nid` does not
    /// capture), so two boundaries sharing every other key field but differing in
    /// inherited style must key differently. Covers every field that can affect a
    /// descendant primitive's pixels; identical accumulators fingerprint identically
    /// (so genuine cross-render hits are preserved). Pattern fills fold in the tile
    /// `Rc` identity — a rebuilt-but-equal tile keys differently and re-renders,
    /// which is safe (correctness over the optimisation, a rare case).
    pub fn fingerprint(&self) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut h = std::collections::hash_map::DefaultHasher::new();
        hash_opt_paint(&self.fill, &mut h);
        match self.col {
            Some(c) => {
                1u8.hash(&mut h);
                hash_rgba(c, &mut h);
            }
            None => 0u8.hash(&mut h),
        }
        self.lwd.to_bits().hash(&mut h);
        self.alpha.to_bits().hash(&mut h);
        hash_lty(&self.lty, &mut h);
        std::mem::discriminant(&self.lineend).hash(&mut h);
        std::mem::discriminant(&self.linejoin).hash(&mut h);
        self.linemitre.to_bits().hash(&mut h);
        h.finish()
    }
}

fn hash_rgba(c: Rgba, h: &mut impl std::hash::Hasher) {
    use std::hash::Hash;
    [c.r, c.g, c.b, c.a].hash(h);
}

fn hash_unit(u: &Unit, h: &mut impl std::hash::Hasher) {
    use std::hash::Hash;
    std::mem::discriminant(&u.kind).hash(h);
    u.off_mm.to_bits().hash(h);
}

fn hash_stops(stops: &[Stop], h: &mut impl std::hash::Hasher) {
    use std::hash::Hash;
    (stops.len() as u64).hash(h);
    for s in stops {
        s.offset.to_bits().hash(h);
        hash_rgba(s.color, h);
    }
}

fn hash_lty(lty: &Lty, h: &mut impl std::hash::Hasher) {
    use std::hash::Hash;
    match lty {
        Lty::Solid => 0u8.hash(h),
        Lty::Blank => 1u8.hash(h),
        Lty::Dash(v) => {
            2u8.hash(h);
            (v.len() as u64).hash(h);
            for f in v {
                f.to_bits().hash(h);
            }
        }
    }
}

fn hash_paint(p: &Paint, h: &mut impl std::hash::Hasher) {
    use std::hash::Hash;
    match p {
        Paint::Solid(c) => {
            0u8.hash(h);
            hash_rgba(*c, h);
        }
        Paint::Linear { x1, y1, x2, y2, unit, stops, extend } => {
            1u8.hash(h);
            for v in [*x1, *y1, *x2, *y2] {
                v.to_bits().hash(h);
            }
            hash_unit(unit, h);
            hash_stops(stops, h);
            std::mem::discriminant(extend).hash(h);
        }
        Paint::Radial { cx, cy, r, fx, fy, fr, unit, stops, extend } => {
            2u8.hash(h);
            for v in [*cx, *cy, *r, *fx, *fy, *fr] {
                v.to_bits().hash(h);
            }
            hash_unit(unit, h);
            hash_stops(stops, h);
            std::mem::discriminant(extend).hash(h);
        }
        Paint::Pattern(pf) => {
            3u8.hash(h);
            (Rc::as_ptr(&pf.tile) as usize).hash(h);
            pf.tw.hash(h);
            pf.th.hash(h);
            for v in [pf.x, pf.y, pf.w, pf.h] {
                v.to_bits().hash(h);
            }
            hash_unit(&pf.unit, h);
            std::mem::discriminant(&pf.extend).hash(h);
            pf.opacity.to_bits().hash(h);
        }
    }
}

fn hash_opt_paint(p: &Option<Paint>, h: &mut impl std::hash::Hasher) {
    use std::hash::Hash;
    match p {
        Some(pp) => {
            1u8.hash(h);
            hash_paint(pp, h);
        }
        None => 0u8.hash(h),
    }
}

/// Effective graphical parameters for a single primitive (alpha already applied).
#[derive(Clone, Debug)]
pub struct Gpar {
    pub fill: Option<Paint>,
    pub col: Option<Rgba>,
    /// Line width in R "lwd" units (1 == 1/96 inch).
    pub lwd: f64,
    /// Dash nibble lengths (`None` = solid); scaled by `lwd_px` at draw time.
    pub lty: Lty,
    pub lineend: LineCap,
    pub linejoin: LineJoin,
    pub linemitre: f64,
}

impl Gpar {
    /// Stroke width in device pixels.
    pub fn lwd_px(&self, dpi: f64) -> f32 {
        (self.lwd * dpi / 96.0) as f32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn with_alpha_ignores_non_finite() {
        let c = Rgba { r: 10, g: 20, b: 30, a: 200 };
        // NaN / infinities must not silently zero the alpha (a NaN `as u8` -> 0).
        assert_eq!(c.with_alpha(f64::NAN).a, 200);
        assert_eq!(c.with_alpha(f64::INFINITY).a, 200);
        assert_eq!(c.with_alpha(f64::NEG_INFINITY).a, 200);
        // Finite multipliers still apply (and clamp).
        assert_eq!(c.with_alpha(0.5).a, 100);
        assert_eq!(c.with_alpha(0.0).a, 0);
        assert_eq!(c.with_alpha(2.0).a, 200); // clamped to 1.0
    }
}
