//! The scene graph and its rasterization to a tiny-skia pixmap.
//!
//! The scene holds a **tree of viewports** (an arena) and a flat list of
//! primitives, each tagged with the viewport it was drawn into. A layout pass
//! ([`Scene::resolve_all`]) walks the tree top-down, computing each viewport's
//! affine transform (placement + rotation), its size, its accumulated graphical
//! parameters, and its clip mask — then rendering draws each primitive in its
//! viewport's local pixels through that transform and clip.
//!
//! The `Scene` is held in Rust and exposed to R as an external-pointer object.
use std::cell::{Ref, RefCell};
use std::collections::HashMap;
use std::sync::Arc;

use extendr_api::prelude::*;
use tiny_skia::{FillRule, Mask, PathBuilder, Pixmap, Transform};

use crate::render::{
    hexagon_path, hexagon_path_xy, push_circle_precise, push_far_poly, rect_path, roundrect_path,
    roundrect_ring_in, sector_path, sector_path_in, xml_escape, BlendKind, Clip, ClipShape, FarWin,
    GroupEffect, MaskKind, MaskLayer, PdfBackend, RasterBackend, RenderBackend, ResolvedPaint,
    Shadow, StrokeStyle, SvgBackend, TextRun,
};
use crate::render::{
    pptx_package, resolve_media, write_media_files, DmlBackend, SlidePart, EMU_PER_INCH,
};

use crate::cache::TwoGenCache;
use crate::color::{opt_color, Gpar, GparAcc, Lty, Paint, PartialGpar, Rgba};
use crate::geom::{
    parts_bbox, parts_cover, parts_dist, parts_rule, parts_runs, union_bbox, RecordBackend,
    Recording,
};
use crate::spatial::{Item as SpatialItem, Region, SpatialIndex};
use crate::units::{rotation_about, Affine, Unit, UnitKind, Vp, PRECISE_PX};

mod dlist;
mod draw;
mod layout;
mod marks;
mod node;
mod paint;
mod query;
mod shapes;
mod subraster;

use layout::*;
use marks::*;
use node::*;
use paint::*;
use shapes::*;
use subraster::*;

pub use draw::{set_profiling, take_node_times};
pub use ffi::get_scene_metadata;
pub use node::NodeMeta;
pub use shapes::set_simplify_tol;
pub use subraster::{clear_subraster_cache, subraster_stats};

// Non-reactive keyframe animation: interpolate between compiled scenes and render
// the tweened frames in parallel. A child module, so it can reach this module's
// private `Scene`/`Node` internals directly (see scene/tween.rs).
mod tween;

/// A drawing scene held in the Rust backend. Internal: the public R API is the
/// S7 layer (`vl_scene()`, grobs, `render()`), which compiles to this object.
/// @keywords internal
#[extendr]
#[derive(Clone, Debug)]
pub struct Scene {
    w_px: u32,
    h_px: u32,
    dpi: f64,
    bg: Rgba,
    viewports: Vec<ViewportNode>,
    current: usize,
    nodes: Vec<(usize, Node)>,
    /// Mask definitions, referenced by index from `Node::GroupEnd`.
    masks: Vec<MaskDef>,
    /// Stack of mask indices currently being filled (nested mask compilation);
    /// while non-empty, new primitives are routed to the top mask's content.
    mask_target: Vec<usize>,
    /// Hit-test pick id for each entry in `nodes` (parallel). Set by `set_pick`
    /// before compiling each grob; used by `hit_test`'s colour pick-buffer.
    picks: Vec<i32>,
    cur_pick: i32,
    /// Semantic metadata for each entry in `nodes` (parallel). Set by `set_meta`
    /// before compiling each grob; emitted by vector backends as `data-*`/`role`.
    meta: Vec<NodeMeta>,
    cur_meta: NodeMeta,
    /// Lazy full-page raster memo (see `cached_pixmap`). A compiled `Scene` is
    /// immutable after building — every method below is `&self` and none mutate
    /// the drawn content — so this needs no invalidation. The R side keys a
    /// compiled `Scene` on an object-identity token and reuses it across renders,
    /// so this memo makes a repeated rasterisation (a `display()` redraw at the
    /// same size, an animation frame replayed) free. INVARIANT: do not add a
    /// method that mutates `nodes`/`viewports`/`masks` after compilation without
    /// clearing this cache first.
    raster_cache: RefCell<Option<Pixmap>>,
    /// Lazy memo of the recorded element geometry every query reads (see
    /// `recording` and `geom.rs`). Same invariant as `raster_cache`, and
    /// additionally dropped by `emit_node`, so a scene drawn into after a query
    /// is re-recorded rather than answering from stale geometry.
    geom_cache: RefCell<Option<Arc<Recording>>>,
    /// Lazy memo of the uniform-grid spatial index over the keyed elements
    /// (`spatial.rs`), built from `geom_cache`'s recording for `vl_nearest()`,
    /// `vl_brush()` and `vl_lasso()`. Dropped with it, by `emit_node`.
    spatial_cache: RefCell<Option<Arc<crate::spatial::SpatialIndex>>>,
    /// Total glyphs across all text nodes, accumulated at compile. Drives the
    /// glyph-bitmap fast path's per-render threshold (see `cached_pixmap`/`render_png`).
    text_glyphs: usize,
    /// Scene-level accessibility: an accessible name (`a11y_title`) and long
    /// description (`a11y_desc`), plus an id prefix to uniquify the emitted
    /// `<title>`/`<desc>` ids. Empty => no a11y markup (output unchanged). Set from
    /// R via `set_a11y`; consumed by the SVG (`role="img"`) and PDF (tagged) paths.
    a11y_title: String,
    a11y_desc: String,
    a11y_prefix: String,
}

// Declared after `Scene` on purpose: extendr collects the struct's doc comment
// when `#[extendr] struct Scene` expands and attaches it to the R wrappers when
// the `#[extendr] impl` in `ffi.rs` expands, so the struct must come first.
mod ffi;

thread_local! {
    /// CVD simulation for the current render, set from R per call (see
    /// `rs_set_cvd_mode`). A post-pass over the finished pixmap, so it is off the
    /// drawing path entirely and costs nothing when unset.
    static CVD_MODE: std::cell::Cell<Option<crate::cvd::Cvd>> = const { std::cell::Cell::new(None) };
}

/// Set the CVD simulation for subsequent renders on this thread.
pub fn set_cvd_mode(kind: Option<crate::cvd::Cvd>) {
    CVD_MODE.with(|c| c.set(kind));
}

fn cvd_mode() -> Option<crate::cvd::Cvd> {
    CVD_MODE.with(|c| c.get())
}

/// Enable the glyph-bitmap fast path once a render draws at least this many
/// glyphs (auto mode): the per-glyph sprite cache pays off for dense text and is
/// pointless for a handful of labels. Mirrors the marker-sprite `SPRITE_MIN`.
const GLYPH_BITMAP_MIN: usize = 2_000;

/// Serialize several scenes as the pages of one PDF.
///
/// Pages may differ in size -- krilla sets the box per page -- which is what
/// makes this useful for a report rather than only for facet-by-page.
///
/// Returns `(warnings, bytes)`; `bytes` is empty when a path was given and the
/// file was written instead.
pub(crate) fn pdf_pages(scenes: List, path: Option<&str>) -> (Vec<String>, Vec<u8>) {
    if scenes.is_empty() {
        throw_r_error("a PDF needs at least one page");
    }
    let mut doc = krilla::Document::new();
    let mut warnings: Vec<String> = Vec::new();
    let mut groups: Vec<krilla::tagging::TagGroup> = Vec::new();
    for robj in scenes.values() {
        let ep = <ExternalPtr<Scene>>::try_from(robj)
            .unwrap_or_else(|_| throw_r_error("pages must be compiled vellum scenes"));
        let (warns, group) = ep.add_pdf_page(&mut doc);
        for w in warns {
            // The same degradation usually recurs on every page; the user needs
            // to hear it once.
            if !warnings.contains(&w) {
                warnings.push(w);
            }
        }
        if let Some(g) = group {
            groups.push(g);
        }
    }
    // One tree for the whole document, with each tagged page a top-level figure.
    if !groups.is_empty() {
        let mut tree = krilla::tagging::TagTree::new();
        for g in groups {
            tree.push(g);
        }
        doc.set_tag_tree(tree);
    }
    let bytes = match doc.finish() {
        Ok(b) => b,
        Err(e) => throw_r_error(format!("failed to serialize PDF: {e}")),
    };
    match path {
        Some(p) => {
            if let Err(e) = std::fs::write(p, bytes) {
                throw_r_error(format!("failed to write PDF: {e}"));
            }
            (warnings, Vec::new())
        }
        None => (warnings, bytes),
    }
}

/// Several scenes as the slides of one `.pptx`, returned as bytes with the
/// degradation warnings (de-duplicated across slides). A presentation has one
/// slide size, so it takes the largest page; a smaller page is centred.
pub(crate) fn pptx_pages(scenes: List, outline_text: bool, title: &str) -> (Vec<String>, Vec<u8>) {
    if scenes.is_empty() {
        throw_r_error("a presentation needs at least one slide");
    }
    let eps: Vec<ExternalPtr<Scene>> = scenes
        .values()
        .map(|r| {
            <ExternalPtr<Scene>>::try_from(r)
                .unwrap_or_else(|_| throw_r_error("slides must be compiled vellum scenes"))
        })
        .collect();
    let emu = |px: u32, dpi: f64| (px as f64 * EMU_PER_INCH / dpi).round() as i64;
    let sizes: Vec<(i64, i64)> = eps
        .iter()
        .map(|s| (emu(s.w_px, s.dpi), emu(s.h_px, s.dpi)))
        .collect();
    // PowerPoint's slide size range: 1 to 56 inches each way.
    let (min, max) = (914_400i64, 51_206_400i64);
    let cx = sizes.iter().map(|s| s.0).max().unwrap_or(min).max(min);
    let cy = sizes.iter().map(|s| s.1).max().unwrap_or(min).max(min);
    if cx > max || cy > max {
        throw_r_error("a PowerPoint slide is at most 56 inches on a side");
    }
    let mut warnings: Vec<String> = Vec::new();
    let mut slides = Vec::with_capacity(eps.len());
    for (s, (w, h)) in eps.iter().zip(sizes) {
        let (xml, media, warns) = s.dml_parts((cx - w) / 2, (cy - h) / 2, outline_text);
        for w in warns {
            if !warnings.contains(&w) {
                warnings.push(w);
            }
        }
        slides.push(SlidePart { xml, media });
    }
    let title = if title.is_empty() {
        eps[0].a11y_title.as_str()
    } else {
        title
    };
    (warnings, pptx_package(&slides, cx, cy, title))
}

// Non-exported helpers on `Scene`. extendr exports every method of an
// `#[extendr] impl` block, so anything with a non-FFI signature lives here.
impl Scene {
    /// The scene as a DrawingML fragment placed `(left, top)` EMU from the
    /// slide corner: `(xml with media tokens, PNGs, warnings)`.
    pub(crate) fn dml_parts(
        &self,
        left: i64,
        top: i64,
        outline_text: bool,
    ) -> (String, Vec<Vec<u8>>, Vec<String>) {
        let mut b = DmlBackend::new(
            self.w_px,
            self.h_px,
            self.dpi,
            self.bg,
            left,
            top,
            outline_text,
        );
        b.set_a11y(&self.a11y_title, &self.a11y_desc);
        // A blended group composites onto what lies beneath it, so the backend
        // keeps a raster of the page when the scene has one.
        if self.nodes.iter().any(
            |(_, n)| matches!(n, Node::GroupStart { blend, .. } if *blend != BlendKind::Normal),
        ) {
            b.enable_mirror(self.bg);
        }
        let warnings = self.render_to(&mut b);
        let (xml, media, _) = b.finish();
        (xml, media, warnings)
    }

    /// Serialize the scene as a PDF document, returning `(bytes, warnings)`.
    /// Shared by `render_pdf` (writes a file) and `render_pdf_raw` (returns the
    /// bytes to R), so the two can never drift.
    /// Drop the document-level accessibility strings.
    ///
    /// Used when a scene becomes one *frame* of an animation: the title and
    /// description belong to the document, and repeating them per frame would
    /// have a screen reader announce the figure once for every frame.
    pub(crate) fn clear_a11y(&mut self) {
        self.a11y_title.clear();
        self.a11y_desc.clear();
    }

    /// `render_svg_string` for internal callers (the animated-SVG builder).
    ///
    /// `id_prefix` namespaces the generated `<defs>` ids; the animated-SVG builder
    /// passes a per-frame value because all frames share one document.
    pub(crate) fn svg_string(&self, outline_text: bool, id_prefix: &str) -> String {
        let mut b = SvgBackend::new(self.w_px, self.h_px, self.bg, outline_text);
        b.set_a11y(&self.a11y_title, &self.a11y_desc, &self.a11y_prefix);
        b.set_id_prefix(id_prefix);
        let _warnings = self.render_to(&mut b);
        b.into_string()
    }

    fn pdf_bytes(&self) -> (Vec<u8>, Vec<String>) {
        let mut doc = krilla::Document::new();
        let (warnings, group) = self.add_pdf_page(&mut doc);
        if let Some(g) = group {
            let mut tree = krilla::tagging::TagTree::new();
            tree.push(g);
            doc.set_tag_tree(tree);
        }
        match doc.finish() {
            Ok(bytes) => (bytes, warnings),
            Err(e) => throw_r_error(format!("failed to serialize PDF: {e}")),
        }
    }

    /// Draw this scene as one more page of `doc`.
    ///
    /// Returns the page's degradation warnings and, if it has any tagged
    /// content, the structure group to put in the document's tag tree.
    ///
    /// It returns the group rather than setting the tree itself because a
    /// document has exactly ONE tag tree: a per-page `set_tag_tree` would have
    /// each page discard the previous page's, orphaning its content
    /// identifiers -- which krilla rejects outright when the document is
    /// serialised. The caller assembles all the pages' groups into one tree.
    ///
    /// Split out of `pdf_bytes` so a multi-page document is the *same* code per
    /// page: a second page-drawing path would drift from the first, and the
    /// tagging in particular is easy to get subtly wrong twice.
    fn add_pdf_page(
        &self,
        doc: &mut krilla::Document,
    ) -> (Vec<String>, Option<krilla::tagging::TagGroup>) {
        let scale = 72.0 / self.dpi as f32;
        let w_pt = self.w_px as f32 * scale;
        let h_pt = self.h_px as f32 * scale;
        let settings = match krilla::page::PageSettings::from_wh(w_pt, h_pt) {
            Some(s) => s,
            None => throw_r_error("invalid PDF page size"),
        };
        let mut page = doc.start_page_with(settings);
        let mut surface = page.surface();
        // One root transform maps device pixels -> PDF points.
        surface.push_transform(&krilla::geom::Transform::from_scale(scale, scale));
        // Accessibility: when the scene is described, bracket all drawn content
        // with a tagged marker so it can be attached to a Figure (with Alt text)
        // in the structure tree below — a tagged PDF (WCAG 1.1.1). Absent => an
        // ordinary, untagged PDF (unchanged).
        let alt = if !self.a11y_desc.is_empty() {
            self.a11y_desc.as_str()
        } else {
            self.a11y_title.as_str()
        };
        // Per-mark tagging and a single whole-content span are mutually
        // exclusive: PDF does not allow one tagged content span inside another,
        // and krilla aborts rather than emitting an invalid stream.
        //
        // So when any node carries *meaningful* metadata, the marks own the
        // tagging and the root Figure is built from them. When none does — either
        // no metadata at all, or only decorative nodes (artifacts) — the whole page
        // is one Figure and the marks are its visual content. A decorative node
        // must not count here: an all-decorative chart (every mark tagged
        // `role = "presentation"`) is exactly the one-Figure case, not a per-mark
        // one. This keeps every existing metadata-free scene byte-for-byte
        // unchanged.
        let per_mark = self
            .meta
            .iter()
            .any(|m| !m.is_empty() && !crate::render::is_decorative(m));
        let tag_id = if alt.is_empty() || per_mark {
            None
        } else {
            Some(surface.start_tagged(krilla::tagging::ContentTag::Other))
        };
        // The walk is guarded against the geometry krilla cannot take (see
        // `render::pdf::drawable`), but a panic inside krilla must still never
        // reach the `Surface` / `Page` destructors: they assert that every push
        // was popped, and a panic in a destructor while unwinding aborts the R
        // process (VR-38). So catch it here, leak the half-built page rather
        // than run those destructors, and keep unwinding with a clear message:
        // the extendr wrapper of every PDF entry point catches it and raises an
        // ordinary R error, after the Rust frames between have been dropped
        // normally (no longjmp over them).
        let drawn = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut b = PdfBackend::new(&mut surface, scale, self.w_px, self.h_px);
            // With the whole-content span open, per-node tagging stands down (no
            // nested spans); the decorative marks draw as the figure's content.
            b.set_outer_tagged(tag_id.is_some());
            b.fill_background(self.w_px, self.h_px, self.bg);
            let w = self.render_to(&mut b);
            (w, b.take_tagged())
        }));
        let (warnings, marks) = match drawn {
            Ok(v) => v,
            Err(payload) => {
                std::mem::forget(surface);
                std::mem::forget(page);
                std::panic::resume_unwind(Box::new(format!(
                    "PDF rendering failed: {}",
                    crate::render::panic_message(payload.as_ref())
                )));
            }
        };
        if tag_id.is_some() {
            surface.end_tagged();
        }
        surface.pop();
        surface.finish();
        page.finish();
        // Build the structure tree.
        //
        // Two levels: the figure as a whole (carrying the scene's `describe()`
        // text), and one entry per named/roled mark inside it. Draw order IS
        // reading order for a graphic -- it is the order the author put the
        // marks in -- so the children go in unchanged.
        //
        // A scene with neither a description nor any marked-up node gets no tree
        // at all, and its PDF is byte-for-byte what it was before tagging
        // existed.
        let group = if tag_id.is_some() || !marks.is_empty() {
            let root_alt = if alt.is_empty() { "figure" } else { alt };
            let mut figure = krilla::tagging::TagGroup::new(krilla::tagging::Tag::Figure(Some(
                root_alt.to_string(),
            )));
            if let Some(id) = tag_id {
                figure.push(id);
            }
            for (id, meta) in marks {
                let mut g = krilla::tagging::TagGroup::new(crate::render::pdf_tag(&meta));
                g.push(id);
                figure.push(g);
            }
            Some(figure)
        } else {
            None
        };
        (warnings, group)
    }
}

impl Scene {
    /// Append a primitive to the current draw target: the mask being filled (if
    /// any), else the drawn scene. Tagged with the current viewport.
    fn emit_node(&mut self, node: Node) {
        *self.geom_cache.get_mut() = None;
        *self.spatial_cache.get_mut() = None;
        let vp = self.current;
        match self.mask_target.last() {
            Some(&mi) => self.masks[mi].nodes.push((vp, node)),
            None => {
                self.nodes.push((vp, node));
                self.picks.push(self.cur_pick);
                self.meta.push(self.cur_meta.clone());
            }
        }
    }
}
