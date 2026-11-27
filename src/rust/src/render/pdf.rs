//! The PDF backend, built on krilla.

use super::fit::{self, VecFill, VecStroke};
use super::*;
use krilla::blend::BlendMode as KBlend;
use krilla::color::rgb;
use krilla::geom::{
    Path as KPath, PathBuilder as KPathBuilder, Point as KPoint, Size as KSize,
    Transform as KTransform,
};
use krilla::image::Image as KImage;
use krilla::mask::{Mask as KMask, MaskType as KMaskType};
use krilla::num::NormalizedF32;
use krilla::paint::{
    Fill, FillRule as KFillRule, LineCap as KLineCap, LineJoin as KLineJoin,
    LinearGradient as KLinear, Paint as KPaint, Pattern as KPattern, RadialGradient as KRadial,
    SpreadMethod as KSpread, Stop as KStop, Stroke as KStroke, StrokeDash as KStrokeDash,
};
use krilla::surface::Surface;
use krilla::text::{Font, GlyphId, KrillaGlyph};

/// Map a blend mode to krilla's, or `None` for `Normal` (skip the state push).
fn krilla_blend(b: BlendKind) -> Option<KBlend> {
    use BlendKind::*;
    Some(match b {
        Normal => return None,
        Multiply => KBlend::Multiply,
        Screen => KBlend::Screen,
        Overlay => KBlend::Overlay,
        Darken => KBlend::Darken,
        Lighten => KBlend::Lighten,
        ColorDodge => KBlend::ColorDodge,
        ColorBurn => KBlend::ColorBurn,
        HardLight => KBlend::HardLight,
        SoftLight => KBlend::SoftLight,
        Difference => KBlend::Difference,
        Exclusion => KBlend::Exclusion,
        Hue => KBlend::Hue,
        Saturation => KBlend::Saturation,
        Color => KBlend::Color,
        Luminosity => KBlend::Luminosity,
    })
}

/// Draws onto a krilla PDF surface. Geometry is converted from `tiny_skia`
/// types; everything is drawn in device pixels and a single root scale
/// (`72/dpi`) maps to PDF points.
pub struct PdfBackend<'a, 'b> {
    surface: &'a mut Surface<'b>,
    fonts: HashMap<(String, u32), Option<Font>>,
    /// For each open group, how many `surface.pop()`s `end_group` must issue
    /// (1 if it installed a soft mask, 0 otherwise).
    group_pushes: Vec<usize>,
    /// Degradation messages: features this PDF walk could not honour (a dropped
    /// tiling pattern, a skipped mask). Surfaced to the user as one R warning.
    warnings: Vec<String>,
    /// Structure-tree entries for tagged nodes, in draw order.
    ///
    /// Draw order *is* reading order for a graphic: it is the order the author
    /// put the marks in, and it is what a screen reader will walk. Collected
    /// flat and assembled into the tree after the page is finished, because
    /// krilla's identifiers are only valid once the content stream exists.
    tagged: Vec<(krilla::tagging::Identifier, NodeMeta)>,
    /// Depth of open tagged spans, so `end_node` only closes one it opened.
    tag_depth: usize,
    /// A single whole-content tagged span is open around the entire page (the
    /// caller opened it directly on the surface). Per-node tagging must then
    /// stand down entirely: PDF forbids nesting one tagged span in another, and
    /// the whole page already belongs to the one Figure. Set when every node is
    /// decorative, so the marks are the visual content of a single figure rather
    /// than figures in their own right.
    outer_tagged: bool,
    /// The page's root transform (device px -> PDF pt, `72 / dpi`), which krilla
    /// applies on top of every primitive transform; `drawable()` checks boxes
    /// under it too, since at a low dpi it enlarges them.
    root: Transform,
    /// The page size in device px, the box far geometry is cut to (VR-44).
    page: (u32, u32),
}

impl<'a, 'b> PdfBackend<'a, 'b> {
    /// `root_scale` is the uniform px -> pt scale the caller pushed as the
    /// page's root transform; the page is `w` x `h` device px.
    pub fn new(surface: &'a mut Surface<'b>, root_scale: f32, w: u32, h: u32) -> Self {
        PdfBackend {
            root: Transform::from_scale(root_scale, root_scale),
            page: (w, h),
            surface,
            fonts: HashMap::new(),
            group_pushes: Vec::new(),
            warnings: Vec::new(),
            tagged: Vec::new(),
            tag_depth: 0,
            outer_tagged: false,
        }
    }

    /// Stand down per-node tagging because a whole-content span is open around
    /// the page (see `outer_tagged`).
    pub fn set_outer_tagged(&mut self, on: bool) {
        self.outer_tagged = on;
    }

    /// The krilla paint and opacity for a resolved paint, shared by fills and
    /// strokes so a gradient or tiled pattern draws the same either way. `None`
    /// for a hatch (expanded to spans by the walk) or a degenerate tile. `role`
    /// names what the paint is for, so a degradation warning says which.
    fn pdf_paint(
        &mut self,
        paint: &ResolvedPaint,
        role: PaintRole,
    ) -> Option<(KPaint, NormalizedF32)> {
        Some(match paint {
            // Expanded to stroked spans by the walk before it reaches a backend.
            ResolvedPaint::Hatch { .. } => return None,
            ResolvedPaint::Solid(c) => (rgb::Color::new(c.r, c.g, c.b).into(), norm(c.a)),
            // krilla unwraps a transform built from the gradient's geometry (a
            // repeating ramp's rotation is inverted), so a missing coordinate
            // would panic; leave the shape unpainted instead (VR-38).
            ResolvedPaint::Linear { x1, y1, x2, y2, .. } if !all_finite(&[*x1, *y1, *x2, *y2]) => {
                self.warn_nonfinite(role);
                return None;
            }
            ResolvedPaint::Radial {
                cx,
                cy,
                r,
                fx,
                fy,
                fr,
                ..
            } if !all_finite(&[*cx, *cy, *r, *fx, *fy, *fr]) => {
                self.warn_nonfinite(role);
                return None;
            }
            ResolvedPaint::Pattern { x, y, .. } if !all_finite(&[*x, *y]) => {
                self.warn_nonfinite(role);
                return None;
            }
            ResolvedPaint::Linear {
                x1,
                y1,
                x2,
                y2,
                stops,
                extend,
            } => (
                KPaint::from(KLinear {
                    x1: *x1 as f32,
                    y1: *y1 as f32,
                    x2: *x2 as f32,
                    y2: *y2 as f32,
                    transform: KTransform::identity(),
                    spread_method: krilla_spread(*extend),
                    stops: krilla_stops(stops),
                    anti_alias: true,
                }),
                NormalizedF32::ONE,
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
            } => (
                KPaint::from(KRadial {
                    fx: *fx as f32,
                    fy: *fy as f32,
                    fr: *fr as f32,
                    cx: *cx as f32,
                    cy: *cy as f32,
                    cr: *r as f32,
                    transform: KTransform::identity(),
                    spread_method: krilla_spread(*extend),
                    stops: krilla_stops(stops),
                    anti_alias: true,
                }),
                NormalizedF32::ONE,
            ),
            // A real tiling pattern: draw the tile image into a stream sized to the
            // cell, anchored at the cell's top-left (matching raster/SVG).
            ResolvedPaint::Pattern {
                tile,
                tw,
                th,
                x,
                y,
                w,
                h,
                opacity,
                ..
            } => {
                // Overflow-checked tile byte count (parity with pixmap_from_straight).
                let need = (*tw as usize)
                    .checked_mul(*th as usize)
                    .and_then(|p| p.checked_mul(4));
                match (KSize::from_wh(*w as f32, *h as f32), need) {
                    // `>=` for parity with the raster/SVG tile checks (which accept a
                    // buffer at least the required size, not exactly it).
                    (Some(cell), Some(n)) if tile.len() >= n => {
                        let img = KImage::from_rgba8(tile[..n].to_vec(), *tw, *th);
                        let stream = image_stream(self.surface, img, cell);
                        let pat = KPattern {
                            stream,
                            transform: KTransform::from_translate(
                                (x - w / 2.0) as f32,
                                (y - h / 2.0) as f32,
                            ),
                            width: *w as f32,
                            height: *h as f32,
                        };
                        (
                            KPaint::from(pat),
                            NormalizedF32::new(opacity.clamp(0.0, 1.0))
                                .unwrap_or(NormalizedF32::ONE),
                        )
                    }
                    _ => {
                        let (what, left) = match role {
                            PaintRole::Fill => ("fill", "unfilled"),
                            PaintRole::Stroke => ("stroke", "unstroked"),
                        };
                        self.warn(format!(
                            "a tiling-pattern {what} could not be rendered to PDF (degenerate tile or cell size); the shape was left {left}"
                        ));
                        return None;
                    }
                }
            }
        })
    }

    /// Record a degradation, de-duplicated (the same gap usually recurs across
    /// many primitives; the user needs to hear it once).
    fn warn(&mut self, msg: impl Into<String>) {
        let msg = msg.into();
        if !self.warnings.contains(&msg) {
            self.warnings.push(msg);
        }
    }

    /// A paint whose geometry has a non-finite coordinate, skipped (VR-38).
    fn warn_nonfinite(&mut self, role: PaintRole) {
        let (what, left) = match role {
            PaintRole::Fill => ("fill", "unfilled"),
            PaintRole::Stroke => ("stroke", "unstroked"),
        };
        self.warn(format!(
            "a gradient or pattern {what} with a missing (non-finite) coordinate could not be rendered to PDF; the shape was left {left}"
        ));
    }

    /// The structure-tree entries collected during the walk, in draw order.
    pub fn take_tagged(&mut self) -> Vec<(krilla::tagging::Identifier, NodeMeta)> {
        std::mem::take(&mut self.tagged)
    }

    /// Fill the page with the background colour (device-px page rect).
    pub fn fill_background(&mut self, w: u32, h: u32, bg: Rgba) {
        if bg.a == 0 {
            return;
        }
        if let Some(path) = rect_path(0.0, 0.0, w as f64, h as f64) {
            let empty = Clip {
                id: usize::MAX,
                shapes: &[],
            };
            self.fill_path(
                &path,
                Transform::identity(),
                &ResolvedPaint::Solid(bg),
                FillRule::Winding,
                &empty,
            );
        }
    }

    /// Push clip paths (under the root scale) then the primitive transform;
    /// returns the number of `pop()`s needed to unwind, or `None` (with nothing
    /// left pushed) when the clip admits nothing, so the caller draws nothing.
    ///
    /// A clip region that cannot be represented (non-finite geometry) or has no
    /// area clips everything away. It used to be skipped, which drew the
    /// content unclipped where PNG, SVG and PowerPoint drew nothing (VR-42).
    fn push_state(&mut self, transform: Transform, clip: &Clip) -> Option<usize> {
        let mut n = 0;
        for shape in clip.shapes {
            // The device path, and whether its box has any area.
            let (pw, ph) = self.page;
            let (kpath, rule, area) = match shape {
                // A region reaching far beyond the page is cut to it first, as
                // on PNG: poppler drops a clip path at 1e12 px (VR-44).
                ClipShape::Rect { w, h, transform }
                    if !fit::rect_corners_near(&rect_corners(*w, *h, *transform)) =>
                {
                    let dev = rect_path(0.0, 0.0, *w, *h)
                        .and_then(|p| fit::vector_clip(&p, *transform, pw, ph))
                        .flatten();
                    let area = dev
                        .as_ref()
                        .is_some_and(|p| p.bounds().width() > 0.0 && p.bounds().height() > 0.0);
                    (dev.and_then(|p| to_kpath(&p)), KFillRule::NonZero, area)
                }
                ClipShape::Rect { w, h, transform } => {
                    let c = rect_corners(*w, *h, *transform);
                    let span = |f: fn(&(f64, f64)) -> f64| {
                        let v = c.iter().map(f);
                        v.clone().fold(f64::NEG_INFINITY, f64::max)
                            - v.fold(f64::INFINITY, f64::min)
                    };
                    (
                        clip_rect_kpath(*w, *h, *transform),
                        KFillRule::NonZero,
                        span(|p| p.0) > 0.0 && span(|p| p.1) > 0.0,
                    )
                }
                ClipShape::Path {
                    path,
                    evenodd,
                    transform,
                } => {
                    let dev = match fit::vector_clip(path, *transform, pw, ph) {
                        Some(fitted) => fitted,
                        None => path.clone().transform(*transform),
                    };
                    let area = dev
                        .as_ref()
                        .is_some_and(|p| p.bounds().width() > 0.0 && p.bounds().height() > 0.0);
                    (
                        dev.and_then(|p| to_kpath(&p)),
                        if *evenodd {
                            KFillRule::EvenOdd
                        } else {
                            KFillRule::NonZero
                        },
                        area,
                    )
                }
            };
            match kpath {
                Some(p) if area => {
                    self.surface.push_clip_path(&p, &rule);
                    n += 1;
                }
                _ => {
                    self.pop_state(n);
                    return None;
                }
            }
        }
        self.surface.push_transform(&to_ktransform(transform));
        Some(n + 1)
    }

    fn pop_state(&mut self, n: usize) {
        for _ in 0..n {
            self.surface.pop();
        }
    }

    /// A stroke whose geometry is in range (see `stroke_path`).
    fn stroke_unfitted(
        &mut self,
        path: &Path,
        transform: Transform,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    ) {
        // Written so a NaN width (an R `NA`) is skipped too: `NaN <= 0.0` is false.
        if !(stroke.width > 0.0 && stroke.width.is_finite())
            || !drawable(path, transform, self.root)
        {
            return;
        }
        let kp = match to_kpath(path) {
            Some(p) => p,
            None => return,
        };
        // A gradient/pattern stroke uses the same krilla paint a fill would.
        let (kpaint, kopacity) = match &stroke.paint {
            Some(p) => match self.pdf_paint(p, PaintRole::Stroke) {
                Some(kp) => kp,
                None => return,
            },
            None => (
                rgb::Color::new(color.r, color.g, color.b).into(),
                norm(color.a),
            ),
        };
        let Some(n) = self.push_state(transform, clip) else {
            return;
        };
        self.surface.set_fill(None);
        self.surface.set_stroke(Some(KStroke {
            paint: kpaint,
            width: stroke.width,
            opacity: kopacity,
            miter_limit: if stroke.miter.is_finite() {
                stroke.miter
            } else {
                KStroke::default().miter_limit
            },
            line_cap: krilla_cap(stroke.cap),
            line_join: krilla_join(stroke.join),
            // A dash with a missing or negative entry draws solid, as tiny-skia
            // (the raster backend) rejects such a dash.
            dash: if stroke.dash.is_empty()
                || !stroke.dash.iter().all(|d| d.is_finite() && *d >= 0.0)
                || !stroke.phase.is_finite()
            {
                None
            } else {
                Some(KStrokeDash {
                    array: stroke.dash.clone(),
                    offset: stroke.phase,
                })
            },
            ..KStroke::default()
        }));
        self.surface.draw_path(&kp);
        self.pop_state(n);
    }

    fn font_for(&mut self, path: &str, index: u32) -> Option<Font> {
        let key = (path.to_string(), index);
        if let Some(f) = self.fonts.get(&key) {
            return f.clone();
        }
        let font = std::fs::read(path)
            .ok()
            .and_then(|bytes| Font::new(krilla::Data::from(bytes), index));
        self.fonts.insert(key, font.clone());
        font
    }
}

/// Map a vellum `role` onto a PDF structure element.
///
/// `role` is an ARIA-flavoured string on the R side, and PDF's structure types
/// are not ARIA — so this is a deliberate, documented, small mapping rather than
/// a general translation. Anything unrecognised becomes a `Figure`, which is the
/// correct default for a mark in a graphic and the one PDF/UA requires alt text
/// for.
pub fn pdf_tag(meta: &NodeMeta) -> krilla::tagging::TagKind {
    use krilla::tagging::Tag;
    // PDF/UA requires a Figure to carry alt text. Prefer the human-readable
    // name, fall back to the id, and last of all say *something* -- an empty Alt
    // is a validation failure, and a screen reader announcing "graphic" beats it
    // announcing nothing.
    let alt = if !meta.name.is_empty() {
        meta.name.clone()
    } else if !meta.id.is_empty() {
        meta.id.clone()
    } else {
        "graphic".to_string()
    };
    match meta.role.as_str() {
        "paragraph" | "text" => Tag::P.into(),
        "heading" => Tag::Hn(
            std::num::NonZeroU16::new(1).expect("1 is non-zero"),
            Some(alt),
        )
        .into(),
        "caption" => Tag::Caption.into(),
        "listitem" => Tag::LI.into(),
        _ => Tag::Figure(Some(alt)).into(),
    }
}

/// Whether a node is decorative -- present for looks, carrying no meaning.
///
/// Such content is tagged as an *artifact* rather than given a structure entry,
/// which is how PDF says "skip this": a screen reader announcing every gridline
/// is worse than one announcing none.
pub(crate) fn is_decorative(meta: &NodeMeta) -> bool {
    // `grid` is the role a downstream (e.g. vellumplot gridlines) sets so an
    // interactive SVG host can find and hide the gridlines; it is also, plainly,
    // decorative furniture that a screen reader must not read. Treating it as
    // decorative here skips it in the PDF structure tree without disturbing the
    // SVG role the host relies on.
    matches!(
        meta.role.as_str(),
        "presentation" | "none" | "decorative" | "grid"
    )
}

/// What a paint is applied to, for wording degradation warnings.
#[derive(Clone, Copy)]
enum PaintRole {
    Fill,
    Stroke,
}

impl RenderBackend for PdfBackend<'_, '_> {
    fn far_window(&self, transform: Transform) -> FarWin {
        let (w, h) = self.page;
        FarWin::for_page(transform, w, h)
    }
    fn wants_node_meta(&self) -> bool {
        true
    }

    fn begin_node(&mut self, meta: &NodeMeta) {
        // A whole-content span already brackets the whole page (one Figure); stand
        // down so we do not nest a second tagged span inside it.
        if self.outer_tagged {
            return;
        }
        // One tagged content span per node. Nesting tagged spans is not allowed
        // in PDF, and the walk never nests them, but guard anyway: a stray
        // unbalanced pair would corrupt the whole content stream.
        if self.tag_depth > 0 {
            return;
        }
        if is_decorative(meta) {
            use krilla::tagging::{Artifact, ArtifactType, ContentTag};
            self.surface
                .start_tagged(ContentTag::Artifact(Artifact::new(
                    ArtifactType::Other,
                    None,
                )));
        } else {
            let id = self
                .surface
                .start_tagged(krilla::tagging::ContentTag::Other);
            self.tagged.push((id, meta.clone()));
        }
        self.tag_depth += 1;
    }

    fn end_node(&mut self) {
        // The whole-content span is closed by the caller, not per node.
        if self.outer_tagged {
            return;
        }
        if self.tag_depth > 0 {
            self.surface.end_tagged();
            self.tag_depth -= 1;
        }
    }

    fn fill_path(
        &mut self,
        path: &Path,
        transform: Transform,
        paint: &ResolvedPaint,
        rule: FillRule,
        clip: &Clip,
    ) {
        // Far geometry is cut to the page first, as on PNG (VR-44).
        let fitted;
        let (w, h) = self.page;
        let solid = matches!(paint, ResolvedPaint::Solid(_));
        let (path, transform) = match fit::vector_fill(path, transform, w, h, solid) {
            VecFill::Keep => (path, transform),
            VecFill::Draw(p, t) => {
                fitted = p;
                (&fitted, t)
            }
            VecFill::Skip => return,
        };
        if !drawable(path, transform, self.root) {
            return;
        }
        let kp = match to_kpath(path) {
            Some(p) => p,
            None => return,
        };
        // Gradient geometry is local px (identity gradient transform); the
        // primitive `transform` pushed below maps it to device, like the path.
        let (kpaint, opacity) = match self.pdf_paint(paint, PaintRole::Fill) {
            Some(p) => p,
            None => return,
        };
        let krule = match rule {
            FillRule::EvenOdd => KFillRule::EvenOdd,
            FillRule::Winding => KFillRule::NonZero,
        };
        let Some(n) = self.push_state(transform, clip) else {
            return;
        };
        self.surface.set_stroke(None);
        self.surface.set_fill(Some(Fill {
            paint: kpaint,
            opacity,
            rule: krule,
        }));
        self.surface.draw_path(&kp);
        self.pop_state(n);
    }

    fn stroke_path(
        &mut self,
        path: &Path,
        transform: Transform,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    ) {
        // Written so a NaN width (an R `NA`) is skipped too: `NaN <= 0.0` is false.
        if !(stroke.width > 0.0 && stroke.width.is_finite()) {
            return;
        }
        // Far geometry is cut to the page first, as on PNG (VR-44).
        let (w, h) = self.page;
        match fit::vector_stroke_style(path, transform, stroke, w, h) {
            VecStroke::Keep => self.stroke_unfitted(path, transform, color, stroke, clip),
            VecStroke::Runs(runs) => {
                for (run, phase) in runs {
                    let style = StrokeStyle {
                        phase,
                        ..stroke.clone()
                    };
                    self.stroke_unfitted(&run, transform, color, &style, clip);
                }
            }
            VecStroke::Outline => {
                if let Some(outline) = fit::stroke_outline_path(path, transform, stroke) {
                    let paint = stroke.paint.clone().unwrap_or(ResolvedPaint::Solid(color));
                    self.fill_path(&outline, transform, &paint, FillRule::Winding, clip);
                }
            }
            VecStroke::Skip => {}
        }
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        let n = run
            .gid
            .len()
            .min(run.gx.len())
            .min(run.gy.len())
            .min(run.gsize.len())
            .min(run.gpath.len())
            .min(run.gface.len());
        // Rules (a tex() label's bars) draw even when there are no glyphs
        // (`\\overline{\\quad}`); with neither there is nothing to do. The
        // glyph loop below only indexes gy when n > 0.
        if run.rules.is_empty() && (n == 0 || run.label.is_empty()) {
            return;
        }
        let size_px = (run.size * run.dpi / 72.0) as f32;
        if !(size_px > 0.0 && size_px.is_finite()) {
            return;
        }
        // Text origin (local px). Glyph i sits at origin + gx[i]. The baseline y
        // is per-line: glyph runs are split on a change of `gy` (a new line) and
        // each is drawn at its own `start_y`, so multi-line text stacks correctly
        // (avoids guessing krilla's per-glyph y_offset sign). Mirrors raster.
        let start_x = (run.ax - run.hjust * run.w) as f32;
        let base = if run.rot != 0.0 {
            transform.pre_concat(rotation_about(run.rot, run.ax, run.ay))
        } else {
            transform
        };

        // The text glyphs map back to: a tex() label carries one character
        // per glyph separately from its label (the TeX source).
        let text: &str = if run.gtext.is_empty() {
            run.label
        } else {
            run.gtext
        };
        // char byte boundaries for ToUnicode (exact when glyphs == chars).
        let bounds: Vec<usize> = text
            .char_indices()
            .map(|(b, _)| b)
            .chain(std::iter::once(text.len()))
            .collect();
        let exact = n + 1 == bounds.len();
        let range_for = |i: usize| {
            if exact {
                bounds[i]..bounds[i + 1]
            } else if i == 0 {
                0..text.len()
            } else {
                0..0
            }
        };

        // krilla unwraps the glyph bounding box, which a non-finite transform
        // or origin makes impossible to compute (VR-38).
        if !base.is_finite() || !start_x.is_finite() {
            return;
        }
        // The label's anchor must also land on a representable point of the page.
        if !placeable_point(self.root.pre_concat(base), start_x, run.ay as f32) {
            return;
        }
        let Some(pushes) = self.push_state(base, clip) else {
            return;
        };
        let rich = !run.gcolor.is_empty();
        // A halo means drawing the whole label twice: once stroke-only underneath,
        // then normally on top. PDF has a fill-and-stroke text mode, but it paints
        // the stroke *over* the fill, which is an outline, not a halo.
        let passes: &[bool] = if run.halo.is_some_and(|(_, hw)| hw.is_finite()) {
            &[true, false]
        } else {
            &[false]
        };
        for &halo_pass in passes {
            if halo_pass {
                let (hcol, hw) = run.halo.expect("halo pass implies a halo");
                self.surface.set_fill(None);
                self.surface.set_stroke(Some(KStroke {
                    paint: rgb::Color::new(hcol.r, hcol.g, hcol.b).into(),
                    // Centred stroke: double it so `hw` is the visible outer width,
                    // matching the raster and SVG backends.
                    width: (hw * 2.0) as f32,
                    line_join: KLineJoin::Round,
                    line_cap: KLineCap::Round,
                    opacity: norm(hcol.a),
                    ..Default::default()
                }));
            } else {
                self.surface.set_stroke(None);
                // Plain labels set the single fill once; rich labels set it per colour run.
                if !rich {
                    self.surface.set_fill(Some(Fill {
                        paint: rgb::Color::new(run.color.r, run.color.g, run.color.b).into(),
                        opacity: norm(run.color.a),
                        rule: KFillRule::NonZero,
                    }));
                }
            }

            // Draw in runs of consecutive glyphs sharing a font, a size AND a baseline
            // (so a line break, which changes gy, starts a new run; handles font
            // fallback too). Rich labels additionally break on a colour change so each
            // run gets its fill, and on a size change: a superscript or a `size`
            // span is drawn at its own glyph size, as the raster and SVG backends do.
            let mut i = 0;
            while i < n {
                let (gpath, gface, gy0) = (&run.gpath[i], run.gface[i], run.gy[i]);
                let gsize0 = run.gsize[i];
                let col0 = run.gcolor.get(i).copied();
                let mut j = i;
                while j < n
                    && &run.gpath[j] == gpath
                    && run.gface[j] == gface
                    && run.gy[j] == gy0
                    && run.gsize[j] == gsize0
                    && run.gcolor.get(j).copied() == col0
                {
                    j += 1;
                }
                // Per-run fill for rich labels -- but not on the halo pass, which is
                // stroke-only and must keep fill disabled.
                if let (Some(c), false) = (col0, halo_pass) {
                    self.surface.set_fill(Some(Fill {
                        paint: rgb::Color::new(c.r, c.g, c.b).into(),
                        opacity: norm(c.a),
                        rule: KFillRule::NonZero,
                    }));
                }
                let start_y = (run.ay - (gy0 - run.vjust * run.h)) as f32;
                // The run's own glyph size (px); fall back to the label size.
                let run_px = if gsize0 > 0.0 { gsize0 as f32 } else { size_px };
                let placeable = start_y.is_finite()
                    && run_px.is_finite()
                    && (i..j).all(|k| (run.gx[k] as f32 / run_px).is_finite());
                if !placeable {
                    i = j;
                    continue;
                }
                if let Some(font) = self.font_for(gpath, gface) {
                    let glyphs: Vec<KrillaGlyph> = (i..j)
                        .map(|k| {
                            KrillaGlyph::new(
                                GlyphId::new(run.gid[k]),
                                0.0,                       // x_advance (positions via x_offset)
                                run.gx[k] as f32 / run_px, // x_offset, normalized
                                0.0,
                                0.0,
                                range_for(k),
                                None,
                            )
                        })
                        .collect();
                    self.surface.draw_glyphs(
                        KPoint::from_xy(start_x, start_y),
                        &glyphs,
                        font,
                        text,
                        run_px,
                        false,
                    );
                }
                i = j;
            }
            // A tex() label's fraction bars and radical overbars: stroked
            // with the halo on the halo pass, filled on the fill pass.
            for r in run.rules {
                let Some(kp) = text_rule_path(run, r).as_ref().and_then(to_kpath) else {
                    continue;
                };
                if !halo_pass {
                    self.surface.set_fill(Some(Fill {
                        paint: rgb::Color::new(r.col.r, r.col.g, r.col.b).into(),
                        opacity: norm(r.col.a),
                        rule: KFillRule::NonZero,
                    }));
                }
                self.surface.draw_path(&kp);
            }
        }
        self.surface.set_stroke(None);
        self.pop_state(pushes);
    }

    // PDF masks: krilla can only install a soft mask *before* the masked content
    // (`push_mask` + draw live + `pop`), so the walk hands us the mask at
    // group-start. We bake the rasterized mask into a page-sized grayscale image
    // (coverage in RGB, alpha 255) and install it as a Luminosity mask — this
    // unifies alpha/luminance kinds and avoids premultiplied-color pitfalls. The
    // mask stream is drawn in device px, matching the root px->pt scale that is on
    // the surface stack throughout the walk, so it aligns with the content.
    fn begin_group(
        &mut self,
        mask: Option<MaskLayer>,
        alpha: f32,
        blend: BlendKind,
        effect: GroupEffect,
    ) {
        // PDF has no filter model: krilla exposes no blur or drop-shadow
        // primitive, and emulating one would mean rasterising the group, which
        // silently turns vector output into a bitmap. Fail visibly instead.
        if !effect.is_none() {
            self.warn(
                "a group blur/shadow (PDF has no filter model; the group is drawn unfiltered)",
            );
        }
        let mut pushes = 0usize;
        if let Some(ml) = mask {
            let (w, h) = (ml.pixmap.width(), ml.pixmap.height());
            if let Some(size) = KSize::from_wh(w as f32, h as f32) {
                let img = KImage::from_rgba8(mask_gray_rgba(&ml.pixmap, ml.kind), w, h);
                let stream = image_stream(self.surface, img, size);
                self.surface
                    .push_mask(KMask::new(stream, KMaskType::Luminosity));
                pushes += 1;
            } else {
                self.warn("a viewport mask could not be applied to PDF (degenerate mask size); the group was drawn unmasked");
            }
        }
        // Group blend: the group's content is composited on its own first and the
        // result blended against the backdrop below it, as PNG and SVG do. A
        // blend mode in the graphics state applies to each object drawn under it,
        // so `push_blend_mode` alone blends every mark (and a nested group's
        // content) against the page; the isolated transparency group pushed after
        // it collects the content (drawn normally inside) into one XObject, which
        // is what the blend mode then applies to (VR-23).
        if let Some(kb) = krilla_blend(blend) {
            self.surface.push_blend_mode(kb);
            self.surface.push_isolated();
            pushes += 2;
        }
        // Group opacity: an isolated transparency group composited at `alpha`.
        if alpha < 1.0 {
            if let Some(a) = NormalizedF32::new(alpha.clamp(0.0, 1.0)) {
                self.surface.push_opacity(a);
                pushes += 1;
            }
        }
        self.group_pushes.push(pushes);
    }

    fn end_group(&mut self) {
        if let Some(n) = self.group_pushes.pop() {
            for _ in 0..n {
                self.surface.pop();
            }
        }
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
        if iw == 0 || ih == 0 || rgba.len() < (iw as usize) * (ih as usize) * 4 {
            return;
        }
        let (pw, ph) = self.page;
        // A far image is cut to the part over the page first (VR-46).
        let fitted;
        let (rgba, iw, ih, x, y, w, h, interpolate) = match super::fit::vector_image(
            rgba,
            iw,
            ih,
            x,
            y,
            w,
            h,
            interpolate,
            transform,
            pw,
            ph,
        ) {
            super::fit::VecImage::Keep => (rgba, iw, ih, x, y, w, h, interpolate),
            super::fit::VecImage::Draw(f) => {
                fitted = f;
                (
                    &fitted.rgba[..],
                    fitted.iw,
                    fitted.ih,
                    fitted.x,
                    fitted.y,
                    fitted.w,
                    fitted.h,
                    fitted.interpolate,
                )
            }
            super::fit::VecImage::Skip => return,
        };
        let size = match KSize::from_wh(w as f32, h as f32) {
            Some(s) => s,
            None => return,
        };
        // krilla's `from_rgba8` hard-codes non-interpolated sampling, so honour
        // `interpolate` (as raster/SVG do) by routing an interpolated image through
        // a PNG — `from_png` carries the `/Interpolate` flag. Nearest otherwise, and
        // as a fallback if PNG encoding fails.
        let img = if interpolate {
            match straight_png(rgba, iw, ih)
                .and_then(|png| KImage::from_png(krilla::Data::from(png), true).ok())
            {
                Some(i) => i,
                None => KImage::from_rgba8(rgba.to_vec(), iw, ih),
            }
        } else {
            KImage::from_rgba8(rgba.to_vec(), iw, ih)
        };
        // draw_image places the image at the origin scaled to `size`; translate to
        // the cell's top-left, under the primitive transform + clip.
        let place = transform.pre_concat(Transform::from_row(
            1.0,
            0.0,
            0.0,
            1.0,
            (x - w / 2.0) as f32,
            (y - h / 2.0) as f32,
        ));
        let on_page = self.root.pre_concat(place);
        if !place.is_finite()
            || !placeable_point(on_page, 0.0, 0.0)
            || !placeable_point(on_page, w as f32, h as f32)
        {
            return;
        }
        let Some(n) = self.push_state(place, clip) else {
            return;
        };
        self.surface.draw_image(img, size);
        self.pop_state(n);
    }

    fn take_warnings(&mut self) -> Vec<String> {
        std::mem::take(&mut self.warnings)
    }
}

/// The largest device coordinate (px or pt) a drawn box may reach. Far beyond
/// any page, but small enough that a union of such boxes (krilla grows one
/// bounding box per content stream) cannot overflow `f32`.
pub(super) const MAX_COORD: f32 = 1e15;

/// Can krilla draw `path` under `transform`? krilla maps every drawn object's
/// bounding box through the current transform (the primitive's, under the
/// page's `root` px -> pt scale) and unwraps the result, so a non-finite
/// transform (a marker scaled by an `NA` size) or a box that overflows panics
/// inside krilla. Unchecked, that panic unwound through krilla's `Surface`,
/// whose `Drop` asserts that every push was popped, and the second panic
/// aborted R (VR-38). Such an object draws nothing on the other backends
/// either, so skip it. The box is checked under the primitive transform alone
/// and under the root too, as krilla's sub-streams (groups, masks) start
/// without the root.
pub(crate) fn drawable(path: &Path, transform: Transform, root: Transform) -> bool {
    let within = |t: Transform| {
        path.bounds().transform(t).is_some_and(|b| {
            b.left().abs() <= MAX_COORD
                && b.right().abs() <= MAX_COORD
                && b.top().abs() <= MAX_COORD
                && b.bottom().abs() <= MAX_COORD
        })
    };
    transform.is_finite() && within(transform) && within(root.pre_concat(transform))
}

/// Does `(x, y)` map through `t` to a point within [`MAX_COORD`]? Used for the
/// text and image anchors, whose boxes krilla computes itself.
fn placeable_point(t: Transform, x: f32, y: f32) -> bool {
    let mut p = [tiny_skia::Point::from_xy(x, y)];
    t.map_points(&mut p);
    t.is_finite() && p[0].x.abs() <= MAX_COORD && p[0].y.abs() <= MAX_COORD
}

/// Draw `img` at `size` into a fresh stream (a tile or a mask). The nested
/// surface has no pushes of its own, so its asserting `Drop` would pass, but a
/// krilla panic mid-draw could still leave its builder half-written; leak it
/// and keep unwinding to the page-level `catch_unwind` in `add_pdf_page`
/// rather than run its destructor (VR-38).
fn image_stream(surface: &mut Surface, img: KImage, size: KSize) -> krilla::stream::Stream {
    let mut sb = surface.stream_builder();
    let mut surf = sb.surface();
    let drawn = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        surf.draw_image(img, size);
    }));
    if let Err(payload) = drawn {
        std::mem::forget(surf);
        std::mem::forget(sb);
        std::panic::resume_unwind(payload);
    }
    surf.finish();
    sb.finish()
}

fn all_finite(v: &[f64]) -> bool {
    v.iter().all(|x| x.is_finite())
}

fn to_kpath(p: &Path) -> Option<KPath> {
    use tiny_skia::PathSegment;
    let mut pb = KPathBuilder::new();
    for seg in p.segments() {
        match seg {
            PathSegment::MoveTo(pt) => pb.move_to(pt.x, pt.y),
            PathSegment::LineTo(pt) => pb.line_to(pt.x, pt.y),
            PathSegment::QuadTo(c, pt) => pb.quad_to(c.x, c.y, pt.x, pt.y),
            PathSegment::CubicTo(c1, c2, pt) => pb.cubic_to(c1.x, c1.y, c2.x, c2.y, pt.x, pt.y),
            PathSegment::Close => pb.close(),
        }
    }
    pb.finish()
}

fn to_ktransform(t: Transform) -> KTransform {
    KTransform::from_row(t.sx, t.ky, t.kx, t.sy, t.tx, t.ty)
}

pub(super) fn clip_rect_kpath(w: f64, h: f64, transform: Transform) -> Option<KPath> {
    let c = rect_corners(w, h, transform);
    let mut pb = KPathBuilder::new();
    pb.move_to(c[0].0 as f32, c[0].1 as f32);
    pb.line_to(c[1].0 as f32, c[1].1 as f32);
    pb.line_to(c[2].0 as f32, c[2].1 as f32);
    pb.line_to(c[3].0 as f32, c[3].1 as f32);
    pb.close();
    pb.finish()
}

fn norm(a: u8) -> NormalizedF32 {
    NormalizedF32::new(a as f32 / 255.0).unwrap_or(NormalizedF32::ONE)
}

fn krilla_spread(extend: Extend) -> KSpread {
    match extend {
        Extend::Pad => KSpread::Pad,
        Extend::Repeat => KSpread::Repeat,
        Extend::Reflect => KSpread::Reflect,
    }
}

fn krilla_cap(c: LineCap) -> KLineCap {
    match c {
        LineCap::Round => KLineCap::Round,
        LineCap::Butt => KLineCap::Butt,
        LineCap::Square => KLineCap::Square,
    }
}

fn krilla_join(j: LineJoin) -> KLineJoin {
    match j {
        LineJoin::Round => KLineJoin::Round,
        LineJoin::Mitre => KLineJoin::Miter,
        LineJoin::Bevel => KLineJoin::Bevel,
    }
}

fn krilla_stops(stops: &[Stop]) -> Vec<KStop> {
    stops
        .iter()
        .map(|s| KStop {
            offset: NormalizedF32::new(s.offset.clamp(0.0, 1.0)).unwrap_or(NormalizedF32::ZERO),
            color: rgb::Color::new(s.color.r, s.color.g, s.color.b).into(),
            opacity: norm(s.color.a),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::Stop;

    const NAN: f64 = f64::NAN;
    const INF: f64 = f64::INFINITY;
    const BLACK: Rgba = Rgba {
        r: 0,
        g: 0,
        b: 0,
        a: 255,
    };

    /// Draw onto one 100 x 100 px page the way `add_pdf_page` does (root
    /// px -> pt scale, then the walk) and serialise it. Like the real page
    /// there is no `catch_unwind` here: if a guard regresses, krilla's panic
    /// unwinds through the `Surface`, its asserting `Drop` panics again and the
    /// test binary aborts (which is how these tests fail; with the guards
    /// disabled they reproduce the original crash).
    fn pdf(draw: impl FnOnce(&mut PdfBackend)) -> (Vec<u8>, Vec<String>) {
        let mut doc = krilla::Document::new();
        let mut page =
            doc.start_page_with(krilla::page::PageSettings::from_wh(75.0, 75.0).unwrap());
        let mut surface = page.surface();
        surface.push_transform(&KTransform::from_scale(0.75, 0.75));
        let warnings = {
            let mut b = PdfBackend::new(&mut surface, 0.75, 100, 100);
            draw(&mut b);
            b.take_warnings()
        };
        surface.pop();
        surface.finish();
        page.finish();
        (doc.finish().expect("a valid PDF"), warnings)
    }

    fn no_clip() -> Clip<'static> {
        Clip { id: 0, shapes: &[] }
    }

    fn unit_circle() -> Path {
        let mut pb = tiny_skia::PathBuilder::new();
        pb.push_circle(0.0, 0.0, 1.0);
        pb.finish().unwrap()
    }

    fn square() -> Path {
        tiny_skia::PathBuilder::from_rect(
            tiny_skia::Rect::from_xywh(10.0, 10.0, 20.0, 20.0).unwrap(),
        )
    }

    /// A marker placed by `scale(r) then translate(cx, cy)`, as the walk
    /// places a point marker of radius `r`.
    fn marker(r: f64, cx: f64, cy: f64) -> Transform {
        Transform::from_row(r as f32, 0.0, 0.0, r as f32, cx as f32, cy as f32)
    }

    fn style(width: f32) -> StrokeStyle {
        StrokeStyle {
            width,
            dash: Vec::new(),
            cap: LineCap::Butt,
            join: LineJoin::Mitre,
            miter: 4.0,
            crisp: false,
            paint: None,
            phase: 0.0,
        }
    }

    // The bare bytes of a page that draws nothing but this rect.
    fn baseline() -> Vec<u8> {
        pdf(|b| {
            b.fill_path(
                &square(),
                Transform::identity(),
                &ResolvedPaint::Solid(BLACK),
                FillRule::Winding,
                &no_clip(),
            )
        })
        .0
    }

    #[test]
    fn a_marker_with_a_missing_size_is_skipped_not_a_panic() {
        // VR-38: `size = NA` reached krilla as a NaN scale; krilla unwrapped the
        // transformed bounding box and the unwind then aborted R.
        let base = baseline();
        for r in [NAN, INF, -INF] {
            let (bytes, _) = pdf(|b| {
                b.fill_path(
                    &square(),
                    Transform::identity(),
                    &ResolvedPaint::Solid(BLACK),
                    FillRule::Winding,
                    &no_clip(),
                );
                b.fill_path(
                    &unit_circle(),
                    marker(r, 50.0, 50.0),
                    &ResolvedPaint::Solid(BLACK),
                    FillRule::Winding,
                    &no_clip(),
                );
                b.stroke_path(
                    &unit_circle(),
                    marker(r, 50.0, 50.0),
                    BLACK,
                    &style(1.0),
                    &no_clip(),
                );
            });
            assert!(bytes == base, "radius {r} should draw nothing");
        }
    }

    #[test]
    fn a_missing_position_is_skipped() {
        let base = baseline();
        for (cx, cy) in [(NAN, 50.0), (50.0, INF), (-INF, NAN)] {
            let (bytes, _) = pdf(|b| {
                b.fill_path(
                    &square(),
                    Transform::identity(),
                    &ResolvedPaint::Solid(BLACK),
                    FillRule::Winding,
                    &no_clip(),
                );
                b.fill_path(
                    &unit_circle(),
                    marker(3.0, cx, cy),
                    &ResolvedPaint::Solid(BLACK),
                    FillRule::Winding,
                    &no_clip(),
                );
            });
            assert!(bytes == base);
        }
    }

    #[test]
    fn a_negative_scale_still_draws() {
        // A reflection is a legitimate transform, not a missing value.
        let base = baseline();
        let (bytes, _) = pdf(|b| {
            b.fill_path(
                &unit_circle(),
                marker(-3.0, 50.0, 50.0),
                &ResolvedPaint::Solid(BLACK),
                FillRule::Winding,
                &no_clip(),
            )
        });
        assert!(bytes != base);
    }

    #[test]
    fn non_finite_or_negative_stroke_settings_do_not_panic() {
        let base = baseline();
        for w in [f32::NAN, f32::INFINITY, -1.0, 0.0] {
            let (bytes, _) = pdf(|b| {
                b.fill_path(
                    &square(),
                    Transform::identity(),
                    &ResolvedPaint::Solid(BLACK),
                    FillRule::Winding,
                    &no_clip(),
                );
                b.stroke_path(
                    &square(),
                    Transform::identity(),
                    BLACK,
                    &style(w),
                    &no_clip(),
                );
            });
            assert!(bytes == base, "width {w} should draw nothing");
        }
        // A broken dash or miter limit falls back to a solid line / the default
        // limit rather than writing NaN into the content stream.
        let (bytes, _) = pdf(|b| {
            let mut s = style(2.0);
            s.dash = vec![f32::NAN, -1.0];
            s.phase = f32::NAN;
            s.miter = f32::INFINITY;
            b.stroke_path(&square(), Transform::identity(), BLACK, &s, &no_clip());
        });
        let solid = pdf(|b| {
            let mut s = style(2.0);
            s.miter = KStroke::default().miter_limit;
            b.stroke_path(&square(), Transform::identity(), BLACK, &s, &no_clip())
        })
        .0;
        assert!(bytes == solid);
    }

    #[test]
    fn a_gradient_with_a_missing_coordinate_is_dropped_with_a_warning() {
        let stops = vec![
            Stop {
                offset: 0.0,
                color: BLACK,
            },
            Stop {
                offset: 1.0,
                color: Rgba {
                    r: 255,
                    g: 255,
                    b: 255,
                    a: 255,
                },
            },
        ];
        let paints = [
            // Repeat: krilla inverts a transform built from the ramp's angle.
            ResolvedPaint::Linear {
                x1: NAN,
                y1: 0.0,
                x2: 10.0,
                y2: 0.0,
                stops: stops.clone(),
                extend: Extend::Repeat,
            },
            ResolvedPaint::Linear {
                x1: 0.0,
                y1: 0.0,
                x2: INF,
                y2: 0.0,
                stops: stops.clone(),
                extend: Extend::Pad,
            },
            ResolvedPaint::Radial {
                cx: 20.0,
                cy: 20.0,
                r: NAN,
                fx: 20.0,
                fy: 20.0,
                fr: 0.0,
                stops: stops.clone(),
                extend: Extend::Pad,
            },
        ];
        for paint in &paints {
            let (_, warnings) = pdf(|b| {
                b.fill_path(
                    &square(),
                    Transform::identity(),
                    paint,
                    FillRule::Winding,
                    &no_clip(),
                );
                let mut s = style(2.0);
                s.paint = Some(paint.clone());
                b.stroke_path(&square(), Transform::identity(), BLACK, &s, &no_clip());
            });
            assert_eq!(warnings.len(), 2, "{warnings:?}");
            assert!(warnings[0].contains("non-finite"));
        }
    }

    #[test]
    fn an_image_with_a_missing_placement_is_skipped() {
        let px = vec![0u8; 4 * 4];
        let base = pdf(|_| {}).0;
        for (x, w, t) in [
            (NAN, 10.0, Transform::identity()),
            (5.0, NAN, Transform::identity()),
            (5.0, -10.0, Transform::identity()),
            (5.0, 10.0, marker(NAN, 0.0, 0.0)),
        ] {
            let (bytes, _) =
                pdf(|b| b.draw_image(&px, 2, 2, x, 5.0, w, 10.0, false, t, &no_clip()));
            assert!(bytes == base);
        }
    }

    const STIX: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../inst/fonts/STIXTwoMath-Regular.otf"
    );

    /// A two-glyph label in the bundled STIX font (or `font`), with a tex()
    /// style rule when `rule` is set, so both the glyph runs and the rules are
    /// exercised.
    struct Label {
        size: f64,
        ax: f64,
        rot: f64,
        gx: [f64; 2],
        halo: Option<(Rgba, f64)>,
        font: &'static str,
        rule: bool,
    }

    impl Default for Label {
        fn default() -> Self {
            Label {
                size: 10.0,
                ax: 10.0,
                rot: 0.0,
                gx: [0.0, 8.0],
                halo: None,
                font: STIX,
                rule: false,
            }
        }
    }

    fn label_pdf(l: &Label) -> Vec<u8> {
        let rule = [TextRule {
            x: 0.0,
            y: 0.0,
            w: 10.0,
            h: 1.0,
            col: BLACK,
        }];
        let gpath = [l.font.to_string(), l.font.to_string()];
        let run = TextRun {
            ax: l.ax,
            ay: 20.0,
            w: 16.0,
            h: 10.0,
            hjust: 0.0,
            vjust: 0.0,
            rot: l.rot,
            color: BLACK,
            gid: &[36, 37],
            gx: &l.gx,
            gy: &[0.0, 0.0],
            gsize: &[0.0, 0.0],
            gpath: &gpath,
            gface: &[0, 0],
            gcolor: &[],
            rules: if l.rule { &rule } else { &[] },
            gtext: "",
            spans: &[],
            halo: l.halo,
            label: "ab",
            family: "",
            face: "",
            size: l.size,
            dpi: 72.0,
        };
        pdf(|b| b.draw_text(&run, Transform::identity(), &no_clip())).0
    }

    #[test]
    fn a_label_with_a_missing_size_or_anchor_is_skipped() {
        let blank = pdf(|_| {}).0;
        // Positive controls: a valid label (glyphs, and glyphs plus a rule)
        // draws something, so the comparisons below can fail.
        assert!(label_pdf(&Label::default()) != blank);
        assert!(
            label_pdf(&Label {
                rule: true,
                ..Label::default()
            }) != label_pdf(&Label::default())
        );
        for (size, ax, rot) in [
            (NAN, 10.0, 0.0),
            (INF, 10.0, 0.0),
            (-3.0, 10.0, 0.0),
            (10.0, NAN, 0.0),
            (10.0, 1e30, 0.0),
            (10.0, 10.0, NAN),
        ] {
            let got = label_pdf(&Label {
                size,
                ax,
                rot,
                rule: true,
                ..Label::default()
            });
            assert!(got == blank, "size {size}, ax {ax}, rot {rot}");
        }
    }

    #[test]
    fn a_glyph_run_with_a_missing_offset_is_skipped() {
        // Reaches the per-run guard: the label itself is placeable, one run is
        // not. It then draws exactly what an unloadable font draws: nothing,
        // inside the label's pushed state.
        let no_font = label_pdf(&Label {
            font: "/nonexistent/font.otf",
            ..Label::default()
        });
        assert!(label_pdf(&Label::default()) != no_font);
        for gx in [[0.0, NAN], [INF, 8.0]] {
            assert!(
                label_pdf(&Label {
                    gx,
                    ..Label::default()
                }) == no_font
            );
        }
    }

    #[test]
    fn a_halo_with_a_missing_width_is_dropped() {
        let plain = label_pdf(&Label::default());
        let red = Rgba {
            r: 255,
            g: 0,
            b: 0,
            a: 255,
        };
        // Positive control: a real halo adds a stroke pass.
        assert!(
            label_pdf(&Label {
                halo: Some((red, 2.0)),
                ..Label::default()
            }) != plain
        );
        for hw in [NAN, INF] {
            let got = label_pdf(&Label {
                halo: Some((red, hw)),
                ..Label::default()
            });
            assert!(got == plain, "halo width {hw}");
        }
    }

    #[test]
    fn a_box_that_overflows_under_the_page_scale_is_skipped() {
        // At 36 dpi the root scale is 2: a finite box near f32::MAX in px
        // overflows in pt inside krilla.
        let blank = {
            let mut doc = krilla::Document::new();
            let mut page =
                doc.start_page_with(krilla::page::PageSettings::from_wh(75.0, 75.0).unwrap());
            let mut surface = page.surface();
            surface.push_transform(&KTransform::from_scale(2.0, 2.0));
            {
                let _ = PdfBackend::new(&mut surface, 2.0, 37, 37);
            }
            surface.pop();
            surface.finish();
            page.finish();
            doc.finish().unwrap()
        };
        let mut doc = krilla::Document::new();
        let mut page =
            doc.start_page_with(krilla::page::PageSettings::from_wh(75.0, 75.0).unwrap());
        let mut surface = page.surface();
        surface.push_transform(&KTransform::from_scale(2.0, 2.0));
        {
            let mut b = PdfBackend::new(&mut surface, 2.0, 37, 37);
            let huge = tiny_skia::PathBuilder::from_rect(
                tiny_skia::Rect::from_xywh(2.0e38, 0.0, 1.0e38, 10.0).unwrap(),
            );
            b.fill_path(
                &huge,
                Transform::identity(),
                &ResolvedPaint::Solid(BLACK),
                FillRule::Winding,
                &no_clip(),
            );
        }
        surface.pop();
        surface.finish();
        page.finish();
        assert!(doc.finish().unwrap() == blank);
    }

    #[test]
    fn circles_with_a_missing_radius_or_centre_draw_nothing() {
        // The batched circle path (vellumplot's plain points) shares the guard
        // with the markers, so every backend drops the same elements.
        let base = pdf(|_| {}).0;
        let (bytes, _) = pdf(|b| {
            b.draw_circles(
                &[10.0, NAN, 30.0, 40.0],
                &[10.0, 20.0, INF, 40.0],
                &[NAN, 2.0, 2.0, -1.0],
                Some(&ResolvedPaint::Solid(BLACK)),
                Some((BLACK, style(1.0))),
                Transform::identity(),
                &no_clip(),
                &[],
            )
        });
        assert!(bytes == base);
    }
}
