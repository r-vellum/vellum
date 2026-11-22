//! One `draw_*` function per drawable [`Node`] variant, called from the
//! render walk in `draw.rs` with the node's resolved gpar, viewport, transform
//! and clip already in hand. Each draws through the [`RenderBackend`], so a
//! mark is drawn the same way for raster, SVG, PDF and the geometry recorder.

use super::*;

/// Draw a [`Node::Rect`].
pub(super) fn draw_rect<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Rect {
        x,
        y,
        w,
        h,
        xu,
        yu,
        wu,
        hu,
        ..
    } = node
    else {
        unreachable!("draw_rect called on another node kind")
    };
    let cx = vp.x_pos(*x, *xu);
    let cy = vp.y_pos(*y, *yu);
    let pw = vp.x_extent(*w, *wu);
    let ph = vp.y_extent(*h, *hu);
    if let Some(g) = b.geom_sink() {
        g.rect(0, cx - pw / 2.0, cy - ph / 2.0, pw, ph);
    }
    if let Some(path) = rect_path(cx - pw / 2.0, cy - ph / 2.0, pw, ph) {
        fill_then_stroke(b, &path, gp, t, clip, vp, FillRule::Winding);
    }
}

/// Draw a [`Node::RoundRect`].
pub(super) fn draw_round_rect<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::RoundRect {
        x,
        y,
        w,
        h,
        r,
        xu,
        yu,
        wu,
        hu,
        ru,
        sketch,
        key,
        ..
    } = node
    else {
        unreachable!("draw_round_rect called on another node kind")
    };
    b.set_element_key(key.as_deref());
    let cx = vp.x_pos(*x, *xu);
    let cy = vp.y_pos(*y, *yu);
    let pw = vp.x_extent(*w, *wu);
    let ph = vp.y_extent(*h, *hu);
    let pr = vp.r_len(*r, *ru); // isotropic radius (npc -> min side)
    if let Some(g) = b.geom_sink() {
        // The crisp outline, also for a sketched one: the wobble
        // is decoration, not where the mark is.
        g.ring(0, &roundrect_ring(cx - pw / 2.0, cy - ph / 2.0, pw, ph, pr));
    }
    if let Some(sk) = sketch {
        let ring = roundrect_ring(cx - pw / 2.0, cy - ph / 2.0, pw, ph, pr);
        let o = resolve_sketch(sk, gp, vp.dpi);
        let s = crate::sketch::closed_curve(&ring, &o, gp.fill.is_some());
        paint_sketch(b, &s, gp, t, clip, vp, o.fill_weight);
    } else if let Some(path) = roundrect_path(cx - pw / 2.0, cy - ph / 2.0, pw, ph, pr) {
        fill_then_stroke(b, &path, gp, t, clip, vp, FillRule::Winding);
    }
}

/// Draw a [`Node::Lines`].
pub(super) fn draw_lines<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Lines {
        x,
        y,
        xu,
        yu,
        scap,
        ecap,
        off,
        arrow,
        sketch,
        hw,
        key,
        ..
    } = node
    else {
        unreachable!("draw_lines called on another node kind")
    };
    b.set_element_key(key.as_deref());
    let lwd = gp.lwd_px(vp.dpi) as f64;
    if sketch.is_some() || hw.is_some() {
        // Sketched and variable-width strokes follow the raw
        // vertices (neither takes an offset or caps): record that
        // centre-line, at the widest width a profile reaches.
        if let Some(g) = b.geom_sink() {
            let n = x.len().min(y.len()).min(xu.len()).min(yu.len());
            let pts: Vec<(f32, f32)> = (0..n)
                .map(|i| (vp.x_pos(x[i], xu[i]) as f32, vp.y_pos(y[i], yu[i]) as f32))
                .collect();
            let k = hw.as_ref().map_or(1.0, |h| {
                h.iter()
                    .copied()
                    .filter(|v| v.is_finite())
                    .fold(0.0, f64::max)
            });
            g.stroke(0, &pts, lwd * k);
        }
    }
    if let Some(sk) = sketch {
        draw_sketch_polyline(b, x, y, xu, yu, gp, sk, t, clip, vp);
    } else if let Some(hw) = hw {
        // A variable-width stroke is a FILLED ribbon: no backend
        // can stroke one path at several widths, so the generator
        // builds the outline and we fill it with the stroke
        // colour. Non-zero rule, matching `variable_stroke`'s own
        // self-union.
        draw_var_stroke(b, x, y, xu, yu, hw, gp, t, clip, vp);
    } else {
        let n = x.len().min(y.len()).min(xu.len()).min(yu.len());
        if n >= 2 {
            // Resolve to local px, rigidly translate the whole polyline by
            // any perpendicular offset (along its chord normal), then trim
            // the ends by any absolute caps (heads land on the capped ends).
            let mut pts: Vec<(f32, f32)> = (0..n)
                .map(|i| (vp.x_pos(x[i], xu[i]) as f32, vp.y_pos(y[i], yu[i]) as f32))
                .collect();
            if let Some((v, u)) = off {
                let o = vp.x_len(*v, *u); // signed
                offset_polyline(&mut pts, o);
            }
            let sc = scap.map_or(0.0, |(v, u)| vp.x_len(v.max(0.0), u));
            let ec = ecap.map_or(0.0, |(v, u)| vp.x_len(v.max(0.0), u));
            if sc > 0.0 || ec > 0.0 {
                trim_poly_ends(&mut pts, sc, ec);
            }
            // The centre-line as drawn: offset, then trimmed.
            if let Some(g) = b.geom_sink() {
                g.stroke(0, &pts, lwd);
            }
            // Geometry above is recorded even when nothing is
            // painted; painting needs a colour.
            let Some(col) = gp.col else {
                return;
            };
            let style = stroke_style(gp, vp);
            if let Some(path) = build_poly_px(&pts, false) {
                if style.width > 0.0 {
                    b.stroke_lines(&path, t, col, &style, clip);
                }
            }
            if let Some(a) = arrow {
                let finite = |q: (f32, f32)| q.0.is_finite() && q.1.is_finite();
                let mut ends = Vec::new();
                if a.ends & 2 != 0 {
                    if let Some(z) = pts.iter().rposition(|&q| finite(q)) {
                        if let Some(w) = (0..z).rev().find(|&j| finite(pts[j])) {
                            let (ex, ey) = pts[z];
                            let (qx, qy) = pts[w];
                            ends.push((ex, ey, (ex - qx) as f64, (ey - qy) as f64));
                        }
                    }
                }
                if a.ends & 1 != 0 {
                    if let Some(a0) = pts.iter().position(|&q| finite(q)) {
                        if let Some(b0) = (a0 + 1..pts.len()).find(|&j| finite(pts[j])) {
                            let (sx, sy) = pts[a0];
                            let (qx, qy) = pts[b0];
                            ends.push((sx, sy, (sx - qx) as f64, (sy - qy) as f64));
                        }
                    }
                }
                draw_arrows(b, a, &ends, col, &style, t, clip, vp.dpi);
            }
        }
    }
}

/// Draw a [`Node::Polygon`].
pub(super) fn draw_polygon<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Polygon {
        x,
        y,
        xu,
        yu,
        sketch,
        key,
        ..
    } = node
    else {
        unreachable!("draw_polygon called on another node kind")
    };
    b.set_element_key(key.as_deref());
    if let Some(g) = b.geom_sink() {
        // The vertices as given (before any display
        // simplification), one closed ring.
        g.ring(0, &resolve_pts(vp, x, y, xu, yu));
    }
    if let Some(sk) = sketch {
        let n = x.len().min(y.len()).min(xu.len()).min(yu.len());
        let ring: Vec<(f64, f64)> = (0..n)
            .map(|i| (vp.x_pos(x[i], xu[i]), vp.y_pos(y[i], yu[i])))
            .filter(|p| p.0.is_finite() && p.1.is_finite())
            .collect();
        if ring.len() >= 2 {
            draw_sketch_rings(b, &[ring], gp, sk, t, clip, vp);
        }
    } else if let Some(path) = build_poly(x, y, xu, yu, vp, true) {
        fill_then_stroke(b, &path, gp, t, clip, vp, FillRule::Winding);
    }
}

/// Draw a [`Node::Circle`].
pub(super) fn draw_circle<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Circle {
        x,
        y,
        r,
        xu,
        yu,
        ru,
        sketch,
        ..
    } = node
    else {
        unreachable!("draw_circle called on another node kind")
    };
    let cx = vp.x_pos(*x, *xu);
    let cy = vp.y_pos(*y, *yu);
    let rr = vp.r_len(*r, *ru);
    if let Some(g) = b.geom_sink() {
        g.disc(0, cx, cy, rr);
    }
    if let Some(sk) = sketch {
        let o = resolve_sketch(sk, gp, vp.dpi);
        let s = crate::sketch::ellipse(cx, cy, rr * 2.0, rr * 2.0, &o, gp.fill.is_some());
        paint_sketch(b, &s, gp, t, clip, vp, o.fill_weight);
    } else {
        let mut pb = PathBuilder::new();
        pb.push_circle(cx as f32, cy as f32, rr as f32);
        if let Some(path) = pb.finish() {
            fill_then_stroke(b, &path, gp, t, clip, vp, FillRule::Winding);
        }
    }
}

/// Draw a [`Node::Rects`].
pub(super) fn draw_rects<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Rects {
        x,
        y,
        w,
        h,
        xu,
        yu,
        wu,
        hu,
        sketch,
        keys,
        ..
    } = node
    else {
        unreachable!("draw_rects called on another node kind")
    };
    let n = [
        x.len(),
        y.len(),
        w.len(),
        h.len(),
        xu.len(),
        yu.len(),
        wu.len(),
        hu.len(),
    ]
    .into_iter()
    .min()
    .unwrap_or(0);
    // Recorded per element up front: the paint paths below split
    // three ways (sketch / unit-rect fast path / per-rect), and
    // all three place each rect at exactly this box.
    if let Some(g) = b.geom_sink() {
        for i in 0..n {
            let (cx, cy) = (vp.x_pos(x[i], xu[i]), vp.y_pos(y[i], yu[i]));
            let (pw, ph) = (vp.x_extent(w[i], wu[i]), vp.y_extent(h[i], hu[i]));
            g.rect(i, cx - pw / 2.0, cy - ph / 2.0, pw, ph);
        }
    }
    if let Some(sk) = sketch {
        // Per-element sketch (the batched fast paths don't apply —
        // every rect is unique wobbly geometry). See DESIGN §4 ex.5.
        for i in 0..n {
            b.set_element_key(key_at(keys, i));
            let cx = vp.x_pos(x[i], xu[i]);
            let cy = vp.y_pos(y[i], yu[i]);
            let pw = vp.x_extent(w[i], wu[i]);
            let ph = vp.y_extent(h[i], hu[i]);
            if pw <= 0.0 || ph <= 0.0 {
                continue;
            }
            let (x0, y0) = (cx - pw / 2.0, cy - ph / 2.0);
            let (x1, y1) = (cx + pw / 2.0, cy + ph / 2.0);
            let ring = vec![(x0, y0), (x1, y0), (x1, y1), (x0, y1)];
            let mut ski = sk.clone();
            ski.seed = sk.seed.wrapping_add(i as u64);
            draw_sketch_rings(b, &[ring], gp, &ski, t, clip, vp);
        }
    } else {
        let lwd = gp.lwd_px(vp.dpi);
        let stroke = gp.col.filter(|_| lwd > 0.0);
        let rf = gp.fill.as_ref().map(|p| resolve_paint(p, vp)); // resolve gradient/pattern geom once
        let solid = matches!(gp.fill, Some(Paint::Solid(_)) | None);
        if solid && stroke.is_none() {
            // Fast path: a single unit rect placed per-element by an
            // affine transform (solid fill is transform-invariant).
            if let Some(rp) = &rf {
                let unit = unit_rect();
                for i in 0..n {
                    b.set_element_key(key_at(keys, i));
                    let cx = vp.x_pos(x[i], xu[i]);
                    let cy = vp.y_pos(y[i], yu[i]);
                    let pw = vp.x_extent(w[i], wu[i]);
                    let ph = vp.y_extent(h[i], hu[i]);
                    if pw <= 0.0 || ph <= 0.0 {
                        continue;
                    }
                    let tr = t.pre_concat(Transform::from_row(
                        pw as f32, 0.0, 0.0, ph as f32, cx as f32, cy as f32,
                    ));
                    fill_or_hatch(b, &unit, tr, rp, FillRule::Winding, clip);
                }
            } else if !keys.is_empty() && b.wants_element_keys() {
                // Neither fill nor stroke: nothing is painted, but a keyed
                // rect is still a hover target (the display list's pick-only
                // records, VR-17).
                let unit = unit_rect();
                for i in 0..n {
                    b.set_element_key(key_at(keys, i));
                    let cx = vp.x_pos(x[i], xu[i]);
                    let cy = vp.y_pos(y[i], yu[i]);
                    let pw = vp.x_extent(w[i], wu[i]);
                    let ph = vp.y_extent(h[i], hu[i]);
                    if pw <= 0.0 || ph <= 0.0 {
                        continue;
                    }
                    let tr = t.pre_concat(Transform::from_row(
                        pw as f32, 0.0, 0.0, ph as f32, cx as f32, cy as f32,
                    ));
                    b.pick_only_path(&unit, tr, FillRule::Winding, clip);
                }
            }
        } else {
            // Stroke (non-uniform scale would distort it) or a gradient
            // that must be resolved in local px: build each rect.
            let style = stroke_style(gp, vp);
            let pen = stroke.map(|c| (c, style)).filter(|(_, s)| s.width > 0.0);
            for i in 0..n {
                b.set_element_key(key_at(keys, i));
                let cx = vp.x_pos(x[i], xu[i]);
                let cy = vp.y_pos(y[i], yu[i]);
                let pw = vp.x_extent(w[i], wu[i]);
                let ph = vp.y_extent(h[i], hu[i]);
                if let Some(path) = rect_path(cx - pw / 2.0, cy - ph / 2.0, pw, ph) {
                    fill_paint_then_stroke(
                        b,
                        &path,
                        t,
                        rf.as_ref(),
                        pen.as_ref(),
                        FillRule::Winding,
                        clip,
                    );
                }
            }
        }
    }
}

/// Draw a [`Node::Circles`].
pub(super) fn draw_circles<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Circles {
        x,
        y,
        r,
        xu,
        yu,
        ru,
        sketch,
        keys,
        ..
    } = node
    else {
        unreachable!("draw_circles called on another node kind")
    };
    let n = [x.len(), y.len(), r.len(), xu.len(), yu.len(), ru.len()]
        .into_iter()
        .min()
        .unwrap_or(0);
    // Up front, for the same reason as Rects: the batched fast
    // path never visits elements one by one.
    if let Some(g) = b.geom_sink() {
        for i in 0..n {
            g.disc(
                i,
                vp.x_pos(x[i], xu[i]),
                vp.y_pos(y[i], yu[i]),
                vp.r_len(r[i], ru[i]),
            );
        }
    }
    if let Some(sk) = sketch {
        // Per-element sketch (batched fast paths don't apply); vary the
        // seed per element so many circles don't look mechanically cloned.
        let o = resolve_sketch(sk, gp, vp.dpi);
        for i in 0..n {
            b.set_element_key(key_at(keys, i));
            let cx = vp.x_pos(x[i], xu[i]);
            let cy = vp.y_pos(y[i], yu[i]);
            let rr = vp.r_len(r[i], ru[i]);
            if rr <= 0.0 {
                continue;
            }
            let mut oi = o.clone();
            oi.seed = o.seed.wrapping_add(i as u64);
            let s = crate::sketch::ellipse(cx, cy, rr * 2.0, rr * 2.0, &oi, gp.fill.is_some());
            paint_sketch(b, &s, gp, t, clip, vp, oi.fill_weight);
        }
        return;
    }
    let lwd = gp.lwd_px(vp.dpi);
    let stroke = gp.col.filter(|_| lwd > 0.0);
    let rf = gp.fill.as_ref().map(|p| resolve_paint(p, vp));
    // Solid/no fill hands the whole batch, keys included, to
    // `draw_circles`: raster may sprite-stamp it, SVG tags each circle
    // with its key, the display list records it as one point table.
    // Raster/PDF ignore keys, so they stay pixel-identical whether or
    // not the scene is keyed. A gradient/
    // pattern *stroke* drops to the per-element build: the fast
    // path draws a unit circle placed by an affine transform, but the
    // stroke paint is resolved in viewport px, so on the unit circle it
    // would sample a single point of the ramp (collapsing to one stop).
    // Real-coordinate circles keep the ramp aligned, exactly as Rects do.
    if matches!(gp.fill, Some(Paint::Solid(_)) | None) && gp.col_paint.is_none() {
        let mut cx = Vec::with_capacity(n);
        let mut cy = Vec::with_capacity(n);
        let mut rr = Vec::with_capacity(n);
        for i in 0..n {
            cx.push(vp.x_pos(x[i], xu[i]));
            cy.push(vp.y_pos(y[i], yu[i]));
            rr.push(vp.r_len(r[i], ru[i]));
        }
        b.draw_circles(
            &cx,
            &cy,
            &rr,
            rf.as_ref(),
            stroke.map(|c| (c, stroke_style(gp, vp))),
            t,
            clip,
            keys,
        );
    } else {
        // Per-element build: a gradient/pattern fill or stroke (resolved
        // in local px, so position-dependent).
        let style = stroke_style(gp, vp);
        let pen = stroke.map(|c| (c, style)).filter(|(_, s)| s.width > 0.0);
        for i in 0..n {
            b.set_element_key(key_at(keys, i));
            let cx = vp.x_pos(x[i], xu[i]);
            let cy = vp.y_pos(y[i], yu[i]);
            let rr = vp.r_len(r[i], ru[i]);
            let mut pb = PathBuilder::new();
            pb.push_circle(cx as f32, cy as f32, rr as f32);
            if let Some(path) = pb.finish() {
                fill_paint_then_stroke(
                    b,
                    &path,
                    t,
                    rf.as_ref(),
                    pen.as_ref(),
                    FillRule::Winding,
                    clip,
                );
            }
        }
    }
}

/// Draw a [`Node::Markers`].
pub(super) fn draw_markers<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Markers {
        x,
        y,
        size,
        xu,
        yu,
        su,
        shape,
        sketch,
        keys,
        ..
    } = node
    else {
        unreachable!("draw_markers called on another node kind")
    };
    let n = [
        x.len(),
        y.len(),
        size.len(),
        xu.len(),
        yu.len(),
        su.len(),
        shape.len(),
    ]
    .into_iter()
    .min()
    .unwrap_or(0);
    // A marker is picked as the disc of its radius, whatever its
    // glyph: the target a reader aims at, and one point of
    // geometry for a client to measure against.
    if let Some(g) = b.geom_sink() {
        for i in 0..n {
            let (cx, cy) = (vp.x_pos(x[i], xu[i]), vp.y_pos(y[i], yu[i]));
            let rr = vp.r_len(size[i], su[i]);
            if rr > 0.0 && cx.is_finite() && cy.is_finite() {
                g.disc(i, cx, cy, rr);
            }
        }
    }
    if let Some(sk) = sketch {
        // Per-marker hand-drawn geometry: circle -> rough ellipse;
        // square/triangle/diamond -> rough polygon; plus/cross ->
        // rough stroke arms. Per-element seed.
        let o = resolve_sketch(sk, gp, vp.dpi);
        let col = gp.col;
        let style = stroke_style(gp, vp);
        for i in 0..n {
            b.set_element_key(key_at(keys, i));
            let cx = vp.x_pos(x[i], xu[i]);
            let cy = vp.y_pos(y[i], yu[i]);
            let rr = vp.r_len(size[i], su[i]);
            if rr <= 0.0 || !cx.is_finite() || !cy.is_finite() {
                continue;
            }
            let mut oi = o.clone();
            oi.seed = o.seed.wrapping_add(i as u64);
            match shape[i] {
                4 | 5 => {
                    // plus / cross: two stroke arms
                    let arms: [[(f64, f64); 2]; 2] = if shape[i] == 4 {
                        [
                            [(cx - rr, cy), (cx + rr, cy)],
                            [(cx, cy - rr), (cx, cy + rr)],
                        ]
                    } else {
                        [
                            [(cx - rr, cy - rr), (cx + rr, cy + rr)],
                            [(cx - rr, cy + rr), (cx + rr, cy - rr)],
                        ]
                    };
                    if let Some(c) = col {
                        if style.width > 0.0 {
                            for arm in arms.iter() {
                                let s = crate::sketch::polyline(arm, &oi);
                                for p in &s.stroke {
                                    b.stroke_path(p, t, c, &style, clip);
                                }
                            }
                        }
                    }
                }
                0 => {
                    let s =
                        crate::sketch::ellipse(cx, cy, rr * 2.0, rr * 2.0, &oi, gp.fill.is_some());
                    paint_sketch(b, &s, gp, t, clip, vp, oi.fill_weight);
                }
                sh => {
                    let ring: Vec<(f64, f64)> = match sh {
                        1 => vec![
                            (cx - rr, cy - rr),
                            (cx + rr, cy - rr),
                            (cx + rr, cy + rr),
                            (cx - rr, cy + rr),
                        ],
                        2 => vec![
                            (cx, cy - rr),
                            (cx + 0.866 * rr, cy + 0.5 * rr),
                            (cx - 0.866 * rr, cy + 0.5 * rr),
                        ],
                        6 => vec![
                            (cx, cy + rr),
                            (cx + 0.866 * rr, cy - 0.5 * rr),
                            (cx - 0.866 * rr, cy - 0.5 * rr),
                        ],
                        7 => (0..10)
                            .map(|k| {
                                let ang = -std::f64::consts::FRAC_PI_2
                                    + k as f64 * std::f64::consts::PI / 5.0;
                                let rad = if k % 2 == 0 { rr } else { rr * 0.382 };
                                (cx + rad * ang.cos(), cy + rad * ang.sin())
                            })
                            .collect(),
                        _ => vec![(cx, cy - rr), (cx + rr, cy), (cx, cy + rr), (cx - rr, cy)],
                    };
                    let s = crate::sketch::rings(&[ring], &oi, gp.fill.is_some());
                    paint_sketch(b, &s, gp, t, clip, vp, oi.fill_weight);
                }
            }
        }
        return;
    }
    let lwd = gp.lwd_px(vp.dpi);
    let stroke = gp.col.filter(|_| lwd > 0.0);
    let rf = gp.fill.as_ref().map(|p| resolve_paint(p, vp));
    let solid = matches!(gp.fill, Some(Paint::Solid(_)) | None);
    let style = stroke_style(gp, vp);
    // Fast path: a solid (transform-invariant) fill with no stroke
    // reuses one unit shape per marker kind, placed by an affine
    // transform — mirrors the Rects fast path and is pixel-identical.
    // Stroked / gradient / line-glyph (plus, cross) markers keep the
    // per-element build below (a scaled stroke would distort).
    let fast = solid && stroke.is_none();
    // Indexed by shape code (0..=7); plus/cross (4/5) never reach here.
    let mut unit_cache: [Option<tiny_skia::Path>; 8] =
        [None, None, None, None, None, None, None, None];
    for i in 0..n {
        b.set_element_key(key_at(keys, i));
        let cx = vp.x_pos(x[i], xu[i]);
        let cy = vp.y_pos(y[i], yu[i]);
        let rr = vp.r_len(size[i], su[i]);
        // Drop a marker at a non-finite position (an R `NA`).
        if rr <= 0.0 || !cx.is_finite() || !cy.is_finite() {
            continue;
        }
        let sh = shape[i];
        b.begin_marker(sh, cx, cy, rr, t, clip);
        if fast && sh != 4 && sh != 5 {
            if let Some(rp) = &rf {
                let slot = (sh as usize).min(7);
                let unit = unit_cache[slot].get_or_insert_with(|| unit_marker(sh));
                let tr = t.pre_concat(Transform::from_row(
                    rr as f32, 0.0, 0.0, rr as f32, cx as f32, cy as f32,
                ));
                fill_or_hatch(b, unit, tr, rp, FillRule::Winding, clip);
            }
            continue;
        }
        let (cxf, cyf, rrf) = (cx as f32, cy as f32, rr as f32);
        let mut pb = PathBuilder::new();
        match sh {
            // plus / cross: stroke-only line glyphs (no fill)
            4 | 5 => {
                if sh == 4 {
                    pb.move_to(cxf, cyf - rrf);
                    pb.line_to(cxf, cyf + rrf);
                    pb.move_to(cxf - rrf, cyf);
                    pb.line_to(cxf + rrf, cyf);
                } else {
                    let d = rrf * std::f32::consts::FRAC_1_SQRT_2;
                    pb.move_to(cxf - d, cyf - d);
                    pb.line_to(cxf + d, cyf + d);
                    pb.move_to(cxf - d, cyf + d);
                    pb.line_to(cxf + d, cyf - d);
                }
                if let (Some(path), Some(col)) = (pb.finish(), gp.col) {
                    if style.width > 0.0 {
                        b.stroke_lines(&path, t, col, &style, clip);
                    }
                }
            }
            // filled / outlined polygons + circle (y-down: -y is up)
            s => {
                match s {
                    1 => {
                        pb.move_to(cxf - rrf, cyf - rrf);
                        pb.line_to(cxf + rrf, cyf - rrf);
                        pb.line_to(cxf + rrf, cyf + rrf);
                        pb.line_to(cxf - rrf, cyf + rrf);
                        pb.close();
                    }
                    2 => {
                        pb.move_to(cxf, cyf - rrf);
                        pb.line_to(cxf + 0.866 * rrf, cyf + 0.5 * rrf);
                        pb.line_to(cxf - 0.866 * rrf, cyf + 0.5 * rrf);
                        pb.close();
                    }
                    3 => {
                        pb.move_to(cxf, cyf - rrf);
                        pb.line_to(cxf + rrf, cyf);
                        pb.line_to(cxf, cyf + rrf);
                        pb.line_to(cxf - rrf, cyf);
                        pb.close();
                    }
                    6 => {
                        pb.move_to(cxf, cyf + rrf);
                        pb.line_to(cxf + 0.866 * rrf, cyf - 0.5 * rrf);
                        pb.line_to(cxf - 0.866 * rrf, cyf - 0.5 * rrf);
                        pb.close();
                    }
                    7 => {
                        star_path(&mut pb, cxf, cyf, rrf);
                    }
                    _ => {
                        pb.push_circle(cxf, cyf, rrf);
                    }
                }
                if let Some(path) = pb.finish() {
                    fill_then_stroke(b, &path, gp, t, clip, vp, FillRule::Winding);
                }
            }
        }
    }
}

/// Draw a [`Node::Hexagons`].
pub(super) fn draw_hexagons<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Hexagons {
        x,
        y,
        size,
        w,
        h,
        xu,
        yu,
        su,
        wu,
        hu,
        fill,
        flat,
        keys,
        ..
    } = node
    else {
        unreachable!("draw_hexagons called on another node kind")
    };
    // n excludes w/h: they are empty for the regular (size-driven) path.
    // `fill` is empty when the shared `gp` paint applies to every
    // element (a gradient/pattern/hatch), so it must not bound the
    // element count -- that would draw nothing at all.
    let nonreg = !w.is_empty();
    // Every array the loop indexes bounds it: the size-driven path reads
    // `size`/`su`, the width/height path `w`/`h`/`wu`/`hu`. The R compiler
    // recycles them all to one length, but a tween frame can mix keyframes
    // (geometry and size snap on different easings), so they may disagree.
    let lens = [x.len(), y.len(), xu.len(), yu.len()];
    let n = if nonreg {
        lens.into_iter()
            .chain([w.len(), h.len(), wu.len(), hu.len()])
            .min()
    } else {
        lens.into_iter().chain([size.len(), su.len()]).min()
    }
    .unwrap_or(0);
    let style = stroke_style(gp, vp);
    let pen = gp.col.filter(|_| style.width > 0.0).map(|c| (c, style));
    for i in 0..n {
        b.set_element_key(key_at(keys, i));
        let cx = vp.x_pos(x[i], xu[i]);
        let cy = vp.y_pos(y[i], yu[i]);
        if !cx.is_finite() || !cy.is_finite() {
            continue; // drop NA-positioned hexes
        }
        // hexagon_path / _xy drop non-positive extents -> None.
        let path = if nonreg {
            hexagon_path_xy(
                cx,
                cy,
                vp.x_extent(w[i], wu[i]) * 0.5,
                vp.y_extent(h[i], hu[i]) * 0.5,
                *flat,
            )
        } else {
            hexagon_path(cx, cy, vp.r_len(size[i], su[i]), *flat)
        };
        if let (Some(g), Some(p)) = (b.geom_sink(), path.as_ref()) {
            g.path(i, p, FillRule::Winding);
        }
        if let Some(path) = path {
            // Per-element fill (the binned-count colour); uniform stroke.
            // Per-element colour when given; otherwise the shared `gp` paint, which
            // is how a gradient/pattern/hatch reaches a batched mark at all.
            let rp = match fill.get(i) {
                Some(c) => Some(ResolvedPaint::Solid(*c)),
                None => gp.fill.as_ref().map(|p| resolve_paint(p, vp)),
            };
            fill_paint_then_stroke(
                b,
                &path,
                t,
                rp.as_ref(),
                pen.as_ref(),
                FillRule::Winding,
                clip,
            );
        }
    }
}

/// Draw a [`Node::Sectors`].
pub(super) fn draw_sectors<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Sectors {
        x,
        y,
        r0,
        r1,
        theta0,
        theta1,
        xu,
        yu,
        r0u,
        r1u,
        fill,
        arrow,
        sketch,
        keys,
        ..
    } = node
    else {
        unreachable!("draw_sectors called on another node kind")
    };
    let n = [
        x.len(),
        y.len(),
        r0.len(),
        r1.len(),
        theta0.len(),
        theta1.len(),
        xu.len(),
        yu.len(),
        r0u.len(),
        r1u.len(),
    ]
    .into_iter()
    .min()
    .unwrap_or(0);
    if let Some(sk) = sketch {
        // Hand-drawn pie/donut wedges: per-element fill colour, curve-fit
        // outline, hachure interior. Arrows (self-loops) are ignored here.
        let o = resolve_sketch(sk, gp, vp.dpi);
        for i in 0..n {
            b.set_element_key(key_at(keys, i));
            let cx = vp.x_pos(x[i], xu[i]);
            let cy = vp.y_pos(y[i], yu[i]);
            if !cx.is_finite() || !cy.is_finite() {
                continue;
            }
            let rr0 = vp.r_len(r0[i], r0u[i]);
            let rr1 = vp.r_len(r1[i], r1u[i]);
            let (lo, hi) = (rr0.min(rr1), rr0.max(rr1));
            if let Some(g) = b.geom_sink() {
                if let Some(p) = sector_path(cx, cy, rr0, rr1, theta0[i], theta1[i]) {
                    g.path(i, &p, FillRule::Winding);
                }
            }
            let ring = wedge_ring(cx, cy, lo, hi, theta0[i], theta1[i]);
            if ring.len() < 3 {
                continue;
            }
            let mut gp2 = gp.clone();
            // `fill` is empty when one shared gradient/pattern/hatch paints every
            // wedge (see the crisp path below); fall back to that paint.
            if let Some(c) = fill.get(i) {
                gp2.fill = Some(Paint::Solid(*c));
            }
            let want_fill = (hi - lo).abs() > 0.5;
            let mut oi = o.clone();
            oi.seed = o.seed.wrapping_add(i as u64);
            let s = crate::sketch::closed_curve(&ring, &oi, want_fill);
            paint_sketch(b, &s, &gp2, t, clip, vp, oi.fill_weight);
        }
        return;
    }
    let style = stroke_style(gp, vp);
    let pen = gp.col.filter(|_| style.width > 0.0).map(|c| (c, style.clone()));
    // Arrowheads (directed self-loops) accumulate across the batch and
    // are drawn once at the end, tangent to each outer arc's end(s).
    let mut ends: Vec<(f32, f32, f64, f64)> = Vec::new();
    for i in 0..n {
        b.set_element_key(key_at(keys, i));
        let cx = vp.x_pos(x[i], xu[i]);
        let cy = vp.y_pos(y[i], yu[i]);
        if !cx.is_finite() || !cy.is_finite() {
            continue; // drop NA-positioned sectors
        }
        let rr0 = vp.r_len(r0[i], r0u[i]);
        let rr1 = vp.r_len(r1[i], r1u[i]);
        if let Some(path) = sector_path(cx, cy, rr0, rr1, theta0[i], theta1[i]) {
            if let Some(g) = b.geom_sink() {
                g.path(i, &path, FillRule::Winding);
            }
            // Per-element fill; uniform stroke (matches hexagons).
            // Per-element colour when given; otherwise the shared `gp` paint, which
            // is how a gradient/pattern/hatch reaches a batched mark at all.
            let rp = match fill.get(i) {
                Some(c) => Some(ResolvedPaint::Solid(*c)),
                None => gp.fill.as_ref().map(|p| resolve_paint(p, vp)),
            };
            fill_paint_then_stroke(
                b,
                &path,
                t,
                rp.as_ref(),
                pen.as_ref(),
                FillRule::Winding,
                clip,
            );
        }
        if let Some(a) = arrow {
            // Endpoints and travel-tangent of the outer arc in local px.
            // The path is (cx + r cos θ, cy - r sin θ) — the y term is
            // negated for the y-down device frame (see `sector_path`) — so
            // dP/dθ = (-sin θ, -cos θ) and the forward tangent is
            // sgn·(-sin θ, -cos θ); the arrowhead direction for the "last"
            // end points forward, "first" points backward.
            let (t0, t1) = (theta0[i], theta1[i]);
            let sgn = if t1 >= t0 { 1.0 } else { -1.0 };
            let outer = rr1.max(rr0);
            if a.ends & 2 != 0 {
                let (px, py) = (
                    (cx + outer * t1.cos()) as f32,
                    (cy - outer * t1.sin()) as f32,
                );
                ends.push((px, py, sgn * -t1.sin(), sgn * -t1.cos()));
            }
            if a.ends & 1 != 0 {
                let (px, py) = (
                    (cx + outer * t0.cos()) as f32,
                    (cy - outer * t0.sin()) as f32,
                );
                ends.push((px, py, sgn * t0.sin(), sgn * t0.cos()));
            }
        }
    }
    b.set_element_key(None); // arrowheads are batch decoration, unkeyed
    if let (Some(a), Some(col)) = (arrow, gp.col) {
        if !ends.is_empty() {
            draw_arrows(b, a, &ends, col, &style, t, clip, vp.dpi);
        }
    }
}

/// Draw a [`Node::Text`].
pub(super) fn draw_text<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Text {
        x,
        y,
        xu,
        yu,
        rot,
        hjust,
        vjust,
        w,
        h,
        gid,
        gx,
        gy,
        gsize,
        gpath,
        gface,
        gcol,
        halo,
        label,
        family,
        face,
        size,
        tpath,
        key,
        ..
    } = node
    else {
        unreachable!("draw_text called on another node kind")
    };
    // A keyed label is an addressable element like any other
    // mark, so it carries `data-key` into the SVG.
    b.set_element_key(key.as_deref());
    // Per-glyph colours carry their own paint, so a rich label draws
    // even when the shared `gp.col` is "inherit/none" (the base colour
    // is folded into `gcol` on the R side). A plain label still needs a
    // resolved shared colour.
    let color = match gp.col {
        Some(c) => c,
        None if !gcol.is_empty() => Rgba {
            r: 0,
            g: 0,
            b: 0,
            a: 255,
        },
        // A recording walk still wants the label's box: the
        // recorder takes it from `draw_text` and paints nothing.
        None if b.geom_sink().is_some() => Rgba {
            r: 0,
            g: 0,
            b: 0,
            a: 0,
        },
        // Nothing to draw, but a metadata node was already opened at
        // the top of the loop; close it before skipping so the SVG
        // backend's node buffer stays balanced (else all following
        // output mis-nests). See BUGFIX1 Phase 1.
        None => return,
    };
    let run = TextRun {
        ax: vp.x_pos(*x, *xu),
        ay: vp.y_pos(*y, *yu),
        w: *w,
        h: *h,
        hjust: *hjust,
        vjust: *vjust,
        rot: *rot,
        color,
        gid,
        gx,
        gy,
        gsize,
        gpath,
        gface,
        gcolor: gcol,
        halo: *halo,
        label,
        family,
        face,
        size: *size,
        dpi: vp.dpi,
    };
    match tpath {
        // Ordinary label: one run at one anchor, exactly as before.
        None => b.draw_text(&run, t, clip),
        // Set along a curve: fan the run out into one single-glyph
        // run per glyph, each at its own point and tangent angle.
        // Every backend then draws it through the path it already
        // has, so raster/SVG/PDF need no new code.
        Some(tp) => draw_text_on_path(b, &run, tp, vp, t, clip),
    }
}

/// Draw a [`Node::Segments`].
pub(super) fn draw_segments<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Segments {
        x0,
        y0,
        x1,
        y1,
        x0u,
        y0u,
        x1u,
        y1u,
        scap,
        ecap,
        scapu,
        ecapu,
        off,
        offu,
        arrow,
        sketch,
        keys,
        cols,
        lwds,
        ..
    } = node
    else {
        unreachable!("draw_segments called on another node kind")
    };
    if let Some(sk) = sketch {
        // Hand-drawn: rough each segment (ignores offset/caps/arrow —
        // §4 exception 4). Per-segment seed so they don't look cloned.
        if let Some(g) = b.geom_sink() {
            let n = [
                x0.len(),
                y0.len(),
                x1.len(),
                y1.len(),
                x0u.len(),
                y0u.len(),
                x1u.len(),
                y1u.len(),
            ]
            .into_iter()
            .min()
            .unwrap_or(0);
            let lwd = gp.lwd_px(vp.dpi) as f64;
            for i in 0..n {
                let a = (
                    vp.x_pos(x0[i], x0u[i]) as f32,
                    vp.y_pos(y0[i], y0u[i]) as f32,
                );
                let e = (
                    vp.x_pos(x1[i], x1u[i]) as f32,
                    vp.y_pos(y1[i], y1u[i]) as f32,
                );
                if a.0.is_finite() && a.1.is_finite() && e.0.is_finite() && e.1.is_finite() {
                    g.stroke(i, &[a, e], lwds.get(i).map_or(lwd, |w| w * vp.dpi / 96.0));
                }
            }
        }
        if let Some(col) = gp.col {
            let style = stroke_style(gp, vp);
            if style.width > 0.0 {
                let n = [
                    x0.len(),
                    y0.len(),
                    x1.len(),
                    y1.len(),
                    x0u.len(),
                    y0u.len(),
                    x1u.len(),
                    y1u.len(),
                ]
                .into_iter()
                .min()
                .unwrap_or(0);
                let o = resolve_sketch(sk, gp, vp.dpi);
                for i in 0..n {
                    b.set_element_key(key_at(keys, i));
                    let a = (vp.x_pos(x0[i], x0u[i]), vp.y_pos(y0[i], y0u[i]));
                    let bpt = (vp.x_pos(x1[i], x1u[i]), vp.y_pos(y1[i], y1u[i]));
                    if !(a.0.is_finite()
                        && a.1.is_finite()
                        && bpt.0.is_finite()
                        && bpt.1.is_finite())
                    {
                        continue;
                    }
                    let mut oi = o.clone();
                    oi.seed = o.seed.wrapping_add(i as u64);
                    let s = crate::sketch::polyline(&[a, bpt], &oi);
                    for p in &s.stroke {
                        b.stroke_path(p, t, col, &style, clip);
                    }
                }
            }
        }
        return;
    }
    {
        let style = stroke_style(gp, vp);
        let n = [
            x0.len(),
            y0.len(),
            x1.len(),
            y1.len(),
            x0u.len(),
            y0u.len(),
            x1u.len(),
            y1u.len(),
        ]
        .into_iter()
        .min()
        .unwrap_or(0);
        let has_caps = !scap.is_empty() || !ecap.is_empty();
        let has_off = !off.is_empty();
        // Resolve each segment's endpoints once, so the stroke and the
        // arrowhead share the same geometry. Order per the handover:
        // perpendicular offset first, then caps, then the arrow along the
        // shifted+capped direction. A segment is dropped when a coordinate
        // is non-finite (an R `NA`) or when caps shorten it away entirely.
        // Each seg carries its originating element index so a keyed
        // batch can tag every segment with its own `data-key`.
        let mut segs: Vec<(f32, f32, f32, f32, usize)> = Vec::with_capacity(n);
        for i in 0..n {
            let (mut sx, mut sy) = (
                vp.x_pos(x0[i], x0u[i]) as f32,
                vp.y_pos(y0[i], y0u[i]) as f32,
            );
            let (mut ex, mut ey) = (
                vp.x_pos(x1[i], x1u[i]) as f32,
                vp.y_pos(y1[i], y1u[i]) as f32,
            );
            if !(sx.is_finite() && sy.is_finite() && ex.is_finite() && ey.is_finite()) {
                continue;
            }
            if has_off {
                // signed offset — keep the sign (no `.max(0)` clamp).
                let o = off_len_px(off, offu, i, vp);
                let (a, b, c, d) = offset_segment(sx, sy, ex, ey, o);
                sx = a;
                sy = b;
                ex = c;
                ey = d;
            }
            if has_caps {
                let sc = cap_len_px(scap, scapu, i, vp);
                let ec = cap_len_px(ecap, ecapu, i, vp);
                match cap_segment(sx, sy, ex, ey, sc, ec) {
                    Some((a, b, c, d)) => segs.push((a, b, c, d, i)),
                    None => continue,
                }
            } else {
                segs.push((sx, sy, ex, ey, i));
            }
        }
        // Each segment as drawn -- offset, then capped -- is the
        // element's geometry, recorded whether or not it is
        // painted.
        if let Some(g) = b.geom_sink() {
            let lwd = gp.lwd_px(vp.dpi) as f64;
            for &(sx, sy, ex, ey, gi) in &segs {
                g.stroke(
                    gi,
                    &[(sx, sy), (ex, ey)],
                    lwds.get(gi).map_or(lwd, |w| w * vp.dpi / 96.0),
                );
            }
        }
        let Some(col) = gp.col else {
            return;
        };
        // Per-element stroke style forces one stroke per segment --
        // there is no "stroke each differently in one call" anywhere,
        // so this is inherent, not a missed optimisation. The win is
        // on the R side: one grob instead of N.
        let per_el = !cols.is_empty() || !lwds.is_empty();
        if per_el {
            for &(sx, sy, ex, ey, gi) in &segs {
                let c = cols.get(gi).copied().unwrap_or(col);
                let mut st = style.clone();
                if let Some(w) = lwds.get(gi) {
                    st.width = (w * vp.dpi / 96.0) as f32;
                    // Dash nibbles scale with the width (grid's rule),
                    // so rescale them from the shared style's width.
                    if !st.dash.is_empty() && style.width > 0.0 {
                        let k = st.width / style.width;
                        for d in st.dash.iter_mut() {
                            *d *= k;
                        }
                    }
                }
                if st.width <= 0.0 || c.a == 0 {
                    continue;
                }
                b.set_element_key(key_at(keys, gi));
                let mut pb = PathBuilder::new();
                pb.move_to(sx, sy);
                pb.line_to(ex, ey);
                if let Some(path) = pb.finish() {
                    b.stroke_lines(&path, t, c, &st, clip);
                }
            }
            b.set_element_key(None);
        } else if style.width > 0.0 {
            if keys.is_empty() || !b.wants_element_keys() {
                // Fast path: all segments in one combined stroke.
                // (Also taken by raster/PDF for keyed batches — they
                // ignore keys, so they stay pixel-identical.)
                let mut pb = PathBuilder::new();
                for &(sx, sy, ex, ey, _) in &segs {
                    pb.move_to(sx, sy);
                    pb.line_to(ex, ey);
                }
                if let Some(path) = pb.finish() {
                    b.stroke_lines(&path, t, col, &style, clip);
                }
            } else {
                // Keyed: stroke each segment on its own so it can carry
                // its `data-key` (the interactivity opt-in).
                for &(sx, sy, ex, ey, gi) in &segs {
                    b.set_element_key(key_at(keys, gi));
                    let mut pb = PathBuilder::new();
                    pb.move_to(sx, sy);
                    pb.line_to(ex, ey);
                    if let Some(path) = pb.finish() {
                        b.stroke_lines(&path, t, col, &style, clip);
                    }
                }
                b.set_element_key(None);
            }
        }
        if let Some(a) = arrow {
            let mut ends = Vec::new();
            for &(sx, sy, ex, ey, _) in &segs {
                if a.ends & 2 != 0 {
                    ends.push((ex, ey, (ex - sx) as f64, (ey - sy) as f64));
                }
                if a.ends & 1 != 0 {
                    ends.push((sx, sy, (sx - ex) as f64, (sy - ey) as f64));
                }
            }
            draw_arrows(b, a, &ends, col, &style, t, clip, vp.dpi);
        }
    }
}

/// Draw a [`Node::Loop`].
pub(super) fn draw_loop<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Loop {
        x,
        y,
        xu,
        yu,
        size,
        su,
        foot,
        fu,
        angle,
        width,
        arrow,
        ..
    } = node
    else {
        unreachable!("draw_loop called on another node kind")
    };
    if let Some(g) = b.geom_sink() {
        let n = [
            x.len(),
            y.len(),
            xu.len(),
            yu.len(),
            size.len(),
            su.len(),
            foot.len(),
            fu.len(),
            angle.len(),
            width.len(),
        ]
        .into_iter()
        .min()
        .unwrap_or(0);
        let lwd = gp.lwd_px(vp.dpi) as f64;
        for i in 0..n {
            let (cx, cy) = (vp.x_pos(x[i], xu[i]), vp.y_pos(y[i], yu[i]));
            if !cx.is_finite() || !cy.is_finite() {
                continue;
            }
            let cp = loop_control_points(
                cx,
                cy,
                vp.x_len(size[i], su[i]),
                vp.x_len(foot[i], fu[i]),
                angle[i],
                width[i],
            );
            let mut pb = PathBuilder::new();
            pb.move_to(cp[0].0, cp[0].1);
            pb.cubic_to(cp[1].0, cp[1].1, cp[2].0, cp[2].1, cp[3].0, cp[3].1);
            if let Some(p) = pb.finish() {
                g.stroke_path(i, &p, lwd);
            }
        }
    }
    if let Some(col) = gp.col {
        let style = stroke_style(gp, vp);
        let n = [
            x.len(),
            y.len(),
            xu.len(),
            yu.len(),
            size.len(),
            su.len(),
            foot.len(),
            fu.len(),
            angle.len(),
            width.len(),
        ]
        .into_iter()
        .min()
        .unwrap_or(0);
        let mut ends: Vec<(f32, f32, f64, f64)> = Vec::new();
        for i in 0..n {
            let cx = vp.x_pos(x[i], xu[i]);
            let cy = vp.y_pos(y[i], yu[i]);
            if !cx.is_finite() || !cy.is_finite() {
                continue;
            }
            let s = vp.x_len(size[i], su[i]); // mm -> device px
            let f = vp.x_len(foot[i], fu[i]);
            let cp = loop_control_points(cx, cy, s, f, angle[i], width[i]);
            // Per-element path build: a loop is a distinct Bézier
            // teardrop (position/size-dependent control points) and
            // stroke-only, so unit-path+transform reuse doesn't apply.
            if style.width > 0.0 {
                let mut pb = PathBuilder::new();
                pb.move_to(cp[0].0, cp[0].1);
                pb.cubic_to(cp[1].0, cp[1].1, cp[2].0, cp[2].1, cp[3].0, cp[3].1);
                if let Some(path) = pb.finish() {
                    b.stroke_path(&path, t, col, &style, clip);
                }
            }
            if let Some(a) = arrow {
                // Head at the returning foot (P3), tangent = 3·(P3−P2) ∝ P3−P2.
                if a.ends & 2 != 0 {
                    ends.push((
                        cp[3].0,
                        cp[3].1,
                        (cp[3].0 - cp[2].0) as f64,
                        (cp[3].1 - cp[2].1) as f64,
                    ));
                }
                if a.ends & 1 != 0 {
                    ends.push((
                        cp[0].0,
                        cp[0].1,
                        (cp[0].0 - cp[1].0) as f64,
                        (cp[0].1 - cp[1].1) as f64,
                    ));
                }
            }
        }
        if let Some(a) = arrow {
            if !ends.is_empty() {
                draw_arrows(b, a, &ends, col, &style, t, clip, vp.dpi);
            }
        }
    }
}

/// Draw a [`Node::Path`].
pub(super) fn draw_path<B: RenderBackend>(
    b: &mut B,
    node: &Node,
    gp: &Gpar,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let Node::Path {
        x,
        y,
        xu,
        yu,
        nper,
        evenodd,
        sketch,
        key,
        ..
    } = node
    else {
        unreachable!("draw_path called on another node kind")
    };
    b.set_element_key(key.as_deref());
    if let Some(g) = b.geom_sink() {
        // Every ring, filled together under the path's own rule.
        if let Some(p) = build_subpaths(x, y, xu, yu, nper, vp) {
            g.path(
                0,
                &p,
                if *evenodd {
                    FillRule::EvenOdd
                } else {
                    FillRule::Winding
                },
            );
        }
    }
    if let Some(sk) = sketch {
        // Resolve each sub-path to a ring of local-px points.
        let mut rings: Vec<Vec<(f64, f64)>> = Vec::new();
        let mut i = 0usize;
        for &cnt in nper {
            let end = i + cnt;
            if cnt >= 2 && end <= x.len() && end <= y.len() && end <= xu.len() && end <= yu.len() {
                let ring: Vec<(f64, f64)> = (i..end)
                    .map(|k| (vp.x_pos(x[k], xu[k]), vp.y_pos(y[k], yu[k])))
                    .filter(|p| p.0.is_finite() && p.1.is_finite())
                    .collect();
                if ring.len() >= 2 {
                    rings.push(ring);
                }
            }
            i = end;
        }
        if !rings.is_empty() {
            draw_sketch_rings(b, &rings, gp, sk, t, clip, vp);
        }
    } else if let Some(path) = build_subpaths(x, y, xu, yu, nper, vp) {
        let rule = if *evenodd {
            FillRule::EvenOdd
        } else {
            FillRule::Winding
        };
        fill_then_stroke(b, &path, gp, t, clip, vp, rule);
    }
}
