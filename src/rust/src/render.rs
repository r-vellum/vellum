//! Render backends.
//!
//! The scene walk (`scene.rs`) resolves each node to a primitive path, an
//! absolute transform, a colour, and a clip region, then emits it through the
//! [`RenderBackend`] trait. tiny-skia raster is one implementation; SVG (and PDF,
//! later) are others. Geometry is carried as `tiny_skia::Path` + `Transform`.

use std::collections::HashMap;
use std::rc::Rc;

use tiny_skia::{FilterQuality, FillRule, Mask, Paint, Path, PathBuilder, Pixmap, Stroke, Transform};

use crate::color::{Extend, Rgba, Stop};
use crate::font::FontCache;
use crate::units::rotation_about;

/// A fill paint with geometry resolved to viewport-local pixels (the backend's
/// own draw transform then maps it to device space, exactly like the path).
pub enum ResolvedPaint {
    Solid(Rgba),
    Linear { x1: f64, y1: f64, x2: f64, y2: f64, stops: Vec<Stop>, extend: Extend },
    Radial { cx: f64, cy: f64, r: f64, stops: Vec<Stop>, extend: Extend },
    /// A tiled image: `tile` is straight RGBA (`tw` x `th`, top-left); it fills a
    /// `w` x `h` (px) cell centred at `(x, y)` and repeats per `extend`. `opacity`
    /// is the folded gpar alpha (applied without touching the shared tile).
    Pattern { tile: Rc<Vec<u8>>, tw: u32, th: u32, x: f64, y: f64, w: f64, h: f64, extend: Extend, opacity: f32 },
}

/// One viewport rectangle contributing to a clip, in device space: a `w` x `h`
/// rectangle (viewport-local pixels) placed by `transform`.
#[derive(Clone, Copy, Debug)]
pub struct ClipRect {
    pub w: f64,
    pub h: f64,
    pub transform: Transform,
}

/// The clip applying to a draw: the intersection of `rects` (empty = no clip).
/// `id` identifies the originating viewport so backends can cache per-viewport
/// clip artifacts (a raster `Mask`, an SVG `<clipPath>`).
pub struct Clip<'a> {
    pub id: usize,
    pub rects: &'a [ClipRect],
}

/// Everything a backend needs to render one text node. Glyphs are pre-shaped
/// (raster fills outlines, PDF embeds them); `label`/`family`/`face`/`size` let
/// vector backends emit real `<text>` instead.
pub struct TextRun<'a> {
    pub ax: f64,
    pub ay: f64,
    pub w: f64,
    pub h: f64,
    pub hjust: f64,
    pub vjust: f64,
    pub rot: f64,
    pub color: Rgba,
    pub gid: &'a [u32],
    pub gx: &'a [f64],
    pub gy: &'a [f64],
    pub gsize: &'a [f64],
    pub gpath: &'a [String],
    pub gface: &'a [u32],
    pub label: &'a str,
    pub family: &'a str,
    pub face: &'a str,
    pub size: f64,
    pub dpi: f64,
}

/// How a mask's pixels modulate the group they cover.
#[derive(Clone, Copy, Debug)]
pub enum MaskKind {
    /// Use the mask's alpha channel as coverage.
    Alpha,
    /// Use the mask's luminance (`0.2126R + 0.7152G + 0.0722B`) as coverage.
    Luminance,
}

impl MaskKind {
    pub fn from_code(c: i32) -> MaskKind {
        match c {
            1 => MaskKind::Luminance,
            _ => MaskKind::Alpha,
        }
    }
}

/// A rendered mask handed to `end_group`: a page-sized RGBA raster plus how to
/// read coverage from it. The mask is always rasterized (uniform across output
/// formats); only how each backend *applies* it differs.
pub struct MaskLayer<'a> {
    pub pixmap: &'a Pixmap,
    pub kind: MaskKind,
}

/// A drawing target. The walk calls these in paint order. `begin_group` /
/// `end_group` bracket an isolated compositing layer: drawing in between targets
/// the layer, and `end_group` composites it back (optionally through a mask).
pub trait RenderBackend {
    fn fill_path(&mut self, path: &Path, transform: Transform, paint: &ResolvedPaint, clip: &Clip);
    fn stroke_path(&mut self, path: &Path, transform: Transform, color: Rgba, width_px: f32, clip: &Clip);
    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip);
    fn begin_group(&mut self);
    fn end_group(&mut self, mask: Option<MaskLayer>);

    /// Draw a batch of circles: centres `(cx, cy)` + radii `r` in local px,
    /// mapped to device by `transform`. The default places one unit circle per
    /// element; the raster backend overrides this to stamp a cached sprite for
    /// large uniform solid-fill point clouds. `stroke` is `(colour, width_px)`.
    fn draw_circles(
        &mut self,
        cx: &[f64],
        cy: &[f64],
        r: &[f64],
        fill: Option<&ResolvedPaint>,
        stroke: Option<(Rgba, f32)>,
        transform: Transform,
        clip: &Clip,
    ) where
        Self: Sized,
    {
        circles_by_path(self, cx, cy, r, fill, stroke, transform, clip);
    }
}

/// One unit circle (origin, radius 1) reused with a per-element affine transform.
/// Stroke width is pre-divided by the radius so it lands at `width_px` device px
/// after the uniform scale.
fn circles_by_path<B: RenderBackend>(
    b: &mut B,
    cx: &[f64],
    cy: &[f64],
    r: &[f64],
    fill: Option<&ResolvedPaint>,
    stroke: Option<(Rgba, f32)>,
    transform: Transform,
    clip: &Clip,
) {
    let n = cx.len().min(cy.len()).min(r.len());
    let unit = unit_circle_path();
    for i in 0..n {
        let rr = r[i];
        if rr <= 0.0 {
            continue;
        }
        let tr = transform.pre_concat(Transform::from_row(rr as f32, 0.0, 0.0, rr as f32, cx[i] as f32, cy[i] as f32));
        if let Some(f) = fill {
            b.fill_path(&unit, tr, f, clip);
        }
        if let Some((c, w)) = stroke {
            b.stroke_path(&unit, tr, c, w / rr as f32, clip);
        }
    }
}

fn unit_circle_path() -> Path {
    let mut pb = PathBuilder::new();
    pb.push_circle(0.0, 0.0, 1.0);
    pb.finish().expect("unit circle path")
}

fn skia_masktype(k: MaskKind) -> tiny_skia::MaskType {
    match k {
        MaskKind::Alpha => tiny_skia::MaskType::Alpha,
        MaskKind::Luminance => tiny_skia::MaskType::Luminance,
    }
}

// --- shared geometry helpers ------------------------------------------------

pub fn rect_path(x: f64, y: f64, w: f64, h: f64) -> Option<Path> {
    tiny_skia::Rect::from_xywh(x as f32, y as f32, w as f32, h as f32).map(PathBuilder::from_rect)
}

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
    paint.anti_alias = true;
    pm.fill_path(&path, &paint, FillRule::Winding, Transform::identity(), None);
    Some(pm)
}

/// Build a `Pixmap` from straight (non-premultiplied) RGBA bytes, top-left origin.
fn pixmap_from_straight(tile: &[u8], tw: u32, th: u32) -> Option<Pixmap> {
    let n = (tw as usize).checked_mul(th as usize)?;
    if tile.len() < n * 4 {
        return None;
    }
    let mut pm = Pixmap::new(tw, th)?;
    let px = pm.pixels_mut();
    for (i, p) in px.iter_mut().enumerate() {
        *p = tiny_skia::ColorU8::from_rgba(tile[4 * i], tile[4 * i + 1], tile[4 * i + 2], tile[4 * i + 3])
            .premultiply();
    }
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

/// Mean straight-RGBA colour of a tile (a solid stand-in where image fills are
/// unavailable, e.g. the PDF backend without `raster-images`).
fn average_rgba(tile: &[u8]) -> Rgba {
    let px = tile.len() / 4;
    if px == 0 {
        return Rgba { r: 0, g: 0, b: 0, a: 0 };
    }
    let (mut r, mut g, mut b, mut a) = (0u64, 0u64, 0u64, 0u64);
    for c in tile.chunks_exact(4) {
        r += c[0] as u64;
        g += c[1] as u64;
        b += c[2] as u64;
        a += c[3] as u64;
    }
    let n = px as u64;
    Rgba { r: (r / n) as u8, g: (g / n) as u8, b: (b / n) as u8, a: (a / n) as u8 }
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
    fonts: FontCache,
    masks: HashMap<usize, Option<Rc<Mask>>>,
    w: u32,
    h: u32,
}

impl RasterBackend {
    pub fn new(w: u32, h: u32, bg: Rgba) -> Self {
        let mut pm = Pixmap::new(w, h).expect("non-zero pixmap dimensions");
        // `Pixmap::new` is already zeroed (transparent); only paint a non-empty
        // background. This skips a full-page write for every rasterized mask,
        // whose backdrop is always transparent.
        if bg.a != 0 {
            pm.fill(bg.to_skia());
        }
        RasterBackend { targets: vec![pm], fonts: FontCache::default(), masks: HashMap::new(), w, h }
    }

    pub fn into_pixmap(mut self) -> Pixmap {
        // Balanced groups leave only the page; if not, the base is still first.
        self.targets.swap_remove(0)
    }

    fn target(&mut self) -> &mut Pixmap {
        self.targets.last_mut().expect("at least the page target")
    }

    fn mask_for(&mut self, clip: &Clip) -> Option<Rc<Mask>> {
        if clip.rects.is_empty() {
            return None;
        }
        if let Some(m) = self.masks.get(&clip.id) {
            return m.clone();
        }
        let mut m = page_mask(self.w, self.h);
        for r in clip.rects {
            match rect_path(0.0, 0.0, r.w, r.h) {
                Some(rect) => m.intersect_path(&rect, FillRule::Winding, true, r.transform),
                None => m.clear(),
            }
        }
        let m = Some(Rc::new(m));
        self.masks.insert(clip.id, m.clone());
        m
    }
}

fn solid_paint(color: Rgba) -> Paint<'static> {
    let mut paint = Paint::default();
    paint.set_color(color.to_skia());
    paint.anti_alias = true;
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
    stops.iter().map(|s| tiny_skia::GradientStop::new(s.offset, s.color.to_skia())).collect()
}

/// Build a tiny-skia paint for a resolved fill. Gradient geometry is in local px
/// with an identity gradient transform; `fill_path`'s ctm maps it like the path.
fn paint_for(paint: &ResolvedPaint) -> Option<Paint<'static>> {
    let shader = match paint {
        ResolvedPaint::Solid(c) => return Some(solid_paint(*c)),
        ResolvedPaint::Linear { x1, y1, x2, y2, stops, extend } => tiny_skia::LinearGradient::new(
            tiny_skia::Point::from_xy(*x1 as f32, *y1 as f32),
            tiny_skia::Point::from_xy(*x2 as f32, *y2 as f32),
            skia_stops(stops),
            skia_spread(*extend),
            Transform::identity(),
        ),
        ResolvedPaint::Radial { cx, cy, r, stops, extend } => tiny_skia::RadialGradient::new(
            tiny_skia::Point::from_xy(*cx as f32, *cy as f32),
            tiny_skia::Point::from_xy(*cx as f32, *cy as f32),
            *r as f32,
            skia_stops(stops),
            skia_spread(*extend),
            Transform::identity(),
        ),
        // Patterns borrow a Pixmap and are handled inline in RasterBackend::fill_path.
        ResolvedPaint::Pattern { .. } => return None,
    }?;
    let mut p = Paint::default();
    p.shader = shader;
    p.anti_alias = true;
    Some(p)
}

impl RenderBackend for RasterBackend {
    fn fill_path(&mut self, path: &Path, transform: Transform, paint: &ResolvedPaint, clip: &Clip) {
        let mask = self.mask_for(clip);
        if let ResolvedPaint::Pattern { tile, tw, th, x, y, w, h, extend, opacity } = paint {
            // The tile Pixmap must outlive the Pattern shader (it borrows it), so
            // build both here rather than via paint_for's `'static` return.
            let pm = match pixmap_from_straight(tile, *tw, *th) {
                Some(pm) => pm,
                None => return,
            };
            let t = pattern_transform(*tw, *th, *x, *y, *w, *h);
            let mut p = Paint::default();
            p.shader = tiny_skia::Pattern::new(pm.as_ref(), skia_spread(*extend), FilterQuality::Bilinear, *opacity, t);
            p.anti_alias = true;
            self.target().fill_path(path, &p, FillRule::Winding, transform, mask.as_deref());
            return;
        }
        if let Some(p) = paint_for(paint) {
            self.target().fill_path(path, &p, FillRule::Winding, transform, mask.as_deref());
        }
    }

    fn stroke_path(&mut self, path: &Path, transform: Transform, color: Rgba, width_px: f32, clip: &Clip) {
        if width_px <= 0.0 {
            return;
        }
        let mask = self.mask_for(clip);
        let stroke = Stroke { width: width_px, ..Stroke::default() };
        self.target().stroke_path(path, &solid_paint(color), &stroke, transform, mask.as_deref());
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        let mask = self.mask_for(clip);
        let paint = solid_paint(run.color);
        let base = if run.rot != 0.0 {
            transform.pre_concat(rotation_about(run.rot, run.ax, run.ay))
        } else {
            transform
        };
        let n = run.gid.len()
            .min(run.gx.len())
            .min(run.gy.len())
            .min(run.gsize.len())
            .min(run.gpath.len())
            .min(run.gface.len());
        for i in 0..n {
            let outline = match self.fonts.glyph_outline(&run.gpath[i], run.gface[i], run.gid[i], run.gsize[i] as f32) {
                Some(p) => p,
                None => continue,
            };
            let ox = run.ax + run.gx[i] - run.hjust * run.w;
            let oy = run.ay - (run.gy[i] - run.vjust * run.h);
            let place = Transform::from_row(1.0, 0.0, 0.0, -1.0, ox as f32, oy as f32);
            self.targets.last_mut().expect("at least the page target").fill_path(
                &outline,
                &paint,
                FillRule::Winding,
                base.pre_concat(place),
                mask.as_deref(),
            );
        }
    }

    fn begin_group(&mut self) {
        // A transparent isolated layer; subsequent drawing targets it.
        self.targets.push(Pixmap::new(self.w, self.h).expect("non-zero layer dimensions"));
    }

    fn end_group(&mut self, mask: Option<MaskLayer>) {
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
        let m = mask.map(|ml| Mask::from_pixmap(ml.pixmap.as_ref(), skia_masktype(ml.kind)));
        self.target().draw_pixmap(
            0,
            0,
            layer.as_ref(),
            &tiny_skia::PixmapPaint::default(),
            Transform::identity(),
            m.as_ref(),
        );
    }

    fn draw_circles(
        &mut self,
        cx: &[f64],
        cy: &[f64],
        r: &[f64],
        fill: Option<&ResolvedPaint>,
        stroke: Option<(Rgba, f32)>,
        transform: Transform,
        clip: &Clip,
    ) {
        // Sprite fast path: a large cloud of equal-radius, solid-fill, unstroked
        // markers. Rasterize the marker once and blit it per point (pixel-snapped,
        // imperceptible at the densities where it triggers). Anything else falls
        // back to per-element path fills.
        const SPRITE_MIN: usize = 10_000;
        let n = cx.len().min(cy.len()).min(r.len());
        let uniform_small = n >= SPRITE_MIN
            && stroke.is_none()
            && r[0] > 0.0
            && r[0] <= 64.0
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
                        let dx = transform.sx as f64 * cx[i] + transform.kx as f64 * cy[i] + transform.tx as f64;
                        let dy = transform.ky as f64 * cx[i] + transform.sy as f64 * cy[i] + transform.ty as f64;
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
        circles_by_path(self, cx, cy, r, fill, stroke, transform, clip);
    }
}

// --- SVG backend ------------------------------------------------------------

pub struct SvgBackend {
    w: u32,
    h: u32,
    defs: String,
    body: String,
    /// A stack of open group buffers; drawing appends to the top (or `body` when
    /// empty). `end_group` pops one and wraps it in a `<g>` (with a mask).
    groups: Vec<String>,
    clip_attrs: HashMap<usize, String>,
    /// Deduplicates gradient/pattern `<defs>` by content signature so repeated
    /// identical fills reference one def instead of emitting N copies.
    def_ids: HashMap<String, String>,
    next_clip: u32,
    next_grad: u32,
}

impl SvgBackend {
    pub fn new(w: u32, h: u32, bg: Rgba) -> Self {
        let mut body = String::new();
        if bg.a > 0 {
            body.push_str(&format!(
                "<rect width=\"{w}\" height=\"{h}\" fill=\"{}\" fill-opacity=\"{}\"/>",
                rgb_hex(bg),
                opacity(bg)
            ));
        }
        SvgBackend {
            w,
            h,
            defs: String::new(),
            body,
            groups: Vec::new(),
            clip_attrs: HashMap::new(),
            def_ids: HashMap::new(),
            next_clip: 0,
            next_grad: 0,
        }
    }

    /// Return the id of a `<defs>` entry with signature `key`, emitting it via
    /// `make(id)` the first time and reusing it afterwards.
    fn intern_def(&mut self, key: String, make: impl FnOnce(&str) -> String) -> String {
        if let Some(id) = self.def_ids.get(&key) {
            return id.clone();
        }
        let id = format!("g{}", self.next_grad);
        self.next_grad += 1;
        let def = make(&id);
        self.defs.push_str(&def);
        self.def_ids.insert(key, id.clone());
        id
    }

    /// The buffer currently receiving output: the innermost open group, else the
    /// document body.
    fn out(&mut self) -> &mut String {
        match self.groups.last_mut() {
            Some(b) => b,
            None => &mut self.body,
        }
    }

    /// The `fill="..."` attributes for a resolved paint (registers a gradient def
    /// when needed). Gradient coords are local px (`userSpaceOnUse`); the element's
    /// own `transform` maps them to device, exactly like the path geometry.
    fn svg_fill(&mut self, paint: &ResolvedPaint) -> String {
        match paint {
            ResolvedPaint::Solid(c) => format!("fill=\"{}\" fill-opacity=\"{}\"", rgb_hex(*c), opacity(*c)),
            ResolvedPaint::Linear { x1, y1, x2, y2, stops, extend } => {
                let stops_xml = svg_stops(stops);
                let s = svg_spread(*extend);
                let key = format!("L|{x1}|{y1}|{x2}|{y2}|{s}|{stops_xml}");
                let id = self.intern_def(key, |id| {
                    format!(
                        "<linearGradient id=\"{id}\" gradientUnits=\"userSpaceOnUse\" \
                         x1=\"{x1}\" y1=\"{y1}\" x2=\"{x2}\" y2=\"{y2}\" spreadMethod=\"{s}\">{stops_xml}</linearGradient>"
                    )
                });
                format!("fill=\"url(#{id})\"")
            }
            ResolvedPaint::Radial { cx, cy, r, stops, extend } => {
                let stops_xml = svg_stops(stops);
                let s = svg_spread(*extend);
                let key = format!("R|{cx}|{cy}|{r}|{s}|{stops_xml}");
                let id = self.intern_def(key, |id| {
                    format!(
                        "<radialGradient id=\"{id}\" gradientUnits=\"userSpaceOnUse\" \
                         cx=\"{cx}\" cy=\"{cy}\" r=\"{r}\" spreadMethod=\"{s}\">{stops_xml}</radialGradient>"
                    )
                });
                format!("fill=\"url(#{id})\"")
            }
            ResolvedPaint::Pattern { tile, tw, th, x, y, w, h, opacity, .. } => {
                // The tile is embedded as a PNG data URI and stretched over a
                // userSpaceOnUse cell; the element's own transform maps it to
                // device, like the path. (SVG patterns tile by repeat; the
                // reflect/pad extend modes degrade to repeat here.) Dedup by the
                // tile's `Rc` identity + geometry so we don't re-encode the PNG.
                let (px, py) = (x - w / 2.0, y - h / 2.0);
                let key = format!("P|{:p}|{px}|{py}|{w}|{h}", Rc::as_ptr(tile));
                let id = match self.def_ids.get(&key) {
                    Some(id) => id.clone(),
                    None => {
                        let png = pixmap_from_straight(tile, *tw, *th).and_then(|pm| pm.encode_png().ok());
                        let href = match png {
                            Some(bytes) => format!("data:image/png;base64,{}", b64(&bytes)),
                            None => return String::from("fill=\"none\""),
                        };
                        let id = format!("g{}", self.next_grad);
                        self.next_grad += 1;
                        self.defs.push_str(&format!(
                            "<pattern id=\"{id}\" patternUnits=\"userSpaceOnUse\" \
                             x=\"{px}\" y=\"{py}\" width=\"{w}\" height=\"{h}\">\
                             <image href=\"{href}\" x=\"0\" y=\"0\" width=\"{w}\" height=\"{h}\" \
                             preserveAspectRatio=\"none\"/></pattern>"
                        ));
                        self.def_ids.insert(key, id.clone());
                        id
                    }
                };
                let op = if *opacity < 1.0 { format!(" fill-opacity=\"{opacity}\"") } else { String::new() };
                format!("fill=\"url(#{id})\"{op}")
            }
        }
    }

    pub fn into_string(self) -> String {
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{w}\" height=\"{h}\" \
             viewBox=\"0 0 {w} {h}\"><defs>{defs}</defs>{body}</svg>\n",
            w = self.w,
            h = self.h,
            defs = self.defs,
            body = self.body
        )
    }

    /// Append `element`, wrapped in a clipping `<g>` when a clip applies. The
    /// clip group carries no transform, so its `userSpaceOnUse` clipPath (device
    /// coords) and the element's own `transform` both resolve in device space
    /// and stay aligned — putting `clip-path` directly on a transformed element
    /// would double-transform the clip region.
    fn emit(&mut self, element: &str, clip: &Clip) {
        let attr = self.clip_attr(clip);
        let wrapped = if attr.is_empty() {
            element.to_string()
        } else {
            format!("<g{attr}>{element}</g>")
        };
        self.out().push_str(&wrapped);
    }

    /// A ` clip-path="url(#…)"` attribute for this clip (empty string = none).
    /// Nested `<clipPath>` elements (each referencing the previous) intersect.
    fn clip_attr(&mut self, clip: &Clip) -> String {
        if clip.rects.is_empty() {
            return String::new();
        }
        if let Some(a) = self.clip_attrs.get(&clip.id) {
            return a.clone();
        }
        let mut parent_ref = String::new();
        let mut last = String::new();
        for r in clip.rects {
            let id = format!("c{}", self.next_clip);
            self.next_clip += 1;
            self.defs.push_str(&format!(
                "<clipPath id=\"{id}\" clipPathUnits=\"userSpaceOnUse\"{parent_ref}><path d=\"{d}\"/></clipPath>",
                d = rect_corners_d(r)
            ));
            parent_ref = format!(" clip-path=\"url(#{id})\"");
            last = id;
        }
        let attr = format!(" clip-path=\"url(#{last})\"");
        self.clip_attrs.insert(clip.id, attr.clone());
        attr
    }
}

impl RenderBackend for SvgBackend {
    fn fill_path(&mut self, path: &Path, transform: Transform, paint: &ResolvedPaint, clip: &Clip) {
        let fill = self.svg_fill(paint);
        let element = format!(
            "<path d=\"{}\" {fill}{}/>",
            path_to_d(path),
            transform_attr(transform),
        );
        self.emit(&element, clip);
    }

    fn stroke_path(&mut self, path: &Path, transform: Transform, color: Rgba, width_px: f32, clip: &Clip) {
        if width_px <= 0.0 {
            return;
        }
        let element = format!(
            "<path d=\"{}\" fill=\"none\" stroke=\"{}\" stroke-opacity=\"{}\" stroke-width=\"{}\"{}/>",
            path_to_d(path),
            rgb_hex(color),
            opacity(color),
            width_px,
            transform_attr(transform),
        );
        self.emit(&element, clip);
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        if run.label.is_empty() {
            return;
        }
        let anchor = match run.hjust {
            h if h <= 0.0 => "start",
            h if h >= 1.0 => "end",
            _ => "middle",
        };
        let baseline = match run.vjust {
            v if v <= 0.0 => "text-after-edge",
            v if v >= 1.0 => "text-before-edge",
            _ => "central",
        };
        // Local-px font size (the viewport transform is isometric, so 1 local
        // unit == 1 device px); shape_text size is in points.
        let font_px = run.size * run.dpi / 72.0;
        let weight = if run.face.contains("bold") { " font-weight=\"bold\"" } else { "" };
        let style = if run.face.contains("italic") || run.face.contains("oblique") {
            " font-style=\"italic\""
        } else {
            ""
        };
        let rot = if run.rot != 0.0 {
            // SVG rotate is clockwise in the y-down frame; grid angle is CCW.
            format!(" rotate({} {} {})", -run.rot, run.ax, run.ay)
        } else {
            String::new()
        };
        let family = if run.family.is_empty() { "sans-serif" } else { run.family };
        let element = format!(
            "<text x=\"{x}\" y=\"{y}\" transform=\"{t}{rot}\" fill=\"{col}\" fill-opacity=\"{op}\" \
             font-family=\"{fam}\" font-size=\"{size}\" text-anchor=\"{anchor}\" \
             dominant-baseline=\"{baseline}\"{weight}{style}>{label}</text>",
            x = run.ax,
            y = run.ay,
            t = matrix_str(transform),
            col = rgb_hex(run.color),
            op = opacity(run.color),
            fam = xml_escape(family),
            size = font_px,
            label = xml_escape(run.label),
        );
        self.emit(&element, clip);
    }

    fn begin_group(&mut self) {
        self.groups.push(String::new());
    }

    fn end_group(&mut self, mask: Option<MaskLayer>) {
        let inner = self.groups.pop().unwrap_or_default();
        // SVG masks are luminance-based; bake the chosen coverage into a grayscale
        // image (gray == coverage) so a single luminance mask serves both kinds.
        let wrapped = match mask.and_then(|ml| mask_png(ml.pixmap, ml.kind)) {
            Some(png) => {
                let id = format!("g{}", self.next_grad);
                self.next_grad += 1;
                self.defs.push_str(&format!(
                    "<mask id=\"{id}\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" \
                     width=\"{w}\" height=\"{h}\"><image href=\"data:image/png;base64,{b}\" \
                     x=\"0\" y=\"0\" width=\"{w}\" height=\"{h}\" preserveAspectRatio=\"none\"/></mask>",
                    w = self.w,
                    h = self.h,
                    b = b64(&png),
                ));
                format!("<g mask=\"url(#{id})\">{inner}</g>")
            }
            None => format!("<g>{inner}</g>"),
        };
        self.out().push_str(&wrapped);
    }
}

/// Encode a mask raster as an opaque grayscale PNG where each pixel's gray level
/// is its coverage (alpha or luminance), for use as an SVG luminance `<mask>`.
fn mask_png(pm: &Pixmap, kind: MaskKind) -> Option<Vec<u8>> {
    let mut out = Pixmap::new(pm.width(), pm.height())?;
    let src = pm.pixels();
    let dst = out.pixels_mut();
    for (s, d) in src.iter().zip(dst.iter_mut()) {
        let c = s.demultiply();
        let cov = match kind {
            MaskKind::Alpha => c.alpha(),
            MaskKind::Luminance => {
                (0.2126 * c.red() as f32 + 0.7152 * c.green() as f32 + 0.0722 * c.blue() as f32)
                    .round() as u8
            }
        };
        *d = tiny_skia::ColorU8::from_rgba(cov, cov, cov, 255).premultiply();
    }
    out.encode_png().ok()
}

// --- SVG serialization helpers ----------------------------------------------

fn rgb_hex(c: Rgba) -> String {
    format!("#{:02x}{:02x}{:02x}", c.r, c.g, c.b)
}

fn b64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn svg_spread(extend: Extend) -> &'static str {
    match extend {
        Extend::Pad => "pad",
        Extend::Repeat => "repeat",
        Extend::Reflect => "reflect",
    }
}

fn svg_stops(stops: &[Stop]) -> String {
    stops
        .iter()
        .map(|s| {
            format!(
                "<stop offset=\"{}\" stop-color=\"{}\" stop-opacity=\"{}\"/>",
                s.offset,
                rgb_hex(s.color),
                opacity(s.color)
            )
        })
        .collect()
}

fn opacity(c: Rgba) -> f32 {
    c.a as f32 / 255.0
}

fn matrix_str(t: Transform) -> String {
    format!("matrix({} {} {} {} {} {})", t.sx, t.ky, t.kx, t.sy, t.tx, t.ty)
}

fn transform_attr(t: Transform) -> String {
    if t.sx == 1.0 && t.ky == 0.0 && t.kx == 0.0 && t.sy == 1.0 && t.tx == 0.0 && t.ty == 0.0 {
        String::new()
    } else {
        format!(" transform=\"{}\"", matrix_str(t))
    }
}

fn path_to_d(path: &Path) -> String {
    use tiny_skia::PathSegment;
    let mut d = String::new();
    for seg in path.segments() {
        match seg {
            PathSegment::MoveTo(p) => d.push_str(&format!("M{} {} ", p.x, p.y)),
            PathSegment::LineTo(p) => d.push_str(&format!("L{} {} ", p.x, p.y)),
            PathSegment::QuadTo(c, p) => d.push_str(&format!("Q{} {} {} {} ", c.x, c.y, p.x, p.y)),
            PathSegment::CubicTo(c1, c2, p) => {
                d.push_str(&format!("C{} {} {} {} {} {} ", c1.x, c1.y, c2.x, c2.y, p.x, p.y))
            }
            PathSegment::Close => d.push('Z'),
        }
    }
    d.trim_end().to_string()
}

/// The four transformed corners of a `w` x `h` rect as a closed SVG path `d`.
fn rect_corners_d(r: &ClipRect) -> String {
    let pt = |x: f64, y: f64| {
        let dx = r.transform.sx as f64 * x + r.transform.kx as f64 * y + r.transform.tx as f64;
        let dy = r.transform.ky as f64 * x + r.transform.sy as f64 * y + r.transform.ty as f64;
        (dx, dy)
    };
    let (x0, y0) = pt(0.0, 0.0);
    let (x1, y1) = pt(r.w, 0.0);
    let (x2, y2) = pt(r.w, r.h);
    let (x3, y3) = pt(0.0, r.h);
    format!("M{x0} {y0} L{x1} {y1} L{x2} {y2} L{x3} {y3} Z")
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

// --- PDF backend (krilla) ---------------------------------------------------

use krilla::color::rgb;
use krilla::geom::{Path as KPath, PathBuilder as KPathBuilder, Point as KPoint, Transform as KTransform};
use krilla::num::NormalizedF32;
use krilla::paint::{
    Fill, FillRule as KFillRule, LinearGradient as KLinear, Paint as KPaint, RadialGradient as KRadial,
    SpreadMethod as KSpread, Stop as KStop, Stroke as KStroke,
};
use krilla::surface::Surface;
use krilla::text::{Font, GlyphId, KrillaGlyph};

/// Draws onto a krilla PDF surface. Geometry is converted from `tiny_skia`
/// types; everything is drawn in device pixels and a single root scale
/// (`72/dpi`) maps to PDF points.
pub struct PdfBackend<'a, 'b> {
    surface: &'a mut Surface<'b>,
    fonts: HashMap<(String, u32), Option<Font>>,
}

impl<'a, 'b> PdfBackend<'a, 'b> {
    pub fn new(surface: &'a mut Surface<'b>) -> Self {
        PdfBackend { surface, fonts: HashMap::new() }
    }

    /// Fill the page with the background colour (device-px page rect).
    pub fn fill_background(&mut self, w: u32, h: u32, bg: Rgba) {
        if bg.a == 0 {
            return;
        }
        if let Some(path) = rect_path(0.0, 0.0, w as f64, h as f64) {
            let empty = Clip { id: usize::MAX, rects: &[] };
            self.fill_path(&path, Transform::identity(), &ResolvedPaint::Solid(bg), &empty);
        }
    }

    /// Push clip paths (under the root scale) then the primitive transform;
    /// returns the number of `pop()`s needed to unwind.
    fn push_state(&mut self, transform: Transform, clip: &Clip) -> usize {
        let mut n = 0;
        for r in clip.rects {
            if let Some(p) = clip_rect_kpath(r) {
                self.surface.push_clip_path(&p, &KFillRule::NonZero);
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

impl RenderBackend for PdfBackend<'_, '_> {
    fn fill_path(&mut self, path: &Path, transform: Transform, paint: &ResolvedPaint, clip: &Clip) {
        let kp = match to_kpath(path) {
            Some(p) => p,
            None => return,
        };
        // Gradient geometry is local px (identity gradient transform); the
        // primitive `transform` pushed below maps it to device, like the path.
        let (kpaint, opacity) = match paint {
            ResolvedPaint::Solid(c) => (rgb::Color::new(c.r, c.g, c.b).into(), norm(c.a)),
            ResolvedPaint::Linear { x1, y1, x2, y2, stops, extend } => (
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
            ResolvedPaint::Radial { cx, cy, r, stops, extend } => (
                KPaint::from(KRadial {
                    fx: *cx as f32,
                    fy: *cy as f32,
                    fr: 0.0,
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
            // Image patterns need krilla's `raster-images` feature (extra vendored
            // codecs); until then a pattern degrades to its mean colour in PDF.
            ResolvedPaint::Pattern { tile, opacity, .. } => {
                let c = average_rgba(tile);
                let a = NormalizedF32::new((c.a as f32 / 255.0) * opacity).unwrap_or(NormalizedF32::ONE);
                (rgb::Color::new(c.r, c.g, c.b).into(), a)
            }
        };
        let n = self.push_state(transform, clip);
        self.surface.set_stroke(None);
        self.surface.set_fill(Some(Fill { paint: kpaint, opacity, rule: KFillRule::NonZero }));
        self.surface.draw_path(&kp);
        self.pop_state(n);
    }

    fn stroke_path(&mut self, path: &Path, transform: Transform, color: Rgba, width_px: f32, clip: &Clip) {
        if width_px <= 0.0 {
            return;
        }
        let kp = match to_kpath(path) {
            Some(p) => p,
            None => return,
        };
        let n = self.push_state(transform, clip);
        self.surface.set_fill(None);
        self.surface.set_stroke(Some(KStroke {
            paint: rgb::Color::new(color.r, color.g, color.b).into(),
            width: width_px,
            opacity: norm(color.a),
            ..KStroke::default()
        }));
        self.surface.draw_path(&kp);
        self.pop_state(n);
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        let n = run.gid.len()
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
        // Text origin (local px). Glyph i sits at origin + gx[i]; baseline y is
        // shared. Mirrors the raster placement.
        let start_x = (run.ax - run.hjust * run.w) as f32;
        let start_y = (run.ay - (run.gy[0] - run.vjust * run.h)) as f32;
        let base = if run.rot != 0.0 {
            transform.pre_concat(rotation_about(run.rot, run.ax, run.ay))
        } else {
            transform
        };

        // char byte boundaries for ToUnicode (exact when glyphs == chars).
        let bounds: Vec<usize> =
            run.label.char_indices().map(|(b, _)| b).chain(std::iter::once(run.label.len())).collect();
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
        self.surface.set_stroke(None);
        self.surface.set_fill(Some(Fill {
            paint: rgb::Color::new(run.color.r, run.color.g, run.color.b).into(),
            opacity: norm(run.color.a),
            rule: KFillRule::NonZero,
        }));

        // Draw in runs of consecutive glyphs sharing a font (handles fallback).
        let mut i = 0;
        while i < n {
            let (gpath, gface) = (&run.gpath[i], run.gface[i]);
            let mut j = i;
            while j < n && &run.gpath[j] == gpath && run.gface[j] == gface {
                j += 1;
            }
            if let Some(font) = self.font_for(gpath, gface) {
                let glyphs: Vec<KrillaGlyph> = (i..j)
                    .map(|k| {
                        KrillaGlyph::new(
                            GlyphId::new(run.gid[k]),
                            0.0,                              // x_advance (positions via x_offset)
                            run.gx[k] as f32 / size_px,       // x_offset, normalized
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
        self.pop_state(pushes);
    }

    // Masks need an image/transparency-group path krilla can't take without the
    // `raster-images` feature (un-vendored codecs); the group draws unmasked.
    fn begin_group(&mut self) {}
    fn end_group(&mut self, _mask: Option<MaskLayer>) {}
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

fn clip_rect_kpath(r: &ClipRect) -> Option<KPath> {
    let pt = |x: f64, y: f64| {
        let dx = r.transform.sx as f64 * x + r.transform.kx as f64 * y + r.transform.tx as f64;
        let dy = r.transform.ky as f64 * x + r.transform.sy as f64 * y + r.transform.ty as f64;
        (dx as f32, dy as f32)
    };
    let mut pb = KPathBuilder::new();
    let (x0, y0) = pt(0.0, 0.0);
    pb.move_to(x0, y0);
    let (x1, y1) = pt(r.w, 0.0);
    pb.line_to(x1, y1);
    let (x2, y2) = pt(r.w, r.h);
    pb.line_to(x2, y2);
    let (x3, y3) = pt(0.0, r.h);
    pb.line_to(x3, y3);
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
