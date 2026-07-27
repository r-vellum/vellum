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

use std::cell::RefCell;
use std::fs::File;
use std::io::BufWriter;
use std::path::Path;

use extendr_api::prelude::*;
use rayon::prelude::*;
use tiny_skia::Pixmap;

use super::{Node, Scene};
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
            Node::RoundRect { x: ax, y: ay, w: aw, h: ah, r: ar, xu, yu, wu, hu, ru, sketch, gp: agp },
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
            Node::Segments { x0: ax0, y0: ay0, x1: ax1, y1: ay1, x0u, y0u, x1u, y1u, scap, ecap, scapu, ecapu, off, offu, arrow, sketch, gp: agp, keys },
            Node::Segments { x0: bx0, y0: by0, x1: bx1, y1: by1, gp: bgp, .. },
        ) => Node::Segments {
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
            Node::Text { x: ax, y: ay, xu, yu, rot: arot, hjust, vjust, w, h, gid, gx, gy, gsize, gpath, gface, gcol, label, family, face, size, gp: agp },
            Node::Text { x: bx, y: by, rot: brot, gp: bgp, .. },
        ) => Node::Text {
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

// --- per-frame scene assembly + render --------------------------------------

/// Build the tweened scene for one frame: clone keyframe `a`'s structure
/// (viewports, masks, meta — identical across keyframes under frozen scales) and
/// replace its nodes with the interpolated ones. A different node count between
/// keyframes (a structural change, out of P1 scope) falls back to `a`'s nodes.
fn tween_scene(a: &Scene, b: &Scene, t: f64) -> Scene {
    let nodes = if a.nodes.len() == b.nodes.len() {
        a.nodes
            .iter()
            .zip(b.nodes.iter())
            .map(|((vp, na), (_, nb))| (*vp, lerp_node(na, nb, t)))
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
        masks: a.masks.clone(),
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
    Gif { encoder: gif::Encoder<BufWriter<File>>, w: u16, h: u16, delay_cs: u16 },
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
            Sink::Gif { encoder, w, h, delay_cs } => {
                let mut rgba = straight_rgba(pm);
                let mut frame = gif::Frame::from_rgba_speed(*w, *h, &mut rgba, 10);
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
///
/// Returns any renderer degradation warnings (currently none for the raster path).
#[extendr]
fn render_animation(
    keyframes: List,
    seg: &[i32],
    frac: &[f64],
    format: &str,
    path: &str,
    delay_num: i32,
    delay_den: i32,
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

    // Sink first, so a bad path fails before any rendering work.
    let (w, h) = (kf[0].w_px, kf[0].h_px);
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
            Sink::Gif { encoder, w: w as u16, h: h as u16, delay_cs }
        }
        other => throw_r_error(format!(
            "render_animation(): unknown format {other:?} (use \"frames\", \"apng\", or \"gif\")"
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
