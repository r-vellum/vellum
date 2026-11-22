//! Non-reactive keyframe animation: interpolate ("tween") between compiled
//! keyframe scenes and render the in-between frames in parallel, streaming them
//! into an encoder.
//!
//! R compiles `K` keyframe scenes (per-state stats recomputed, but scales trained
//! once and **frozen**, so nothing retrains between frames — the non-reactive
//! guardrail) and a per-frame schedule: for frame `k`, keyframe pair
//! `(seg[k], seg[k]+1)` at eased fraction `frac[k]`. This one entry point does the
//! rest: tween the node lists, rasterize each frame, and encode.
//!
//! This is a **child module of `scene`**, so it reaches `Scene`/`Node` and the
//! private `render_to`/`want_bitmap_text` directly, with no visibility widening.
//! The interpolation: unit geometry lerps its resolved value on a matching base
//! code (mismatched bases and vertex counts snap here — the clean, frozen-scale
//! P1 scope keeps them matched); colours lerp in Oklab (reusing `oklab.rs`);
//! bounded gpar numerics lerp; discrete fields snap at `t >= 0.5`.
//!
//! The fraction is not one number but a [`Fracs`] — one per property class
//! (position, colour, size, alpha) — so an animation can ease each aesthetic on
//! its own curve. All four equal is the single-curve case.

use crate::scene::xml_escape;
use std::borrow::Cow;
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::BufWriter;
use std::path::Path;

use color_quant::NeuQuant;
use extendr_api::prelude::*;
use rayon::prelude::*;
use tiny_skia::Pixmap;

use super::{MaskDef, Node, Scene};
use crate::color::{Inh, Paint, PartialGpar, Rgba};
use crate::oklab::{oklab_to_rgba, rgba_to_oklab};
use crate::render::RasterBackend;

// --- per-aesthetic fractions -------------------------------------------------

/// The eased interpolation fraction for one frame, **per property class**.
///
/// A single curve for the whole scene is the special case where all four are
/// equal, which is what an animation with one `ease_aes()` sends and what keeps
/// its output byte-identical. Splitting them lets position arrive on, say,
/// `cubic-in-out` while colour crossfades `linear`.
///
/// The classes, and what picks each:
///
/// * `pos` — coordinate-space geometry: x/y, widths/heights, angles, path
///   vertices, text rotation. Also the **tie-breaker for everything discrete**:
///   the `t >= 0.5` snap of `lty`/`lineend`/`label`/…, and the fallback for a
///   structural or variant mismatch. Note that this is a real choice, not a
///   neutral one — an eased curve crosses 0.5 at a different *frame* than a
///   linear one, so the class driving a snap decides which frame it flips on.
/// * `col` — anything that resolves to a colour: `fill`, `col`, the stroke
///   paint, and the per-element colour vectors on `Hexagons`/`Sectors`.
/// * `size` — extents that read as thickness rather than place: `lwd`, marker
///   `size`, circle radius, hex size, corner radius, `linemitre`.
/// * `alpha` — opacity, including the **enter/exit fade**: a keyed element
///   appearing or leaving fades on this curve, so `ease_aes(alpha =)` retimes
///   entrances as well as explicit alpha changes.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Fracs {
    pub pos: f64,
    pub col: f64,
    pub size: f64,
    pub alpha: f64,
}

// --- scalar / colour interpolation ------------------------------------------

#[inline]
fn lerp(a: f64, b: f64, t: f64) -> f64 {
    a + (b - a) * t
}

/// Interpolate two colours perceptually in Oklab (rectangular L,a,b), alpha
/// lerped linearly — the same space the gradient path uses, so animation and
/// gradients agree.
fn lerp_rgba(a: Rgba, b: Rgba, t: f64) -> Rgba {
    let tf = t as f32;
    let (la, aa) = rgba_to_oklab(a);
    let (lb, ab) = rgba_to_oklab(b);
    let lab = [
        la[0] + (lb[0] - la[0]) * tf,
        la[1] + (lb[1] - la[1]) * tf,
        la[2] + (lb[2] - la[2]) * tf,
    ];
    oklab_to_rgba(lab, aa + (ab - aa) * tf)
}

/// Lerp two parallel scalar vectors element-wise; a length mismatch (a changed
/// element set) snaps to the near side rather than morphing.
fn lerp_vec(a: &[f64], b: &[f64], t: f64) -> Vec<f64> {
    if a.len() != b.len() {
        return snap_slice(a, b, t).to_vec();
    }
    a.iter().zip(b).map(|(x, y)| lerp(*x, *y, t)).collect()
}

fn lerp_rgba_vec(a: &[Rgba], b: &[Rgba], t: f64) -> Vec<Rgba> {
    if a.len() != b.len() {
        return snap_slice(a, b, t).to_vec();
    }
    a.iter().zip(b).map(|(x, y)| lerp_rgba(*x, *y, t)).collect()
}

/// Easing curves such as `back` and `elastic` overshoot, driving the fraction
/// outside `[0, 1]`. Position may overshoot (that is the point of the curve), but
/// a size, radius or stroke width below 0 or an opacity outside `[0, 1]` has no
/// meaning, so those classes are clamped after the lerp.
#[inline]
fn nonneg(v: f64) -> f64 {
    v.max(0.0)
}

#[inline]
fn unit(v: f64) -> f64 {
    v.clamp(0.0, 1.0)
}

/// A size-class lerp (radius, marker size, extent): never below 0.
#[inline]
fn lerp_size(a: f64, b: f64, t: f64) -> f64 {
    nonneg(lerp(a, b, t))
}

fn lerp_vec_size(a: &[f64], b: &[f64], t: f64) -> Vec<f64> {
    let mut v = lerp_vec(a, b, t);
    v.iter_mut().for_each(|x| *x = nonneg(*x));
    v
}

fn map_inh(v: Inh<f64>, f: fn(f64) -> f64) -> Inh<f64> {
    match v {
        Inh::Set(x) => Inh::Set(f(x)),
        Inh::Inherit => Inh::Inherit,
    }
}

#[inline]
fn snap_slice<'a, T>(a: &'a [T], b: &'a [T], t: f64) -> &'a [T] {
    if t < 0.5 {
        a
    } else {
        b
    }
}

// --- gpar interpolation -----------------------------------------------------

fn lerp_col_inh(a: &Inh<Option<Rgba>>, b: &Inh<Option<Rgba>>, t: f64) -> Inh<Option<Rgba>> {
    match (a, b) {
        // Both an explicit solid colour -> perceptual lerp.
        (Inh::Set(Some(x)), Inh::Set(Some(y))) => Inh::Set(Some(lerp_rgba(*x, *y, t))),
        // Inherit or "no paint" (None) on either side has no colour to blend
        // (that is enter/exit, handled via alpha) -> snap.
        _ => snap(a, b, t).clone(),
    }
}

fn lerp_paint_inh(a: &Inh<Option<Paint>>, b: &Inh<Option<Paint>>, t: f64) -> Inh<Option<Paint>> {
    match (a, b) {
        (Inh::Set(Some(Paint::Solid(x))), Inh::Set(Some(Paint::Solid(y)))) => {
            Inh::Set(Some(Paint::Solid(lerp_rgba(*x, *y, t))))
        }
        // A gradient or pattern doesn't lerp continuously -> snap.
        _ => snap(a, b, t).clone(),
    }
}

fn lerp_f64_inh(a: &Inh<f64>, b: &Inh<f64>, t: f64) -> Inh<f64> {
    match (a, b) {
        (Inh::Set(x), Inh::Set(y)) => Inh::Set(lerp(*x, *y, t)),
        _ => snap(a, b, t).clone(),
    }
}

#[inline]
fn snap<'a, T>(a: &'a T, b: &'a T, t: f64) -> &'a T {
    if t < 0.5 {
        a
    } else {
        b
    }
}

/// Tween two graphical-parameter sets: colours in Oklab, bounded numerics
/// linearly; discrete stroke style (lty/lineend/linejoin) snaps with the near
/// side.
///
/// This is where the per-class fractions do most of their work: paints move on
/// `fr.col`, stroke width and mitre on `fr.size`, opacity on `fr.alpha`, and the
/// discrete near-side pick on `fr.pos`.
fn lerp_gpar(a: &PartialGpar, b: &PartialGpar, fr: &Fracs) -> PartialGpar {
    // Discrete style has no aesthetic class of its own; it rides the positional
    // curve, like every other `t >= 0.5` snap.
    let base = snap(a, b, fr.pos);
    PartialGpar {
        fill: lerp_paint_inh(&a.fill, &b.fill, fr.col),
        col: lerp_col_inh(&a.col, &b.col, fr.col),
        lwd: map_inh(lerp_f64_inh(&a.lwd, &b.lwd, fr.size), nonneg),
        alpha: map_inh(lerp_f64_inh(&a.alpha, &b.alpha, fr.alpha), unit),
        linemitre: map_inh(lerp_f64_inh(&a.linemitre, &b.linemitre, fr.size), nonneg),
        lty: base.lty.clone(),
        lineend: base.lineend,
        linejoin: base.linejoin,
        // Discrete render-quality flags: snap with the near side like lty.
        antialias: base.antialias,
        crisp: base.crisp,
        // A stroke paint interpolates like a fill paint; the dash phase is a
        // continuous quantity, so it tweens (which is what animates marching ants).
        // The phase is a distance *along* the path, so it moves with position.
        col_paint: lerp_paint_inh(&a.col_paint, &b.col_paint, fr.col),
        dash_phase: lerp_f64_inh(&a.dash_phase, &b.dash_phase, fr.pos),
    }
}

// --- node interpolation -----------------------------------------------------

/// Interpolate one node against its counterpart in the other keyframe. Unit
/// vectors and discrete fields are carried from `a` (identical across keyframes
/// under the frozen-scale, stable-element-set scope); geometry values, per-element
/// colours, and gpar interpolate. Structural nodes and any variant mismatch snap.
///
/// Coordinate geometry is the common case, so `t` below is bound to the
/// positional fraction; the fields that belong to another class (radii and
/// marker sizes on `size`, per-element colour vectors on `col`) name theirs
/// explicitly, and `gp` splits four ways inside `lerp_gpar`.
fn lerp_node(a: &Node, b: &Node, fr: &Fracs) -> Node {
    let t = fr.pos;
    // Two nodes whose element or vertex counts differ cannot be lerped
    // element-wise: the per-element units, styles and keys would come from one
    // side and the geometry from the other. Show one keyframe's node whole,
    // switching at the positional midpoint, so the final frame is `b` exactly.
    // (A real morph -- resampling both to a common vertex count -- is future work.)
    if !same_shape(a, b) {
        return snap(a, b, t).clone();
    }
    match (a, b) {
        (
            Node::Rect { x: ax, y: ay, w: aw, h: ah, xu, yu, wu, hu, gp: agp },
            Node::Rect { x: bx, y: by, w: bw, h: bh, gp: bgp, .. },
        ) => Node::Rect {
            x: lerp(*ax, *bx, t),
            y: lerp(*ay, *by, t),
            w: lerp(*aw, *bw, t),
            h: lerp(*ah, *bh, t),
            xu: *xu,
            yu: *yu,
            wu: *wu,
            hu: *hu,
            gp: lerp_gpar(agp, bgp, fr),
        },
        (
            Node::RoundRect { x: ax, y: ay, w: aw, h: ah, r: ar, xu, yu, wu, hu, ru, sketch, key, gp: agp },
            Node::RoundRect { x: bx, y: by, w: bw, h: bh, r: br, gp: bgp, .. },
        ) => Node::RoundRect {
            x: lerp(*ax, *bx, t),
            y: lerp(*ay, *by, t),
            w: lerp(*aw, *bw, t),
            h: lerp(*ah, *bh, t),
            r: lerp_size(*ar, *br, fr.size),
            xu: *xu,
            yu: *yu,
            wu: *wu,
            hu: *hu,
            ru: *ru,
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, fr),
            key: key.clone(),
        },
        (
            Node::Circle { x: ax, y: ay, r: ar, xu, yu, ru, sketch, gp: agp },
            Node::Circle { x: bx, y: by, r: br, gp: bgp, .. },
        ) => Node::Circle {
            x: lerp(*ax, *bx, t),
            y: lerp(*ay, *by, t),
            r: lerp_size(*ar, *br, fr.size),
            xu: *xu,
            yu: *yu,
            ru: *ru,
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, fr),
        },
        (
            Node::Lines { x: ax, y: ay, xu, yu, scap, ecap, off, arrow, sketch, hw: ahw, gp: agp, key },
            Node::Lines { x: bx, y: by, hw: bhw, .. },
        ) => Node::Lines {
            x: lerp_vec(ax, bx, t),
            y: lerp_vec(ay, by, t),
            xu: xu.clone(),
            yu: yu.clone(),
            scap: *scap,
            ecap: *ecap,
            off: *off,
            arrow: arrow.clone(),
            sketch: sketch.clone(),
            // A stroke width is a size, so the profile rides `frac_size` rather
            // than the position fraction (#45). Tweening between a profiled and
            // an unprofiled frame would change the KIND of mark mid-flight, so
            // that case snaps to the near keyframe rather than inventing a ribbon.
            hw: match (ahw, bhw) {
                (Some(a2), Some(b2)) => Some(lerp_vec_size(a2, b2, fr.size)),
                _ => snap(ahw, bhw, t).clone(),
            },
            gp: lerp_gpar(agp, snap_node_gp(b, agp), fr),
            key: key.clone(),
        },
        (
            Node::Polygon { x: ax, y: ay, xu, yu, sketch, gp: agp, key },
            Node::Polygon { x: bx, y: by, gp: bgp, .. },
        ) => Node::Polygon {
            x: lerp_vec(ax, bx, t),
            y: lerp_vec(ay, by, t),
            xu: xu.clone(),
            yu: yu.clone(),
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, fr),
            key: key.clone(),
        },
        (
            Node::Rects { x: ax, y: ay, w: aw, h: ah, xu, yu, wu, hu, sketch, gp: agp, keys },
            Node::Rects { x: bx, y: by, w: bw, h: bh, gp: bgp, .. },
        ) => Node::Rects {
            x: lerp_vec(ax, bx, t),
            y: lerp_vec(ay, by, t),
            w: lerp_vec(aw, bw, t),
            h: lerp_vec(ah, bh, t),
            xu: xu.clone(),
            yu: yu.clone(),
            wu: wu.clone(),
            hu: hu.clone(),
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, fr),
            keys: keys.clone(),
        },
        (
            Node::Circles { x: ax, y: ay, r: ar, xu, yu, ru, sketch, gp: agp, keys },
            Node::Circles { x: bx, y: by, r: br, gp: bgp, .. },
        ) => Node::Circles {
            x: lerp_vec(ax, bx, t),
            y: lerp_vec(ay, by, t),
            r: lerp_vec_size(ar, br, fr.size),
            xu: xu.clone(),
            yu: yu.clone(),
            ru: ru.clone(),
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, fr),
            keys: keys.clone(),
        },
        (
            Node::Markers { x: ax, y: ay, size: asz, xu, yu, su, shape, sketch, gp: agp, keys },
            Node::Markers { x: bx, y: by, size: bsz, gp: bgp, .. },
        ) => Node::Markers {
            x: lerp_vec(ax, bx, t),
            y: lerp_vec(ay, by, t),
            size: lerp_vec_size(asz, bsz, fr.size),
            xu: xu.clone(),
            yu: yu.clone(),
            su: su.clone(),
            shape: shape.clone(),
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, fr),
            keys: keys.clone(),
        },
        (
            Node::Hexagons { x: ax, y: ay, size: asz, w: aw, h: ah, xu, yu, su, wu, hu, fill: afill, flat, gp: agp, keys },
            Node::Hexagons { x: bx, y: by, size: bsz, w: bw, h: bh, fill: bfill, gp: bgp, .. },
        ) => Node::Hexagons {
            x: lerp_vec(ax, bx, t),
            y: lerp_vec(ay, by, t),
            size: lerp_vec_size(asz, bsz, fr.size),
            // A hexagon's w/h are its own corner-to-corner extent (the non-regular
            // form of `size`), not a position in the panel -- so they size, not move.
            w: lerp_vec_size(aw, bw, fr.size),
            h: lerp_vec_size(ah, bh, fr.size),
            xu: xu.clone(),
            yu: yu.clone(),
            su: su.clone(),
            wu: wu.clone(),
            hu: hu.clone(),
            fill: lerp_rgba_vec(afill, bfill, fr.col),
            flat: *flat,
            gp: lerp_gpar(agp, bgp, fr),
            keys: keys.clone(),
        },
        (
            Node::Sectors { x: ax, y: ay, r0: ar0, r1: ar1, theta0: at0, theta1: at1, xu, yu, r0u, r1u, fill: afill, arrow, sketch, gp: agp, keys },
            Node::Sectors { x: bx, y: by, r0: br0, r1: br1, theta0: bt0, theta1: bt1, fill: bfill, gp: bgp, .. },
        ) => Node::Sectors {
            x: lerp_vec(ax, bx, t),
            y: lerp_vec(ay, by, t),
            r0: lerp_vec(ar0, br0, t),
            r1: lerp_vec(ar1, br1, t),
            theta0: lerp_vec(at0, bt0, t),
            theta1: lerp_vec(at1, bt1, t),
            xu: xu.clone(),
            yu: yu.clone(),
            r0u: r0u.clone(),
            r1u: r1u.clone(),
            fill: lerp_rgba_vec(afill, bfill, fr.col),
            arrow: arrow.clone(),
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, fr),
            keys: keys.clone(),
        },
        (
            Node::Segments { x0: ax0, y0: ay0, x1: ax1, y1: ay1, x0u, y0u, x1u, y1u, scap, ecap, scapu, ecapu, off, offu, arrow, sketch, gp: agp, keys, cols, lwds },
            Node::Segments { x0: bx0, y0: by0, x1: bx1, y1: by1, gp: bgp, cols: bcols, lwds: blwds, .. },
        ) => Node::Segments {
            // Per-element stroke style is discrete data, not a continuous
            // quantity: take it from the near keyframe.
            cols: snap(cols, bcols, t).clone(),
            lwds: snap(lwds, blwds, t).clone(),
            x0: lerp_vec(ax0, bx0, t),
            y0: lerp_vec(ay0, by0, t),
            x1: lerp_vec(ax1, bx1, t),
            y1: lerp_vec(ay1, by1, t),
            x0u: x0u.clone(),
            y0u: y0u.clone(),
            x1u: x1u.clone(),
            y1u: y1u.clone(),
            scap: scap.clone(),
            ecap: ecap.clone(),
            scapu: scapu.clone(),
            ecapu: ecapu.clone(),
            off: off.clone(),
            offu: offu.clone(),
            arrow: arrow.clone(),
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, fr),
            keys: keys.clone(),
        },
        (
            Node::Loop { x: ax, y: ay, xu, yu, size: asz, su, foot: af, fu, angle: aang, width: aw, arrow, gp: agp },
            Node::Loop { x: bx, y: by, size: bsz, foot: bf, angle: bang, width: bw, gp: bgp, .. },
        ) => Node::Loop {
            x: lerp_vec(ax, bx, t),
            y: lerp_vec(ay, by, t),
            xu: xu.clone(),
            yu: yu.clone(),
            size: lerp_vec_size(asz, bsz, fr.size),
            su: su.clone(),
            // `foot` is the node radius the loop attaches at and `width` its
            // lateral petal scale: both are extents of the loop, like `size`.
            foot: lerp_vec_size(af, bf, fr.size),
            fu: fu.clone(),
            // The bulge direction is an angle in the panel -- positional.
            angle: lerp_vec(aang, bang, t),
            width: lerp_vec_size(aw, bw, fr.size),
            arrow: arrow.clone(),
            gp: lerp_gpar(agp, bgp, fr),
        },
        (
            Node::Path { x: ax, y: ay, xu, yu, nper, evenodd, sketch, gp: agp, key },
            Node::Path { x: bx, y: by, gp: bgp, .. },
        ) => Node::Path {
            x: lerp_vec(ax, bx, t),
            y: lerp_vec(ay, by, t),
            xu: xu.clone(),
            yu: yu.clone(),
            nper: nper.clone(),
            evenodd: *evenodd,
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, fr),
            key: key.clone(),
        },
        (Node::Text { x: ax, y: ay, rot: arot, gp: agp, .. }, Node::Text { x: bx, y: by, rot: brot, gp: bgp, .. }) => {
            // Position and rotation tween. Everything else -- the string, its
            // glyph layout and extent, font, halo, baseline path -- is layout,
            // not a continuous quantity: take it whole from the near keyframe, so
            // a changed label switches at the positional midpoint and the last
            // keyframe's text is what the final frame shows.
            let Node::Text {
                xu, yu, hjust, vjust, w, h, gid, gx, gy, gsize, gpath, gface, gcol, halo, label, family, face, size,
                tpath, key, ..
            } = snap(a, b, t)
            else {
                unreachable!()
            };
            Node::Text {
                halo: *halo,
                x: lerp(*ax, *bx, t),
                y: lerp(*ay, *by, t),
                xu: *xu,
                yu: *yu,
                rot: lerp(*arot, *brot, t),
                hjust: *hjust,
                vjust: *vjust,
                w: *w,
                h: *h,
                gid: gid.clone(),
                gx: gx.clone(),
                gy: gy.clone(),
                gsize: gsize.clone(),
                gpath: gpath.clone(),
                gface: gface.clone(),
                gcol: gcol.clone(),
                label: label.clone(),
                family: family.clone(),
                face: face.clone(),
                size: *size,
                tpath: tpath.clone(),
                key: key.clone(),
                gp: lerp_gpar(agp, bgp, fr),
            }
        }
        // Structural nodes (image/group/subraster/panel) and any variant mismatch
        // carry through unchanged from the near side.
        _ => snap(a, b, t).clone(),
    }
}

/// Whether two nodes of one variant have the same element count (a batch) or
/// vertex count (a line, polygon or path, plus the same sub-path split), so they
/// can be lerped element by element. A variant mismatch also counts as a
/// different shape. Single-element nodes and text always match: text layout is
/// taken from the near side inside `lerp_node`.
fn same_shape(a: &Node, b: &Node) -> bool {
    match (a, b) {
        (Node::Lines { x: ax, .. }, Node::Lines { x: bx, .. })
        | (Node::Polygon { x: ax, .. }, Node::Polygon { x: bx, .. })
        | (Node::Rects { x: ax, .. }, Node::Rects { x: bx, .. })
        | (Node::Circles { x: ax, .. }, Node::Circles { x: bx, .. })
        | (Node::Markers { x: ax, .. }, Node::Markers { x: bx, .. })
        | (Node::Hexagons { x: ax, .. }, Node::Hexagons { x: bx, .. })
        | (Node::Sectors { x: ax, .. }, Node::Sectors { x: bx, .. })
        | (Node::Loop { x: ax, .. }, Node::Loop { x: bx, .. })
        | (Node::Segments { x0: ax, .. }, Node::Segments { x0: bx, .. }) => ax.len() == bx.len(),
        (Node::Path { x: ax, nper: an, .. }, Node::Path { x: bx, nper: bn, .. }) => ax.len() == bx.len() && an == bn,
        _ => std::mem::discriminant(a) == std::mem::discriminant(b),
    }
}

/// A `Lines`/`Polygon`/etc. gp lookup fallback: `Node::gp()` returns the node's
/// own gpar, used when the `b` arm didn't bind it. (Lines binds `gp` on `a` but
/// the `b` pattern elides it with `..`; pull it back out.)
fn snap_node_gp<'a>(b: &'a Node, fallback: &'a PartialGpar) -> &'a PartialGpar {
    b.gp().unwrap_or(fallback)
}

// --- enter / exit (per-element, keyed) --------------------------------------

/// Multiply a gpar's alpha by `factor` (an inherited alpha is treated as 1.0),
/// for fading an entering (0 -> target) or exiting (target -> 0) element.
fn fade_gp(gp: &PartialGpar, factor: f64) -> PartialGpar {
    let base = match gp.alpha {
        Inh::Set(a) => a,
        Inh::Inherit => 1.0,
    };
    let mut g = gp.clone();
    g.alpha = Inh::Set(unit(base * factor));
    g
}

/// A whole node with its alpha scaled by `factor`: an entering or leaving
/// single-element node (a keyed line, polygon, path, rounded rect or label).
fn fade_node(n: &Node, factor: f64) -> Node {
    let mut n = n.clone();
    if let Some(gp) = n.gp_mut() {
        *gp = fade_gp(gp, factor);
    }
    n
}

#[inline]
fn gather<T: Clone>(v: &[T], idx: &[usize]) -> Vec<T> {
    idx.iter().map(|&i| v[i].clone()).collect()
}

/// The elements `idx` of a keyed batch (markers, circles or rects) as a batch of
/// their own, alpha scaled by `fade`: the leaving (`1 - alpha`) or entering
/// (`alpha`) part of a node.
fn batch_take(n: &Node, idx: &[usize], fade: f64) -> Node {
    match n {
        Node::Markers {
            x,
            y,
            size,
            xu,
            yu,
            su,
            shape,
            sketch,
            gp,
            keys,
        } => Node::Markers {
            x: gather(x, idx),
            y: gather(y, idx),
            size: gather(size, idx),
            xu: gather(xu, idx),
            yu: gather(yu, idx),
            su: gather(su, idx),
            shape: gather(shape, idx),
            sketch: sketch.clone(),
            gp: fade_gp(gp, fade),
            keys: gather(keys, idx),
        },
        Node::Circles {
            x,
            y,
            r,
            xu,
            yu,
            ru,
            sketch,
            gp,
            keys,
        } => Node::Circles {
            x: gather(x, idx),
            y: gather(y, idx),
            r: gather(r, idx),
            xu: gather(xu, idx),
            yu: gather(yu, idx),
            ru: gather(ru, idx),
            sketch: sketch.clone(),
            gp: fade_gp(gp, fade),
            keys: gather(keys, idx),
        },
        Node::Rects {
            x,
            y,
            w,
            h,
            xu,
            yu,
            wu,
            hu,
            sketch,
            gp,
            keys,
        } => Node::Rects {
            x: gather(x, idx),
            y: gather(y, idx),
            w: gather(w, idx),
            h: gather(h, idx),
            xu: gather(xu, idx),
            yu: gather(yu, idx),
            wu: gather(wu, idx),
            hu: gather(hu, idx),
            sketch: sketch.clone(),
            gp: fade_gp(gp, fade),
            keys: gather(keys, idx),
        },
        _ => fade_node(n, fade),
    }
}

/// Matched elements of two keyed batches of one variant, tweened: `pairs` are
/// `(element of a, element of b)`. The two batches may be different nodes -- a
/// point whose colour group changes moves from one colour's batch to another's
/// -- so the shared gpar lerps too (the colour crossfades along the move).
/// Units, shapes and keys come from `a`.
fn batch_pair(a: &Node, b: &Node, pairs: &[(usize, usize)], fr: &Fracs) -> Node {
    let t = fr.pos;
    let ia: Vec<usize> = pairs.iter().map(|p| p.0).collect();
    let pos = |va: &[f64], vb: &[f64]| -> Vec<f64> {
        pairs.iter().map(|&(i, j)| lerp(va[i], vb[j], t)).collect()
    };
    let size = |va: &[f64], vb: &[f64]| -> Vec<f64> {
        pairs
            .iter()
            .map(|&(i, j)| lerp_size(va[i], vb[j], fr.size))
            .collect()
    };
    match (a, b) {
        (
            Node::Markers {
                x: xa,
                y: ya,
                size: sa,
                xu,
                yu,
                su,
                shape,
                sketch,
                gp: gpa,
                keys,
            },
            Node::Markers {
                x: xb,
                y: yb,
                size: sb,
                gp: gpb,
                ..
            },
        ) => Node::Markers {
            x: pos(xa, xb),
            y: pos(ya, yb),
            size: size(sa, sb),
            xu: gather(xu, &ia),
            yu: gather(yu, &ia),
            su: gather(su, &ia),
            shape: gather(shape, &ia),
            sketch: sketch.clone(),
            gp: lerp_gpar(gpa, gpb, fr),
            keys: gather(keys, &ia),
        },
        (
            Node::Circles {
                x: xa,
                y: ya,
                r: ra,
                xu,
                yu,
                ru,
                sketch,
                gp: gpa,
                keys,
            },
            Node::Circles {
                x: xb,
                y: yb,
                r: rb,
                gp: gpb,
                ..
            },
        ) => Node::Circles {
            x: pos(xa, xb),
            y: pos(ya, yb),
            r: size(ra, rb),
            xu: gather(xu, &ia),
            yu: gather(yu, &ia),
            ru: gather(ru, &ia),
            sketch: sketch.clone(),
            gp: lerp_gpar(gpa, gpb, fr),
            keys: gather(keys, &ia),
        },
        (
            Node::Rects {
                x: xa,
                y: ya,
                w: wa,
                h: ha,
                xu,
                yu,
                wu,
                hu,
                sketch,
                gp: gpa,
                keys,
            },
            Node::Rects {
                x: xb,
                y: yb,
                w: wb,
                h: hb,
                gp: gpb,
                ..
            },
        ) => Node::Rects {
            x: pos(xa, xb),
            y: pos(ya, yb),
            w: pos(wa, wb),
            h: pos(ha, hb),
            xu: gather(xu, &ia),
            yu: gather(yu, &ia),
            wu: gather(wu, &ia),
            hu: gather(hu, &ia),
            sketch: sketch.clone(),
            gp: lerp_gpar(gpa, gpb, fr),
            keys: gather(keys, &ia),
        },
        // `plan_pair` only pairs batches of one variant.
        _ => snap(a, b, t).clone(),
    }
}

// --- identity: pairing two keyframes ----------------------------------------
//
// Marks tween by *identity*, not by where they sit in the node list. Every
// element carrying a data key is matched to the element with the same key in
// the other keyframe, wherever it is drawn: in another node, at another index,
// with another style. A grammar layer therefore makes its keys unique per layer
// (vellumplot prefixes the layer) and stable across states (a `data_id`, or a
// group-plus-occurrence default).
//
// * Keyed batch elements (markers, circles, rects) match across ALL nodes. The
//   matched elements of one node pair tween as one batch whose gpar lerps
//   between the two nodes' (a point changing colour group slides and recolours);
//   an element with no partner fades out (leaving) or in (entering) on the alpha
//   fraction.
// * Keyed single-element nodes (lines, polygons, paths, rounded rects, labels)
//   match by their key and tween through `lerp_node` (a vertex-count change
//   still switches whole at the midpoint); unmatched ones fade.
// * Unkeyed nodes (axes, grid, legend, unkeyed marks) pair in order within their
//   class -- same viewport, variant and role. A class with the same number of
//   nodes in both keyframes pairs one to one, as before; a class whose count
//   differs cannot be matched, so its nodes switch whole at the midpoint.
//
// Two keyframes whose nodes line up one to one with identical keys (the common
// case: same groups, same rows) skip all of this and tween node by node.

/// How a node is keyed, for identity matching.
enum Keys<'a> {
    None,
    /// A batch with per-element keys (markers, circles, rects).
    Batch(&'a [String]),
    /// A single-element node with a key.
    One(&'a str),
}

fn node_keys(n: &Node) -> Keys<'_> {
    match n {
        Node::Markers { keys, .. } | Node::Circles { keys, .. } | Node::Rects { keys, .. }
            if keys.iter().any(|k| !k.is_empty()) =>
        {
            Keys::Batch(keys)
        }
        Node::RoundRect { key, .. }
        | Node::Lines { key, .. }
        | Node::Polygon { key, .. }
        | Node::Path { key, .. }
        | Node::Text { key, .. } => match key.as_deref() {
            Some(k) if !k.is_empty() => Keys::One(k),
            _ => Keys::None,
        },
        _ => Keys::None,
    }
}

/// Whether two nodes carry the same keys (both unkeyed counts as the same).
fn same_keys(a: &Node, b: &Node) -> bool {
    match (node_keys(a), node_keys(b)) {
        (Keys::None, Keys::None) => true,
        (Keys::Batch(x), Keys::Batch(y)) => x == y,
        (Keys::One(x), Keys::One(y)) => x == y,
        _ => false,
    }
}

/// Whether two keyframes line up node for node with identical keys, so the
/// index-wise tween is the identity tween (and byte-identical to it).
fn scenes_aligned(a: &Scene, b: &Scene) -> bool {
    a.nodes.len() == b.nodes.len()
        && a.viewports.len() == b.viewports.len()
        && a.nodes
            .iter()
            .zip(&b.nodes)
            .all(|((_, x), (_, y))| same_keys(x, y))
}

/// Whether two keyframes can be tweened at all: they must share a viewport tree
/// (under frozen scales they always do). Keyframes that do not are cut at the
/// positional midpoint instead.
pub(crate) fn scenes_pair(a: &Scene, b: &Scene) -> bool {
    a.viewports.len() == b.viewports.len()
}

/// One step of a frame, in paint order. Indices are into `a.nodes` or
/// `b.nodes` as named.
enum Op {
    /// A node pair tweened whole (`lerp_node`; a shape change snaps).
    Pair(usize, usize),
    /// An unkeyed node of `a` with no counterpart: shown until the midpoint.
    OnlyA(usize),
    /// An unkeyed node of `b` with no counterpart: shown from the midpoint.
    OnlyB(usize),
    /// A keyed single-element node of `a` leaving (fades out).
    FadeA(usize),
    /// A keyed single-element node of `b` entering (fades in).
    FadeB(usize),
    /// Matched elements `(of a[.0], of b[.1])`, tweened as one batch.
    Batch(usize, usize, Vec<(usize, usize)>),
    /// Elements of batch `a[.0]` with no partner, fading out.
    Exit(usize, Vec<usize>),
    /// Elements of batch `b[.0]` with no partner, fading in.
    Enter(usize, Vec<usize>),
}

impl Op {
    /// The node the output takes its viewport, pick and metadata from.
    fn source(&self) -> (bool, usize) {
        match self {
            Op::Pair(i, _) | Op::OnlyA(i) | Op::FadeA(i) | Op::Batch(i, _, _) | Op::Exit(i, _) => {
                (false, *i)
            }
            Op::OnlyB(j) | Op::FadeB(j) | Op::Enter(j, _) => (true, *j),
        }
    }
}

/// How one keyframe pair tweens: the frame recipe plus what it reports.
pub(crate) struct Plan {
    ops: Vec<Op>,
    /// Nodes (or node pairs) that switch whole at the midpoint.
    snapped: usize,
    /// Keyed elements with no partner in the next / previous keyframe.
    exited: usize,
    entered: usize,
}

/// The class an unkeyed node pairs within: viewport, variant, role.
fn class_of<'a>(s: &'a Scene, i: usize) -> (usize, std::mem::Discriminant<Node>, &'a str) {
    let (vp, n) = &s.nodes[i];
    (
        *vp,
        std::mem::discriminant(n),
        s.meta.get(i).map_or("", |m| m.role.as_str()),
    )
}

/// Match two keyframes by identity (see the section comment). `None` when they
/// do not share a viewport tree and cannot be tweened at all.
pub(crate) fn plan_pair(a: &Scene, b: &Scene) -> Option<Plan> {
    if !scenes_pair(a, b) {
        return None;
    }
    if scenes_aligned(a, b) {
        let ops: Vec<Op> = (0..a.nodes.len()).map(|i| Op::Pair(i, i)).collect();
        let snapped = a
            .nodes
            .iter()
            .zip(&b.nodes)
            .filter(|((_, x), (_, y))| !same_shape(x, y))
            .count();
        return Some(Plan {
            ops,
            snapped,
            exited: 0,
            entered: 0,
        });
    }

    // Every keyed element of `b`, by key: (node, element). The first wins.
    let mut bmap: HashMap<&str, (usize, usize)> = HashMap::new();
    let mut used: Vec<Vec<bool>> = Vec::with_capacity(b.nodes.len());
    for (j, (_, n)) in b.nodes.iter().enumerate() {
        match node_keys(n) {
            Keys::Batch(ks) => {
                for (e, k) in ks.iter().enumerate() {
                    if !k.is_empty() {
                        bmap.entry(k.as_str()).or_insert((j, e));
                    }
                }
                used.push(vec![false; ks.len()]);
            }
            Keys::One(k) => {
                bmap.entry(k).or_insert((j, 0));
                used.push(vec![false]);
            }
            Keys::None => used.push(Vec::new()),
        }
    }

    // Unkeyed nodes, per class, in order.
    type Class<'s> = (usize, std::mem::Discriminant<Node>, &'s str);
    let mut a_cls: HashMap<Class<'_>, Vec<usize>> = HashMap::new();
    let mut b_cls: HashMap<Class<'_>, Vec<usize>> = HashMap::new();
    for i in 0..a.nodes.len() {
        if matches!(node_keys(&a.nodes[i].1), Keys::None) {
            a_cls.entry(class_of(a, i)).or_default().push(i);
        }
    }
    for j in 0..b.nodes.len() {
        if matches!(node_keys(&b.nodes[j].1), Keys::None) {
            b_cls.entry(class_of(b, j)).or_default().push(j);
        }
    }
    // The partner of each unkeyed node of `a` (classes of equal size pair in order).
    let mut a_partner: Vec<Option<usize>> = vec![None; a.nodes.len()];
    let mut b_paired = vec![false; b.nodes.len()];
    for (c, ia) in &a_cls {
        if let Some(jb) = b_cls.get(c) {
            if ia.len() == jb.len() {
                for (&i, &j) in ia.iter().zip(jb) {
                    a_partner[i] = Some(j);
                    b_paired[j] = true;
                }
            }
        }
    }

    let disc = |n: &Node| std::mem::discriminant(n);
    let mut ops: Vec<Op> = Vec::new();
    // For each node of `b`, the last op index it was matched at (its anchor).
    let mut b_at: Vec<Option<usize>> = vec![None; b.nodes.len()];
    let (mut snapped, mut exited) = (0usize, 0usize);
    for (i, (_, na)) in a.nodes.iter().enumerate() {
        match node_keys(na) {
            Keys::None => match a_partner[i] {
                Some(j) => {
                    if !same_shape(na, &b.nodes[j].1) {
                        snapped += 1;
                    }
                    b_at[j] = Some(ops.len());
                    ops.push(Op::Pair(i, j));
                }
                None => {
                    snapped += 1;
                    ops.push(Op::OnlyA(i));
                }
            },
            Keys::One(k) => match bmap.get(k) {
                Some(&(j, 0))
                    if !used[j][0]
                        && matches!(node_keys(&b.nodes[j].1), Keys::One(_))
                        && disc(na) == disc(&b.nodes[j].1) =>
                {
                    used[j][0] = true;
                    if !same_shape(na, &b.nodes[j].1) {
                        snapped += 1;
                    }
                    b_at[j] = Some(ops.len());
                    ops.push(Op::Pair(i, j));
                }
                _ => {
                    exited += 1;
                    ops.push(Op::FadeA(i));
                }
            },
            Keys::Batch(ks) => {
                // Matched elements grouped by the `b` node they land in, in order
                // of first appearance; the rest leave.
                let mut groups: Vec<(usize, Vec<(usize, usize)>)> = Vec::new();
                let mut gi: HashMap<usize, usize> = HashMap::new();
                let mut gone = Vec::new();
                for (e, k) in ks.iter().enumerate() {
                    let hit = if k.is_empty() {
                        None
                    } else {
                        bmap.get(k.as_str()).copied()
                    };
                    match hit {
                        Some((j, f))
                            if !used[j][f]
                                && matches!(node_keys(&b.nodes[j].1), Keys::Batch(_))
                                && disc(na) == disc(&b.nodes[j].1) =>
                        {
                            used[j][f] = true;
                            let g = *gi.entry(j).or_insert_with(|| {
                                groups.push((j, Vec::new()));
                                groups.len() - 1
                            });
                            groups[g].1.push((e, f));
                        }
                        _ => gone.push(e),
                    }
                }
                for (j, pairs) in groups {
                    b_at[j] = Some(ops.len());
                    ops.push(Op::Batch(i, j, pairs));
                }
                if !gone.is_empty() {
                    exited += gone.len();
                    ops.push(Op::Exit(i, gone));
                }
            }
        }
    }

    // What only `b` has, each placed after the last op of an earlier-or-same `b`
    // node that was matched, so it keeps its place in `b`'s paint order.
    let mut late: Vec<(usize, Op)> = Vec::new(); // (insert after op index + 1, op)
    let mut anchor = 0usize; // 0 = before everything
    let mut entered = 0usize;
    for (j, (_, nb)) in b.nodes.iter().enumerate() {
        if let Some(p) = b_at[j] {
            anchor = anchor.max(p + 1);
        }
        match node_keys(nb) {
            Keys::None => {
                if !b_paired[j] {
                    snapped += 1;
                    late.push((anchor, Op::OnlyB(j)));
                }
            }
            Keys::One(_) => {
                if !used[j][0] {
                    entered += 1;
                    late.push((anchor, Op::FadeB(j)));
                }
            }
            Keys::Batch(_) => {
                let new: Vec<usize> = (0..used[j].len()).filter(|&f| !used[j][f]).collect();
                if !new.is_empty() {
                    entered += new.len();
                    late.push((anchor, Op::Enter(j, new)));
                }
            }
        }
    }
    if !late.is_empty() {
        // `late` is already in anchor order (anchors never decrease).
        let mut merged = Vec::with_capacity(ops.len() + late.len());
        let mut late = late.into_iter().peekable();
        for (k, op) in ops.into_iter().enumerate() {
            while late.peek().is_some_and(|(at, _)| *at <= k) {
                merged.push(late.next().unwrap().1);
            }
            merged.push(op);
        }
        merged.extend(late.map(|(_, op)| op));
        ops = merged;
    }
    Some(Plan {
        ops,
        snapped,
        exited,
        entered,
    })
}

/// Build one frame from a plan.
fn apply_plan(plan: &Plan, a: &Scene, b: &Scene, fr: &Fracs) -> Scene {
    let t = fr.pos;
    // Picks and metadata are parallel to the nodes when present at all.
    let with_picks = a.picks.len() == a.nodes.len() && b.picks.len() == b.nodes.len();
    let with_meta = a.meta.len() == a.nodes.len() && b.meta.len() == b.nodes.len();
    let mut nodes = Vec::with_capacity(plan.ops.len());
    let mut picks = Vec::new();
    let mut meta = Vec::new();
    for op in &plan.ops {
        let node = match op {
            Op::Pair(i, j) => lerp_node(&a.nodes[*i].1, &b.nodes[*j].1, fr),
            Op::OnlyA(i) if t < 0.5 => a.nodes[*i].1.clone(),
            Op::OnlyB(j) if t >= 0.5 => b.nodes[*j].1.clone(),
            Op::OnlyA(_) | Op::OnlyB(_) => continue,
            Op::FadeA(i) => fade_node(&a.nodes[*i].1, 1.0 - fr.alpha),
            Op::FadeB(j) => fade_node(&b.nodes[*j].1, fr.alpha),
            Op::Batch(i, j, pairs) => batch_pair(&a.nodes[*i].1, &b.nodes[*j].1, pairs, fr),
            Op::Exit(i, els) => batch_take(&a.nodes[*i].1, els, 1.0 - fr.alpha),
            Op::Enter(j, els) => batch_take(&b.nodes[*j].1, els, fr.alpha),
        };
        let (from_b, k) = op.source();
        let s = if from_b { b } else { a };
        nodes.push((s.nodes[k].0, node));
        if with_picks {
            picks.push(s.picks[k]);
        }
        if with_meta {
            meta.push(s.meta[k].clone());
        }
    }
    frame_scene(a, nodes, picks, meta, tween_masks(&a.masks, &b.masks, fr))
}
// --- per-frame scene assembly + render --------------------------------------

/// Tween the viewport masks between keyframes. Masks are the clip/reveal
/// geometry attached to a viewport; interpolating them lets a `transition_reveal`
/// grow a clip rectangle so the plot wipes into view. Structurally parallel masks
/// (same count, same node counts) tween element-wise; anything else snaps to the
/// near keyframe's.
fn tween_masks(a: &[MaskDef], b: &[MaskDef], fr: &Fracs) -> Vec<MaskDef> {
    if a.len() != b.len() {
        return snap_slice(a, b, fr.pos).to_vec();
    }
    a.iter()
        .zip(b.iter())
        .map(|(ma, mb)| {
            let nodes = if ma.nodes.len() == mb.nodes.len() {
                ma.nodes
                    .iter()
                    .zip(mb.nodes.iter())
                    .map(|((vp, na), (_, nb))| (*vp, lerp_node(na, nb, fr)))
                    .collect()
            } else {
                snap(ma, mb, fr.pos).nodes.clone()
            };
            MaskDef { kind: ma.kind.clone(), nodes }
        })
        .collect()
}

/// Build the tweened scene for one frame from keyframes `a` and `b`, matched by
/// [`plan_pair`] (computed once per keyframe pair, see [`plans_for`]).
///
/// Keyframes that do not pair at all (different viewport trees, so no plan)
/// cannot be matched, so the frame shows one keyframe whole: `a` before the
/// positional midpoint, `b` from it on.
fn tween_scene(a: &Scene, b: &Scene, plan: Option<&Plan>, fr: &Fracs) -> Scene {
    match plan {
        Some(p) => apply_plan(p, a, b, fr),
        None => {
            let s = snap(a, b, fr.pos);
            frame_scene(
                s,
                s.nodes.clone(),
                s.picks.clone(),
                s.meta.clone(),
                s.masks.clone(),
            )
        }
    }
}

/// The plan of every keyframe pair `(k, k + 1)` the schedule uses, computed
/// once per pair rather than once per frame.
fn plans_for(kf: &[Scene], seg: &[i32]) -> Vec<Option<Plan>> {
    let mut want = vec![false; kf.len().saturating_sub(1)];
    for &s in seg {
        want[s as usize] = true;
    }
    want.iter()
        .enumerate()
        .map(|(k, &w)| {
            if w {
                plan_pair(&kf[k], &kf[k + 1])
            } else {
                None
            }
        })
        .collect()
}
/// A fresh frame scene with `base`'s page, viewports and document-level fields
/// and the given drawn content. Caches start empty.
fn frame_scene(
    base: &Scene,
    nodes: Vec<(usize, Node)>,
    picks: Vec<i32>,
    meta: Vec<super::NodeMeta>,
    masks: Vec<MaskDef>,
) -> Scene {
    Scene {
        w_px: base.w_px,
        h_px: base.h_px,
        dpi: base.dpi,
        bg: base.bg,
        viewports: base.viewports.clone(),
        current: base.current,
        nodes,
        masks,
        mask_target: base.mask_target.clone(),
        picks,
        cur_pick: base.cur_pick,
        meta,
        cur_meta: base.cur_meta.clone(),
        raster_cache: RefCell::new(None),
        geom_cache: RefCell::new(None),
        spatial_cache: RefCell::new(None),
        text_glyphs: base.text_glyphs,
        a11y_title: base.a11y_title.clone(),
        a11y_desc: base.a11y_desc.clone(),
        a11y_prefix: base.a11y_prefix.clone(),
    }
}

/// Per-frame text: the keyed text nodes of one variant scene, by key. A frame
/// that uses the variant takes each matching text node's string and glyph
/// layout from it (see `patch_text`).
type TextVariant = HashMap<String, Node>;

/// The keyed text nodes of each variant scene.
fn text_variants_of(scenes: &[Scene]) -> Vec<TextVariant> {
    scenes
        .iter()
        .map(|sc| {
            let mut m = TextVariant::new();
            for (_, n) in &sc.nodes {
                if let Node::Text { key: Some(k), .. } = n {
                    m.entry(k.clone()).or_insert_with(|| n.clone());
                }
            }
            m
        })
        .collect()
}

/// Swap the content of a frame's keyed text nodes for the variant's: the
/// string, its glyph layout and extent, font and size come from the variant,
/// while the position, rotation, justification, colour and halo stay as the
/// tween left them. This is how a label that changes on every frame (a
/// `{frame_time}` title) is drawn without a keyframe per frame: the R caller
/// shapes each distinct string once, in a small scene keyed like the node it
/// replaces.
fn patch_text(nodes: &mut [(usize, Node)], variant: &TextVariant) {
    if variant.is_empty() {
        return;
    }
    for (_, n) in nodes.iter_mut() {
        let Node::Text {
            key: Some(k),
            w,
            h,
            gid,
            gx,
            gy,
            gsize,
            gpath,
            gface,
            gcol,
            label,
            family,
            face,
            size,
            ..
        } = n
        else {
            continue;
        };
        let Some(Node::Text {
            w: vw,
            h: vh,
            gid: vgid,
            gx: vgx,
            gy: vgy,
            gsize: vgsize,
            gpath: vgpath,
            gface: vgface,
            gcol: vgcol,
            label: vlabel,
            family: vfamily,
            face: vface,
            size: vsize,
            ..
        }) = variant.get(k.as_str())
        else {
            continue;
        };
        *w = *vw;
        *h = *vh;
        *gid = vgid.clone();
        *gx = vgx.clone();
        *gy = vgy.clone();
        *gsize = vgsize.clone();
        *gpath = vgpath.clone();
        *gface = vgface.clone();
        *gcol = vgcol.clone();
        *label = vlabel.clone();
        *family = vfamily.clone();
        *face = vface.clone();
        *size = *vsize;
    }
}

/// The text variant frame `frame` uses, if any (`text_frame` is 1-based, 0 =
/// none, and empty when the animation has no per-frame text).
fn frame_variant<'a>(texts: &'a [TextVariant], text_frame: &[i32], frame: usize) -> Option<&'a TextVariant> {
    let v = *text_frame.get(frame)?;
    if v < 1 {
        return None;
    }
    texts.get(v as usize - 1)
}

/// Build a single animated SVG from the frame schedule.
///
/// Every frame is emitted in full, as a `<g>` shown for its slice of the
/// timeline by a CSS step animation. That is *not* the smallest possible
/// encoding — attribute-level SMIL would emit the scene once and animate the
/// values that change — but it is the one that is always correct, because it
/// makes no assumption that a node's SVG representation has the same shape in
/// every frame.
///
/// The size trade-off is real and worth stating plainly (measured on a scatter
/// animation, 30 frames, gzipped):
///
/// | marks | animated SVG (gz) | GIF  |
/// |-------|-------------------|------|
/// |    20 |             20 KB | 61 KB |
/// |   200 |             80 KB | 296 KB |
/// |  2000 |            720 KB | 124 KB |
///
/// So it wins on line art -- an explanatory animation of a few moving marks --
/// and loses on dense scatter, where a raster format is the right answer. It is
/// resolution-independent either way, which no raster format is.
fn animated_svg(
    kf: &[Scene],
    seg: &[i32],
    frac: &[Fracs],
    delay_num: i32,
    delay_den: i32,
    texts: &[TextVariant],
    text_frame: &[i32],
) -> String {
    let n = seg.len();
    let dur = (delay_num.max(0) as f64 / delay_den.max(1) as f64) * n as f64;
    let (w, h) = (kf[0].w_px, kf[0].h_px);

    // Sequential, unlike the raster path: the SVG backend holds a non-`Send`
    // glyph-outline cache. It is also much the cheaper of the two -- emitting
    // markup rather than rasterising -- so there is little to win here.
    let plans = plans_for(kf, seg);
    let bodies: Vec<String> = (0..n)
        .map(|frame| {
            let s = seg[frame] as usize;
            let mut sc = tween_scene(&kf[s], &kf[s + 1], plans[s].as_ref(), &frac[frame]);
            if let Some(v) = frame_variant(texts, text_frame, frame) {
                patch_text(&mut sc.nodes, v);
            }
            // The title/desc belong to the document, not to each of its frames:
            // repeating them would have a screen reader announce the figure once
            // per frame.
            sc.clear_a11y();
            clear_keys(&mut sc);
            // Every frame is a separate render with its own id counters, but they
            // all end up in ONE document, so the ids need a per-frame namespace.
            svg_body(&sc.svg_string(false, &format!("f{frame}-")))
        })
        .collect();
    // Every frame's `<defs>` (gradients, patterns, clip paths, masks, filters)
    // move into one document-level `<defs>`, each distinct definition once: a
    // colour bar's 256-stop gradient or a panel's clip path is the same in every
    // frame, and was written out in full per frame (VR-36).
    let mut shared = SharedDefs::default();
    let bodies: Vec<String> = bodies
        .into_iter()
        .enumerate()
        .map(|(frame, b)| {
            let prefix = format!("{}-f{frame}-", crate::render::ID_TOKEN);
            hoist_defs(b, &prefix, &mut shared)
        })
        .collect();

    let mut out = String::with_capacity(bodies.iter().map(|b| b.len()).sum::<usize>() + 4096);
    out.push_str(&format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{w}\" height=\"{h}\" \
         viewBox=\"0 0 {w} {h}\" role=\"img\">"
    ));
    if !kf[0].a11y_title.is_empty() {
        out.push_str(&format!("<title>{}</title>", xml_escape(&kf[0].a11y_title)));
    }
    if !kf[0].a11y_desc.is_empty() {
        out.push_str(&format!("<desc>{}</desc>", xml_escape(&kf[0].a11y_desc)));
    }
    // One frame visible at a time. `steps(1, end)` with a per-frame negative
    // delay is the standard sprite-sheet trick: every frame runs the same
    // animation, offset so exactly one is in its visible window at any moment.
    //
    // The class and keyframes names carry the document's id prefix (`C` below
    // stands in for it until the document is finished): an HTML page holding two
    // animated SVGs -- or two widgets, which inline the SVG -- shares one CSS
    // namespace, so unprefixed names let the later document's timing drive both.
    //
    // Under `prefers-reduced-motion` one still frame is shown instead (`vs`): the
    // last frame when the timeline ends on the final keyframe (a reveal,
    // `transition_time()`, a non-looping `transition_states()` -- the complete
    // picture), otherwise the first (a loop, whose first frame is its first state).
    let still = still_frame(kf.len(), seg, frac);
    // The visible window, rounded UP to the 6 decimals written: rounded to
    // nearest it could fall a hair short of the next frame's start, leaving a
    // sub-nanosecond gap with no frame visible that a seek to a round time can
    // land in (a blank flash). Rounded up, adjacent frames overlap by as much
    // instead, and the later one paints over the earlier.
    let pct = (100.0 / n as f64 * 1e6).ceil() / 1e6;
    out.push_str(&format!(
        "<style>\
         .{C}vf{{visibility:hidden;animation:{C}vc {dur}s steps(1,end) infinite}}\
         @keyframes {C}vc{{0%{{visibility:visible}}{pct:.6}%{{visibility:hidden}}}}\
         @media (prefers-reduced-motion:reduce){{.{C}vf{{animation:none}}.{C}vs{{visibility:visible}}}}\
         </style>",
        C = CSS_TOKEN
    ));
    if !shared.defs.is_empty() {
        out.push_str("<defs>");
        out.push_str(&shared.defs);
        out.push_str("</defs>");
    }
    for (i, body) in bodies.iter().enumerate() {
        // A negative delay starts each frame that far into the cycle, so frame `i`
        // is in its visible window once the cycle has `dur - i*dur/n` still to run
        // -- i.e. at wall time `i*dur/n`. Offsetting by `i` rather than `n - i`
        // would run the frames backwards (0, n-1, n-2, ...).
        let delay = -(((n - i) % n) as f64) * dur / n as f64;
        let class = if i == still { format!("{CSS_TOKEN}vf {CSS_TOKEN}vs") } else { format!("{CSS_TOKEN}vf") };
        out.push_str(&format!("<g class=\"{class}\" style=\"animation-delay:{delay:.4}s\">{body}</g>"));
    }
    out.push_str("</svg>");
    // One prefix for the whole document (the frames left the token in place):
    // the ids get it as is, the CSS names a CSS-identifier-safe form of it.
    let prefix = crate::render::doc_id_prefix(&out, &kf[0].a11y_prefix);
    let out = out.replace(CSS_TOKEN, &format!("{}-", css_ident(&prefix)));
    crate::render::resolve_ids(out, &prefix)
}

/// The document-level `<defs>` of an animated SVG: each distinct definition
/// once, by content (its own id blanked, its references already pointing at
/// shared ids).
#[derive(Default)]
struct SharedDefs {
    defs: String,
    by_content: HashMap<String, String>,
}

/// The top-level elements of a run of sibling XML elements (the content of a
/// `<defs>`), or `None` when it does not split cleanly. Attribute values and
/// text are escaped by the writer, so a raw `<`/`>` only ever delimits a tag.
fn split_elements(s: &str) -> Option<Vec<&str>> {
    let mut out = Vec::new();
    let (mut depth, mut start, mut i) = (0usize, 0usize, 0usize);
    let b = s.as_bytes();
    while i < b.len() {
        if b[i] != b'<' {
            if depth == 0 && !b[i].is_ascii_whitespace() {
                return None;
            }
            i += 1;
            continue;
        }
        let j = i + s[i..].find('>')?;
        if depth == 0 {
            start = i;
        }
        if b[i + 1] == b'/' {
            depth = depth.checked_sub(1)?;
            if depth == 0 {
                out.push(&s[start..=j]);
            }
        } else if b[j - 1] == b'/' {
            if depth == 0 {
                out.push(&s[start..=j]);
            }
        } else if matches!(b[i + 1], b'?' | b'!') {
            return None;
        } else {
            depth += 1;
        }
        i = j + 1;
    }
    (depth == 0).then_some(out)
}

/// `s` with every `url(#id)` whose id is in `map` pointed at the mapped id.
fn remap_urls(s: &str, map: &HashMap<String, String>) -> String {
    if map.is_empty() {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(k) = rest.find("url(#") {
        let (head, tail) = rest.split_at(k + 5);
        out.push_str(head);
        match tail.find(')') {
            Some(e) => {
                let id = &tail[..e];
                out.push_str(map.get(id).map_or(id, |v| v.as_str()));
                rest = &tail[e..];
            }
            None => {
                rest = tail;
                break;
            }
        }
    }
    out.push_str(rest);
    out
}

/// Move one frame's `<defs>` into `shared`, keeping one copy of each distinct
/// definition across the whole animation, and point the frame's references at
/// the shared ids. Definitions are compared after their own references are
/// remapped, so a clip path nested in an already-shared one matches too. Only
/// ids carrying this frame's prefix are touched; a frame whose `<defs>` does
/// not parse is left as it was.
fn hoist_defs(body: String, frame_prefix: &str, shared: &mut SharedDefs) -> String {
    let Some(open) = body.find("<defs>") else {
        return body;
    };
    let Some(close) = body[open..].find("</defs>").map(|c| open + c) else {
        return body;
    };
    let inner = &body[open + 6..close];
    let Some(elems) = split_elements(inner) else {
        return body;
    };
    let mut map: HashMap<String, String> = HashMap::new();
    let mut kept: Vec<String> = Vec::new();
    for el in elems {
        let own = el
            .split_once('>')
            .and_then(|(tag, _)| tag.split_once(" id=\"").map(|(_, r)| r))
            .and_then(|r| r.split_once('"'))
            .map(|(id, _)| id.to_string());
        let el = remap_urls(el, &map);
        let Some(own) = own.filter(|id| id.starts_with(frame_prefix)) else {
            kept.push(el);
            continue;
        };
        let key = el.replacen(&format!(" id=\"{own}\""), " id=\"\"", 1);
        match shared.by_content.get(&key) {
            Some(canon) => {
                map.insert(own, canon.clone());
            }
            None => {
                kept.push(el);
                shared.by_content.insert(key, own);
            }
        }
    }
    // A kept definition may reference one defined after it that turned out
    // to be shared: point it there too.
    for el in kept {
        shared.defs.push_str(&remap_urls(&el, &map));
    }
    let mut out = String::with_capacity(body.len());
    out.push_str(&body[..open]);
    out.push_str(&remap_urls(&body[close + 7..], &map));
    out
}

/// Drop every data key from a frame. An animated SVG is a picture, not an
/// interactive scene: the keys the tween matched marks by would otherwise put a
/// `data-key` on every element of every frame.
fn clear_keys(sc: &mut Scene) {
    for (_, n) in sc.nodes.iter_mut() {
        match n {
            Node::Rects { keys, .. }
            | Node::Circles { keys, .. }
            | Node::Markers { keys, .. }
            | Node::Hexagons { keys, .. }
            | Node::Sectors { keys, .. }
            | Node::Segments { keys, .. } => keys.clear(),
            Node::RoundRect { key, .. }
            | Node::Lines { key, .. }
            | Node::Polygon { key, .. }
            | Node::Path { key, .. }
            | Node::Text { key, .. } => *key = None,
            _ => {}
        }
    }
}
/// Stands in for the CSS-name prefix while the animated SVG is assembled: two
/// id tokens, which no id contains (every id token is followed by `-`).
const CSS_TOKEN: &str = "\0\0";

/// The frame shown, alone, under `prefers-reduced-motion`: the last when it is
/// the final keyframe exactly, else the first.
fn still_frame(k: usize, seg: &[i32], frac: &[Fracs]) -> usize {
    let n = seg.len();
    match (seg.last(), frac.last()) {
        (Some(&s), Some(f)) if s as usize + 2 == k && f.pos >= 1.0 => n - 1,
        _ => 0,
    }
}

/// `p` as a CSS identifier: characters outside `[A-Za-z0-9_-]` become `_`, and
/// a leading digit or dash gets a `v` in front.
fn css_ident(p: &str) -> String {
    let mut s: String =
        p.chars().map(|c| if c.is_ascii_alphanumeric() || c == '_' || c == '-' { c } else { '_' }).collect();
    if !s.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_') {
        s.insert(0, 'v');
    }
    s
}

/// The inner content of an SVG document -- everything between the opening `<svg …>`
/// tag and the closing `</svg>`.
fn svg_body(doc: &str) -> String {
    let start = match doc.find("<svg").and_then(|i| doc[i..].find('>').map(|j| i + j + 1)) {
        Some(i) => i,
        None => return String::new(),
    };
    let end = doc.rfind("</svg>").unwrap_or(doc.len());
    if end <= start {
        return String::new();
    }
    doc[start..end].to_string()
}

fn render_frame(s: &Scene) -> Pixmap {
    let mut b = RasterBackend::new(s.w_px, s.h_px, s.bg);
    b.set_bitmap_text(s.want_bitmap_text());
    let _warnings = s.render_to(&mut b);
    b.into_pixmap()
}

/// A `Pixmap`'s straight (demultiplied) RGBA bytes, row-major top-left — the form
/// PNG/APNG encoders expect (tiny-skia stores premultiplied).
fn straight_rgba(pm: &Pixmap) -> Vec<u8> {
    let mut out = Vec::with_capacity((pm.width() as usize) * (pm.height() as usize) * 4);
    for p in pm.pixels() {
        let c = p.demultiply();
        out.push(c.red());
        out.push(c.green());
        out.push(c.blue());
        out.push(c.alpha());
    }
    out
}

// --- streaming encoders -----------------------------------------------------

/// Where rendered frames are written, chosen by `format`. Each variant consumes
/// frames **in order as they are produced**, so peak memory stays bounded by one
/// render chunk rather than all `N` frames.
/// Encoder result: `Ok`, or a human-readable message surfaced to R as an error.
type EncResult<T> = std::result::Result<T, String>;

enum Sink {
    /// One PNG per frame: `<dir>/frame00001.png`, ...
    Frames { dir: String, next: usize },
    /// A single animated PNG at `path`, frames appended to an open writer.
    Apng { writer: png::Writer<BufWriter<File>> },
    /// A single animated GIF at `path`. Each frame is quantised to a local 256
    /// colour palette by the pure-Rust `color_quant` (NeuQuant) — no C library.
    /// `speed` is the NeuQuant sample factor (1 = best quality, 30 = fastest);
    /// `dither` applies Floyd–Steinberg error diffusion to hide the banding a
    /// nearest-colour remap leaves on antialiased/gradient content.
    Gif { encoder: gif::Encoder<BufWriter<File>>, w: u16, h: u16, delay_cs: u16, speed: i32, dither: bool },
}

impl Sink {
    fn consume(&mut self, pm: &Pixmap) -> EncResult<()> {
        match self {
            Sink::Frames { dir, next } => {
                let path = Path::new(dir).join(format!("frame{:05}.png", *next + 1));
                *next += 1;
                pm.save_png(&path)
                    .map_err(|e| format!("failed to write {}: {e}", path.display()))
            }
            Sink::Apng { writer } => writer
                .write_image_data(&straight_rgba(pm))
                .map_err(|e| format!("APNG frame write failed: {e}")),
            Sink::Gif { encoder, w, h, delay_cs, speed, dither } => {
                let mut frame = gif_frame(&straight_rgba(pm), *w, *h, *speed, *dither);
                frame.delay = *delay_cs;
                encoder
                    .write_frame(&frame)
                    .map_err(|e| format!("GIF frame write failed: {e}"))
            }
        }
    }

    fn finish(self) -> EncResult<()> {
        match self {
            Sink::Frames { .. } => Ok(()),
            Sink::Apng { writer } => writer.finish().map_err(|e| format!("APNG finalise failed: {e}")),
            // The gif encoder writes the trailer on drop (raii_no_panic).
            Sink::Gif { .. } => Ok(()),
        }
    }
}

/// Open an APNG writer for `n` frames of `w`x`h`, looping forever, each shown for
/// `delay_num/delay_den` seconds.
fn open_apng(
    path: &str,
    w: u32,
    h: u32,
    n: u32,
    delay_num: u16,
    delay_den: u16,
) -> EncResult<png::Writer<BufWriter<File>>> {
    let file = File::create(path).map_err(|e| format!("cannot create {path}: {e}"))?;
    let mut enc = png::Encoder::new(BufWriter::new(file), w, h);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.set_animated(n, 0).map_err(|e| format!("APNG header failed: {e}"))?;
    enc.set_frame_delay(delay_num, delay_den).map_err(|e| format!("APNG delay failed: {e}"))?;
    enc.write_header().map_err(|e| format!("APNG header write failed: {e}"))
}

/// Encode one straight-RGBA frame to a GIF `Frame`.
///
/// A frame with ≤256 distinct colours (a flat plot) keeps them exactly — no
/// quantisation loss. Otherwise it is reduced to a 256-colour NeuQuant palette at
/// sample factor `speed` (1 = best), then remapped: with `dither`, via
/// Floyd–Steinberg error diffusion (much cleaner on antialiased edges and
/// gradients); without, nearest-colour like the crate default.
fn gif_frame(rgba: &[u8], w: u16, h: u16, speed: i32, dither: bool) -> gif::Frame<'static> {
    let speed = speed.clamp(1, 30);
    // Exact palette when the frame fits in 256 colours (and lossless either way).
    if !dither || fits_256_colours(rgba) {
        let mut buf = rgba.to_vec();
        return gif::Frame::from_rgba_speed(w, h, &mut buf, speed);
    }
    fs_dither_frame(rgba, w, h, speed)
}

/// Whether the straight-RGBA buffer uses at most 256 distinct colours.
fn fits_256_colours(rgba: &[u8]) -> bool {
    let mut seen = HashSet::with_capacity(257);
    for px in rgba.chunks_exact(4) {
        seen.insert([px[0], px[1], px[2], px[3]]);
        if seen.len() > 256 {
            return false;
        }
    }
    true
}

/// NeuQuant palette + Floyd–Steinberg dithered remap of one opaque frame.
fn fs_dither_frame(rgba: &[u8], w: u16, h: u16, speed: i32) -> gif::Frame<'static> {
    let nq = NeuQuant::new(speed, 256, rgba);
    let palette = nq.color_map_rgb(); // 256 RGB triples
    let (wi, hi) = (w as usize, h as usize);

    // Working buffer of RGB with accumulated diffusion error (f32 to avoid
    // truncation as error spreads).
    let mut work: Vec<[f32; 3]> = rgba
        .chunks_exact(4)
        .map(|p| [p[0] as f32, p[1] as f32, p[2] as f32])
        .collect();
    let mut out = vec![0u8; wi * hi];

    for y in 0..hi {
        for x in 0..wi {
            let i = y * wi + x;
            let old = work[i];
            let r = old[0].round().clamp(0.0, 255.0) as u8;
            let g = old[1].round().clamp(0.0, 255.0) as u8;
            let b = old[2].round().clamp(0.0, 255.0) as u8;
            let idx = nq.index_of(&[r, g, b, 255]);
            out[i] = idx as u8;
            let err = [
                old[0] - palette[idx * 3] as f32,
                old[1] - palette[idx * 3 + 1] as f32,
                old[2] - palette[idx * 3 + 2] as f32,
            ];
            let mut diffuse = |xx: usize, yy: usize, f: f32| {
                let j = yy * wi + xx;
                work[j][0] += err[0] * f;
                work[j][1] += err[1] * f;
                work[j][2] += err[2] * f;
            };
            if x + 1 < wi {
                diffuse(x + 1, y, 7.0 / 16.0);
            }
            if y + 1 < hi {
                if x > 0 {
                    diffuse(x - 1, y + 1, 3.0 / 16.0);
                }
                diffuse(x, y + 1, 5.0 / 16.0);
                if x + 1 < wi {
                    diffuse(x + 1, y + 1, 1.0 / 16.0);
                }
            }
        }
    }

    gif::Frame {
        width: w,
        height: h,
        buffer: Cow::Owned(out),
        palette: Some(palette),
        ..Default::default()
    }
}

/// Open a looping GIF encoder for `w`x`h` frames.
fn open_gif(path: &str, w: u16, h: u16) -> EncResult<gif::Encoder<BufWriter<File>>> {
    let file = File::create(path).map_err(|e| format!("cannot create {path}: {e}"))?;
    let mut enc = gif::Encoder::new(BufWriter::new(file), w, h, &[])
        .map_err(|e| format!("GIF header failed: {e}"))?;
    enc.set_repeat(gif::Repeat::Infinite)
        .map_err(|e| format!("GIF repeat failed: {e}"))?;
    Ok(enc)
}

// --- the batch entry point --------------------------------------------------

/// Render a keyframe animation to `path`.
///
/// * `keyframes` — a list of compiled `Scene` external pointers (the `K` states).
/// * `seg` — per frame, the 0-based index of the frame's **left** keyframe (the
///   right one is `seg + 1`).
/// * `frac` — per frame, the eased interpolation fraction in `[0, 1]`, applied to
///   **positional** geometry (and to every discrete `t >= 0.5` snap).
/// * `frac_col`, `frac_size`, `frac_alpha` — the same schedule for the colour,
///   size and opacity classes, each the same length as `frac`. Pass `frac` for
///   all three to ease everything on one curve (the default, and byte-identical
///   to a single-fraction tween); pass a differently-eased vector to have, say,
///   position arrive on a cubic curve while colour crossfades linearly. The
///   alpha schedule also drives the enter/exit fade of keyed elements.
/// * `format` — `"frames"` (a PNG per frame into directory `path`), `"apng"` (a
///   single animated PNG at `path`), or `"gif"` (a looping animated GIF).
/// * `delay_num`/`delay_den` — per-frame delay as a fraction of a second (e.g.
///   `1`/`25` for 25 fps); rounded to centiseconds for GIF.
/// * `gif_speed` — GIF only: NeuQuant palette sample factor, 1 (best) to 30
///   (fastest). Ignored by the other formats.
/// * `gif_dither` — GIF only: apply Floyd–Steinberg dithering.
///
/// * `text_variants`, `text_frame` — per-frame text: a list of compiled scenes
///   holding keyed text nodes, and per frame the 1-based variant whose text
///   replaces the frame's same-keyed text nodes (0 = none). An empty
///   `text_frame` means no per-frame text.
///
/// Returns any renderer degradation warnings (currently none for the raster path).
///
/// @keywords internal
#[extendr]
fn render_animation(
    keyframes: List,
    seg: &[i32],
    frac: &[f64],
    format: &str,
    path: &str,
    delay_num: i32,
    delay_den: i32,
    gif_speed: i32,
    gif_dither: bool,
    frac_col: &[f64],
    frac_size: &[f64],
    frac_alpha: &[f64],
    text_variants: List,
    text_frame: &[i32],
) -> Vec<String> {
    let k = keyframes.len();
    if k < 2 {
        throw_r_error("render_animation() needs at least 2 keyframes");
    }
    if seg.len() != frac.len() {
        throw_r_error("render_animation(): seg and frac must have the same length");
    }
    let n = seg.len();
    if n == 0 {
        throw_r_error("render_animation(): no frames scheduled");
    }
    // The three per-aesthetic schedules are parallel to `frac` (the positional
    // one). The R wrapper defaults each to `frac`, so a single-curve animation
    // sends four identical vectors and every class lerps on the same `t` --
    // byte-identical to the pre-split behaviour.
    for (name, v) in [("frac_col", frac_col), ("frac_size", frac_size), ("frac_alpha", frac_alpha)] {
        if v.len() != n {
            throw_r_error(&format!(
                "render_animation(): {name} must have the same length as frac ({n}), got {}",
                v.len()
            ));
        }
    }
    let frac: Vec<Fracs> = (0..n)
        .map(|i| Fracs { pos: frac[i], col: frac_col[i], size: frac_size[i], alpha: frac_alpha[i] })
        .collect();
    let frac = &frac[..];

    // Per-frame text (empty `text_frame` = none): variant scenes whose keyed
    // text nodes replace the same-keyed nodes of the frames that name them.
    let variant_scenes: Vec<Scene> = text_variants
        .values()
        .map(|robj| {
            let ep = <ExternalPtr<Scene>>::try_from(robj).unwrap_or_else(|_| {
                throw_r_error("render_animation(): text_variants must be compiled vellum scenes")
            });
            (*ep).clone()
        })
        .collect();
    if !text_frame.is_empty() {
        if text_frame.len() != n {
            throw_r_error(&format!(
                "render_animation(): text_frame must have one entry per frame ({n}), got {}",
                text_frame.len()
            ));
        }
        if let Some(&bad) = text_frame.iter().find(|&&v| v < 0 || v as usize > variant_scenes.len()) {
            throw_r_error(&format!(
                "render_animation(): text_frame entry {bad} is not a text variant (0..{})",
                variant_scenes.len()
            ));
        }
    }
    let texts = text_variants_of(&variant_scenes);

    // Own the keyframe scenes (clone out of the external pointers) so the tween
    // can read them freely and they outlive the R call cleanly.
    let kf: Vec<Scene> = keyframes
        .values()
        .map(|robj| {
            let ep = <ExternalPtr<Scene>>::try_from(robj)
                .unwrap_or_else(|_| throw_r_error("render_animation(): keyframes must be compiled vellum scenes"));
            (*ep).clone()
        })
        .collect();

    for (i, &s) in seg.iter().enumerate() {
        // A negative i32 cast to usize wraps to usize::MAX, and `s + 1` back to 0.
        if s < 0 || s as usize + 1 >= k {
            throw_r_error(&format!(
                "render_animation(): frame {i} references keyframe pair ({s},{}) but only {k} keyframes were given",
                s + 1
            ));
        }
    }

    let (w, h) = (kf[0].w_px, kf[0].h_px);
    // Every frame is drawn at its left keyframe's size, but the output is sized
    // from the first: a later keyframe of another size fed the GIF encoder a frame
    // of the wrong length (a panic in the dither and the frame builder).
    if let Some((i, s)) = kf
        .iter()
        .enumerate()
        .find(|(_, s)| (s.w_px, s.h_px) != (w, h))
    {
        throw_r_error(format!(
            "render_animation(): all keyframes must have the same pixel size; keyframe 1 is \
             {w} x {h} px but keyframe {} is {} x {} px",
            i + 1,
            s.w_px,
            s.h_px
        ));
    }
    if format != "svg" {
        // Frames rasterise on worker threads, which must not raise an R error.
        super::ffi::check_raster_area(w, h);
    }

    // Animated SVG takes its own path: it needs the tweened *scenes*, not
    // rasterised pixmaps, so it cannot go through `Sink`.
    if format == "svg" {
        let body = animated_svg(&kf, seg, frac, delay_num, delay_den, &texts, text_frame);
        if let Err(e) = std::fs::write(path, body) {
            throw_r_error(format!("failed to write {path}: {e}"));
        }
        return Vec::new();
    }

    // Sink first, so a bad path fails before any rendering work.
    let mut sink = match format {
        "frames" => {
            std::fs::create_dir_all(path)
                .unwrap_or_else(|e| throw_r_error(&format!("cannot create frame directory {path}: {e}")));
            Sink::Frames { dir: path.to_string(), next: 0 }
        }
        "apng" => {
            let dn = delay_num.clamp(0, u16::MAX as i32) as u16;
            let dd = delay_den.clamp(1, u16::MAX as i32) as u16;
            let writer = open_apng(path, w, h, n as u32, dn, dd).unwrap_or_else(|e| throw_r_error(e));
            Sink::Apng { writer }
        }
        "gif" => {
            if w > u16::MAX as u32 || h > u16::MAX as u32 {
                throw_r_error("render_animation(): GIF dimensions must be <= 65535 px");
            }
            // GIF frame delay is in centiseconds (1/100 s).
            let delay_cs = ((delay_num.max(0) as f64 / delay_den.max(1) as f64) * 100.0)
                .round()
                .clamp(1.0, u16::MAX as f64) as u16;
            let encoder = open_gif(path, w as u16, h as u16).unwrap_or_else(|e| throw_r_error(e));
            Sink::Gif {
                encoder,
                w: w as u16,
                h: h as u16,
                delay_cs,
                speed: gif_speed,
                dither: gif_dither,
            }
        }
        other => throw_r_error(format!(
            "render_animation(): unknown format {other:?} (use \"frames\", \"apng\", \"gif\", or \"svg\")"
        )),
    };

    // Chunk the frames so at most one chunk of pixmaps is resident: tween each
    // chunk's frames (cheap, sequential), rasterize them across cores, then feed
    // the encoder in order. Bounded memory + parallel render + streaming encode.
    let plans = plans_for(&kf, seg);
    let chunk = (rayon::current_num_threads() * 8).max(1);
    for start in (0..n).step_by(chunk) {
        let end = (start + chunk).min(n);
        let scenes: Vec<Scene> = (start..end)
            .map(|frame| {
                let s = seg[frame] as usize;
                let mut sc = tween_scene(&kf[s], &kf[s + 1], plans[s].as_ref(), &frac[frame]);
                if let Some(v) = frame_variant(&texts, text_frame, frame) {
                    patch_text(&mut sc.nodes, v);
                }
                sc
            })
            .collect();
        if let Sink::Gif { encoder, w, h, delay_cs, speed, dither } = &mut sink {
            // A GIF frame's palette quantisation and dither cost far more than
            // its rasterisation (NeuQuant + Floyd-Steinberg over every pixel), so
            // they run on the workers too, each frame independently; only the
            // LZW write stays sequential, in frame order.
            let (w, h, speed, dither) = (*w, *h, *speed, *dither);
            let frames: Vec<gif::Frame<'static>> = scenes
                .into_par_iter()
                .map(|s| gif_frame(&straight_rgba(&render_frame(&s)), w, h, speed, dither))
                .collect();
            for mut frame in frames {
                frame.delay = *delay_cs;
                encoder
                    .write_frame(&frame)
                    .unwrap_or_else(|e| throw_r_error(format!("GIF frame write failed: {e}")));
            }
            continue;
        }
        let pixmaps: Vec<Pixmap> = scenes.into_par_iter().map(|s| render_frame(&s)).collect();
        for pm in &pixmaps {
            sink.consume(pm).unwrap_or_else(|e| throw_r_error(e));
        }
    }
    sink.finish().unwrap_or_else(|e| throw_r_error(e));

    Vec::new()
}

/// How each adjacent keyframe pair will tween, for a caller that wants to warn
/// before rendering. One entry per pair `(i, i + 1)`:
///
/// * `paired` -- the keyframes can be matched (`FALSE`: they do not share a
///   viewport tree, so the frames cut from one to the next at the midpoint);
/// * `nodes_a`, `nodes_b` -- the two node counts;
/// * `snapped` -- for a paired segment, how many nodes (or node pairs) still
///   switch whole at the midpoint: a matched pair whose variant or vertex count
///   differs, or an unkeyed node with no counterpart; `NA` for an unpaired one;
/// * `exited`, `entered` -- keyed elements with no partner, which fade out or
///   in; `NA` for an unpaired segment.
///
/// @keywords internal
#[extendr]
fn tween_pairing(keyframes: List) -> List {
    let kf: Vec<ExternalPtr<Scene>> = keyframes
        .values()
        .map(|robj| {
            <ExternalPtr<Scene>>::try_from(robj).unwrap_or_else(|_| {
                throw_r_error("tween_pairing(): keyframes must be compiled vellum scenes")
            })
        })
        .collect();
    let m = kf.len().saturating_sub(1);
    let (mut paired, mut na, mut nb) = (
        Vec::with_capacity(m),
        Vec::with_capacity(m),
        Vec::with_capacity(m),
    );
    let (mut snapped, mut exited, mut entered) = (
        Vec::with_capacity(m),
        Vec::with_capacity(m),
        Vec::with_capacity(m),
    );
    let na_or = |v: Option<usize>| v.map(|x| Rint::from(x as i32)).unwrap_or(Rint::na());
    for w in kf.windows(2) {
        let (a, b): (&Scene, &Scene) = (&w[0], &w[1]);
        let plan = plan_pair(a, b);
        paired.push(plan.is_some());
        na.push(a.nodes.len() as i32);
        nb.push(b.nodes.len() as i32);
        snapped.push(na_or(plan.as_ref().map(|p| p.snapped)));
        exited.push(na_or(plan.as_ref().map(|p| p.exited)));
        entered.push(na_or(plan.as_ref().map(|p| p.entered)));
    }
    list!(
        paired = paired,
        nodes_a = na,
        nodes_b = nb,
        snapped = Integers::from_values(snapped),
        exited = Integers::from_values(exited),
        entered = Integers::from_values(entered)
    )
}
/// The tweened scene of one frame between keyframes `a` and `b` at fraction
/// `frac` (one curve for every class), for inspecting a mid-transition frame
/// (`$element_table()`, `$pixel()`) without rendering a whole animation.
///
/// @keywords internal
#[extendr]
fn tween_frame(a: Robj, b: Robj, frac: f64) -> Scene {
    let get = |r: Robj| {
        <ExternalPtr<Scene>>::try_from(r).unwrap_or_else(|_| {
            throw_r_error("tween_frame(): keyframes must be compiled vellum scenes")
        })
    };
    let (a, b) = (get(a), get(b));
    let (a, b): (&Scene, &Scene) = (&a, &b);
    let plan = plan_pair(a, b);
    let fr = Fracs {
        pos: frac,
        col: frac,
        size: frac,
        alpha: frac,
    };
    tween_scene(a, b, plan.as_ref(), &fr)
}
extendr_module! {
    mod tween;
    fn render_animation;
    fn tween_pairing;
    fn tween_frame;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fr(pos: f64) -> Fracs {
        Fracs { pos, col: pos, size: pos, alpha: pos }
    }

    fn gp(alpha: f64, lwd: f64) -> PartialGpar {
        PartialGpar {
            fill: Inh::Inherit,
            col: Inh::Inherit,
            lwd: Inh::Set(lwd),
            alpha: Inh::Set(alpha),
            lty: Inh::Inherit,
            lineend: Inh::Inherit,
            linejoin: Inh::Inherit,
            linemitre: Inh::Inherit,
            antialias: Inh::Inherit,
            crisp: Inh::Inherit,
            col_paint: Inh::Inherit,
            dash_phase: Inh::Inherit,
        }
    }

    #[test]
    fn overshoot_clamps_size_and_alpha() {
        // back-in-out dips below 0 and elastic rises above 1.
        assert_eq!(lerp_size(1.0, 5.0, -0.5), 0.0);
        assert_eq!(lerp_vec_size(&[1.0, 2.0], &[3.0, 6.0], -1.0), vec![0.0, 0.0]);
        let (a, b) = (gp(0.2, 1.0), gp(1.0, 4.0));
        let g = lerp_gpar(&a, &b, &fr(1.3));
        assert!(matches!(g.alpha, Inh::Set(x) if x == 1.0));
        let g = lerp_gpar(&a, &b, &fr(-0.6));
        assert!(matches!(g.alpha, Inh::Set(x) if x == 0.0));
        assert!(matches!(g.lwd, Inh::Set(x) if x == 0.0));
        assert!(matches!(fade_gp(&b, 1.4).alpha, Inh::Set(x) if x == 1.0));
        assert!(matches!(fade_gp(&b, -0.2).alpha, Inh::Set(x) if x == 0.0));
    }

    #[test]
    fn still_frame_holds_the_final_keyframe_only_when_reached() {
        // A non-looping schedule over 3 keyframes that ends at (seg 1, frac 1).
        let seg = [0, 0, 1, 1];
        assert_eq!(still_frame(3, &seg, &[fr(0.0), fr(0.5), fr(0.5), fr(1.0)]), 3);
        // A loop stops short of its end: hold the first frame.
        assert_eq!(still_frame(3, &seg, &[fr(0.0), fr(0.5), fr(0.0), fr(0.5)]), 0);
        // Ending on an earlier keyframe pair is not the end either.
        assert_eq!(still_frame(4, &seg, &[fr(0.0), fr(0.5), fr(0.5), fr(1.0)]), 0);
    }

    fn text_node(label: &str, key: Option<&str>, x: f64, w: f64) -> Node {
        use crate::units::Unit;
        Node::Text {
            x,
            y: 0.5,
            xu: Unit::from_code_off(0, 0.0),
            yu: Unit::from_code_off(0, 0.0),
            rot: 0.0,
            hjust: 0.0,
            vjust: 0.5,
            w,
            h: 10.0,
            gid: vec![1; label.len()],
            gx: (0..label.len()).map(|i| i as f64).collect(),
            gy: vec![0.0; label.len()],
            gsize: vec![12.0; label.len()],
            gpath: vec![String::new(); label.len()],
            gface: vec![0; label.len()],
            gcol: Vec::new(),
            halo: None,
            label: label.to_string(),
            family: "sans".to_string(),
            face: "plain".to_string(),
            size: 12.0,
            tpath: None,
            key: key.map(|k| k.to_string()),
            gp: gp(1.0, 1.0),
        }
    }

    #[test]
    fn patch_text_swaps_the_string_but_keeps_the_tweened_position() {
        let mut nodes = vec![
            (0, text_node("1952", Some("vp:title"), 0.3, 40.0)),
            (0, text_node("axis", None, 0.1, 30.0)),
        ];
        let mut v = TextVariant::new();
        v.insert("vp:title".to_string(), text_node("1954.5", Some("vp:title"), 0.9, 60.0));
        patch_text(&mut nodes, &v);
        match &nodes[0].1 {
            Node::Text { label, x, w, gid, .. } => {
                assert_eq!(label, "1954.5");
                assert_eq!(*x, 0.3); // position from the tween, not the variant
                assert_eq!(*w, 60.0); // extent from the variant's layout
                assert_eq!(gid.len(), 6);
            }
            _ => unreachable!(),
        }
        match &nodes[1].1 {
            Node::Text { label, .. } => assert_eq!(label, "axis"), // unkeyed: untouched
            _ => unreachable!(),
        }
        assert!(frame_variant(&[v], &[0, 1], 0).is_none());
    }

    #[test]
    fn hoist_defs_shares_identical_definitions_across_frames() {
        let t = crate::render::ID_TOKEN;
        let frame = |f: usize, stop: &str| {
            format!(
                "<defs><clipPath id=\"{t}-f{f}-c0\"><path d=\"M0 0\"/></clipPath>\
                 <clipPath id=\"{t}-f{f}-c1\" clip-path=\"url(#{t}-f{f}-c0)\"><path d=\"M1 1\"/></clipPath>\
                 <linearGradient id=\"{t}-f{f}-g0\"><stop offset=\"{stop}\"/></linearGradient></defs>\
                 <rect clip-path=\"url(#{t}-f{f}-c1)\" fill=\"url(#{t}-f{f}-g0)\"/>"
            )
        };
        let mut sh = SharedDefs::default();
        let b0 = hoist_defs(frame(0, "0"), &format!("{t}-f0-"), &mut sh);
        let b1 = hoist_defs(frame(1, "0"), &format!("{t}-f1-"), &mut sh);
        let b2 = hoist_defs(frame(2, "1"), &format!("{t}-f2-"), &mut sh);
        // No frame keeps a <defs>; frame 1 reuses all of frame 0's (the nested
        // clip matches once its parent reference is remapped), frame 2 only the
        // clips, its gradient differs.
        assert!(!b0.contains("<defs>") && !b1.contains("<defs>") && !b2.contains("<defs>"));
        assert_eq!(b1, b0);
        assert!(b2.contains(&format!("url(#{t}-f0-c1)")));
        assert!(b2.contains(&format!("url(#{t}-f2-g0)")));
        assert_eq!(sh.defs.matches("<clipPath").count(), 2);
        assert_eq!(sh.defs.matches("<linearGradient").count(), 2);
        // A body with no defs, or defs that do not split, is left alone.
        let raw = "<rect/>".to_string();
        assert_eq!(hoist_defs(raw.clone(), "x", &mut sh), raw);
        let odd = format!("<defs>text<a/></defs><rect/>");
        assert_eq!(hoist_defs(odd.clone(), "x", &mut sh), odd);
    }

    #[test]
    fn split_elements_and_remap_urls() {
        assert_eq!(
            split_elements("<a x=\"1\"><b/></a><c/> <d></d>").unwrap(),
            vec!["<a x=\"1\"><b/></a>", "<c/>", "<d></d>"]
        );
        assert!(split_elements("<a>").is_none());
        let m: HashMap<String, String> = [("p1".to_string(), "p0".to_string())].into();
        let got = remap_urls("url(#p1) url(#p10) url(#p1", &m);
        assert_eq!(got, "url(#p0) url(#p10) url(#p1");
    }

    #[test]
    fn css_ident_is_always_a_valid_identifier() {
        assert_eq!(css_ident("vl0a1b2c3d"), "vl0a1b2c3d");
        assert_eq!(css_ident("my fig.1"), "my_fig_1");
        assert_eq!(css_ident("1st"), "v1st");
        assert_eq!(css_ident("-x"), "v-x");
    }
}
