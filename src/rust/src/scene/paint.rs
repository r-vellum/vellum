//! Shared paint helpers used by the mark drawers: gpar -> stroke/paint
//! resolution, hatch expansion, sketch painting, variable-width strokes, text on
//! a path and arrowheads.

use super::*;

/// Fill then stroke a shape according to its effective gpar, using `rule` for the
/// fill. Gradient fill geometry is resolved against `vp` into viewport-local px.
pub(super) fn fill_then_stroke<B: RenderBackend>(
    b: &mut B,
    path: &tiny_skia::Path,
    gp: &Gpar,
    t: Transform,
    clip: &Clip,
    vp: &Vp,
    rule: FillRule,
) {
    let fill = gp.fill.as_ref().map(|f| resolve_paint(f, vp));
    let stroke = gp
        .col
        .map(|col| (col, stroke_style(gp, vp)))
        .filter(|(_, style)| style.width > 0.0);
    fill_paint_then_stroke(b, path, t, fill.as_ref(), stroke.as_ref(), rule, clip);
}

/// Fill (expanding a hatch) then stroke `path`. A non-hatch fill with a stroke
/// goes through [`RenderBackend::fill_and_stroke_path`], so a backend can draw
/// the pair as one element; `stroke` must have `width > 0`.
pub(super) fn fill_paint_then_stroke<B: RenderBackend>(
    b: &mut B,
    path: &tiny_skia::Path,
    t: Transform,
    fill: Option<&ResolvedPaint>,
    stroke: Option<&(Rgba, StrokeStyle)>,
    rule: FillRule,
    clip: &Clip,
) {
    match (fill, stroke) {
        (None, None) => b.pick_only_path(path, t, rule, clip),
        (Some(rp), Some((col, style))) if !matches!(rp, ResolvedPaint::Hatch { .. }) => {
            b.fill_and_stroke_path(path, t, rp, rule, *col, style, clip);
        }
        (fill, stroke) => {
            if let Some(rp) = fill {
                fill_or_hatch(b, path, t, rp, rule, clip);
            }
            if let Some((col, style)) = stroke {
                b.stroke_path(path, t, *col, style, clip);
            }
        }
    }
}

/// Build a device-space [`StrokeStyle`] from a resolved gpar. The dash nibbles are
/// scaled by the line width (grid's convention, so thicker lines get longer dashes).
pub(super) fn stroke_style(gp: &Gpar, vp: &Vp) -> StrokeStyle {
    let width = gp.lwd_px(vp.dpi);
    // `blank` suppresses the stroke (width 0 -> backends skip it). A dash pattern
    // scales by the line width (grid convention).
    let (width, dash) = match &gp.lty {
        Lty::Blank => (0.0, Vec::new()),
        Lty::Solid => (width, Vec::new()),
        Lty::Dash(nibs) => {
            let px: Vec<f32> = nibs.iter().map(|n| n * width).collect();
            (width, crate::render::normalize_dash(&px))
        }
    };
    // A gradient/pattern stroke resolves its geometry against the viewport exactly
    // as a fill does, so the two cannot disagree about where the ramp sits.
    // A hatch is fill geometry with no stroke meaning (R rejects it for `col`);
    // one arriving from an older scene spec strokes in its rule colour, the same
    // on every backend.
    let paint = gp.col_paint.as_ref().map(|p| match resolve_paint(p, vp) {
        ResolvedPaint::Hatch { col, .. } => ResolvedPaint::Solid(col),
        rp => rp,
    });
    StrokeStyle {
        width,
        dash,
        cap: gp.lineend,
        join: gp.linejoin,
        miter: gp.linemitre as f32,
        crisp: gp.crisp,
        paint,
        phase: {
            let ph = gp.dash_phase as f32 * gp.lwd_px(vp.dpi);
            if ph.is_finite() {
                ph
            } else {
                0.0
            }
        },
    }
}

/// Resolve a paint's gradient geometry through the viewport into local px.
/// Fill a path, expanding a hatch paint into stroked spans.
///
/// A hatch is geometry rather than a tile, and every backend already knows how
/// to stroke, so it is expanded here in the shared walk instead of becoming a
/// primitive each backend must implement. One consequence worth knowing: SVG
/// gets one `<path>` of spans rather than a `<pattern>` reference.
pub(super) fn fill_or_hatch<B: RenderBackend>(
    b: &mut B,
    path: &tiny_skia::Path,
    t: Transform,
    paint: &ResolvedPaint,
    rule: FillRule,
    clip: &Clip,
) {
    let (angle, spacing, width, col, bg) = match paint {
        ResolvedPaint::Hatch {
            angle,
            spacing,
            width,
            col,
            bg,
        } => (*angle, *spacing, *width, *col, *bg),
        _ => {
            b.fill_path(path, t, paint, rule, clip);
            return;
        }
    };
    // An opaque background behind the rules, when asked for: a hatch over white
    // and a hatch over the map beneath it are different designs.
    if let Some(c) = bg {
        b.fill_path(path, t, &ResolvedPaint::Solid(c), rule, clip);
    }
    if let Some(lines) = crate::render::hatch_path(path, angle, spacing) {
        let style = StrokeStyle {
            width: width as f32,
            dash: Vec::new(),
            cap: crate::color::LineCap::Butt,
            join: crate::color::LineJoin::Round,
            miter: 10.0,
            crisp: false,
            paint: None,
            phase: 0.0,
        };
        b.stroke_lines(&lines, t, col, &style, clip);
    }
}

pub(super) fn resolve_paint(paint: &Paint, vp: &Vp) -> ResolvedPaint {
    match paint {
        Paint::Solid(c) => ResolvedPaint::Solid(*c),
        // Spacing and width arrive in device px already (scaled R-side from
        // points, like the text halo), so there is nothing to resolve.
        Paint::Hatch {
            angle,
            spacing,
            width,
            col,
            bg,
        } => ResolvedPaint::Hatch {
            angle: *angle,
            spacing: *spacing,
            width: *width,
            col: *col,
            bg: *bg,
        },
        Paint::Linear {
            x1,
            y1,
            x2,
            y2,
            unit,
            stops,
            extend,
        } => ResolvedPaint::Linear {
            x1: vp.x_pos(*x1, *unit),
            y1: vp.y_pos(*y1, *unit),
            x2: vp.x_pos(*x2, *unit),
            y2: vp.y_pos(*y2, *unit),
            stops: stops.clone(),
            extend: *extend,
        },
        Paint::Radial {
            cx,
            cy,
            r,
            fx,
            fy,
            fr,
            unit,
            stops,
            extend,
        } => ResolvedPaint::Radial {
            cx: vp.x_pos(*cx, *unit),
            cy: vp.y_pos(*cy, *unit),
            r: vp.r_len(*r, *unit),
            fx: vp.x_pos(*fx, *unit),
            fy: vp.y_pos(*fy, *unit),
            fr: vp.r_len(*fr, *unit),
            stops: stops.clone(),
            extend: *extend,
        },
        Paint::Pattern(p) => {
            let (mut x, mut y) = (vp.x_pos(p.x, p.unit), vp.y_pos(p.y, p.unit));
            let (mut w, mut h) = (vp.x_len(p.w, p.unit), vp.y_len(p.h, p.unit));
            // A reflected pattern was turned into a 2x2 mirrored tile at parse
            // time: the tile now spans two cells each way from the same top-left.
            if p.mirrored {
                x += w / 2.0;
                y += h / 2.0;
                w *= 2.0;
                h *= 2.0;
            }
            ResolvedPaint::Pattern {
                tile: p.tile.clone(),
                tw: p.tw,
                th: p.th,
                x,
                y,
                w,
                h,
                extend: p.extend,
                opacity: p.opacity as f32,
            }
        }
    }
}

/// Resolve sketch options to device pixels for a given render (dpi + gpar): the
/// wobble amplitude and any explicit fill weight / hachure gap scale with dpi so
/// the look is resolution-independent; an auto fill weight derives from `lwd`.
pub(super) fn resolve_sketch(
    o: &crate::sketch::SketchOpts,
    gp: &Gpar,
    dpi: f64,
) -> crate::sketch::SketchOpts {
    let s = dpi / 96.0;
    let mut r = o.clone();
    r.max_offset = o.max_offset * s;
    r.fill_weight = if o.fill_weight > 0.0 {
        o.fill_weight * s
    } else {
        (gp.lwd_px(dpi) as f64 * 0.5).max(0.5 * s)
    };
    if o.hachure_gap > 0.0 {
        r.hachure_gap = o.hachure_gap * s;
    }
    r
}

/// Paint a generated [`crate::sketch::Sketched`] through the backend: the solid
/// fill region (or hachure lines in the fill colour) first, then the wobbly
/// outline in `col`/`lwd`. Hachure lines are supported only for a solid fill
/// colour; a gradient/pattern fill degrades to a solid region fill.
pub(super) fn paint_sketch<B: RenderBackend>(
    b: &mut B,
    s: &crate::sketch::Sketched,
    gp: &Gpar,
    t: Transform,
    clip: &Clip,
    vp: &Vp,
    fill_weight: f64,
) {
    if let Some(fill) = &gp.fill {
        let hachure_col = if s.fill_sketch.is_empty() {
            None
        } else {
            match fill {
                Paint::Solid(c) => Some(*c),
                _ => None,
            }
        };
        match hachure_col {
            Some(c) => {
                let mut style = stroke_style(gp, vp);
                style.width = fill_weight.max(0.1) as f32;
                style.dash = Vec::new();
                for p in &s.fill_sketch {
                    b.stroke_path(p, t, c, &style, clip);
                }
            }
            None => {
                if let Some(region) = &s.fill_solid {
                    fill_or_hatch(
                        b,
                        region,
                        t,
                        &resolve_paint(fill, vp),
                        FillRule::Winding,
                        clip,
                    );
                }
            }
        }
    }
    if let Some(col) = gp.col {
        let style = stroke_style(gp, vp);
        if style.width > 0.0 {
            for p in &s.stroke {
                b.stroke_path(p, t, col, &style, clip);
            }
        }
    }
}

/// Draw a hand-drawn (sketch) polyline (open path) in `col`/`lwd`. SK1: ignores
/// per-line offset/caps/arrows (documented) — the wobble is the whole point.
#[allow(clippy::too_many_arguments)]
/// Draw a variable-width stroke: build the ribbon outline for a per-vertex
/// half-width profile and FILL it.
///
/// A stroke whose width varies along its length is not something any backend can
/// stroke -- raster, SVG and PDF alike take one width per path -- so it is
/// generated as an outline and filled. The upside is that it degrades nowhere:
/// all three backends get the same geometry, unlike the group effects.
///
/// The geometry is `ribbon.rs`'s, unchanged: external common tangents (not
/// perpendicular offsets, which waist a taper), every contour wound CCW, and one
/// non-zero self-union to resolve tight bends and the inner side of each join.
pub(super) fn draw_var_stroke<B: RenderBackend>(
    b: &mut B,
    x: &[f64],
    y: &[f64],
    xu: &[Unit],
    yu: &[Unit],
    hw: &[f64],
    gp: &Gpar,
    t: Transform,
    clip: &Clip,
    vp: &Vp,
) {
    // Painted with the STROKE colour: this is a stroke that happens to be drawn
    // as a fill, so a gradient/pattern `col` paints the ribbon the way it would
    // ramp along the stroke.
    let paint = match (&gp.col_paint, gp.col) {
        (Some(p), _) => resolve_paint(p, vp),
        (None, Some(c)) => ResolvedPaint::Solid(c),
        (None, None) => return,
    };
    let n = x
        .len()
        .min(y.len())
        .min(xu.len())
        .min(yu.len())
        .min(hw.len());
    if n < 2 {
        return;
    }
    let half = gp.lwd_px(vp.dpi) as f64 * 0.5;
    let (mut px, mut py, mut phw) = (
        Vec::with_capacity(n),
        Vec::with_capacity(n),
        Vec::with_capacity(n),
    );
    for i in 0..n {
        let (a, c) = (vp.x_pos(x[i], xu[i]), vp.y_pos(y[i], yu[i]));
        if !a.is_finite() || !c.is_finite() || !hw[i].is_finite() {
            continue;
        }
        px.push(a);
        py.push(c);
        // `hw` is a multiplier of the RESOLVED lwd (which may be inherited), and
        // `lwd_px` already carries the `dpi / 96` convention. Half, because the
        // generator offsets each side by a half-width.
        phw.push((half * hw[i]).max(0.0));
    }
    if px.len() < 2 {
        return;
    }
    let nib = crate::ribbon::Nib {
        cap: match gp.lineend {
            crate::color::LineCap::Butt => crate::ribbon::Cap::Butt,
            crate::color::LineCap::Square => crate::ribbon::Cap::Square,
            _ => crate::ribbon::Cap::Round,
        },
        join: match gp.linejoin {
            crate::color::LineJoin::Mitre => crate::ribbon::Join::Miter,
            crate::color::LineJoin::Bevel => crate::ribbon::Join::Bevel,
            _ => crate::ribbon::Join::Round,
        },
        miter: gp.linemitre,
        arc: 0,
    };
    // `Node::Lines` is an open polyline; a closed ring comes through `Polygon`.
    let (ox, oy, onper) =
        crate::ribbon::variable_stroke(&px, &py, &[px.len() as i32], &phw, false, &nib);
    let mut pb = PathBuilder::new();
    let mut at = 0usize;
    for &cnt in &onper {
        let cnt = cnt.max(0) as usize;
        if cnt >= 3 && at + cnt <= ox.len() {
            pb.move_to(ox[at] as f32, oy[at] as f32);
            for j in 1..cnt {
                pb.line_to(ox[at + j] as f32, oy[at + j] as f32);
            }
            pb.close();
        }
        at += cnt;
    }
    if let Some(path) = pb.finish() {
        // Non-zero: what `variable_stroke` already unioned the contours under.
        fill_or_hatch(b, &path, t, &paint, FillRule::Winding, clip);
    }
}

pub(super) fn draw_sketch_polyline<B: RenderBackend>(
    b: &mut B,
    x: &[f64],
    y: &[f64],
    xu: &[Unit],
    yu: &[Unit],
    gp: &Gpar,
    sk: &crate::sketch::SketchOpts,
    t: Transform,
    clip: &Clip,
    vp: &Vp,
) {
    let Some(col) = gp.col else {
        return;
    };
    let n = x.len().min(y.len()).min(xu.len()).min(yu.len());
    let pts: Vec<(f64, f64)> = (0..n)
        .map(|i| (vp.x_pos(x[i], xu[i]), vp.y_pos(y[i], yu[i])))
        .filter(|p| p.0.is_finite() && p.1.is_finite())
        .collect();
    if pts.len() < 2 {
        return;
    }
    let o = resolve_sketch(sk, gp, vp.dpi);
    let s = crate::sketch::polyline(&pts, &o);
    let style = stroke_style(gp, vp);
    if style.width > 0.0 {
        for p in &s.stroke {
            b.stroke_path(p, t, col, &style, clip);
        }
    }
}

/// Draw a hand-drawn (sketch) closed shape from one or more rings (already in
/// local px). Handles outline + fill (hachure or solid).
pub(super) fn draw_sketch_rings<B: RenderBackend>(
    b: &mut B,
    rings: &[Vec<(f64, f64)>],
    gp: &Gpar,
    sk: &crate::sketch::SketchOpts,
    t: Transform,
    clip: &Clip,
    vp: &Vp,
) {
    let o = resolve_sketch(sk, gp, vp.dpi);
    let s = crate::sketch::rings(rings, &o, gp.fill.is_some());
    paint_sketch(b, &s, gp, t, clip, vp, o.fill_weight);
}

/// Append one arrowhead at `(px, py)` whose line travels in direction `(dx, dy)`
/// (pointing toward the head). Open heads add two barb strokes to `open`; closed
/// heads add a filled triangle to `fill`.
fn push_arrow_head(
    open: &mut PathBuilder,
    fill: &mut PathBuilder,
    a: &Arrow,
    dpi: f64,
    px: f32,
    py: f32,
    dx: f64,
    dy: f64,
) {
    let mag = (dx * dx + dy * dy).sqrt();
    if mag < 1e-9 {
        return;
    }
    let (bx, by) = (-dx / mag, -dy / mag); // unit vector back along the line
    let ang = a.angle.to_radians();
    let (ca, sa) = (ang.cos(), ang.sin());
    let l = a.len * dpi;
    let b1 = (
        px + ((bx * ca - by * sa) * l) as f32,
        py + ((bx * sa + by * ca) * l) as f32,
    );
    let b2 = (
        px + ((bx * ca + by * sa) * l) as f32,
        py + ((-bx * sa + by * ca) * l) as f32,
    );
    if a.closed {
        fill.move_to(px, py);
        fill.line_to(b1.0, b1.1);
        fill.line_to(b2.0, b2.1);
        fill.close();
    } else {
        open.move_to(b1.0, b1.1);
        open.line_to(px, py);
        open.move_to(b2.0, b2.1);
        open.line_to(px, py);
    }
}

/// Draw the arrowheads for a polyline / batch of segments: `ends` is a list of
/// `(point, incoming-direction)` already resolved to local px. Open barbs stroke
/// in `col`; closed heads fill with `col` (and outline). Shared by both nodes.
/// Set one shaped run along a polyline baseline.
///
/// Each glyph keeps the pen position shaping gave it (`gx[i]`, device px) and is
/// re-placed at the point that far along the resolved path, rotated to the local
/// tangent. The run is emitted one glyph at a time through the backend's normal
/// `draw_text`, so raster, SVG and PDF all get correct output — including halos,
/// per-glyph colours and clipping — without any backend changes.
///
/// Assumes one glyph per character: the per-glyph label slice used for PDF
/// `ToUnicode` and SVG `<text>` falls back to the whole label if shaping produced
/// a different glyph count (ligatures, complex scripts), which is why
/// `text_path_grob()` documents itself as Latin-oriented.
pub(super) fn draw_text_on_path<B: RenderBackend>(
    b: &mut B,
    run: &TextRun,
    tp: &TextPath,
    vp: &Vp,
    t: Transform,
    clip: &Clip,
) {
    let n = run
        .gid
        .len()
        .min(run.gx.len())
        .min(run.gy.len())
        .min(run.gsize.len())
        .min(run.gpath.len())
        .min(run.gface.len());
    if n == 0 {
        return;
    }
    // Resolve the baseline to device px, dropping repeated points (a zero-length
    // segment has no tangent).
    let mut ptx: Vec<f64> = Vec::with_capacity(tp.px.len());
    let mut pty: Vec<f64> = Vec::with_capacity(tp.py.len());
    for i in 0..tp.px.len().min(tp.py.len()) {
        let (qx, qy) = (
            vp.x_pos(
                tp.px[i],
                tp.pxu
                    .get(i)
                    .copied()
                    .unwrap_or(Unit::from_code_off(0, 0.0)),
            ),
            vp.y_pos(
                tp.py[i],
                tp.pyu
                    .get(i)
                    .copied()
                    .unwrap_or(Unit::from_code_off(0, 0.0)),
            ),
        );
        if let (Some(&lx), Some(&ly)) = (ptx.last(), pty.last()) {
            if (qx - lx).abs() < 1e-9 && (qy - ly).abs() < 1e-9 {
                continue;
            }
        }
        ptx.push(qx);
        pty.push(qy);
    }
    if ptx.len() < 2 {
        return;
    }
    // Cumulative arc length at each vertex.
    let mut cum: Vec<f64> = Vec::with_capacity(ptx.len());
    cum.push(0.0);
    for i in 1..ptx.len() {
        let d = ((ptx[i] - ptx[i - 1]).powi(2) + (pty[i] - pty[i - 1]).powi(2)).sqrt();
        cum.push(cum[i - 1] + d);
    }
    let total = *cum.last().expect("cum is non-empty");
    if total <= 0.0 {
        return;
    }
    // `hjust` slides the run along the baseline, mirroring what it does to a
    // straight label: 0 starts at the path start, 1 ends at the path end.
    let start = run.hjust * (total - run.w);
    // Perpendicular offset, points -> device px, same scale glyph sizes use.
    let off_px = tp.offset * vp.dpi / 72.0;

    // Point and tangent angle (radians, +y down in device space) at arc length s.
    let at = |s: f64| -> (f64, f64, f64) {
        let s = s.clamp(0.0, total);
        let mut k =
            match cum.binary_search_by(|v| v.partial_cmp(&s).unwrap_or(std::cmp::Ordering::Less)) {
                Ok(i) => i,
                Err(i) => i.saturating_sub(1),
            };
        k = k.min(ptx.len() - 2);
        let seg = cum[k + 1] - cum[k];
        let u = if seg > 0.0 { (s - cum[k]) / seg } else { 0.0 };
        let (dx, dy) = (ptx[k + 1] - ptx[k], pty[k + 1] - pty[k]);
        (ptx[k] + u * dx, pty[k] + u * dy, dy.atan2(dx))
    };

    let bounds: Vec<usize> = run
        .label
        .char_indices()
        .map(|(bi, _)| bi)
        .chain(std::iter::once(run.label.len()))
        .collect();
    let exact = n + 1 == bounds.len();

    // Two rounds when there is a halo: every glyph stroked, then every glyph
    // filled.
    //
    // Fanning one run out into per-glyph runs quietly broke the invariant the
    // raster backend spells out for ordinary text -- "every glyph is stroked
    // before *any* is filled, so a wide halo on one glyph cannot paint over the
    // neighbour that was already filled". Doing stroke-then-fill per glyph meant
    // each glyph's halo chewed into the previous one, which on a tight curve ate
    // the letters visibly.
    //
    // Round 1 asks for a stroke with a fully transparent fill; round 2 fills with
    // no halo. Unhaloed text runs round 2 only, so the common path is unchanged.
    let passes: &[bool] = if run.halo.is_some() {
        &[true, false]
    } else {
        &[false]
    };
    for &halo_pass in passes {
        for i in 0..n {
            let (cx, cy, ang) = at(start + run.gx[i]);
            // Glyphs follow the tangent unconditionally, which is what SVG
            // `textPath` does: on the underside of a closed curve they read
            // upside-down. Flipping them individually would turn the run into
            // mirror-writing, so the fix is to reverse the path, not the glyph.
            // Normal to the path, pointing left of travel in device space (+y down).
            let (nx, ny) = (ang.sin() * off_px, -ang.cos() * off_px);
            let glyph_label: &str = if exact {
                &run.label[bounds[i]..bounds[i + 1]]
            } else {
                run.label
            };
            let one = TextRun {
                // `w = 0` with `hjust = 0` puts this glyph's pen exactly at (ax, ay);
                // the along-path offset is already baked into the point.
                ax: cx + nx,
                ay: cy + ny,
                w: 0.0,
                h: run.h,
                hjust: 0.0,
                vjust: run.vjust,
                // Device y grows downward, `rot` is counter-clockwise in user space.
                rot: -ang.to_degrees(),
                // A transparent fill on the halo pass leaves the stroke alone.
                color: if halo_pass { TRANSPARENT } else { run.color },
                gid: &run.gid[i..i + 1],
                gx: &ZERO_GX,
                gy: &run.gy[i..i + 1],
                gsize: &run.gsize[i..i + 1],
                gpath: &run.gpath[i..i + 1],
                gface: &run.gface[i..i + 1],
                gcolor: if halo_pass {
                    &[]
                } else if run.gcolor.len() > i {
                    &run.gcolor[i..i + 1]
                } else {
                    &[]
                },
                // tex() labels can't be set on a path (text_path_grob takes
                // plain strings), so a path run never has rules or gtext.
                rules: &[],
                gtext: "",
                spans: &[],
                halo: if halo_pass { run.halo } else { None },
                label: glyph_label,
                family: run.family,
                face: run.face,
                size: run.size,
                dpi: run.dpi,
            };
            b.draw_text(&one, t, clip);
        }
    }
}

/// A fully transparent fill, for the halo-only pass of on-path text.
const TRANSPARENT: Rgba = Rgba {
    r: 0,
    g: 0,
    b: 0,
    a: 0,
};

/// The single-element `gx` every on-path glyph uses (its pen offset is folded
/// into the anchor instead).
static ZERO_GX: [f64; 1] = [0.0];

pub(super) fn draw_arrows<B: RenderBackend>(
    b: &mut B,
    arrow: &Arrow,
    ends: &[(f32, f32, f64, f64)],
    col: Rgba,
    style: &StrokeStyle,
    t: Transform,
    clip: &Clip,
    dpi: f64,
) {
    let mut open = PathBuilder::new();
    let mut fill = PathBuilder::new();
    for &(px, py, dx, dy) in ends {
        push_arrow_head(&mut open, &mut fill, arrow, dpi, px, py, dx, dy);
    }
    if let Some(path) = open.finish() {
        if style.width > 0.0 {
            b.stroke_lines(&path, t, col, style, clip);
        }
    }
    if let Some(path) = fill.finish() {
        fill_or_hatch(
            b,
            &path,
            t,
            &ResolvedPaint::Solid(col),
            FillRule::Winding,
            clip,
        );
        if style.width > 0.0 {
            b.stroke_lines(&path, t, col, style, clip);
        }
    }
}
