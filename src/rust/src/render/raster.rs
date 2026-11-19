//! The tiny-skia raster backend (PNG and in-memory RGBA).

use super::*;

/// Snap a device coordinate so a stroke of `width` covers whole pixels: an
/// odd-pixel-wide stroke wants its centre on a half-integer, an even one on an
/// integer. Only meaningful for axis-parallel edges.
fn snap_coord(v: f32, width: f32) -> f32 {
    let w = width.round().max(1.0);
    if (w as i32) % 2 == 1 {
        v.floor() + 0.5
    } else {
        v.round()
    }
}

fn skia_cap(c: LineCap) -> tiny_skia::LineCap {
    match c {
        LineCap::Round => tiny_skia::LineCap::Round,
        LineCap::Butt => tiny_skia::LineCap::Butt,
        LineCap::Square => tiny_skia::LineCap::Square,
    }
}

fn skia_join(j: LineJoin) -> tiny_skia::LineJoin {
    match j {
        LineJoin::Round => tiny_skia::LineJoin::Round,
        LineJoin::Mitre => tiny_skia::LineJoin::Miter,
        LineJoin::Bevel => tiny_skia::LineJoin::Bevel,
    }
}

fn skia_stroke(s: &StrokeStyle) -> Stroke {
    Stroke {
        width: s.width,
        miter_limit: s.miter,
        line_cap: skia_cap(s.cap),
        line_join: skia_join(s.join),
        dash: if s.dash.is_empty() {
            None
        } else {
            StrokeDash::new(s.dash.clone(), s.phase)
        },
        ..Stroke::default()
    }
}

fn skia_masktype(k: MaskKind) -> tiny_skia::MaskType {
    match k {
        MaskKind::Alpha => tiny_skia::MaskType::Alpha,
        MaskKind::Luminance => tiny_skia::MaskType::Luminance,
    }
}

// --- shared geometry helpers ------------------------------------------------

/// Render a solid AA circle of radius `r` (device px) into a tight square sprite,
/// centred. Used to stamp large uniform point clouds instead of filling each.
fn circle_sprite(r: f64, color: Rgba) -> Option<Pixmap> {
    let dim = ((r + 1.0) * 2.0).ceil() as u32; // +1px AA padding
    let mut pm = Pixmap::new(dim, dim)?;
    let c = dim as f32 / 2.0;
    let mut pb = PathBuilder::new();
    pb.push_circle(c, c, r as f32);
    let path = pb.finish()?;
    let mut paint = Paint::default();
    paint.set_color(color.to_skia());
    // Always AA: this sprite is cached and shared across grobs, so it must not
    // bake in one grob's `antialias` setting. Haloed/aliased text takes the exact
    // outline path instead.
    paint.anti_alias = true;
    pm.fill_path(
        &path,
        &paint,
        FillRule::Winding,
        Transform::identity(),
        None,
    );
    Some(pm)
}

/// The tile -> local-px transform: scale the `tw` x `th` tile into a `w` x `h`
/// cell centred at `(x, y)`. The backend's draw transform then maps local->device.
fn pattern_transform(tw: u32, th: u32, x: f64, y: f64, w: f64, h: f64) -> Transform {
    Transform::from_row(
        (w / tw as f64) as f32,
        0.0,
        0.0,
        (h / th as f64) as f32,
        (x - w / 2.0) as f32,
        (y - h / 2.0) as f32,
    )
}

/// A fully-visible (all-255) page-sized mask, the starting point for clipping.
fn page_mask(w: u32, h: u32) -> Mask {
    let mut m = Mask::new(w, h).expect("non-zero mask dimensions");
    if let Some(p) = rect_path(0.0, 0.0, w as f64, h as f64) {
        m.fill_path(&p, FillRule::Winding, true, Transform::identity());
    }
    m
}

// --- raster backend ---------------------------------------------------------

pub struct RasterBackend {
    /// A stack of draw targets: `targets[0]` is the page; `begin_group` pushes an
    /// isolated layer that drawing then targets until `end_group` composites it.
    targets: Vec<Pixmap>,
    /// Per-open-group mask, opacity, and blend mode (parallel to the layer stack
    /// above the page); applied when the group closes.
    group_masks: Vec<Option<MaskLayer>>,
    group_alpha: Vec<f32>,
    group_blend: Vec<BlendKind>,
    group_effect: Vec<GroupEffect>,
    /// Bounded LRU of compiled clip masks (most-recent first). tiny-skia requires
    /// a clip `Mask` to match the target pixmap size, so each entry is page-sized
    /// and cannot be shrunk to a bounding box; instead we cap how many stay
    /// resident. Primitives sharing a clip are drawn contiguously, so a small
    /// cache captures essentially all reuse while keeping memory bounded on pages
    /// with very many distinct clips or deep clip trees.
    clip_cache: Vec<(usize, Option<Rc<Mask>>)>,
    w: u32,
    h: u32,
    /// Glyph-bitmap fast path enabled? Set only on the page backend (never on
    /// mask/measurement backends — a colour-baked sprite would corrupt what a
    /// luminance mask reads). See `draw_text`.
    bitmap_text: bool,
}

/// Max page-sized clip masks kept resident at once (see `clip_cache`).
const CLIP_CACHE_CAP: usize = 8;

/// Most segments stroked as one path on the raster fast path. Long enough that a
/// contour or a typical line is a single run (and so identical to the combined
/// stroke), short enough that a run of a page-spanning scribble stays local.
const STROKE_RUN: usize = 256;

/// Stroke a polyline (user-space vertices) as one round-capped, round-joined
/// path per [`STROKE_RUN`] segments.
///
/// Adjacent runs share a vertex, and each draws a round cap there. Inside the
/// cap both are fully covered, which blends idempotently, but the antialiased
/// pixels on the cap's rim are blended twice and come out darker: a faint bead at
/// every joint. So before drawing, keep the pixels in a small box around each
/// joint; after drawing, put them back and stroke every segment near the joint
/// over them as one path, which is what the combined stroke draws there. Outside
/// those boxes the result is exactly the runs; inside, exactly one stroke.
fn stroke_polyline(
    target: &mut Pixmap,
    pts: &[(f32, f32)],
    paint: &Paint,
    sk: &Stroke,
    transform: Transform,
    mask: Option<&Mask>,
) {
    let nseg = pts.len().saturating_sub(1);
    if nseg == 0 {
        return;
    }
    let stroke_range = |target: &mut Pixmap, a: usize, b: usize| {
        let mut pb = PathBuilder::new();
        pb.move_to(pts[a].0, pts[a].1);
        for &(x, y) in &pts[a + 1..=b] {
            pb.line_to(x, y);
        }
        if let Some(p) = pb.finish() {
            target.stroke_path(&p, paint, sk, transform, mask);
        }
    };
    if nseg <= STROKE_RUN {
        stroke_range(target, 0, nseg);
        return;
    }

    // Device-space geometry: the vertices, and a half-width that bounds the
    // stroke under any scale or skew in `transform`.
    let dev: Vec<(f32, f32)> = pts
        .iter()
        .map(|&(x, y)| {
            let mut p = tiny_skia::Point::from_xy(x, y);
            transform.map_point(&mut p);
            (p.x, p.y)
        })
        .collect();
    let scale = (transform.sx.hypot(transform.ky)).max(transform.kx.hypot(transform.sy));
    let half_w = sk.width * scale * 0.5;
    // Every doubly blended pixel lies within a cap radius plus its antialiasing
    // of the joint vertex.
    let reach = half_w + 2.0;
    let (pw, ph) = (target.width() as i32, target.height() as i32);
    struct Joint {
        v: (f32, f32),
        x0: i32,
        y0: i32,
        w: u32,
        h: u32,
        saved: Vec<u8>,
    }
    let stride = pw as usize * 4;
    let mut joints: Vec<Joint> = Vec::new();
    let mut k = STROKE_RUN;
    while k < nseg {
        let v = dev[k];
        let x0 = ((v.0 - reach).floor() as i32).max(0);
        let y0 = ((v.1 - reach).floor() as i32).max(0);
        let x1 = ((v.0 + reach).ceil() as i32).min(pw);
        let y1 = ((v.1 + reach).ceil() as i32).min(ph);
        if v.0.is_finite() && v.1.is_finite() && x1 > x0 && y1 > y0 {
            let (w, h) = ((x1 - x0) as u32, (y1 - y0) as u32);
            let mut saved = Vec::with_capacity(w as usize * h as usize * 4);
            let data = target.data();
            for row in y0..y1 {
                let at = row as usize * stride + x0 as usize * 4;
                saved.extend_from_slice(&data[at..at + w as usize * 4]);
            }
            joints.push(Joint {
                v,
                x0,
                y0,
                w,
                h,
                saved,
            });
        }
        k += STROKE_RUN;
    }

    let mut a = 0;
    while a < nseg {
        let b = (a + STROKE_RUN).min(nseg);
        stroke_range(target, a, b);
        a = b;
    }

    // A segment can touch a joint's box if it passes within the box's corner
    // radius plus the stroke's half-width (and a pixel of antialiasing).
    let near = reach * std::f32::consts::SQRT_2 + half_w + 1.5;
    for j in joints {
        let Some(mut scratch) = Pixmap::new(j.w, j.h) else {
            continue;
        };
        scratch.data_mut().copy_from_slice(&j.saved);
        // Every segment near the joint, grouped into consecutive pieces. A far
        // part of the polyline crossing the box is included too, so restoring
        // the box cannot erase it.
        let mut pb = PathBuilder::new();
        let mut open = false;
        for i in 0..nseg {
            if seg_dist(j.v, dev[i], dev[i + 1]) <= near {
                if !open {
                    pb.move_to(pts[i].0, pts[i].1);
                    open = true;
                }
                pb.line_to(pts[i + 1].0, pts[i + 1].1);
            } else {
                open = false;
            }
        }
        let Some(local) = pb.finish() else {
            continue;
        };
        let local_mask = mask.and_then(|m| {
            let mut lm = Mask::new(j.w, j.h)?;
            let mw = m.width() as usize;
            for row in 0..j.h as usize {
                let src = (j.y0 as usize + row) * mw + j.x0 as usize;
                lm.data_mut()[row * j.w as usize..(row + 1) * j.w as usize]
                    .copy_from_slice(&m.data()[src..src + j.w as usize]);
            }
            Some(lm)
        });
        let t = transform.post_translate(-(j.x0 as f32), -(j.y0 as f32));
        scratch.stroke_path(&local, paint, sk, t, local_mask.as_ref());
        let data = target.data_mut();
        let row_len = j.w as usize * 4;
        for row in 0..j.h as usize {
            let at = (j.y0 as usize + row) * stride + j.x0 as usize * 4;
            data[at..at + row_len]
                .copy_from_slice(&scratch.data()[row * row_len..(row + 1) * row_len]);
        }
    }
}

/// Distance from `p` to the segment `a`-`b` (device px).
fn seg_dist(p: (f32, f32), a: (f32, f32), b: (f32, f32)) -> f32 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let len2 = dx * dx + dy * dy;
    let t = if len2 > 0.0 {
        (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / len2).clamp(0.0, 1.0)
    } else {
        0.0
    };
    (p.0 - a.0 - t * dx).hypot(p.1 - a.1 - t * dy)
}

impl RasterBackend {
    pub fn new(w: u32, h: u32, bg: Rgba) -> Self {
        // Clamp to >=1 so a 0-sized target can't panic here (page dimensions are
        // already validated to >=1 by px_dim; this guards the constructor directly
        // and keeps the stored w/h — reused for every group/subraster layer and
        // clip mask below — non-zero). A valid render is unaffected.
        let (w, h) = (w.max(1), h.max(1));
        let mut pm = Pixmap::new(w, h).expect("non-zero pixmap dimensions");
        // `Pixmap::new` is already zeroed (transparent); only paint a non-empty
        // background. This skips a full-page write for every rasterized mask,
        // whose backdrop is always transparent.
        if bg.a != 0 {
            pm.fill(bg.to_skia());
        }
        RasterBackend {
            targets: vec![pm],
            group_masks: Vec::new(),
            group_alpha: Vec::new(),
            group_effect: Vec::new(),
            group_blend: Vec::new(),
            clip_cache: Vec::new(),
            w,
            h,
            bitmap_text: false,
        }
    }

    /// Enable the glyph-bitmap fast path for this backend (page backend only).
    pub fn set_bitmap_text(&mut self, on: bool) {
        self.bitmap_text = on;
    }

    pub fn into_pixmap(mut self) -> Pixmap {
        // Balanced groups leave only the page; if not, the base is still first.
        self.targets.swap_remove(0)
    }

    fn target(&mut self) -> &mut Pixmap {
        self.targets.last_mut().expect("at least the page target")
    }

    fn mask_for(&mut self, clip: &Clip) -> Option<Rc<Mask>> {
        if clip.shapes.is_empty() {
            return None;
        }
        if let Some(pos) = self.clip_cache.iter().position(|(id, _)| *id == clip.id) {
            // Cache hit: promote to most-recent and return.
            let entry = self.clip_cache.remove(pos);
            let val = entry.1.clone();
            self.clip_cache.insert(0, entry);
            return val;
        }
        let mut m = page_mask(self.w, self.h);
        for shape in clip.shapes {
            match shape {
                ClipShape::Rect { w, h, transform } => match rect_path(0.0, 0.0, *w, *h) {
                    Some(rect) => m.intersect_path(&rect, FillRule::Winding, true, *transform),
                    None => m.clear(),
                },
                ClipShape::Path {
                    path,
                    evenodd,
                    transform,
                } => {
                    let rule = if *evenodd {
                        FillRule::EvenOdd
                    } else {
                        FillRule::Winding
                    };
                    m.intersect_path(path, rule, true, *transform);
                }
            }
        }
        let m = Some(Rc::new(m));
        // Insert most-recent-first; evicting the oldest keeps memory bounded. An
        // evicted mask still in use survives via the Rc the caller already holds.
        self.clip_cache.insert(0, (clip.id, m.clone()));
        self.clip_cache.truncate(CLIP_CACHE_CAP);
        m
    }
}

fn solid_paint(color: Rgba) -> Paint<'static> {
    let mut paint = Paint::default();
    paint.set_color(color.to_skia());
    paint.anti_alias = antialias();
    paint
}

fn skia_spread(extend: Extend) -> tiny_skia::SpreadMode {
    match extend {
        Extend::Pad => tiny_skia::SpreadMode::Pad,
        Extend::Repeat => tiny_skia::SpreadMode::Repeat,
        Extend::Reflect => tiny_skia::SpreadMode::Reflect,
    }
}

fn skia_stops(stops: &[Stop]) -> Vec<tiny_skia::GradientStop> {
    stops
        .iter()
        .map(|s| tiny_skia::GradientStop::new(s.offset, s.color.to_skia()))
        .collect()
}

/// Build a tiny-skia paint for a resolved fill. Gradient geometry is in local px
/// with an identity gradient transform; `fill_path`'s ctm maps it like the path.
/// Run `f` with the tiny-skia paint for `paint`, including a tiled pattern,
/// whose shader borrows a tile `Pixmap` and so cannot come out of `paint_for`.
/// `None` when the paint has nothing to draw (a hatch, a degenerate tile).
fn with_paint<R>(paint: &ResolvedPaint, f: impl FnOnce(&Paint) -> R) -> Option<R> {
    if let ResolvedPaint::Pattern {
        tile,
        tw,
        th,
        x,
        y,
        w,
        h,
        extend,
        opacity,
    } = paint
    {
        let pm = pixmap_from_straight(tile, *tw, *th)?;
        let t = pattern_transform(*tw, *th, *x, *y, *w, *h);
        let mut p = Paint::default();
        p.shader = tiny_skia::Pattern::new(
            pm.as_ref(),
            skia_spread(*extend),
            FilterQuality::Bilinear,
            *opacity,
            t,
        );
        p.anti_alias = antialias();
        return Some(f(&p));
    }
    paint_for(paint).map(|p| f(&p))
}

fn paint_for(paint: &ResolvedPaint) -> Option<Paint<'static>> {
    let shader = match paint {
        ResolvedPaint::Solid(c) => return Some(solid_paint(*c)),
        ResolvedPaint::Linear {
            x1,
            y1,
            x2,
            y2,
            stops,
            extend,
        } => tiny_skia::LinearGradient::new(
            tiny_skia::Point::from_xy(*x1 as f32, *y1 as f32),
            tiny_skia::Point::from_xy(*x2 as f32, *y2 as f32),
            skia_stops(stops),
            skia_spread(*extend),
            Transform::identity(),
        ),
        ResolvedPaint::Radial {
            cx,
            cy,
            r,
            fx,
            fy,
            fr,
            stops,
            extend,
        } => tiny_skia::RadialGradient::new(
            // tiny-skia 0.12: new(start_point, start_radius, end_point, end_radius, …).
            // The focal circle `(fx, fy, fr)` is the start (stop offset 0); the outer
            // circle `(cx, cy, r)` is the end (offset 1). A concentric gradient has
            // `fr = 0` and `(fx, fy) == (cx, cy)`.
            tiny_skia::Point::from_xy(*fx as f32, *fy as f32),
            *fr as f32,
            tiny_skia::Point::from_xy(*cx as f32, *cy as f32),
            *r as f32,
            skia_stops(stops),
            skia_spread(*extend),
            Transform::identity(),
        ),
        // Patterns borrow a Pixmap and are handled inline in RasterBackend::fill_path;
        // a hatch is expanded to stroked spans by the walk before it gets here.
        ResolvedPaint::Pattern { .. } | ResolvedPaint::Hatch { .. } => return None,
    }?;
    let mut p = Paint::default();
    p.shader = shader;
    p.anti_alias = antialias();
    Some(p)
}

impl RenderBackend for RasterBackend {
    fn fill_path(
        &mut self,
        path: &Path,
        transform: Transform,
        paint: &ResolvedPaint,
        rule: FillRule,
        clip: &Clip,
    ) {
        let mask = self.mask_for(clip);
        with_paint(paint, |p| {
            self.target()
                .fill_path(path, p, rule, transform, mask.as_deref())
        });
    }

    fn stroke_path(
        &mut self,
        path: &Path,
        transform: Transform,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    ) {
        if stroke.width <= 0.0 {
            return;
        }
        let mask = self.mask_for(clip);
        let sk = skia_stroke(stroke);
        // A gradient/pattern stroke is the same shader a fill would use, applied
        // to the stroked region instead of the enclosed one.
        match &stroke.paint {
            Some(paint) => {
                with_paint(paint, |p| {
                    self.target()
                        .stroke_path(path, p, &sk, transform, mask.as_deref())
                });
            }
            None => {
                let p = solid_paint(color);
                self.target()
                    .stroke_path(path, &p, &sk, transform, mask.as_deref());
            }
        }
    }

    fn stroke_lines(
        &mut self,
        path: &Path,
        transform: Transform,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    ) {
        if stroke.width <= 0.0 {
            return;
        }
        // Fast path for grid's default line style: opaque, solid (no dash), round
        // cap + round join. Stroke each subpath on its own, in runs of at most
        // `RUN` segments. The combined winding-fill pays O(active_edges x height):
        // for a self-intersecting polyline (many outline edges crossing every
        // scanline) or a page-spanning batch of disjoint segments that is the
        // dominant cost, and a short run touches only its own few scanlines.
        //
        // Runs rather than single segments: drawing an overlap twice is only
        // idempotent where coverage is full. An antialiased edge pixel blended
        // twice comes out darker, so stroking every segment separately put a dark
        // bead on each vertex, and a densely sampled thin line (a contour, a
        // smooth curve) looked stippled next to the same line in SVG or PDF. A
        // run is one stroke, so its interior vertices match the combined stroke
        // exactly. Where two runs of a very long polyline meet, both draw a round
        // cap on the shared vertex, which would bead the joint just the same; the
        // joints are redrawn once from a combined stroke (see `stroke_polyline`).
        let fast = color.a == 255
            && stroke.paint.is_none() // a shader must see the whole path at once
            && stroke.dash.is_empty()
            && matches!(stroke.cap, LineCap::Round)
            && matches!(stroke.join, LineJoin::Round);
        if !fast {
            self.stroke_path(path, transform, color, stroke, clip);
            return;
        }
        let mask = self.mask_for(clip);
        let sk = skia_stroke(stroke);
        let paint = solid_paint(color); // fast path: no stroke paint
        let target = self.targets.last_mut().expect("at least the page target");
        use tiny_skia::PathSegment;
        // The current subpath's vertices, stroked when the next one starts.
        let mut pts: Vec<(f32, f32)> = Vec::new();
        let mut prev: Option<(f32, f32)> = None;
        for seg in path.segments() {
            match seg {
                PathSegment::MoveTo(p) => {
                    stroke_polyline(target, &pts, &paint, &sk, transform, mask.as_deref());
                    pts.clear();
                    prev = Some((p.x, p.y));
                }
                PathSegment::LineTo(p) => {
                    let Some((ax, ay)) = prev else {
                        prev = Some((p.x, p.y));
                        continue;
                    };
                    if stroke.crisp {
                        // Crisp mode: a horizontal or vertical run gets its
                        // constant coordinate snapped so the stroke lands on whole
                        // pixels. Diagonals are left alone -- there is no pixel
                        // grid to snap them to. Snapping moves each segment's ends
                        // independently, so crisp segments stay separate strokes.
                        let dev_w = stroke.width * transform.sx.abs().max(transform.sy.abs());
                        let (ax, ay, bx, by) = if (ay - p.y).abs() < 1e-6 {
                            let sy = (snap_coord(transform.ty + ay * transform.sy, dev_w)
                                - transform.ty)
                                / transform.sy;
                            (ax, sy, p.x, sy)
                        } else if (ax - p.x).abs() < 1e-6 {
                            let sx = (snap_coord(transform.tx + ax * transform.sx, dev_w)
                                - transform.tx)
                                / transform.sx;
                            (sx, ay, sx, p.y)
                        } else {
                            (ax, ay, p.x, p.y)
                        };
                        stroke_polyline(
                            target,
                            &[(ax, ay), (bx, by)],
                            &paint,
                            &sk,
                            transform,
                            mask.as_deref(),
                        );
                    } else {
                        if pts.is_empty() {
                            pts.push((ax, ay));
                        }
                        pts.push((p.x, p.y));
                    }
                    prev = Some((p.x, p.y));
                }
                // Lines/segments are polylines only; curves/closes shouldn't occur,
                // but track the endpoint so any stragglers connect sensibly.
                PathSegment::QuadTo(_, p) | PathSegment::CubicTo(_, _, p) => {
                    prev = Some((p.x, p.y))
                }
                PathSegment::Close => {}
            }
        }
        stroke_polyline(target, &pts, &paint, &sk, transform, mask.as_deref());
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        let mask = self.mask_for(clip);
        let paint = solid_paint(run.color);
        let base = if run.rot != 0.0 {
            transform.pre_concat(rotation_about(run.rot, run.ax, run.ay))
        } else {
            transform
        };
        // Glyph-bitmap fast path (FW: high-distinct-label text). Legal only when
        // `base` is a pure translation — rotated text OR a rotated/scaled viewport
        // both make it non-translation, and must fall back to the exact outline
        // fill (which also keeps SVG/PDF and small renders byte-identical). Large
        // glyphs stay exact (quantisation is visible there; per-blit cost grows).
        const GLYPH_SPRITE_MAX_PX: f64 = 40.0;
        // A sprite bakes the *fill* only, so a halo forces the exact outline path
        // (which is what draws the stroke). Haloed text is rare and usually a
        // handful of labels, so the lost fast path costs nothing in practice.
        let sprite_ok = self.bitmap_text
            && run.halo.is_none()
            && base.sx == 1.0
            && base.sy == 1.0
            && base.kx == 0.0
            && base.ky == 0.0;
        let n = run
            .gid
            .len()
            .min(run.gx.len())
            .min(run.gy.len())
            .min(run.gsize.len())
            .min(run.gpath.len())
            .min(run.gface.len());
        // Halo pass. Every glyph is stroked before *any* is filled, so a wide halo
        // on one glyph cannot paint over the neighbour that was already filled --
        // the same reason SVG needs `paint-order: stroke fill`.
        if let Some((hcol, hw)) = run.halo {
            let hpaint = solid_paint(hcol);
            // Stroke is centred on the outline, so half of it lands inside the
            // glyph and is then covered by the fill. Double the width so `hw` is
            // the visible outer thickness, which is what a caller means by it.
            let stroke = tiny_skia::Stroke {
                width: (hw * 2.0) as f32,
                line_join: tiny_skia::LineJoin::Round,
                line_cap: tiny_skia::LineCap::Round,
                ..Default::default()
            };
            for i in 0..n {
                let outline = match glyph_outline_cached(
                    &run.gpath[i],
                    run.gface[i],
                    run.gid[i],
                    run.gsize[i] as f32,
                ) {
                    Some(p) => p,
                    None => continue,
                };
                let ox = run.ax + run.gx[i] - run.hjust * run.w;
                let oy = run.ay - (run.gy[i] - run.vjust * run.h);
                let place = Transform::from_row(1.0, 0.0, 0.0, -1.0, ox as f32, oy as f32);
                self.targets
                    .last_mut()
                    .expect("at least the page target")
                    .stroke_path(
                        outline.as_ref(),
                        &hpaint,
                        &stroke,
                        base.pre_concat(place),
                        mask.as_deref(),
                    );
            }
        }
        for i in 0..n {
            let ox = run.ax + run.gx[i] - run.hjust * run.w;
            let oy = run.ay - (run.gy[i] - run.vjust * run.h);
            if sprite_ok && run.gsize[i] <= GLYPH_SPRITE_MAX_PX {
                // Device pen; quantise the fraction to a sub-pixel phase, carrying
                // a round-up into the integer cell (round(f*N)==N means f≈1.0).
                let px = base.tx as f64 + ox;
                let py = base.ty as f64 + oy;
                let mut ix = px.floor() as i32;
                let mut iy = py.floor() as i32;
                let mut qx = ((px - ix as f64) * PHASE_X as f64).round() as i32;
                if qx >= PHASE_X as i32 {
                    ix += 1;
                    qx = 0;
                }
                let mut qy = ((py - iy as f64) * PHASE_Y as f64).round() as i32;
                if qy >= PHASE_Y as i32 {
                    iy += 1;
                    qy = 0;
                }
                let c = run.gcolor.get(i).copied().unwrap_or(run.color);
                let cc = [c.r, c.g, c.b, c.a];
                if let Some(sprite) = glyph_sprite_cached(
                    &run.gpath[i],
                    run.gface[i],
                    run.gid[i],
                    run.gsize[i] as f32,
                    cc,
                    qx as u8,
                    qy as u8,
                ) {
                    let pmp = tiny_skia::PixmapPaint::default();
                    self.targets
                        .last_mut()
                        .expect("at least the page target")
                        .draw_pixmap(
                            ix + sprite.dx,
                            iy + sprite.dy,
                            sprite.pixmap.as_ref(),
                            &pmp,
                            Transform::identity(),
                            mask.as_deref(),
                        );
                    continue;
                }
                // sprite None (whitespace / oversize) -> fall through to exact fill.
            }
            let outline = match glyph_outline_cached(
                &run.gpath[i],
                run.gface[i],
                run.gid[i],
                run.gsize[i] as f32,
            ) {
                Some(p) => p,
                None => continue,
            };
            let place = Transform::from_row(1.0, 0.0, 0.0, -1.0, ox as f32, oy as f32);
            // Per-glyph colour for rich labels; otherwise the one shared paint.
            let glyph_paint = match run.gcolor.get(i) {
                Some(&c) => solid_paint(c),
                None => paint.clone(),
            };
            self.targets
                .last_mut()
                .expect("at least the page target")
                .fill_path(
                    outline.as_ref(),
                    &glyph_paint,
                    FillRule::Winding,
                    base.pre_concat(place),
                    mask.as_deref(),
                );
        }
    }

    fn begin_group(
        &mut self,
        mask: Option<MaskLayer>,
        alpha: f32,
        blend: BlendKind,
        effect: GroupEffect,
    ) {
        // A transparent isolated layer; subsequent drawing targets it. The mask,
        // opacity, and blend mode are held until the group closes.
        self.targets
            .push(Pixmap::new(self.w, self.h).expect("non-zero layer dimensions"));
        self.group_masks.push(mask);
        self.group_alpha.push(alpha);
        self.group_blend.push(blend);
        self.group_effect.push(effect);
    }

    fn end_group(&mut self) {
        let mask = self.group_masks.pop().flatten();
        let alpha = self.group_alpha.pop().unwrap_or(1.0);
        let blend = self.group_blend.pop().unwrap_or(BlendKind::Normal);
        let effect = self.group_effect.pop().unwrap_or_default();
        let layer = match self.targets.pop() {
            Some(l) if !self.targets.is_empty() => l,
            other => {
                // Unbalanced end_group: nothing to composite onto. Restore and bail.
                if let Some(l) = other {
                    self.targets.push(l);
                }
                return;
            }
        };
        let mut layer = layer;
        // Shadow first: the group's own coverage, tinted and blurred, painted
        // underneath. Derived from the layer *before* it is blurred, so a blurred
        // group still casts a sharp-ish shadow of its own shape.
        let shadow_pm = effect.shadow.map(|sh| {
            let mut sp = Pixmap::new(self.w, self.h).expect("non-zero layer dimensions");
            // Recolour the layer's alpha with the shadow colour: the silhouette,
            // not the artwork. Premultiplied throughout.
            let (sr, sg, sb, sa) = (
                sh.col.r as u32,
                sh.col.g as u32,
                sh.col.b as u32,
                sh.col.a as u32,
            );
            for (dst, src) in sp.pixels_mut().iter_mut().zip(layer.pixels().iter()) {
                let a = (src.alpha() as u32 * sa) / 255;
                *dst = tiny_skia::ColorU8::from_rgba(
                    (sr * a / 255) as u8,
                    (sg * a / 255) as u8,
                    (sb * a / 255) as u8,
                    a as u8,
                )
                .premultiply();
            }
            box_blur(&mut sp, sh.blur);
            sp
        });
        if let (Some(sp), Some(sh)) = (shadow_pm.as_ref(), effect.shadow) {
            let paint = tiny_skia::PixmapPaint {
                opacity: alpha.clamp(0.0, 1.0),
                ..Default::default()
            };
            self.target().draw_pixmap(
                sh.dx.round() as i32,
                sh.dy.round() as i32,
                sp.as_ref(),
                &paint,
                Transform::identity(),
                None,
            );
        }
        if let Some(r) = effect.blur {
            box_blur(&mut layer, r);
        }
        let m = mask.map(|ml| Mask::from_pixmap(ml.pixmap.as_ref(), skia_masktype(ml.kind)));
        // Compositing the layer as a whole at `alpha` (and through `blend`) is what
        // makes group opacity/blend differ from per-element: overlaps inside the
        // layer don't compound, and the blend is against the backdrop below.
        let paint = tiny_skia::PixmapPaint {
            opacity: alpha.clamp(0.0, 1.0),
            blend_mode: blend.to_skia(),
            ..Default::default()
        };
        self.target().draw_pixmap(
            0,
            0,
            layer.as_ref(),
            &paint,
            Transform::identity(),
            m.as_ref(),
        );
    }

    // Repaint boundaries: like begin/end_group but without mask/opacity/blend, and
    // the layer is returned (not composited) so the walk can memoise it and then
    // composite it here at identity. Source-over compositing is associative, so a
    // captured-then-composited layer is byte-identical to drawing the subtree inline.
    fn caches_subrasters(&self) -> bool {
        true
    }

    fn subraster_begin(&mut self) {
        self.targets
            .push(Pixmap::new(self.w, self.h).expect("non-zero layer dimensions"));
    }

    fn subraster_end(&mut self) -> Option<Pixmap> {
        if self.targets.len() <= 1 {
            return None; // never pop the base page target (unbalanced)
        }
        self.targets.pop()
    }

    fn composite_subraster(&mut self, pm: &Pixmap) {
        let paint = tiny_skia::PixmapPaint::default();
        self.target()
            .draw_pixmap(0, 0, pm.as_ref(), &paint, Transform::identity(), None);
    }

    fn draw_circles(
        &mut self,
        cx: &[f64],
        cy: &[f64],
        r: &[f64],
        fill: Option<&ResolvedPaint>,
        stroke: Option<(Rgba, StrokeStyle)>,
        transform: Transform,
        clip: &Clip,
    ) {
        // Sprite fast path: a large cloud of equal-radius, solid-fill, unstroked
        // markers. Rasterize the marker once and blit it per point (pixel-snapped,
        // imperceptible at the densities where it triggers). Anything else falls
        // back to per-element path fills.
        //
        // PERF-4 (measured): the sprite blit beats both alternatives across the
        // whole tested radius range — per-element circle fills (~1.2x slower at
        // r=24px) and a single combined-path fill of all discs (much slower:
        // 3e5 discs in one rasterizer sweep is ~2.7x slower than the sprite).
        // So the sprite is kept for all uniform small-to-large markers; SPRITE_MAX_R
        // only guards against absurd per-blit areas. The residual ~0.6x vs grid for
        // big markers is raster throughput (grid's device circle fill is hard to
        // beat); for huge overplotted clouds use datashade() (PERF-5) instead.
        const SPRITE_MIN: usize = 10_000;
        const SPRITE_MAX_R: f64 = 64.0;
        // The fixed-radius sprite is placed at the mapped centre, so it is exact
        // only when the CTM's linear part preserves length — a rotation/reflection
        // at unit scale keeps a circle the same-radius circle (viewport transforms
        // are isometries by invariant, enforced by a debug_assert in resolve_one).
        // A non-unit scale would need a resized sprite, so verify at runtime and
        // fall back to per-element fills (which apply the full CTM) otherwise —
        // keeping raster identical to SVG/PDF even if the invariant is ever broken.
        let m = &transform;
        let unit_scale = (m.sx * m.sx + m.ky * m.ky - 1.0).abs() < 1e-6
            && (m.kx * m.kx + m.sy * m.sy - 1.0).abs() < 1e-6
            && (m.sx * m.kx + m.ky * m.sy).abs() < 1e-6;
        let n = cx.len().min(cy.len()).min(r.len());
        let uniform_small = n >= SPRITE_MIN
            && unit_scale
            && stroke.is_none()
            && r[0] > 0.0
            && r[0] <= SPRITE_MAX_R
            && r[..n].iter().all(|&v| (v - r[0]).abs() < 1e-9);
        if uniform_small {
            if let Some(ResolvedPaint::Solid(color)) = fill {
                if let Some(sprite) = circle_sprite(r[0], *color) {
                    let mask = self.mask_for(clip);
                    let off = sprite.width() as f64 / 2.0;
                    let paint = tiny_skia::PixmapPaint::default();
                    let target = self.targets.last_mut().expect("at least the page target");
                    for i in 0..n {
                        // transform is a rigid isometry, so map the centre directly.
                        let dx = transform.sx as f64 * cx[i]
                            + transform.kx as f64 * cy[i]
                            + transform.tx as f64;
                        let dy = transform.ky as f64 * cx[i]
                            + transform.sy as f64 * cy[i]
                            + transform.ty as f64;
                        target.draw_pixmap(
                            (dx - off).round() as i32,
                            (dy - off).round() as i32,
                            sprite.as_ref(),
                            &paint,
                            Transform::identity(),
                            mask.as_deref(),
                        );
                    }
                    return;
                }
            }
        }
        circles_by_path(self, cx, cy, r, fill, stroke.as_ref(), transform, clip);
    }

    fn draw_image(
        &mut self,
        rgba: &[u8],
        iw: u32,
        ih: u32,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        interpolate: bool,
        transform: Transform,
        clip: &Clip,
    ) {
        let pm = match pixmap_from_straight(rgba, iw, ih) {
            Some(p) => p,
            None => return,
        };
        let mask = self.mask_for(clip);
        // Map the iw x ih pixmap into the w x h cell at (x-w/2, y-h/2); `transform` then to device.
        let place = transform.pre_concat(Transform::from_row(
            (w / iw as f64) as f32,
            0.0,
            0.0,
            (h / ih as f64) as f32,
            (x - w / 2.0) as f32,
            (y - h / 2.0) as f32,
        ));
        let mut paint = tiny_skia::PixmapPaint::default();
        paint.quality = if interpolate {
            FilterQuality::Bilinear
        } else {
            FilterQuality::Nearest
        };
        self.targets
            .last_mut()
            .expect("at least the page target")
            .draw_pixmap(0, 0, pm.as_ref(), &paint, place, mask.as_deref());
    }
}

// --- SVG backend ------------------------------------------------------------
