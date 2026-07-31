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
//! The interpolation is the byte-for-byte specification the pure-R oracle
//! (`R/tween-oracle.R`) pins down: unit geometry lerps its resolved value on a
//! matching base code (mismatched bases and vertex counts snap here — the clean,
//! frozen-scale P1 scope keeps them matched); colours lerp in Oklab (reusing
//! `oklab.rs`); bounded gpar numerics lerp; discrete fields snap at `t >= 0.5`.

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
fn lerp_gpar(a: &PartialGpar, b: &PartialGpar, t: f64) -> PartialGpar {
    let base = snap(a, b, t);
    PartialGpar {
        fill: lerp_paint_inh(&a.fill, &b.fill, t),
        col: lerp_col_inh(&a.col, &b.col, t),
        lwd: lerp_f64_inh(&a.lwd, &b.lwd, t),
        alpha: lerp_f64_inh(&a.alpha, &b.alpha, t),
        linemitre: lerp_f64_inh(&a.linemitre, &b.linemitre, t),
        lty: base.lty.clone(),
        lineend: base.lineend,
        linejoin: base.linejoin,
        // Discrete render-quality flags: snap with the near side like lty.
        antialias: base.antialias,
        crisp: base.crisp,
        // A stroke paint interpolates like a fill paint; the dash phase is a
        // continuous quantity, so it tweens (which is what animates marching ants).
        col_paint: lerp_paint_inh(&a.col_paint, &b.col_paint, t),
        dash_phase: lerp_f64_inh(&a.dash_phase, &b.dash_phase, t),
    }
}

// --- node interpolation -----------------------------------------------------

/// Interpolate one node against its counterpart in the other keyframe. Unit
/// vectors and discrete fields are carried from `a` (identical across keyframes
/// under the frozen-scale, stable-element-set scope); geometry values, per-element
/// colours, and gpar interpolate. Structural nodes and any variant mismatch snap.
fn lerp_node(a: &Node, b: &Node, t: f64) -> Node {
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
            gp: lerp_gpar(agp, bgp, t),
        },
        (
            Node::RoundRect { x: ax, y: ay, w: aw, h: ah, r: ar, xu, yu, wu, hu, ru, sketch, key, gp: agp },
            Node::RoundRect { x: bx, y: by, w: bw, h: bh, r: br, gp: bgp, .. },
        ) => Node::RoundRect {
            x: lerp(*ax, *bx, t),
            y: lerp(*ay, *by, t),
            w: lerp(*aw, *bw, t),
            h: lerp(*ah, *bh, t),
            r: lerp(*ar, *br, t),
            xu: *xu,
            yu: *yu,
            wu: *wu,
            hu: *hu,
            ru: *ru,
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, t),
            key: key.clone(),
        },
        (
            Node::Circle { x: ax, y: ay, r: ar, xu, yu, ru, sketch, gp: agp },
            Node::Circle { x: bx, y: by, r: br, gp: bgp, .. },
        ) => Node::Circle {
            x: lerp(*ax, *bx, t),
            y: lerp(*ay, *by, t),
            r: lerp(*ar, *br, t),
            xu: *xu,
            yu: *yu,
            ru: *ru,
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, t),
        },
        (
            Node::Lines { x: ax, y: ay, xu, yu, scap, ecap, off, arrow, sketch, gp: agp, key },
            Node::Lines { x: bx, y: by, .. },
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
            gp: lerp_gpar(agp, snap_node_gp(b, agp), t),
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
            gp: lerp_gpar(agp, bgp, t),
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
            gp: lerp_gpar(agp, bgp, t),
            keys: keys.clone(),
        },
        (
            Node::Circles { x: ax, y: ay, r: ar, xu, yu, ru, sketch, gp: agp, keys },
            Node::Circles { x: bx, y: by, r: br, gp: bgp, .. },
        ) => Node::Circles {
            x: lerp_vec(ax, bx, t),
            y: lerp_vec(ay, by, t),
            r: lerp_vec(ar, br, t),
            xu: xu.clone(),
            yu: yu.clone(),
            ru: ru.clone(),
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, t),
            keys: keys.clone(),
        },
        (
            Node::Markers { x: ax, y: ay, size: asz, xu, yu, su, shape, sketch, gp: agp, keys },
            Node::Markers { x: bx, y: by, size: bsz, gp: bgp, .. },
        ) => Node::Markers {
            x: lerp_vec(ax, bx, t),
            y: lerp_vec(ay, by, t),
            size: lerp_vec(asz, bsz, t),
            xu: xu.clone(),
            yu: yu.clone(),
            su: su.clone(),
            shape: shape.clone(),
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, t),
            keys: keys.clone(),
        },
        (
            Node::Hexagons { x: ax, y: ay, size: asz, w: aw, h: ah, xu, yu, su, wu, hu, fill: afill, flat, gp: agp, keys },
            Node::Hexagons { x: bx, y: by, size: bsz, w: bw, h: bh, fill: bfill, gp: bgp, .. },
        ) => Node::Hexagons {
            x: lerp_vec(ax, bx, t),
            y: lerp_vec(ay, by, t),
            size: lerp_vec(asz, bsz, t),
            w: lerp_vec(aw, bw, t),
            h: lerp_vec(ah, bh, t),
            xu: xu.clone(),
            yu: yu.clone(),
            su: su.clone(),
            wu: wu.clone(),
            hu: hu.clone(),
            fill: lerp_rgba_vec(afill, bfill, t),
            flat: *flat,
            gp: lerp_gpar(agp, bgp, t),
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
            fill: lerp_rgba_vec(afill, bfill, t),
            arrow: arrow.clone(),
            sketch: sketch.clone(),
            gp: lerp_gpar(agp, bgp, t),
            keys: keys.clone(),
        },
        (
            Node::Segments { x0: ax0, y0: ay0, x1: ax1, y1: ay1, x0u, y0u, x1u, y1u, scap, ecap, scapu, ecapu, off, offu, arrow, sketch, gp: agp, keys, cols, lwds },
            Node::Segments { x0: bx0, y0: by0, x1: bx1, y1: by1, gp: bgp, .. },
        ) => Node::Segments {
            // Per-element stroke style is discrete data, not a continuous
            // quantity: snap to the left keyframe like keys and sketch.
            cols: cols.clone(),
            lwds: lwds.clone(),
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
            gp: lerp_gpar(agp, bgp, t),
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
            size: lerp_vec(asz, bsz, t),
            su: su.clone(),
            foot: lerp_vec(af, bf, t),
            fu: fu.clone(),
            angle: lerp_vec(aang, bang, t),
            width: lerp_vec(aw, bw, t),
            arrow: arrow.clone(),
            gp: lerp_gpar(agp, bgp, t),
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
            gp: lerp_gpar(agp, bgp, t),
            key: key.clone(),
        },
        (
            Node::Text { x: ax, y: ay, xu, yu, rot: arot, hjust, vjust, w, h, gid, gx, gy, gsize, gpath, gface, gcol, halo, label, family, face, size, tpath, key, gp: agp },
            Node::Text { x: bx, y: by, rot: brot, gp: bgp, .. },
        ) => Node::Text {
            // Halo is a discrete style, not a continuous quantity: snap to
            // the left keyframe's, like the label and font.
            halo: *halo,
            // Position and rotation tween; glyph layout / string snap (a changed
            // label or reflow is a hard case, not a continuous morph).
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
            // A baseline path is layout, not a continuous quantity: snap to the
            // left keyframe's like the glyphs it positions.
            tpath: tpath.clone(),
            key: key.clone(),
            gp: lerp_gpar(agp, bgp, t),
        },
        // Structural nodes (image/group/subraster/panel) and any variant mismatch
        // carry through unchanged from the near side.
        _ => snap(a, b, t).clone(),
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
    g.alpha = Inh::Set(base * factor);
    g
}

/// A per-element join between two keyed batches: `matched` are `(a_index,
/// b_index)` pairs present in both (in A's order), `a_only` exit, `b_only` enter.
struct KeyMatch {
    matched: Vec<(usize, usize)>,
    a_only: Vec<usize>,
    b_only: Vec<usize>,
}

/// Join two element-key vectors by value. Returns `None` (caller falls back to a
/// plain element-wise tween) when either side is unkeyed — so the stable-element
/// path is unchanged — or when the two are already identical (no enter/exit, no
/// reorder), so the common case skips the map entirely. A blank key never matches.
fn match_keys(ka: &[String], kb: &[String]) -> Option<KeyMatch> {
    if ka.is_empty() || kb.is_empty() || ka == kb {
        return None;
    }
    let mut bmap: HashMap<&str, usize> = HashMap::with_capacity(kb.len());
    for (j, k) in kb.iter().enumerate() {
        if !k.is_empty() {
            bmap.entry(k.as_str()).or_insert(j);
        }
    }
    let mut matched = Vec::new();
    let mut a_only = Vec::new();
    let mut used = vec![false; kb.len()];
    for (i, k) in ka.iter().enumerate() {
        match (!k.is_empty()).then(|| bmap.get(k.as_str())).flatten() {
            Some(&j) if !used[j] => {
                matched.push((i, j));
                used[j] = true;
            }
            _ => a_only.push(i),
        }
    }
    let b_only = (0..kb.len()).filter(|&j| !used[j]).collect();
    Some(KeyMatch { matched, a_only, b_only })
}

#[inline]
fn gather<T: Clone>(v: &[T], idx: &[usize]) -> Vec<T> {
    idx.iter().map(|&i| v[i].clone()).collect()
}

/// Tween one node pair, splitting a keyed batch into matched (tweened),
/// exiting (faded out), and entering (faded in) sub-batches. Non-batched or
/// unkeyed nodes fall through to the single-node tween.
fn tween_node_multi(a: &Node, b: &Node, t: f64) -> Vec<Node> {
    match (a, b) {
        (Node::Markers { .. }, Node::Markers { .. }) => ee_markers(a, b, t),
        (Node::Circles { .. }, Node::Circles { .. }) => ee_circles(a, b, t),
        (Node::Rects { .. }, Node::Rects { .. }) => ee_rects(a, b, t),
        _ => vec![lerp_node(a, b, t)],
    }
}

fn ee_markers(a: &Node, b: &Node, t: f64) -> Vec<Node> {
    let (
        Node::Markers { x: xa, y: ya, size: sa, xu, yu, su, shape: sha, sketch, keys: ka, gp: gpa },
        Node::Markers { x: xb, y: yb, size: sb, xu: xub, yu: yub, su: sub, shape: shb, keys: kb, gp: gpb, .. },
    ) = (a, b)
    else {
        return vec![lerp_node(a, b, t)];
    };
    let Some(m) = match_keys(ka, kb) else { return vec![lerp_node(a, b, t)] };
    let mut out = Vec::new();
    if !m.matched.is_empty() {
        let ia: Vec<usize> = m.matched.iter().map(|p| p.0).collect();
        out.push(Node::Markers {
            x: m.matched.iter().map(|(i, j)| lerp(xa[*i], xb[*j], t)).collect(),
            y: m.matched.iter().map(|(i, j)| lerp(ya[*i], yb[*j], t)).collect(),
            size: m.matched.iter().map(|(i, j)| lerp(sa[*i], sb[*j], t)).collect(),
            xu: gather(xu, &ia),
            yu: gather(yu, &ia),
            su: gather(su, &ia),
            shape: gather(sha, &ia),
            sketch: sketch.clone(),
            gp: lerp_gpar(gpa, gpb, t),
            keys: gather(ka, &ia),
        });
    }
    if !m.a_only.is_empty() {
        out.push(Node::Markers {
            x: gather(xa, &m.a_only),
            y: gather(ya, &m.a_only),
            size: gather(sa, &m.a_only),
            xu: gather(xu, &m.a_only),
            yu: gather(yu, &m.a_only),
            su: gather(su, &m.a_only),
            shape: gather(sha, &m.a_only),
            sketch: sketch.clone(),
            gp: fade_gp(gpa, 1.0 - t),
            keys: gather(ka, &m.a_only),
        });
    }
    if !m.b_only.is_empty() {
        out.push(Node::Markers {
            x: gather(xb, &m.b_only),
            y: gather(yb, &m.b_only),
            size: gather(sb, &m.b_only),
            xu: gather(xub, &m.b_only),
            yu: gather(yub, &m.b_only),
            su: gather(sub, &m.b_only),
            shape: gather(shb, &m.b_only),
            sketch: sketch.clone(),
            gp: fade_gp(gpb, t),
            keys: gather(kb, &m.b_only),
        });
    }
    out
}

fn ee_circles(a: &Node, b: &Node, t: f64) -> Vec<Node> {
    let (
        Node::Circles { x: xa, y: ya, r: ra, xu, yu, ru, sketch, keys: ka, gp: gpa },
        Node::Circles { x: xb, y: yb, r: rb, xu: xub, yu: yub, ru: rub, keys: kb, gp: gpb, .. },
    ) = (a, b)
    else {
        return vec![lerp_node(a, b, t)];
    };
    let Some(m) = match_keys(ka, kb) else { return vec![lerp_node(a, b, t)] };
    let mut out = Vec::new();
    if !m.matched.is_empty() {
        let ia: Vec<usize> = m.matched.iter().map(|p| p.0).collect();
        out.push(Node::Circles {
            x: m.matched.iter().map(|(i, j)| lerp(xa[*i], xb[*j], t)).collect(),
            y: m.matched.iter().map(|(i, j)| lerp(ya[*i], yb[*j], t)).collect(),
            r: m.matched.iter().map(|(i, j)| lerp(ra[*i], rb[*j], t)).collect(),
            xu: gather(xu, &ia),
            yu: gather(yu, &ia),
            ru: gather(ru, &ia),
            sketch: sketch.clone(),
            gp: lerp_gpar(gpa, gpb, t),
            keys: gather(ka, &ia),
        });
    }
    if !m.a_only.is_empty() {
        out.push(Node::Circles {
            x: gather(xa, &m.a_only),
            y: gather(ya, &m.a_only),
            r: gather(ra, &m.a_only),
            xu: gather(xu, &m.a_only),
            yu: gather(yu, &m.a_only),
            ru: gather(ru, &m.a_only),
            sketch: sketch.clone(),
            gp: fade_gp(gpa, 1.0 - t),
            keys: gather(ka, &m.a_only),
        });
    }
    if !m.b_only.is_empty() {
        out.push(Node::Circles {
            x: gather(xb, &m.b_only),
            y: gather(yb, &m.b_only),
            r: gather(rb, &m.b_only),
            xu: gather(xub, &m.b_only),
            yu: gather(yub, &m.b_only),
            ru: gather(rub, &m.b_only),
            sketch: sketch.clone(),
            gp: fade_gp(gpb, t),
            keys: gather(kb, &m.b_only),
        });
    }
    out
}

fn ee_rects(a: &Node, b: &Node, t: f64) -> Vec<Node> {
    let (
        Node::Rects { x: xa, y: ya, w: wa, h: ha, xu, yu, wu, hu, sketch, keys: ka, gp: gpa },
        Node::Rects { x: xb, y: yb, w: wb, h: hb, xu: xub, yu: yub, wu: wub, hu: hub, keys: kb, gp: gpb, .. },
    ) = (a, b)
    else {
        return vec![lerp_node(a, b, t)];
    };
    let Some(m) = match_keys(ka, kb) else { return vec![lerp_node(a, b, t)] };
    let mut out = Vec::new();
    if !m.matched.is_empty() {
        let ia: Vec<usize> = m.matched.iter().map(|p| p.0).collect();
        out.push(Node::Rects {
            x: m.matched.iter().map(|(i, j)| lerp(xa[*i], xb[*j], t)).collect(),
            y: m.matched.iter().map(|(i, j)| lerp(ya[*i], yb[*j], t)).collect(),
            w: m.matched.iter().map(|(i, j)| lerp(wa[*i], wb[*j], t)).collect(),
            h: m.matched.iter().map(|(i, j)| lerp(ha[*i], hb[*j], t)).collect(),
            xu: gather(xu, &ia),
            yu: gather(yu, &ia),
            wu: gather(wu, &ia),
            hu: gather(hu, &ia),
            sketch: sketch.clone(),
            gp: lerp_gpar(gpa, gpb, t),
            keys: gather(ka, &ia),
        });
    }
    if !m.a_only.is_empty() {
        out.push(Node::Rects {
            x: gather(xa, &m.a_only),
            y: gather(ya, &m.a_only),
            w: gather(wa, &m.a_only),
            h: gather(ha, &m.a_only),
            xu: gather(xu, &m.a_only),
            yu: gather(yu, &m.a_only),
            wu: gather(wu, &m.a_only),
            hu: gather(hu, &m.a_only),
            sketch: sketch.clone(),
            gp: fade_gp(gpa, 1.0 - t),
            keys: gather(ka, &m.a_only),
        });
    }
    if !m.b_only.is_empty() {
        out.push(Node::Rects {
            x: gather(xb, &m.b_only),
            y: gather(yb, &m.b_only),
            w: gather(wb, &m.b_only),
            h: gather(hb, &m.b_only),
            xu: gather(xub, &m.b_only),
            yu: gather(yub, &m.b_only),
            wu: gather(wub, &m.b_only),
            hu: gather(hub, &m.b_only),
            sketch: sketch.clone(),
            gp: fade_gp(gpb, t),
            keys: gather(kb, &m.b_only),
        });
    }
    out
}

// --- per-frame scene assembly + render --------------------------------------

/// Tween the viewport masks between keyframes. Masks are the clip/reveal
/// geometry attached to a viewport; interpolating them lets a `transition_reveal`
/// grow a clip rectangle so the plot wipes into view. Structurally parallel masks
/// (same count, same node counts) tween element-wise; anything else keeps `a`'s.
fn tween_masks(a: &[MaskDef], b: &[MaskDef], t: f64) -> Vec<MaskDef> {
    if a.len() != b.len() {
        return a.to_vec();
    }
    a.iter()
        .zip(b.iter())
        .map(|(ma, mb)| {
            let nodes = if ma.nodes.len() == mb.nodes.len() {
                ma.nodes
                    .iter()
                    .zip(mb.nodes.iter())
                    .map(|((vp, na), (_, nb))| (*vp, lerp_node(na, nb, t)))
                    .collect()
            } else {
                ma.nodes.clone()
            };
            MaskDef { kind: ma.kind.clone(), nodes }
        })
        .collect()
}

/// Build the tweened scene for one frame: clone keyframe `a`'s structure
/// (viewports, masks, meta — identical across keyframes under frozen scales) and
/// replace its nodes with the interpolated ones. A different node count between
/// keyframes (a structural change, out of P1 scope) falls back to `a`'s nodes.
fn tween_scene(a: &Scene, b: &Scene, t: f64) -> Scene {
    let nodes = if a.nodes.len() == b.nodes.len() {
        a.nodes
            .iter()
            .zip(b.nodes.iter())
            .flat_map(|((vp, na), (_, nb))| {
                tween_node_multi(na, nb, t).into_iter().map(move |n| (*vp, n))
            })
            .collect()
    } else {
        a.nodes.clone()
    };
    Scene {
        w_px: a.w_px,
        h_px: a.h_px,
        dpi: a.dpi,
        bg: a.bg,
        viewports: a.viewports.clone(),
        current: a.current,
        nodes,
        masks: tween_masks(&a.masks, &b.masks, t),
        mask_target: a.mask_target.clone(),
        picks: a.picks.clone(),
        cur_pick: a.cur_pick,
        meta: a.meta.clone(),
        cur_meta: a.cur_meta.clone(),
        raster_cache: RefCell::new(None),
        text_glyphs: a.text_glyphs,
        a11y_title: a.a11y_title.clone(),
        a11y_desc: a.a11y_desc.clone(),
        a11y_prefix: a.a11y_prefix.clone(),
    }
}

/// Rasterize a scene to a fresh `Pixmap` (never touches the `raster_cache`, so it
/// is safe to run on many owned scenes across `rayon` workers).
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
fn animated_svg(kf: &[Scene], seg: &[i32], frac: &[f64], delay_num: i32, delay_den: i32) -> String {
    let n = seg.len();
    let dur = (delay_num.max(0) as f64 / delay_den.max(1) as f64) * n as f64;
    let (w, h) = (kf[0].w_px, kf[0].h_px);

    // Sequential, unlike the raster path: the SVG backend holds a non-`Send`
    // glyph-outline cache. It is also much the cheaper of the two -- emitting
    // markup rather than rasterising -- so there is little to win here.
    let bodies: Vec<String> = (0..n)
        .map(|frame| {
            let s = seg[frame] as usize;
            let mut sc = tween_scene(&kf[s], &kf[s + 1], frac[frame]);
            // The title/desc belong to the document, not to each of its frames:
            // repeating them would have a screen reader announce the figure once
            // per frame.
            sc.clear_a11y();
            svg_body(&sc.svg_string(false))
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
    let pct = 100.0 / n as f64;
    out.push_str(&format!(
        "<style>\
         .vf{{visibility:hidden;animation:vfcycle {dur}s steps(1,end) infinite}}\
         @keyframes vfcycle{{0%{{visibility:visible}}{pct:.6}%{{visibility:hidden}}}}\
         @media (prefers-reduced-motion:reduce){{.vf{{animation:none}}.vf:first-of-type{{visibility:visible}}}}\
         </style>"
    ));
    for (i, body) in bodies.iter().enumerate() {
        // A negative delay starts each frame that far into the cycle.
        let delay = -(i as f64) * dur / n as f64;
        out.push_str(&format!("<g class=\"vf\" style=\"animation-delay:{delay:.4}s\">{body}</g>"));
    }
    out.push_str("</svg>");
    out
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
/// * `frac` — per frame, the eased interpolation fraction in `[0, 1]`.
/// * `format` — `"frames"` (a PNG per frame into directory `path`), `"apng"` (a
///   single animated PNG at `path`), or `"gif"` (a looping animated GIF).
/// * `delay_num`/`delay_den` — per-frame delay as a fraction of a second (e.g.
///   `1`/`25` for 25 fps); rounded to centiseconds for GIF.
/// * `gif_speed` — GIF only: NeuQuant palette sample factor, 1 (best) to 30
///   (fastest). Ignored by the other formats.
/// * `gif_dither` — GIF only: apply Floyd–Steinberg dithering.
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
        let s = s as usize;
        if s + 1 >= k {
            throw_r_error(&format!(
                "render_animation(): frame {i} references keyframe pair ({s},{}) but only {k} keyframes were given",
                s + 1
            ));
        }
    }

    let (w, h) = (kf[0].w_px, kf[0].h_px);

    // Animated SVG takes its own path: it needs the tweened *scenes*, not
    // rasterised pixmaps, so it cannot go through `Sink`.
    if format == "svg" {
        let body = animated_svg(&kf, seg, frac, delay_num, delay_den);
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
    let chunk = (rayon::current_num_threads() * 8).max(1);
    for start in (0..n).step_by(chunk) {
        let end = (start + chunk).min(n);
        let scenes: Vec<Scene> = (start..end)
            .map(|frame| {
                let s = seg[frame] as usize;
                tween_scene(&kf[s], &kf[s + 1], frac[frame])
            })
            .collect();
        let pixmaps: Vec<Pixmap> = scenes.into_par_iter().map(|s| render_frame(&s)).collect();
        for pm in &pixmaps {
            sink.consume(pm).unwrap_or_else(|e| throw_r_error(e));
        }
    }
    sink.finish().unwrap_or_else(|e| throw_r_error(e));

    Vec::new()
}

extendr_module! {
    mod tween;
    fn render_animation;
}
