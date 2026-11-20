//! The marks-only display list (F-5 stage 1, VR-14): a non-raster backend that
//! records every *keyed* primitive the walk paints, resolved to device px, as
//! compact columnar tables -- the payload vellumwidget draws and hit-tests from
//! instead of a per-element bbox index.
//!
//! It is a private vellum <-> vellumwidget format, not a public one: see
//! `scene_display_list()` in R for the field list. Geometry is what is painted,
//! after offsets, caps, sketch and transforms; paints are interned into a small
//! table. What stage 1 cannot reproduce exactly is still listed (so the widget
//! can hit-test it) but flagged, and the widget keeps its bbox path for it:
//! text (its box), non-solid paints, non-rectangular clips, and marks inside a
//! compositing group (opacity, blend, mask, effect).

use std::collections::HashMap;

use tiny_skia::{FillRule, Path, PathSegment, Transform};

use crate::color::{LineCap, LineJoin, Rgba};
use crate::units::rotation_about;

use super::{
    BlendKind, Clip, ClipShape, GroupEffect, MaskLayer, RenderBackend, ResolvedPaint, StrokeStyle,
    TextRun,
};

/// Record kinds (`record$kind`).
pub const KIND_POINT: u8 = 0;
pub const KIND_RECT: u8 = 1;
pub const KIND_PATH: u8 = 2;

/// Record flags (`record$flags`, a bitfield). Zero = drawn exactly.
pub const FLAG_PAINT: u8 = 1; // gradient / pattern / hatch: paint not reproduced
pub const FLAG_CLIP: u8 = 2; // clipped by a path or rotated rect: clip not listed
pub const FLAG_GROUP: u8 = 4; // inside a group with opacity / blend / mask / effect
pub const FLAG_TEXT: u8 = 8; // a text label: geometry is its (rotated) box

/// One paint, interned into the paint table. Colours are packed RGBA; lengths
/// are device px stored as `f32` bits so the struct can be hashed.
#[derive(Clone, Default, PartialEq, Eq, Hash, Debug)]
pub struct PaintKey {
    pub fill: Option<u32>,
    pub stroke: Option<u32>,
    pub width: u32,
    pub dash: Vec<u32>,
    pub cap: u8,
    pub join: u8,
}

#[derive(Clone, Debug)]
pub struct Rec {
    pub kind: u8,
    pub paint: PaintKey,
    pub key: u32,
    pub flags: u8,
    pub clip: u32,
    pub panel: u32,
}

/// The recorded display list (see the module docs).
#[derive(Default, Debug)]
pub struct DisplayList {
    pub recs: Vec<Rec>,
    /// Points: centre, radius (device px), marker shape code (0 = circle; the
    /// `points_grob()` codes otherwise).
    pub pt_cx: Vec<f32>,
    pub pt_cy: Vec<f32>,
    pub pt_r: Vec<f32>,
    pub pt_shape: Vec<u8>,
    /// Axis-aligned rects: top-left corner and size (device px).
    pub rc_x: Vec<f32>,
    pub rc_y: Vec<f32>,
    pub rc_w: Vec<f32>,
    pub rc_h: Vec<f32>,
    /// Paths: interleaved vertices, run starts (vertex index, `n_runs + 1`),
    /// path starts (run index, `n_paths + 1`), whether a path's runs are closed
    /// rings (`1`) or open polylines (`0`), and its fill rule (`1` = even-odd).
    pub xy: Vec<f32>,
    pub run_off: Vec<u32>,
    pub path_off: Vec<u32>,
    pub closed: Vec<u8>,
    pub evenodd: Vec<u8>,
    /// Interned clip rects (device px `x0, y0, x1, y1`); `record$clip` is
    /// 1-based into this, 0 = unclipped.
    pub clips: Vec<[f64; 4]>,
    pub keys: Vec<String>,
    /// Named panels; `record$panel` is 1-based into this (the innermost named
    /// panel a mark is drawn in), 0 = outside every panel.
    pub panels: Vec<String>,
}

pub struct DisplayListBackend {
    pub dl: DisplayList,
    key: Option<u32>,
    key_ix: HashMap<String, u32>,
    /// Clip id -> (1-based clip index or 0, supported?).
    clip_cache: HashMap<usize, (u32, bool)>,
    /// Per open group: does it change how its content composites?
    groups: Vec<bool>,
    effect_depth: usize,
    /// The point record of the marker being painted (see `begin_marker`).
    marker: Option<usize>,
    /// Open panels, as 1-based indices into `dl.panels`.
    panel_stack: Vec<u32>,
    /// Only list marks whose innermost named panel is one of these.
    only_panels: Option<Vec<String>>,
}

impl Default for DisplayListBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl DisplayListBackend {
    /// A backend listing keyed marks, all of them (`panels = None`) or only
    /// those whose innermost named panel is listed.
    pub fn with_panels(panels: Option<Vec<String>>) -> Self {
        let mut b = Self::new();
        b.only_panels = panels;
        b
    }

    pub fn new() -> Self {
        let dl = DisplayList {
            run_off: vec![0],
            path_off: vec![0],
            ..Default::default()
        };
        DisplayListBackend {
            dl,
            key: None,
            key_ix: HashMap::new(),
            clip_cache: HashMap::new(),
            groups: Vec::new(),
            effect_depth: 0,
            marker: None,
            panel_stack: Vec::new(),
            only_panels: None,
        }
    }

    /// Whether the primitive about to be drawn is listed: it has a key, and it
    /// is in one of the requested panels.
    fn active(&self) -> bool {
        if self.key.is_none() {
            return false;
        }
        match &self.only_panels {
            None => true,
            Some(ps) => {
                let cur = self.panel_stack.last().copied().unwrap_or(0);
                cur > 0 && ps.iter().any(|p| *p == self.dl.panels[cur as usize - 1])
            }
        }
    }

    /// The finished list. Keys interned for marks that were not listed (other
    /// panels) are dropped, and the rest renumbered in first-use order.
    pub fn finish(mut self) -> DisplayList {
        let mut remap: Vec<Option<u32>> = vec![None; self.dl.keys.len()];
        let mut keys = Vec::new();
        for r in self.dl.recs.iter_mut() {
            let k = r.key as usize;
            let ix = *remap[k].get_or_insert_with(|| {
                keys.push(std::mem::take(&mut self.dl.keys[k]));
                (keys.len() - 1) as u32
            });
            r.key = ix;
        }
        self.dl.keys = keys;
        let used: Vec<bool> = {
            let mut u = vec![false; self.dl.panels.len()];
            for r in &self.dl.recs {
                if r.panel > 0 {
                    u[r.panel as usize - 1] = true;
                }
            }
            u
        };
        // Same for panels: keep only those that hold a listed mark.
        let mut pmap = vec![0u32; self.dl.panels.len()];
        let mut panels = Vec::new();
        for (i, p) in self.dl.panels.iter().enumerate() {
            if used[i] {
                panels.push(p.clone());
                pmap[i] = panels.len() as u32;
            }
        }
        for r in self.dl.recs.iter_mut() {
            if r.panel > 0 {
                r.panel = pmap[r.panel as usize - 1];
            }
        }
        self.dl.panels = panels;
        self.dl
    }

    fn intern_key(&mut self, k: &str) -> u32 {
        if let Some(&i) = self.key_ix.get(k) {
            return i;
        }
        let i = self.dl.keys.len() as u32;
        self.dl.keys.push(k.to_string());
        self.key_ix.insert(k.to_string(), i);
        i
    }

    /// The clip index for a draw, and whether the clip could be listed.
    fn clip_of(&mut self, clip: &Clip) -> (u32, bool) {
        if clip.shapes.is_empty() {
            return (0, true);
        }
        if let Some(&c) = self.clip_cache.get(&clip.id) {
            return c;
        }
        let mut acc = [
            f64::NEG_INFINITY,
            f64::NEG_INFINITY,
            f64::INFINITY,
            f64::INFINITY,
        ];
        let mut ok = true;
        for s in clip.shapes {
            match s {
                ClipShape::Rect { w, h, transform: t } if t.kx == 0.0 && t.ky == 0.0 => {
                    let (xa, xb) = (t.tx as f64, t.tx as f64 + t.sx as f64 * w);
                    let (ya, yb) = (t.ty as f64, t.ty as f64 + t.sy as f64 * h);
                    acc[0] = acc[0].max(xa.min(xb));
                    acc[1] = acc[1].max(ya.min(yb));
                    acc[2] = acc[2].min(xa.max(xb));
                    acc[3] = acc[3].min(ya.max(yb));
                }
                _ => ok = false,
            }
        }
        let out = if ok {
            if acc[2] < acc[0] {
                acc[2] = acc[0];
            }
            if acc[3] < acc[1] {
                acc[3] = acc[1];
            }
            self.dl.clips.push(acc);
            (self.dl.clips.len() as u32, true)
        } else {
            (0, false)
        };
        self.clip_cache.insert(clip.id, out);
        out
    }

    fn push_rec(&mut self, kind: u8, paint: PaintKey, mut flags: u8, clip: &Clip) {
        let Some(key) = self.key else { return };
        let (ci, ok) = self.clip_of(clip);
        if !ok {
            flags |= FLAG_CLIP;
        }
        if self.effect_depth > 0 {
            flags |= FLAG_GROUP;
        }
        self.dl.recs.push(Rec {
            kind,
            paint,
            key,
            flags,
            clip: ci,
            panel: self.panel_stack.last().copied().unwrap_or(0),
        });
    }

    /// Record a painted path (fill and/or stroke) for the current key.
    fn record_path(
        &mut self,
        path: &Path,
        t: Transform,
        filled: bool,
        paint: PaintKey,
        flags: u8,
        clip: &Clip,
    ) {
        if !self.active() {
            return;
        }
        let runs = flatten_runs(path, t);
        if runs.is_empty() {
            return;
        }
        let all_closed = filled || runs.iter().all(|(_, c)| *c);
        // An axis-aligned quad is a rect: 4 floats instead of a vertex run.
        if all_closed && runs.len() == 1 {
            if let Some((x, y, w, h)) = as_rect(&runs[0].0) {
                self.dl.rc_x.push(x);
                self.dl.rc_y.push(y);
                self.dl.rc_w.push(w);
                self.dl.rc_h.push(h);
                self.push_rec(KIND_RECT, paint, flags, clip);
                return;
            }
        }
        for (pts, _) in &runs {
            for &(x, y) in pts {
                self.dl.xy.push(x);
                self.dl.xy.push(y);
            }
            self.dl.run_off.push((self.dl.xy.len() / 2) as u32);
        }
        self.dl.path_off.push((self.dl.run_off.len() - 1) as u32);
        self.dl.closed.push(all_closed as u8);
        self.dl.evenodd.push(0);
        self.push_rec(KIND_PATH, paint, flags, clip);
    }

    fn set_last_evenodd(&mut self, rule: FillRule) {
        if let (Some(r), Some(e)) = (self.dl.recs.last(), self.dl.evenodd.last_mut()) {
            if r.kind == KIND_PATH {
                *e = (rule == FillRule::EvenOdd) as u8;
            }
        }
    }

    /// While a marker is open, paint calls set its paint instead of recording
    /// geometry. Returns whether the call was absorbed.
    fn absorb(
        &mut self,
        fill: Option<(Option<u32>, u8)>,
        stroke: Option<(Rgba, &StrokeStyle, Transform)>,
    ) -> bool {
        let Some(m) = self.marker else { return false };
        let rec = &mut self.dl.recs[m];
        if let Some((f, fl)) = fill {
            rec.paint.fill = f;
            rec.flags |= fl;
        }
        if let Some((c, st, t)) = stroke {
            let (k, fl) = stroke_paint(c, st, t);
            rec.paint.stroke = k.stroke;
            rec.paint.width = k.width;
            rec.paint.dash = k.dash;
            rec.paint.cap = k.cap;
            rec.paint.join = k.join;
            rec.flags |= fl;
        }
        true
    }
}

fn pack(c: Rgba) -> u32 {
    ((c.r as u32) << 24) | ((c.g as u32) << 16) | ((c.b as u32) << 8) | c.a as u32
}

/// A fill paint: packed colour (None for no/unsupported fill) and flags.
fn fill_paint(p: &ResolvedPaint) -> (Option<u32>, u8) {
    match p {
        ResolvedPaint::Solid(c) => (Some(pack(*c)), 0),
        _ => (None, FLAG_PAINT),
    }
}

/// Linear scale of a transform (exact for the similarity transforms viewports use).
fn scale_of(t: Transform) -> f32 {
    ((t.sx * t.sy - t.kx * t.ky).abs()).sqrt()
}

fn stroke_paint(c: Rgba, st: &StrokeStyle, t: Transform) -> (PaintKey, u8) {
    let s = scale_of(t);
    let k = PaintKey {
        fill: None,
        stroke: Some(pack(c)),
        width: (st.width * s).to_bits(),
        dash: st.dash.iter().map(|d| (d * s).to_bits()).collect(),
        cap: match st.cap {
            LineCap::Butt => 0,
            LineCap::Round => 1,
            LineCap::Square => 2,
        },
        join: match st.join {
            LineJoin::Mitre => 0,
            LineJoin::Round => 1,
            LineJoin::Bevel => 2,
        },
    };
    (k, if st.paint.is_some() { FLAG_PAINT } else { 0 })
}

fn map(t: &Transform, x: f32, y: f32) -> (f32, f32) {
    (t.sx * x + t.kx * y + t.tx, t.ky * x + t.sy * y + t.ty)
}

/// Flatten a path into device-px runs (curves subdivided like the pick
/// geometry), each with whether it was closed. Unlike `flatten_rings`, open
/// runs of two points (a segment) are kept.
pub fn flatten_runs(path: &Path, t: Transform) -> Vec<(Vec<(f32, f32)>, bool)> {
    let mut out: Vec<(Vec<(f32, f32)>, bool)> = Vec::new();
    let mut cur: Vec<(f32, f32)> = Vec::new();
    let steps = |a: (f32, f32), b: (f32, f32)| {
        let d = ((b.0 - a.0).powi(2) + (b.1 - a.1).powi(2)).sqrt();
        (d.ceil() as usize).clamp(2, 24)
    };
    let flush =
        |cur: &mut Vec<(f32, f32)>, out: &mut Vec<(Vec<(f32, f32)>, bool)>, closed: bool| {
            if cur.len() >= 2 {
                out.push((std::mem::take(cur), closed));
            } else {
                cur.clear();
            }
        };
    for seg in path.segments() {
        match seg {
            PathSegment::MoveTo(p) => {
                flush(&mut cur, &mut out, false);
                cur.push((p.x, p.y));
            }
            PathSegment::LineTo(p) => cur.push((p.x, p.y)),
            PathSegment::QuadTo(c, p) => {
                let a = *cur.last().unwrap_or(&(c.x, c.y));
                let n = steps(a, (p.x, p.y));
                for i in 1..=n {
                    let s = i as f32 / n as f32;
                    let m = 1.0 - s;
                    cur.push((
                        m * m * a.0 + 2.0 * m * s * c.x + s * s * p.x,
                        m * m * a.1 + 2.0 * m * s * c.y + s * s * p.y,
                    ));
                }
            }
            PathSegment::CubicTo(c1, c2, p) => {
                let a = *cur.last().unwrap_or(&(c1.x, c1.y));
                let n = steps(a, (p.x, p.y));
                for i in 1..=n {
                    let s = i as f32 / n as f32;
                    let m = 1.0 - s;
                    cur.push((
                        m * m * m * a.0
                            + 3.0 * m * m * s * c1.x
                            + 3.0 * m * s * s * c2.x
                            + s * s * s * p.x,
                        m * m * m * a.1
                            + 3.0 * m * m * s * c1.y
                            + 3.0 * m * s * s * c2.y
                            + s * s * s * p.y,
                    ));
                }
            }
            PathSegment::Close => {
                // A closed ring repeats no vertex: drop an explicit return to start.
                if cur.len() > 2 && cur.first() == cur.last() {
                    cur.pop();
                }
                flush(&mut cur, &mut out, true);
            }
        }
    }
    flush(&mut cur, &mut out, false);
    for (pts, _) in out.iter_mut() {
        for p in pts.iter_mut() {
            *p = map(&t, p.0, p.1);
        }
    }
    out
}

/// `(x, y, w, h)` when a ring is an axis-aligned rectangle (4 corners, or 5
/// with the start repeated).
fn as_rect(r: &[(f32, f32)]) -> Option<(f32, f32, f32, f32)> {
    let r = if r.len() == 5 && r[0] == r[4] {
        &r[..4]
    } else {
        r
    };
    if r.len() != 4 {
        return None;
    }
    let horiz = |a: (f32, f32), b: (f32, f32)| a.1 == b.1;
    let vert = |a: (f32, f32), b: (f32, f32)| a.0 == b.0;
    let ok = (horiz(r[0], r[1]) && vert(r[1], r[2]) && horiz(r[2], r[3]) && vert(r[3], r[0]))
        || (vert(r[0], r[1]) && horiz(r[1], r[2]) && vert(r[2], r[3]) && horiz(r[3], r[0]));
    if !ok {
        return None;
    }
    let x0 = r.iter().map(|p| p.0).fold(f32::INFINITY, f32::min);
    let x1 = r.iter().map(|p| p.0).fold(f32::NEG_INFINITY, f32::max);
    let y0 = r.iter().map(|p| p.1).fold(f32::INFINITY, f32::min);
    let y1 = r.iter().map(|p| p.1).fold(f32::NEG_INFINITY, f32::max);
    Some((x0, y0, x1 - x0, y1 - y0))
}

impl RenderBackend for DisplayListBackend {
    fn fill_path(
        &mut self,
        path: &Path,
        transform: Transform,
        paint: &ResolvedPaint,
        rule: FillRule,
        clip: &Clip,
    ) {
        let (f, fl) = fill_paint(paint);
        if self.absorb(Some((f, fl)), None) {
            return;
        }
        let pk = PaintKey {
            fill: f,
            ..Default::default()
        };
        let n = self.dl.recs.len();
        self.record_path(path, transform, true, pk, fl, clip);
        if self.dl.recs.len() > n {
            self.set_last_evenodd(rule);
        }
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
        if self.absorb(None, Some((color, stroke, transform))) {
            return;
        }
        let (pk, fl) = stroke_paint(color, stroke, transform);
        self.record_path(path, transform, false, pk, fl, clip);
    }

    fn fill_and_stroke_path(
        &mut self,
        path: &Path,
        transform: Transform,
        paint: &ResolvedPaint,
        rule: FillRule,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    ) {
        let (f, ffl) = fill_paint(paint);
        if self.absorb(Some((f, ffl)), Some((color, stroke, transform))) {
            return;
        }
        let (mut pk, sfl) = stroke_paint(color, stroke, transform);
        pk.fill = f;
        let n = self.dl.recs.len();
        self.record_path(path, transform, true, pk, ffl | sfl, clip);
        if self.dl.recs.len() > n {
            self.set_last_evenodd(rule);
        }
    }

    /// A keyed label is listed by its box (flagged): stage 1 carries no glyphs.
    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        if !self.active() {
            return;
        }
        let tr = if run.rot != 0.0 {
            transform.pre_concat(rotation_about(run.rot, run.ax, run.ay))
        } else {
            transform
        };
        let x0 = (run.ax - run.hjust * run.w) as f32;
        let y0 = (run.ay - (1.0 - run.vjust) * run.h) as f32;
        let (w, h) = (run.w as f32, run.h as f32);
        let mut pb = tiny_skia::PathBuilder::new();
        pb.move_to(x0, y0);
        pb.line_to(x0 + w, y0);
        pb.line_to(x0 + w, y0 + h);
        pb.line_to(x0, y0 + h);
        pb.close();
        if let Some(p) = pb.finish() {
            let pk = PaintKey {
                fill: Some(pack(run.color)),
                ..Default::default()
            };
            self.record_path(&p, tr, true, pk, FLAG_TEXT, clip);
        }
    }

    fn begin_group(
        &mut self,
        mask: Option<MaskLayer>,
        alpha: f32,
        blend: BlendKind,
        effect: GroupEffect,
    ) {
        let changes =
            mask.is_some() || alpha < 1.0 || blend != BlendKind::Normal || !effect.is_none();
        if changes {
            self.effect_depth += 1;
        }
        self.groups.push(changes);
    }

    fn end_group(&mut self) {
        if self.groups.pop() == Some(true) {
            self.effect_depth -= 1;
        }
    }

    fn draw_image(
        &mut self,
        _: &[u8],
        _: u32,
        _: u32,
        _: f64,
        _: f64,
        _: f64,
        _: f64,
        _: bool,
        _: Transform,
        _: &Clip,
    ) {
    }

    /// A keyed batch stays one batch: one point record per keyed element.
    fn draw_circles(
        &mut self,
        cx: &[f64],
        cy: &[f64],
        r: &[f64],
        fill: Option<&ResolvedPaint>,
        stroke: Option<(Rgba, StrokeStyle)>,
        transform: Transform,
        clip: &Clip,
        keys: &[String],
    ) {
        if keys.is_empty() {
            return;
        }
        let (f, ffl) = fill.map(fill_paint).unwrap_or((None, 0));
        let (mut pk, sfl) = match &stroke {
            Some((c, st)) if st.width > 0.0 => stroke_paint(*c, st, transform),
            _ => (PaintKey::default(), 0),
        };
        pk.fill = f;
        let s = scale_of(transform);
        let n = cx.len().min(cy.len()).min(r.len());
        for i in 0..n {
            let k = match keys.get(i) {
                Some(k) if !k.is_empty() => k,
                _ => continue,
            };
            if r[i] <= 0.0 || !cx[i].is_finite() || !cy[i].is_finite() {
                continue;
            }
            let ki = self.intern_key(k);
            self.key = Some(ki);
            if !self.active() {
                continue;
            }
            let (x, y) = map(&transform, cx[i] as f32, cy[i] as f32);
            self.dl.pt_cx.push(x);
            self.dl.pt_cy.push(y);
            self.dl.pt_r.push(r[i] as f32 * s);
            self.dl.pt_shape.push(0);
            self.push_rec(KIND_POINT, pk.clone(), ffl | sfl, clip);
        }
        self.key = None;
    }

    fn begin_marker(
        &mut self,
        shape: u32,
        cx: f64,
        cy: f64,
        r: f64,
        transform: Transform,
        clip: &Clip,
    ) {
        if !self.active() {
            return;
        }
        let (x, y) = map(&transform, cx as f32, cy as f32);
        self.dl.pt_cx.push(x);
        self.dl.pt_cy.push(y);
        self.dl.pt_r.push(r as f32 * scale_of(transform));
        self.dl.pt_shape.push(shape.min(255) as u8);
        self.push_rec(KIND_POINT, PaintKey::default(), 0, clip);
        self.marker = Some(self.dl.recs.len() - 1);
    }

    fn set_element_key(&mut self, key: Option<&str>) {
        self.marker = None;
        self.key = match key {
            Some(k) if !k.is_empty() => Some(self.intern_key(k)),
            _ => None,
        };
    }

    fn begin_panel(&mut self, name: &str, _pannable: bool) {
        let ix = match self.dl.panels.iter().position(|p| p == name) {
            Some(i) => i as u32 + 1,
            None => {
                self.dl.panels.push(name.to_string());
                self.dl.panels.len() as u32
            }
        };
        self.panel_stack.push(ix);
    }

    fn end_panel(&mut self) {
        self.panel_stack.pop();
    }

    /// Keys are what this backend is for.
    fn wants_element_keys(&self) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn no_clip() -> Clip<'static> {
        Clip { id: 0, shapes: &[] }
    }

    #[test]
    fn a_keyed_circle_batch_stays_one_point_table() {
        let mut b = DisplayListBackend::new();
        let keys: Vec<String> = vec!["a".into(), "".into(), "c".into()];
        let fill = ResolvedPaint::Solid(Rgba {
            r: 255,
            g: 0,
            b: 0,
            a: 255,
        });
        let t = Transform::from_row(2.0, 0.0, 0.0, 2.0, 10.0, 20.0);
        b.draw_circles(
            &[1.0, 2.0, 3.0],
            &[1.0, 1.0, 1.0],
            &[1.0; 3],
            Some(&fill),
            None,
            t,
            &no_clip(),
            &keys,
        );
        // Unkeyed batches are not listed.
        b.draw_circles(
            &[1.0],
            &[1.0],
            &[1.0],
            Some(&fill),
            None,
            t,
            &no_clip(),
            &[],
        );
        let dl = b.finish();
        assert_eq!(dl.recs.len(), 2); // the empty key is skipped
        assert!(dl.recs.iter().all(|r| r.kind == KIND_POINT && r.flags == 0));
        assert_eq!(dl.keys, vec!["a".to_string(), "c".to_string()]);
        assert_eq!(dl.pt_cx, vec![12.0, 16.0]);
        assert_eq!(dl.pt_cy, vec![22.0, 22.0]);
        assert_eq!(dl.pt_r, vec![2.0, 2.0]);
        assert_eq!(dl.recs[0].paint.fill, Some(0xff0000ff));
    }

    #[test]
    fn open_two_point_runs_survive_flattening() {
        let mut pb = tiny_skia::PathBuilder::new();
        pb.move_to(0.0, 0.0);
        pb.line_to(5.0, 5.0);
        let runs = flatten_runs(&pb.finish().unwrap(), Transform::identity());
        assert_eq!(runs, vec![(vec![(0.0, 0.0), (5.0, 5.0)], false)]);
        assert_eq!(
            as_rect(&[(0.0, 0.0), (2.0, 0.0), (2.0, 1.0), (0.0, 1.0)]),
            Some((0.0, 0.0, 2.0, 1.0))
        );
        assert_eq!(
            as_rect(&[(0.0, 0.0), (2.0, 0.5), (2.0, 1.0), (0.0, 1.0)]),
            None
        );
    }
}
