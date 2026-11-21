//! The PDF backend, built on krilla.

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
}

impl<'a, 'b> PdfBackend<'a, 'b> {
    pub fn new(surface: &'a mut Surface<'b>) -> Self {
        PdfBackend {
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
                        let stream = {
                            let mut sb = self.surface.stream_builder();
                            let mut surf = sb.surface();
                            surf.draw_image(img, cell);
                            surf.finish();
                            sb.finish()
                        };
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
    /// returns the number of `pop()`s needed to unwind.
    fn push_state(&mut self, transform: Transform, clip: &Clip) -> usize {
        let mut n = 0;
        for shape in clip.shapes {
            let (kpath, rule) = match shape {
                ClipShape::Rect { w, h, transform } => {
                    (clip_rect_kpath(*w, *h, *transform), KFillRule::NonZero)
                }
                ClipShape::Path {
                    path,
                    evenodd,
                    transform,
                } => {
                    let dev = path
                        .clone()
                        .transform(*transform)
                        .and_then(|p| to_kpath(&p));
                    (
                        dev,
                        if *evenodd {
                            KFillRule::EvenOdd
                        } else {
                            KFillRule::NonZero
                        },
                    )
                }
            };
            if let Some(p) = kpath {
                self.surface.push_clip_path(&p, &rule);
                n += 1;
            }
        }
        self.surface.push_transform(&to_ktransform(transform));
        n + 1
    }

    fn pop_state(&mut self, n: usize) {
        for _ in 0..n {
            self.surface.pop();
        }
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
        let n = self.push_state(transform, clip);
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
        if stroke.width <= 0.0 {
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
        let n = self.push_state(transform, clip);
        self.surface.set_fill(None);
        self.surface.set_stroke(Some(KStroke {
            paint: kpaint,
            width: stroke.width,
            opacity: kopacity,
            miter_limit: stroke.miter,
            line_cap: krilla_cap(stroke.cap),
            line_join: krilla_join(stroke.join),
            dash: if stroke.dash.is_empty() {
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

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        let n = run
            .gid
            .len()
            .min(run.gx.len())
            .min(run.gy.len())
            .min(run.gsize.len())
            .min(run.gpath.len())
            .min(run.gface.len());
        if n == 0 || run.label.is_empty() {
            return; // n includes gy.len(), so gy[0] below is safe
        }
        let size_px = (run.size * run.dpi / 72.0) as f32;
        if size_px <= 0.0 {
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

        // char byte boundaries for ToUnicode (exact when glyphs == chars).
        let bounds: Vec<usize> = run
            .label
            .char_indices()
            .map(|(b, _)| b)
            .chain(std::iter::once(run.label.len()))
            .collect();
        let exact = n + 1 == bounds.len();
        let range_for = |i: usize| {
            if exact {
                bounds[i]..bounds[i + 1]
            } else if i == 0 {
                0..run.label.len()
            } else {
                0..0
            }
        };

        let pushes = self.push_state(base, clip);
        let rich = !run.gcolor.is_empty();
        // A halo means drawing the whole label twice: once stroke-only underneath,
        // then normally on top. PDF has a fill-and-stroke text mode, but it paints
        // the stroke *over* the fill, which is an outline, not a halo.
        let passes: &[bool] = if run.halo.is_some() {
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

            // Draw in runs of consecutive glyphs sharing a font AND a baseline (so a
            // line break, which changes gy, starts a new run handles font fallback too).
            // Rich labels additionally break on a colour change so each run gets its fill.
            let mut i = 0;
            while i < n {
                let (gpath, gface, gy0) = (&run.gpath[i], run.gface[i], run.gy[i]);
                let col0 = run.gcolor.get(i).copied();
                let mut j = i;
                while j < n
                    && &run.gpath[j] == gpath
                    && run.gface[j] == gface
                    && run.gy[j] == gy0
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
                if let Some(font) = self.font_for(gpath, gface) {
                    let glyphs: Vec<KrillaGlyph> = (i..j)
                        .map(|k| {
                            KrillaGlyph::new(
                                GlyphId::new(run.gid[k]),
                                0.0,                        // x_advance (positions via x_offset)
                                run.gx[k] as f32 / size_px, // x_offset, normalized
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
                        run.label,
                        size_px,
                        false,
                    );
                }
                i = j;
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
                let stream = {
                    let mut sb = self.surface.stream_builder();
                    let mut surf = sb.surface();
                    surf.draw_image(img, size);
                    surf.finish();
                    sb.finish()
                };
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
        let n = self.push_state(place, clip);
        self.surface.draw_image(img, size);
        self.pop_state(n);
    }

    fn take_warnings(&mut self) -> Vec<String> {
        std::mem::take(&mut self.warnings)
    }
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
