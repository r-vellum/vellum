//! The scene graph and its rasterization to a tiny-skia pixmap.
//!
//! M1 is deliberately small: one viewport with a scale, a flat list of
//! primitives, and a single render target (PNG / raster). No nested viewports,
//! layout, editing, or text yet — those are M2/M3. The `Scene` is held in Rust
//! and exposed to R as an external-pointer object.

use extendr_api::prelude::*;
use tiny_skia::{FillRule, Paint, PathBuilder, Pixmap, Stroke, Transform};

use crate::color::{opt_color, Gpar, Rgba};
use crate::units::{Unit, Vp};

/// A viewport described in normalised page coordinates (centre + size), with
/// its own native scales. Resolved to device pixels at render time.
#[derive(Clone, Copy, Debug)]
struct Viewport {
    cx: f64,
    cy: f64,
    w: f64,
    h: f64,
    xscale: (f64, f64),
    yscale: (f64, f64),
}

impl Default for Viewport {
    fn default() -> Self {
        // Whole page; npc == native by default.
        Viewport {
            cx: 0.5,
            cy: 0.5,
            w: 1.0,
            h: 1.0,
            xscale: (0.0, 1.0),
            yscale: (0.0, 1.0),
        }
    }
}

#[derive(Clone, Debug)]
enum Node {
    /// Rectangle, `(x, y)` is the centre.
    Rect {
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        unit: Unit,
        gp: Gpar,
    },
    /// Open polyline (stroke only).
    Lines {
        x: Vec<f64>,
        y: Vec<f64>,
        unit: Unit,
        gp: Gpar,
    },
    /// Closed polygon (fill + stroke).
    Polygon {
        x: Vec<f64>,
        y: Vec<f64>,
        unit: Unit,
        gp: Gpar,
    },
    Circle {
        x: f64,
        y: f64,
        r: f64,
        unit: Unit,
        gp: Gpar,
    },
}

/// A drawing scene held in the Rust backend.
/// @export
#[extendr]
#[derive(Clone, Debug)]
pub struct Scene {
    w_px: u32,
    h_px: u32,
    dpi: f64,
    bg: Rgba,
    vp: Viewport,
    nodes: Vec<Node>,
}

/// @export
#[extendr]
impl Scene {
    /// Create a scene `width` x `height` inches at `dpi`, with background `bg`
    /// (a length-4 integer RGBA vector).
    fn new(width: f64, height: f64, dpi: f64, bg: Robj) -> Self {
        let w_px = (width * dpi).round().max(1.0) as u32;
        let h_px = (height * dpi).round().max(1.0) as u32;
        Scene {
            w_px,
            h_px,
            dpi,
            bg: opt_color(&bg).unwrap_or(Rgba::WHITE),
            vp: Viewport::default(),
            nodes: Vec::new(),
        }
    }

    /// Set the (single) drawing viewport: centre `(x, y)` and size `(w, h)` in
    /// page npc, with native `xscale`/`yscale` (length-2 vectors).
    fn set_viewport(&mut self, x: f64, y: f64, w: f64, h: f64, xscale: &[f64], yscale: &[f64]) {
        self.vp = Viewport {
            cx: x,
            cy: y,
            w,
            h,
            xscale: pair(xscale, (0.0, 1.0)),
            yscale: pair(yscale, (0.0, 1.0)),
        };
    }

    fn rect(&mut self, x: f64, y: f64, w: f64, h: f64, units: &str, fill: Robj, col: Robj, lwd: f64, alpha: f64) {
        self.nodes.push(Node::Rect {
            x,
            y,
            w,
            h,
            unit: Unit::parse(units),
            gp: Gpar::new(&fill, &col, lwd, alpha),
        });
    }

    fn lines(&mut self, x: &[f64], y: &[f64], units: &str, col: Robj, lwd: f64, alpha: f64) {
        self.nodes.push(Node::Lines {
            x: x.to_vec(),
            y: y.to_vec(),
            unit: Unit::parse(units),
            gp: Gpar::new(&Robj::from(NULL), &col, lwd, alpha),
        });
    }

    fn polygon(&mut self, x: &[f64], y: &[f64], units: &str, fill: Robj, col: Robj, lwd: f64, alpha: f64) {
        self.nodes.push(Node::Polygon {
            x: x.to_vec(),
            y: y.to_vec(),
            unit: Unit::parse(units),
            gp: Gpar::new(&fill, &col, lwd, alpha),
        });
    }

    fn circle(&mut self, x: f64, y: f64, r: f64, units: &str, fill: Robj, col: Robj, lwd: f64, alpha: f64) {
        self.nodes.push(Node::Circle {
            x,
            y,
            r,
            unit: Unit::parse(units),
            gp: Gpar::new(&fill, &col, lwd, alpha),
        });
    }

    /// Number of primitives currently in the scene.
    fn len(&self) -> i32 {
        self.nodes.len() as i32
    }

    /// Device dimensions in pixels, `c(width, height)`.
    fn dim(&self) -> Vec<i32> {
        vec![self.w_px as i32, self.h_px as i32]
    }

    /// Render the scene to a PNG file.
    fn render_png(&self, path: &str) {
        let pm = self.rasterize();
        if let Err(e) = pm.save_png(path) {
            throw_r_error(format!("failed to write PNG: {e}"));
        }
    }

    /// Render and return the RGBA of device pixel `(x, y)` (top-left origin,
    /// 0-based) as `c(r, g, b, a)`. For pixel-level testing.
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
    fn resolved_vp(&self) -> Vp {
        let (page_w, page_h) = (self.w_px as f64, self.h_px as f64);
        let w = self.vp.w * page_w;
        let h = self.vp.h * page_h;
        let x0 = self.vp.cx * page_w - w / 2.0;
        // Viewport centre is in npc from the bottom; convert to a top-left top edge.
        let center_top = page_h - self.vp.cy * page_h;
        let top = center_top - h / 2.0;
        Vp {
            x0,
            top,
            w,
            h,
            xscale: self.vp.xscale,
            yscale: self.vp.yscale,
        }
    }

    fn rasterize(&self) -> Pixmap {
        let mut pm = Pixmap::new(self.w_px, self.h_px).expect("non-zero pixmap dimensions");
        pm.fill(self.bg.to_skia());
        let vp = self.resolved_vp();
        for node in &self.nodes {
            draw_node(&mut pm, node, &vp, self.dpi);
        }
        pm
    }
}

fn fill_and_stroke(pm: &mut Pixmap, path: &tiny_skia::Path, gp: &Gpar, dpi: f64, stroke_only: bool) {
    if !stroke_only {
        if let Some(fill) = gp.fill {
            let mut paint = Paint::default();
            paint.set_color(fill.to_skia());
            paint.anti_alias = true;
            pm.fill_path(path, &paint, FillRule::Winding, Transform::identity(), None);
        }
    }
    if let Some(col) = gp.col {
        let width = gp.lwd_px(dpi);
        if width > 0.0 {
            let mut paint = Paint::default();
            paint.set_color(col.to_skia());
            paint.anti_alias = true;
            let stroke = Stroke {
                width,
                ..Stroke::default()
            };
            pm.stroke_path(path, &paint, &stroke, Transform::identity(), None);
        }
    }
}

fn draw_node(pm: &mut Pixmap, node: &Node, vp: &Vp, dpi: f64) {
    match node {
        Node::Rect { x, y, w, h, unit, gp } => {
            let cx = vp.x_pos(*x, *unit, dpi);
            let cy = vp.y_pos(*y, *unit, dpi);
            let pw = vp.x_len(*w, *unit, dpi);
            let ph = vp.y_len(*h, *unit, dpi);
            if let Some(rect) =
                tiny_skia::Rect::from_xywh((cx - pw / 2.0) as f32, (cy - ph / 2.0) as f32, pw as f32, ph as f32)
            {
                let path = PathBuilder::from_rect(rect);
                fill_and_stroke(pm, &path, gp, dpi, false);
            }
        }
        Node::Lines { x, y, unit, gp } => {
            if let Some(path) = build_poly(x, y, *unit, vp, dpi, false) {
                fill_and_stroke(pm, &path, gp, dpi, true);
            }
        }
        Node::Polygon { x, y, unit, gp } => {
            if let Some(path) = build_poly(x, y, *unit, vp, dpi, true) {
                fill_and_stroke(pm, &path, gp, dpi, false);
            }
        }
        Node::Circle { x, y, r, unit, gp } => {
            let cx = vp.x_pos(*x, *unit, dpi);
            let cy = vp.y_pos(*y, *unit, dpi);
            let rr = vp.r_len(*r, *unit, dpi);
            let mut pb = PathBuilder::new();
            pb.push_circle(cx as f32, cy as f32, rr as f32);
            if let Some(path) = pb.finish() {
                fill_and_stroke(pm, &path, gp, dpi, false);
            }
        }
    }
}

fn build_poly(x: &[f64], y: &[f64], unit: Unit, vp: &Vp, dpi: f64, close: bool) -> Option<tiny_skia::Path> {
    let n = x.len().min(y.len());
    if n < 2 {
        return None;
    }
    let mut pb = PathBuilder::new();
    pb.move_to(vp.x_pos(x[0], unit, dpi) as f32, vp.y_pos(y[0], unit, dpi) as f32);
    for i in 1..n {
        pb.line_to(vp.x_pos(x[i], unit, dpi) as f32, vp.y_pos(y[i], unit, dpi) as f32);
    }
    if close {
        pb.close();
    }
    pb.finish()
}

fn pair(s: &[f64], default: (f64, f64)) -> (f64, f64) {
    if s.len() >= 2 {
        (s[0], s[1])
    } else {
        default
    }
}

extendr_module! {
    mod scene;
    impl Scene;
}
