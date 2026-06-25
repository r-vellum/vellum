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

use extendr_api::prelude::*;
use tiny_skia::{PathBuilder, Pixmap, Transform};

use crate::render::{
    rect_path, Clip, ClipRect, PdfBackend, RasterBackend, RenderBackend, ResolvedPaint, SvgBackend, TextRun,
};

use crate::color::{opt_color, Gpar, GparAcc, Paint, PartialGpar, Rgba};
use crate::units::{rotation_about, Unit, Vp};

// --- layout ----------------------------------------------------------------

/// A layout track size: an absolute extent, or a flexible (`null`) weight.
#[derive(Clone, Copy, Debug)]
enum Track {
    Abs(f64, Unit),
    Null(f64),
}

#[derive(Clone, Debug)]
struct Layout {
    widths: Vec<Track>,  // columns
    heights: Vec<Track>, // rows
}

/// Pixel extent of one absolute track within `total` parent pixels.
fn track_abs_px(value: f64, u: Unit, total: f64, dpi: f64) -> f64 {
    match u {
        Unit::Npc | Unit::Native => value * total,
        Unit::Mm => value / 25.4 * dpi,
        Unit::Inch => value * dpi,
        Unit::Pt => value / 72.0 * dpi,
    }
}

/// Solve a list of tracks against `total` pixels into cumulative edge positions
/// (length `tracks.len() + 1`, starting at 0).
fn solve_tracks(tracks: &[Track], total: f64, dpi: f64) -> Vec<f64> {
    let mut sizes = vec![0.0; tracks.len()];
    let mut abs_sum = 0.0;
    let mut weight_sum = 0.0;
    for (i, t) in tracks.iter().enumerate() {
        match t {
            Track::Abs(v, u) => {
                sizes[i] = track_abs_px(*v, *u, total, dpi);
                abs_sum += sizes[i];
            }
            Track::Null(w) => weight_sum += w.max(0.0),
        }
    }
    let avail = (total - abs_sum).max(0.0);
    for (i, t) in tracks.iter().enumerate() {
        if let Track::Null(w) = t {
            sizes[i] = if weight_sum > 0.0 {
                avail * w.max(0.0) / weight_sum
            } else {
                0.0
            };
        }
    }
    let mut edges = vec![0.0; tracks.len() + 1];
    for i in 0..tracks.len() {
        edges[i + 1] = edges[i] + sizes[i];
    }
    edges
}

// --- viewport tree ----------------------------------------------------------

/// How a viewport is positioned within its parent.
#[derive(Clone, Copy, Debug)]
enum Placement {
    /// Centre `(cx, cy)` and size `(w, h)` in parent coordinates, each with its
    /// own unit.
    Absolute { cx: f64, cy: f64, w: f64, h: f64, cxu: Unit, cyu: Unit, wu: Unit, hu: Unit },
    /// A cell (0-based) of the parent's layout, possibly spanning.
    Cell { row: usize, col: usize, rowspan: usize, colspan: usize },
}

#[derive(Clone, Debug)]
struct ViewportNode {
    parent: Option<usize>,
    children: Vec<usize>,
    placement: Placement,
    xscale: (f64, f64),
    yscale: (f64, f64),
    angle: f64,
    clip: bool,
    gp: PartialGpar,
    layout: Option<Layout>,
}

/// A viewport after the layout pass: its local frame and effective context.
/// `clip_chain` is the list of clipping-ancestor rectangles to intersect
/// (empty = no clip); backends turn it into a mask / `<clipPath>` / PDF clip.
#[derive(Clone)]
struct ResolvedVp {
    vp: Vp,
    gp_acc: GparAcc,
    clip_chain: Vec<ClipRect>,
}

// --- primitives -------------------------------------------------------------

#[derive(Clone, Debug)]
enum Node {
    Rect { x: f64, y: f64, w: f64, h: f64, xu: Unit, yu: Unit, wu: Unit, hu: Unit, gp: PartialGpar },
    Lines { x: Vec<f64>, y: Vec<f64>, xu: Vec<Unit>, yu: Vec<Unit>, gp: PartialGpar },
    Polygon { x: Vec<f64>, y: Vec<f64>, xu: Vec<Unit>, yu: Vec<Unit>, gp: PartialGpar },
    Circle { x: f64, y: f64, r: f64, xu: Unit, yu: Unit, ru: Unit, gp: PartialGpar },
    Text {
        x: f64,
        y: f64,
        xu: Unit,
        yu: Unit,
        rot: f64,
        hjust: f64,
        vjust: f64,
        w: f64,
        h: f64,
        gid: Vec<u32>,
        gx: Vec<f64>,
        gy: Vec<f64>,
        gsize: Vec<f64>,
        gpath: Vec<String>,
        gface: Vec<u32>,
        /// Source string + font descriptor, for vector backends that emit real
        /// `<text>` / embedded glyphs rather than filled outlines.
        label: String,
        family: String,
        face: String,
        size: f64,
        gp: PartialGpar,
    },
}

impl Node {
    fn gp(&self) -> &PartialGpar {
        match self {
            Node::Rect { gp, .. }
            | Node::Lines { gp, .. }
            | Node::Polygon { gp, .. }
            | Node::Circle { gp, .. }
            | Node::Text { gp, .. } => gp,
        }
    }
}

/// A drawing scene held in the Rust backend. Internal: the public R API is the
/// S7 layer (`vl_scene()`, grobs, `render()`), which compiles to this object.
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
}

#[extendr]
impl Scene {
    /// Create a scene `width` x `height` inches at `dpi`, with background `bg`
    /// (a length-4 integer RGBA vector). A root viewport covering the whole page
    /// (npc == native) is created as viewport 0.
    fn new(width: f64, height: f64, dpi: f64, bg: Robj) -> Self {
        if !(width.is_finite() && height.is_finite() && dpi.is_finite())
            || width <= 0.0
            || height <= 0.0
            || dpi <= 0.0
        {
            throw_r_error("scene width, height, and dpi must be finite and positive");
        }
        let w_px = px_dim(width * dpi);
        let h_px = px_dim(height * dpi);
        let root = ViewportNode {
            parent: None,
            children: Vec::new(),
            placement: Placement::Absolute {
                cx: 0.5,
                cy: 0.5,
                w: 1.0,
                h: 1.0,
                cxu: Unit::Npc,
                cyu: Unit::Npc,
                wu: Unit::Npc,
                hu: Unit::Npc,
            },
            xscale: (0.0, 1.0),
            yscale: (0.0, 1.0),
            angle: 0.0,
            clip: false,
            gp: PartialGpar::from_robj(&rnull(), &rnull(), &rnull(), &rnull()),
            layout: None,
        };
        Scene {
            w_px,
            h_px,
            dpi,
            bg: opt_color(&bg).unwrap_or(Rgba::WHITE),
            viewports: vec![root],
            current: 0,
            nodes: Vec::new(),
        }
    }

    /// Push a viewport as a child of the current one and make it current.
    /// Returns the new viewport's id. If `lrow`/`lcol` are >= 0 the viewport is
    /// placed into that (0-based) cell of the parent's layout; otherwise it is
    /// placed by centre/size in parent coordinates.
    #[allow(clippy::too_many_arguments)]
    fn push_viewport(
        &mut self,
        cx: f64,
        cy: f64,
        w: f64,
        h: f64,
        cxu: i32,
        cyu: i32,
        wu: i32,
        hu: i32,
        xscale: &[f64],
        yscale: &[f64],
        angle: f64,
        clip: bool,
        lrow: i32,
        lcol: i32,
        lrowspan: i32,
        lcolspan: i32,
        fill: Robj,
        col: Robj,
        lwd: Robj,
        alpha: Robj,
    ) -> i32 {
        let placement = if lrow >= 0 && lcol >= 0 {
            Placement::Cell {
                row: lrow as usize,
                col: lcol as usize,
                rowspan: lrowspan.max(1) as usize,
                colspan: lcolspan.max(1) as usize,
            }
        } else {
            Placement::Absolute {
                cx,
                cy,
                w,
                h,
                cxu: Unit::from_code(cxu),
                cyu: Unit::from_code(cyu),
                wu: Unit::from_code(wu),
                hu: Unit::from_code(hu),
            }
        };
        let id = self.viewports.len();
        self.viewports.push(ViewportNode {
            parent: Some(self.current),
            children: Vec::new(),
            placement,
            xscale: pair(xscale, (0.0, 1.0)),
            yscale: pair(yscale, (0.0, 1.0)),
            angle,
            clip,
            gp: PartialGpar::from_robj(&fill, &col, &lwd, &alpha),
            layout: None,
        });
        self.viewports[self.current].children.push(id);
        self.current = id;
        id as i32
    }

    /// Move the cursor up `n` levels (towards the root). Stops at the root.
    fn pop_viewport(&mut self, n: i32) {
        for _ in 0..n.max(0) {
            if let Some(p) = self.viewports[self.current].parent {
                self.current = p;
            }
        }
    }

    /// Move the cursor to the root viewport.
    fn to_root(&mut self) {
        self.current = 0;
    }

    /// Attach a row/column layout to the current viewport. Tracks are given as
    /// parallel value + unit-code vectors; the unit `"null"` marks a flexible
    /// track whose value is its weight.
    fn set_layout(&mut self, wvals: &[f64], wunits: Vec<String>, hvals: &[f64], hunits: Vec<String>) {
        let widths = build_tracks(wvals, &wunits);
        let heights = build_tracks(hvals, &hunits);
        self.viewports[self.current].layout = Some(Layout { widths, heights });
    }

    #[allow(clippy::too_many_arguments)]
    fn rect(&mut self, x: f64, y: f64, w: f64, h: f64, xu: i32, yu: i32, wu: i32, hu: i32, fill: Robj, col: Robj, lwd: Robj, alpha: Robj) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha);
        self.nodes.push((
            self.current,
            Node::Rect {
                x,
                y,
                w,
                h,
                xu: Unit::from_code(xu),
                yu: Unit::from_code(yu),
                wu: Unit::from_code(wu),
                hu: Unit::from_code(hu),
                gp,
            },
        ));
    }

    fn lines(&mut self, x: &[f64], y: &[f64], xu: &[i32], yu: &[i32], col: Robj, lwd: Robj, alpha: Robj) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &lwd, &alpha);
        self.nodes.push((
            self.current,
            Node::Lines { x: x.to_vec(), y: y.to_vec(), xu: codes(xu), yu: codes(yu), gp },
        ));
    }

    #[allow(clippy::too_many_arguments)]
    fn polygon(&mut self, x: &[f64], y: &[f64], xu: &[i32], yu: &[i32], fill: Robj, col: Robj, lwd: Robj, alpha: Robj) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha);
        self.nodes.push((
            self.current,
            Node::Polygon { x: x.to_vec(), y: y.to_vec(), xu: codes(xu), yu: codes(yu), gp },
        ));
    }

    #[allow(clippy::too_many_arguments)]
    fn circle(&mut self, x: f64, y: f64, r: f64, xu: i32, yu: i32, ru: i32, fill: Robj, col: Robj, lwd: Robj, alpha: Robj) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha);
        self.nodes.push((
            self.current,
            Node::Circle { x, y, r, xu: Unit::from_code(xu), yu: Unit::from_code(yu), ru: Unit::from_code(ru), gp },
        ));
    }

    /// Add pre-shaped text. The R wrapper does shaping (via `textshaping`) and
    /// passes per-glyph ids/positions/fonts plus the block size.
    #[allow(clippy::too_many_arguments)]
    fn text(
        &mut self,
        x: f64,
        y: f64,
        xu: i32,
        yu: i32,
        rot: f64,
        hjust: f64,
        vjust: f64,
        w: f64,
        h: f64,
        gid: &[i32],
        gx: &[f64],
        gy: &[f64],
        gsize: &[f64],
        gpath: Vec<String>,
        gface: &[i32],
        label: &str,
        family: &str,
        face: &str,
        size: f64,
        col: Robj,
        alpha: Robj,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &rnull(), &alpha);
        self.nodes.push((
            self.current,
            Node::Text {
                x,
                y,
                xu: Unit::from_code(xu),
                yu: Unit::from_code(yu),
                rot,
                hjust,
                vjust,
                w,
                h,
                gid: gid.iter().map(|&v| v.max(0) as u32).collect(),
                gx: gx.to_vec(),
                gy: gy.to_vec(),
                gsize: gsize.to_vec(),
                gpath,
                gface: gface.iter().map(|&v| v.max(0) as u32).collect(),
                label: label.to_string(),
                family: family.to_string(),
                face: face.to_string(),
                size,
                gp,
            },
        ));
    }

    /// Number of primitives currently in the scene.
    fn len(&self) -> i32 {
        self.nodes.len() as i32
    }

    /// Device dimensions in pixels, `c(width, height)`.
    fn dim(&self) -> Vec<i32> {
        vec![self.w_px as i32, self.h_px as i32]
    }

    /// Device resolution in dots per inch.
    fn dpi(&self) -> f64 {
        self.dpi
    }

    /// Render the scene to a PNG file.
    fn render_png(&self, path: &str) {
        let pm = self.rasterize();
        if let Err(e) = pm.save_png(path) {
            throw_r_error(format!("failed to write PNG: {e}"));
        }
    }

    /// Render the scene to an SVG file.
    fn render_svg(&self, path: &str) {
        let mut b = SvgBackend::new(self.w_px, self.h_px, self.bg);
        self.render_to(&mut b);
        if let Err(e) = std::fs::write(path, b.into_string()) {
            throw_r_error(format!("failed to write SVG: {e}"));
        }
    }

    /// Render the scene to a PDF file.
    fn render_pdf(&self, path: &str) {
        let scale = 72.0 / self.dpi as f32;
        let w_pt = self.w_px as f32 * scale;
        let h_pt = self.h_px as f32 * scale;
        let mut doc = krilla::Document::new();
        let settings = match krilla::page::PageSettings::from_wh(w_pt, h_pt) {
            Some(s) => s,
            None => throw_r_error("invalid PDF page size"),
        };
        let mut page = doc.start_page_with(settings);
        let mut surface = page.surface();
        // One root transform maps device pixels -> PDF points.
        surface.push_transform(&krilla::geom::Transform::from_scale(scale, scale));
        {
            let mut b = PdfBackend::new(&mut surface);
            b.fill_background(self.w_px, self.h_px, self.bg);
            self.render_to(&mut b);
        }
        surface.pop();
        surface.finish();
        page.finish();
        match doc.finish() {
            Ok(bytes) => {
                if let Err(e) = std::fs::write(path, bytes) {
                    throw_r_error(format!("failed to write PDF: {e}"));
                }
            }
            Err(e) => throw_r_error(format!("failed to serialize PDF: {e}")),
        }
    }

    /// Render and return the whole image as row-major RGBA bytes
    /// `[r, g, b, a, ...]` (top-left origin, x fastest).
    fn rgba(&self) -> Vec<i32> {
        let pm = self.rasterize();
        let mut out = Vec::with_capacity((self.w_px as usize) * (self.h_px as usize) * 4);
        for p in pm.pixels() {
            let c = p.demultiply();
            out.push(c.red() as i32);
            out.push(c.green() as i32);
            out.push(c.blue() as i32);
            out.push(c.alpha() as i32);
        }
        out
    }

    /// Render and return the RGBA of device pixel `(x, y)` as `c(r, g, b, a)`.
    fn pixel(&self, x: i32, y: i32) -> Vec<i32> {
        let pm = self.rasterize();
        if x < 0 || y < 0 || x as u32 >= self.w_px || y as u32 >= self.h_px {
            throw_r_error("pixel out of bounds");
        }
        match pm.pixel(x as u32, y as u32) {
            Some(p) => {
                let c = p.demultiply();
                vec![c.red() as i32, c.green() as i32, c.blue() as i32, c.alpha() as i32]
            }
            None => throw_r_error("pixel out of bounds"),
        }
    }
}

impl Scene {
    /// Resolve every viewport (transform, size, accumulated gpar, clip mask).
    /// DFS from the root guarantees a parent is resolved before its children.
    fn resolve_all(&self) -> Vec<ResolvedVp> {
        let n = self.viewports.len();
        let mut out: Vec<Option<ResolvedVp>> = vec![None; n];

        // Root: identity transform, whole page.
        let root = &self.viewports[0];
        let root_vp = Vp {
            transform: Transform::identity(),
            w: self.w_px as f64,
            h: self.h_px as f64,
            xscale: root.xscale,
            yscale: root.yscale,
            dpi: self.dpi,
        };
        let root_clip = if root.clip {
            vec![ClipRect { w: self.w_px as f64, h: self.h_px as f64, transform: Transform::identity() }]
        } else {
            Vec::new()
        };
        out[0] = Some(ResolvedVp {
            vp: root_vp,
            gp_acc: GparAcc::root_default().apply(&root.gp),
            clip_chain: root_clip,
        });

        let mut stack: Vec<usize> = root.children.iter().rev().copied().collect();
        while let Some(id) = stack.pop() {
            let node = &self.viewports[id];
            let parent = out[node.parent.unwrap()].clone().unwrap();
            out[id] = Some(self.resolve_one(node, &parent));
            for &c in node.children.iter().rev() {
                stack.push(c);
            }
        }

        out.into_iter().map(|r| r.expect("all viewports resolved")).collect()
    }

    fn resolve_one(&self, node: &ViewportNode, parent: &ResolvedVp) -> ResolvedVp {
        // Child rectangle in PARENT-local pixels.
        let (x0, top, cw, ch) = match node.placement {
            Placement::Absolute { cx, cy, w, h, cxu, cyu, wu, hu } => {
                let cw = parent.vp.x_len(w, wu);
                let ch = parent.vp.y_len(h, hu);
                let center_x = parent.vp.x_pos(cx, cxu);
                let center_y = parent.vp.y_pos(cy, cyu);
                (center_x - cw / 2.0, center_y - ch / 2.0, cw, ch)
            }
            Placement::Cell { row, col, rowspan, colspan } => {
                let empty = Layout { widths: vec![], heights: vec![] };
                let layout = self.viewports[node.parent.unwrap()].layout.as_ref().unwrap_or(&empty);
                let xe = solve_tracks(&layout.widths, parent.vp.w, self.dpi);
                let ye = solve_tracks(&layout.heights, parent.vp.h, self.dpi);
                let cstart = col.min(xe.len().saturating_sub(1));
                let cend = (col + colspan).min(xe.len().saturating_sub(1));
                let rstart = row.min(ye.len().saturating_sub(1));
                let rend = (row + rowspan).min(ye.len().saturating_sub(1));
                let x0 = xe.get(cstart).copied().unwrap_or(0.0);
                let top = ye.get(rstart).copied().unwrap_or(0.0);
                (
                    x0,
                    top,
                    (xe.get(cend).copied().unwrap_or(x0) - x0).max(0.0),
                    (ye.get(rend).copied().unwrap_or(top) - top).max(0.0),
                )
            }
        };

        let transform = parent
            .vp
            .transform
            .pre_concat(Transform::from_translate(x0 as f32, top as f32))
            .pre_concat(rotation_about(node.angle, cw / 2.0, ch / 2.0));

        // Invariant: viewport transforms are isometries (translation + rotation),
        // so stroke widths are preserved. Catch any accidental scaling early.
        #[cfg(debug_assertions)]
        {
            let sxl = (transform.sx * transform.sx + transform.ky * transform.ky).sqrt();
            let syl = (transform.kx * transform.kx + transform.sy * transform.sy).sqrt();
            debug_assert!(
                (sxl - 1.0).abs() < 1e-3 && (syl - 1.0).abs() < 1e-3,
                "viewport transform must be isometric (no scale)"
            );
        }

        let vp = Vp {
            transform,
            w: cw,
            h: ch,
            xscale: node.xscale,
            yscale: node.yscale,
            dpi: self.dpi,
        };

        let mut clip_chain = parent.clip_chain.clone();
        if node.clip {
            clip_chain.push(ClipRect { w: cw, h: ch, transform });
        }

        ResolvedVp {
            vp,
            gp_acc: parent.gp_acc.apply(&node.gp),
            clip_chain,
        }
    }

    fn rasterize(&self) -> Pixmap {
        let mut b = RasterBackend::new(self.w_px, self.h_px, self.bg);
        self.render_to(&mut b);
        b.into_pixmap()
    }

    /// Walk the resolved scene in paint order, emitting each primitive through a
    /// [`RenderBackend`]. Geometry resolution (transform, clip, gpar, path) is
    /// shared; only the per-primitive draw calls are backend-specific.
    fn render_to<B: RenderBackend>(&self, b: &mut B) {
        let resolved = self.resolve_all();
        for (vp_id, node) in &self.nodes {
            let rv = &resolved[*vp_id];
            let vp = &rv.vp;
            let gp = rv.gp_acc.apply(node.gp()).resolve();
            let t = vp.transform;
            let clip = Clip { id: *vp_id, rects: &rv.clip_chain };

            match node {
                Node::Rect { x, y, w, h, xu, yu, wu, hu, .. } => {
                    let cx = vp.x_pos(*x, *xu);
                    let cy = vp.y_pos(*y, *yu);
                    let pw = vp.x_len(*w, *wu);
                    let ph = vp.y_len(*h, *hu);
                    if let Some(path) = rect_path(cx - pw / 2.0, cy - ph / 2.0, pw, ph) {
                        fill_then_stroke(b, &path, &gp, t, &clip, vp);
                    }
                }
                Node::Lines { x, y, xu, yu, .. } => {
                    if let (Some(path), Some(col)) = (build_poly(x, y, xu, yu, vp, false), gp.col) {
                        let w = gp.lwd_px(vp.dpi);
                        if w > 0.0 {
                            b.stroke_path(&path, t, col, w, &clip);
                        }
                    }
                }
                Node::Polygon { x, y, xu, yu, .. } => {
                    if let Some(path) = build_poly(x, y, xu, yu, vp, true) {
                        fill_then_stroke(b, &path, &gp, t, &clip, vp);
                    }
                }
                Node::Circle { x, y, r, xu, yu, ru, .. } => {
                    let cx = vp.x_pos(*x, *xu);
                    let cy = vp.y_pos(*y, *yu);
                    let rr = vp.r_len(*r, *ru);
                    let mut pb = PathBuilder::new();
                    pb.push_circle(cx as f32, cy as f32, rr as f32);
                    if let Some(path) = pb.finish() {
                        fill_then_stroke(b, &path, &gp, t, &clip, vp);
                    }
                }
                Node::Text {
                    x, y, xu, yu, rot, hjust, vjust, w, h,
                    gid, gx, gy, gsize, gpath, gface, label, family, face, size, ..
                } => {
                    let color = match gp.col {
                        Some(c) => c,
                        None => continue,
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
                        label,
                        family,
                        face,
                        size: *size,
                        dpi: vp.dpi,
                    };
                    b.draw_text(&run, t, &clip);
                }
            }
        }
    }
}

/// Fill then stroke a shape according to its effective gpar. Gradient fill
/// geometry is resolved against `vp` into viewport-local px (so it transforms
/// with the grob, like the path coordinates).
fn fill_then_stroke<B: RenderBackend>(b: &mut B, path: &tiny_skia::Path, gp: &Gpar, t: Transform, clip: &Clip, vp: &Vp) {
    if let Some(fill) = &gp.fill {
        b.fill_path(path, t, &resolve_paint(fill, vp), clip);
    }
    if let Some(col) = gp.col {
        let width = gp.lwd_px(vp.dpi);
        if width > 0.0 {
            b.stroke_path(path, t, col, width, clip);
        }
    }
}

/// Resolve a paint's gradient geometry through the viewport into local px.
fn resolve_paint(paint: &Paint, vp: &Vp) -> ResolvedPaint {
    match paint {
        Paint::Solid(c) => ResolvedPaint::Solid(*c),
        Paint::Linear { x1, y1, x2, y2, unit, stops, extend } => ResolvedPaint::Linear {
            x1: vp.x_pos(*x1, *unit),
            y1: vp.y_pos(*y1, *unit),
            x2: vp.x_pos(*x2, *unit),
            y2: vp.y_pos(*y2, *unit),
            stops: stops.clone(),
            extend: *extend,
        },
        Paint::Radial { cx, cy, r, unit, stops, extend } => ResolvedPaint::Radial {
            cx: vp.x_pos(*cx, *unit),
            cy: vp.y_pos(*cy, *unit),
            r: vp.r_len(*r, *unit),
            stops: stops.clone(),
            extend: *extend,
        },
    }
}

fn build_poly(x: &[f64], y: &[f64], xu: &[Unit], yu: &[Unit], vp: &Vp, close: bool) -> Option<tiny_skia::Path> {
    let n = x.len().min(y.len()).min(xu.len()).min(yu.len());
    if n < 2 {
        return None;
    }
    let mut pb = PathBuilder::new();
    pb.move_to(vp.x_pos(x[0], xu[0]) as f32, vp.y_pos(y[0], yu[0]) as f32);
    for i in 1..n {
        pb.line_to(vp.x_pos(x[i], xu[i]) as f32, vp.y_pos(y[i], yu[i]) as f32);
    }
    if close {
        pb.close();
    }
    pb.finish()
}

fn build_tracks(vals: &[f64], units: &[String]) -> Vec<Track> {
    vals.iter()
        .enumerate()
        .map(|(i, &v)| {
            let u = units.get(i).map(String::as_str).unwrap_or("null");
            if u == "null" {
                Track::Null(v)
            } else {
                Track::Abs(v, Unit::parse(u))
            }
        })
        .collect()
}

fn pair(s: &[f64], default: (f64, f64)) -> (f64, f64) {
    if s.len() >= 2 {
        (s[0], s[1])
    } else {
        default
    }
}

/// An R `NULL` as an `Robj` (used to mean "inherit" for gpar fields).
fn rnull() -> Robj {
    Robj::from(NULL)
}

/// Decode a slice of integer unit codes from R into `Unit`s (per element).
fn codes(c: &[i32]) -> Vec<Unit> {
    c.iter().map(|&v| Unit::from_code(v)).collect()
}

/// Convert a (finite, positive) dimension in pixels to a `u32`, at least 1 and
/// capped so we never attempt an absurd allocation. Callers validate finiteness.
fn px_dim(v: f64) -> u32 {
    let r = v.round().max(1.0);
    const MAX_DIM: f64 = 30000.0;
    if r > MAX_DIM {
        throw_r_error("scene dimension too large (max 30000 px per side)");
    }
    r as u32
}

extendr_module! {
    mod scene;
    impl Scene;
}
