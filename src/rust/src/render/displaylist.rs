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
//! compositing group (opacity, blend, mask, effect). A keyed mark that paints
//! nothing at all (an invisible hover target) is listed too, flagged pick-only,
//! so the widget can still hit-test it.
//!
//! Version 2 (opt-in, VW-23) makes three of those cases exact instead of
//! flagged: linear and radial gradient fills with `pad` extension (a gradient
//! table the paints refer to), clips by a path or a rotated rect (clip paths
//! in device px), and groups whose only effect is an opacity below 1 (a group
//! table each record refers to; a client composites the group's records as
//! one layer). Masks, blend modes, effects, hatches, patterns, repeating
//! gradients and gradient strokes stay flagged.

use std::collections::HashMap;

use tiny_skia::{FillRule, Path, PathSegment, Transform};

use crate::color::{Extend, LineCap, LineJoin, Rgba, Stop};
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
pub const FLAG_PICK: u8 = 16; // pick-only: paints nothing (an invisible hover target)
pub const FLAG_BLEND: u8 = 32; // inside a group with a blend mode: mixes with what is beneath it

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
    /// Version 2: 1-based into `DisplayList::gradients` for a gradient fill
    /// (then `fill` is `None`), 0 = none.
    pub grad: u32,
}

#[derive(Clone, Debug)]
pub struct Rec {
    pub kind: u8,
    pub paint: PaintKey,
    pub key: u32,
    pub flags: u8,
    pub clip: u32,
    pub panel: u32,
    /// Version 2: 1-based into `DisplayList::groups` (the innermost opacity
    /// group the record is drawn in), 0 = none.
    pub group: u32,
    /// The top-level scene node the record was drawn by.
    pub node: u32,
    /// The flagged run the record belongs to (1-based, 0 = none; see
    /// `assign_runs`).
    pub run: u32,
    /// The blend root the record is drawn in (1-based into
    /// `DisplayList::blend_roots`, 0 = none; see `begin_group`).
    pub blend: u32,
}

/// A gradient fill (version 2): geometry in the shape's local px, placed in
/// device px by `transform` (`[sx, ky, kx, sy, tx, ty]`, the canvas/SVG
/// `matrix(a, b, c, d, e, f)` order). Linear: `p1` -> `p2`. Radial: the focal
/// circle `(p1, r1)` at offset 0 to the outer circle `(p2, r2)` at offset 1.
#[derive(Clone, Debug, PartialEq)]
pub struct Gradient {
    pub radial: bool,
    pub p1: (f64, f64),
    pub p2: (f64, f64),
    pub r1: f64,
    pub r2: f64,
    pub transform: [f32; 6],
    /// `(offset, packed RGBA)`.
    pub stops: Vec<(f32, u32)>,
}

/// An opacity group (version 2): its alpha and its parent group (1-based, 0 =
/// top level).
#[derive(Clone, Debug, PartialEq)]
pub struct Group {
    pub alpha: f32,
    pub parent: u32,
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
    /// Version 2: per clip, the range `(start, n)` of its path shapes in the
    /// clip-path table (n = 0: the rect alone). A record is clipped to the
    /// rect and to every one of its paths.
    pub clip_paths: Vec<(u32, u32)>,
    /// The clip-path table: interleaved device-px vertices, run starts
    /// (`n_runs + 1`), shape starts in runs (`n_shapes + 1`), fill rule.
    pub cp_xy: Vec<f32>,
    pub cp_run_off: Vec<u32>,
    pub cp_path_off: Vec<u32>,
    pub cp_evenodd: Vec<u8>,
    pub gradients: Vec<Gradient>,
    pub groups: Vec<Group>,
    /// The format version the list was recorded for (1 or 2).
    pub version: u32,
    pub keys: Vec<String>,
    /// Named panels; `record$panel` is 1-based into this (the innermost named
    /// panel a mark is drawn in), 0 = outside every panel.
    pub panels: Vec<String>,
    /// The number of flagged runs (`assign_runs`).
    pub runs: u32,
    /// Per top-level node holding a flagged run's marks, its run (1-based).
    pub node_runs: HashMap<u32, u32>,
    /// Blend roots (VW-32): the mode of each outermost group with a blend
    /// mode that is drawn straight onto the page's backdrop, directly or
    /// inside plain (effect-free) groups, which isolate nothing (VR-21).
    pub blend_roots: Vec<BlendKind>,
    /// Per run, how a client composites its raster onto what is beneath it
    /// (`assign_runs`): `"normal"`, a CSS `mix-blend-mode` keyword (the run is
    /// exactly one blend root's marks), or `""` when it cannot be composited
    /// from its own raster (a root this list doesn't hold; since plain groups
    /// stopped isolating, VR-21, a list built here has none).
    pub run_blend: Vec<String>,
}

pub struct DisplayListBackend {
    pub dl: DisplayList,
    key: Option<u32>,
    key_ix: HashMap<String, u32>,
    /// Clip id -> (1-based clip index or 0, supported?).
    clip_cache: HashMap<usize, (u32, bool)>,
    /// Per open group: 0 = composites normally, 1 = an unlisted effect
    /// (flags its content), 2 = a listed opacity group (version 2).
    groups: Vec<u8>,
    /// Open listed opacity groups, as 1-based indices into `dl.groups`.
    alpha_stack: Vec<u32>,
    /// Record the version-2 extensions (gradients, clip paths, opacity groups).
    v2: bool,
    effect_depth: usize,
    /// Open groups with a blend mode other than normal (one flag per open
    /// group, so `end_group` knows what to undo).
    blend_stack: Vec<bool>,
    /// The point record of the marker being painted (see `begin_marker`).
    marker: Option<usize>,
    /// Open panels, as 1-based indices into `dl.panels`.
    panel_stack: Vec<u32>,
    /// Only list marks whose innermost named panel is one of these.
    only_panels: Option<Vec<String>>,
    /// The top-level node being drawn (`begin_draw_node`).
    cur_node: u32,
    /// Per open group, the blend root its content is drawn in (0 = none).
    root_stack: Vec<u32>,
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

    /// As `with_panels()`, recording format `version` (1 or 2).
    pub fn with_options(panels: Option<Vec<String>>, version: u32) -> Self {
        let mut b = Self::with_panels(panels);
        b.v2 = version >= 2;
        b.dl.version = if b.v2 { 2 } else { 1 };
        b.dl.cp_run_off = vec![0];
        b.dl.cp_path_off = vec![0];
        b
    }

    pub fn new() -> Self {
        let dl = DisplayList {
            run_off: vec![0],
            path_off: vec![0],
            cp_run_off: vec![0],
            cp_path_off: vec![0],
            version: 1,
            ..Default::default()
        };
        DisplayListBackend {
            dl,
            key: None,
            key_ix: HashMap::new(),
            clip_cache: HashMap::new(),
            groups: Vec::new(),
            alpha_stack: Vec::new(),
            v2: false,
            effect_depth: 0,
            blend_stack: Vec::new(),
            marker: None,
            panel_stack: Vec::new(),
            only_panels: None,
            cur_node: 0,
            root_stack: Vec::new(),
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
        // A mark with neither fill nor stroke (and not a text box or an
        // unreproducible paint) is a pick-only hover target: a no-paint circle
        // batch, or a marker whose paint calls never came.
        for r in self.dl.recs.iter_mut() {
            if r.paint.fill.is_none()
                && r.paint.grad == 0
                && r.paint.stroke.is_none()
                && r.flags & (FLAG_PAINT | FLAG_TEXT) == 0
            {
                r.flags |= FLAG_PICK;
            }
        }
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
        assign_runs(&mut self.dl);
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
        // Version 2: path shapes (and rotated rects) as device-px polygons.
        let mut paths: Vec<(Vec<(Vec<(f32, f32)>, bool)>, bool)> = Vec::new();
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
                ClipShape::Rect { w, h, transform: t } if self.v2 => {
                    let (w, h) = (*w as f32, *h as f32);
                    let ring = [(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]
                        .iter()
                        .map(|&(x, y)| map(t, x, y))
                        .collect::<Vec<_>>();
                    paths.push((vec![(ring, true)], false));
                }
                ClipShape::Path {
                    path,
                    evenodd,
                    transform: t,
                } if self.v2 => {
                    let runs: Vec<_> = flatten_runs(path, *t)
                        .into_iter()
                        .filter(|(r, _)| r.len() >= 3)
                        .collect();
                    paths.push((runs, *evenodd));
                }
                _ => ok = false,
            }
        }
        // A path clip also bounds the rect (its bbox), for culling.
        for (runs, _) in &paths {
            let (mut x0, mut y0, mut x1, mut y1) = (
                f64::INFINITY,
                f64::INFINITY,
                f64::NEG_INFINITY,
                f64::NEG_INFINITY,
            );
            for (r, _) in runs {
                for &(x, y) in r {
                    x0 = x0.min(x as f64);
                    y0 = y0.min(y as f64);
                    x1 = x1.max(x as f64);
                    y1 = y1.max(y as f64);
                }
            }
            if x0 > x1 {
                // an empty path clips everything away
                x0 = 0.0;
                x1 = 0.0;
                y0 = 0.0;
                y1 = 0.0;
            }
            acc[0] = acc[0].max(x0);
            acc[1] = acc[1].max(y0);
            acc[2] = acc[2].min(x1);
            acc[3] = acc[3].min(y1);
        }
        let out = if ok {
            if acc[2] < acc[0] {
                acc[2] = acc[0];
            }
            if acc[3] < acc[1] {
                acc[3] = acc[1];
            }
            self.dl.clips.push(acc);
            if self.v2 {
                let start = (self.dl.cp_path_off.len() - 1) as u32;
                for (runs, evenodd) in &paths {
                    for (r, _) in runs {
                        for &(x, y) in r {
                            self.dl.cp_xy.push(x);
                            self.dl.cp_xy.push(y);
                        }
                        self.dl.cp_run_off.push((self.dl.cp_xy.len() / 2) as u32);
                    }
                    self.dl
                        .cp_path_off
                        .push((self.dl.cp_run_off.len() - 1) as u32);
                    self.dl.cp_evenodd.push(*evenodd as u8);
                }
                self.dl.clip_paths.push((start, paths.len() as u32));
            }
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
        if self.blend_stack.iter().any(|&b| b) {
            flags |= FLAG_BLEND;
        }
        self.dl.recs.push(Rec {
            kind,
            paint,
            key,
            flags,
            clip: ci,
            panel: self.panel_stack.last().copied().unwrap_or(0),
            group: self.alpha_stack.last().copied().unwrap_or(0),
            node: self.cur_node,
            run: 0,
            blend: self.root_stack.last().copied().unwrap_or(0),
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

    /// A fill paint: packed colour (None for no / non-solid fill), gradient
    /// index (version 2; 0 = none) and flags. Version 2 lists linear and
    /// radial gradients with `pad` extension (only recorded while a listed
    /// mark is being drawn, so unlisted marks add no rows).
    fn fill_of(&mut self, p: &ResolvedPaint, t: Transform) -> (Option<u32>, u32, u8) {
        let (radial, p1, p2, r1, r2, stops, extend) = match p {
            ResolvedPaint::Solid(c) => return (Some(pack(*c)), 0, 0),
            ResolvedPaint::Linear {
                x1,
                y1,
                x2,
                y2,
                stops,
                extend,
            } => (false, (*x1, *y1), (*x2, *y2), 0.0, 0.0, stops, extend),
            ResolvedPaint::Radial {
                cx,
                cy,
                r,
                fx,
                fy,
                fr,
                stops,
                extend,
            } => (true, (*fx, *fy), (*cx, *cy), *fr, *r, stops, extend),
            _ => return (None, 0, FLAG_PAINT),
        };
        if !self.v2
            || !matches!(extend, Extend::Pad)
            || stops.is_empty()
            || (self.marker.is_none() && !self.active())
        {
            return (None, 0, FLAG_PAINT);
        }
        let g = Gradient {
            radial,
            p1,
            p2,
            r1,
            r2,
            transform: [t.sx, t.ky, t.kx, t.sy, t.tx, t.ty],
            stops: stops
                .iter()
                .map(|s: &Stop| (s.offset, pack(s.color)))
                .collect(),
        };
        let ix = match self.dl.gradients.iter().rposition(|h| *h == g) {
            Some(i) => i,
            None => {
                self.dl.gradients.push(g);
                self.dl.gradients.len() - 1
            }
        };
        (None, ix as u32 + 1, 0)
    }

    /// While a marker is open, paint calls set its paint instead of recording
    /// geometry. Returns whether the call was absorbed.
    fn absorb(
        &mut self,
        fill: Option<(Option<u32>, u32, u8)>,
        stroke: Option<(Rgba, &StrokeStyle, Transform)>,
    ) -> bool {
        let Some(m) = self.marker else { return false };
        let rec = &mut self.dl.recs[m];
        if let Some((f, g, fl)) = fill {
            rec.paint.fill = f;
            rec.paint.grad = g;
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

/// Group the marks a client cannot draw from the list into ordered runs
/// (VW-30), so a host can composite a raster of just those marks between the
/// marks it draws itself and keep the paint order.
///
/// A node is *flagged* when one of its records is flagged (pick-only aside):
/// a layer filter selects whole nodes, so every record of that node goes with
/// it. With version 2, a flagged record inside a listed opacity group flags
/// every node in the group's outermost listed ancestor, since that group is
/// composited as one layer and cannot be split between the client's canvas
/// and the raster. A run is a maximal stretch of flagged nodes' records in
/// paint order; only a record that paints (unflagged, not pick-only) ends it.
/// Each record gets its run (0 = none) and `node_runs` its nodes.
///
/// A run also ends where the blend root changes (VW-32), so a run is either
/// free of blend roots (composited normally) or exactly one root's marks
/// (composited with its blend mode); `run_blend` says which.
pub fn assign_runs(dl: &mut DisplayList) {
    let drawn_flag = |r: &Rec| r.flags & !FLAG_PICK != 0;
    let root_of = |dl: &DisplayList, mut g: u32| {
        let mut guard = 0;
        while g > 0 && guard < 256 {
            let p = dl
                .groups
                .get(g as usize - 1)
                .map(|gr| gr.parent)
                .unwrap_or(0);
            if p == 0 {
                break;
            }
            g = p;
            guard += 1;
        }
        g
    };
    let mut tainted: std::collections::HashSet<u32> = std::collections::HashSet::new();
    for r in &dl.recs {
        if r.group > 0 && drawn_flag(r) {
            tainted.insert(root_of(dl, r.group));
        }
    }
    let mut flagged_nodes: std::collections::HashSet<u32> = std::collections::HashSet::new();
    for r in &dl.recs {
        if drawn_flag(r) || (r.group > 0 && tainted.contains(&root_of(dl, r.group))) {
            flagged_nodes.insert(r.node);
        }
    }
    let mut runs = 0u32;
    let mut in_run = false;
    let mut run_root = 0u32;
    let mut node_runs = HashMap::new();
    let mut run_blend: Vec<String> = Vec::new();
    for r in dl.recs.iter_mut() {
        if flagged_nodes.contains(&r.node) {
            if !in_run || r.blend != run_root {
                runs += 1;
                in_run = true;
                run_root = r.blend;
                run_blend.push(match r.blend {
                    0 => "normal".to_string(),
                    b => match dl.blend_roots.get(b as usize - 1).copied() {
                        Some(k) => k.css().unwrap_or("normal").to_string(),
                        None => String::new(),
                    },
                });
            }
            r.run = runs;
            node_runs.entry(r.node).or_insert(runs);
        } else {
            r.run = 0;
            if r.flags & FLAG_PICK == 0 {
                in_run = false;
            }
        }
    }
    dl.runs = runs;
    dl.node_runs = node_runs;
    dl.run_blend = run_blend;
}

fn pack(c: Rgba) -> u32 {
    ((c.r as u32) << 24) | ((c.g as u32) << 16) | ((c.b as u32) << 8) | c.a as u32
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
        grad: 0,
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
        let (f, g, fl) = self.fill_of(paint, transform);
        if self.absorb(Some((f, g, fl)), None) {
            return;
        }
        let pk = PaintKey {
            fill: f,
            grad: g,
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
        let (f, g, ffl) = self.fill_of(paint, transform);
        if self.absorb(Some((f, g, ffl)), Some((color, stroke, transform))) {
            return;
        }
        let (mut pk, sfl) = stroke_paint(color, stroke, transform);
        pk.fill = f;
        pk.grad = g;
        let n = self.dl.recs.len();
        self.record_path(path, transform, true, pk, ffl | sfl, clip);
        if self.dl.recs.len() > n {
            self.set_last_evenodd(rule);
        }
    }

    /// An unpainted closed shape: listed by its geometry, flagged pick-only.
    fn pick_only_path(&mut self, path: &Path, transform: Transform, rule: FillRule, clip: &Clip) {
        if self.marker.is_some() {
            return; // the marker's point record already stands for it
        }
        let n = self.dl.recs.len();
        self.record_path(path, transform, true, PaintKey::default(), FLAG_PICK, clip);
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
        let other = mask.is_some() || blend != BlendKind::Normal || !effect.is_none();
        self.blend_stack.push(blend != BlendKind::Normal);
        // Blend roots (VW-32). Inside a root, everything belongs to it. A
        // blend group drawn straight onto the page is a root a client can
        // composite with its mode. Inside an isolating group (an effect or a
        // listed opacity group, whose content is flagged and rasterised
        // together) the blend happens within that raster: no root. Plain
        // (effect-free) groups don't isolate in any backend (VR-21), so a
        // blend inside only plain groups is a root like one on the page.
        let parent = self.root_stack.last().copied().unwrap_or(0);
        let root = if parent != 0 {
            parent
        } else if blend == BlendKind::Normal || self.groups.iter().any(|&g| g != 0) {
            0
        } else {
            self.dl.blend_roots.push(blend);
            self.dl.blend_roots.len() as u32
        };
        self.root_stack.push(root);
        if !other && alpha < 1.0 && self.v2 {
            // Version 2: an opacity-only group is listed; its records carry it.
            self.dl.groups.push(Group {
                alpha: alpha.max(0.0),
                parent: self.alpha_stack.last().copied().unwrap_or(0),
            });
            self.alpha_stack.push(self.dl.groups.len() as u32);
            self.groups.push(2);
        } else if other || alpha < 1.0 {
            self.effect_depth += 1;
            self.groups.push(1);
        } else {
            self.groups.push(0);
        }
    }

    fn end_group(&mut self) {
        self.blend_stack.pop();
        self.root_stack.pop();
        match self.groups.pop() {
            Some(1) => self.effect_depth -= 1,
            Some(2) => {
                self.alpha_stack.pop();
            }
            _ => {}
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
        let (mut pk, sfl) = match &stroke {
            Some((c, st)) if st.width > 0.0 => stroke_paint(*c, st, transform),
            _ => (PaintKey::default(), 0),
        };
        // The fill is resolved at the first listed circle (a gradient is
        // recorded only for a listed mark).
        let mut ffl: Option<u8> = None;
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
            let fl = match ffl {
                Some(fl) => fl,
                None => {
                    let (f, g, fl) = fill
                        .map(|p| self.fill_of(p, transform))
                        .unwrap_or((None, 0, 0));
                    pk.fill = f;
                    pk.grad = g;
                    ffl = Some(fl);
                    fl
                }
            };
            let (x, y) = map(&transform, cx[i] as f32, cy[i] as f32);
            self.dl.pt_cx.push(x);
            self.dl.pt_cy.push(y);
            self.dl.pt_r.push(r[i] as f32 * s);
            self.dl.pt_shape.push(0);
            self.push_rec(KIND_POINT, pk.clone(), fl | sfl, clip);
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

    fn begin_draw_node(&mut self, node: usize) {
        self.cur_node = node as u32;
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

    fn red() -> ResolvedPaint {
        ResolvedPaint::Solid(Rgba {
            r: 255,
            g: 0,
            b: 0,
            a: 255,
        })
    }

    fn one_circle(b: &mut DisplayListBackend, key: &str, fill: &ResolvedPaint, clip: &Clip) {
        b.draw_circles(
            &[5.0],
            &[5.0],
            &[2.0],
            Some(fill),
            None,
            Transform::identity(),
            clip,
            &[key.to_string()],
        );
    }

    #[test]
    fn version_two_lists_opacity_groups_version_one_flags_them() {
        for v in [1u32, 2] {
            let mut b = DisplayListBackend::with_options(None, v);
            b.begin_group(None, 0.5, BlendKind::Normal, GroupEffect::default());
            b.begin_group(None, 0.4, BlendKind::Normal, GroupEffect::default());
            one_circle(&mut b, "in", &red(), &no_clip());
            b.end_group();
            b.end_group();
            b.begin_group(None, 0.5, BlendKind::Multiply, GroupEffect::default());
            one_circle(&mut b, "bl", &red(), &no_clip());
            b.end_group();
            one_circle(&mut b, "out", &red(), &no_clip());
            let dl = b.finish();
            assert_eq!(dl.version, v);
            if v == 1 {
                assert_eq!(dl.recs[0].flags, FLAG_GROUP);
                assert!(dl.groups.is_empty());
            } else {
                assert_eq!(dl.recs[0].flags, 0);
                assert_eq!(dl.recs[0].group, 2);
                assert_eq!(
                    dl.groups,
                    vec![
                        Group {
                            alpha: 0.5,
                            parent: 0
                        },
                        Group {
                            alpha: 0.4,
                            parent: 1
                        }
                    ]
                );
            }
            assert_eq!(dl.recs[1].flags, FLAG_GROUP | FLAG_BLEND); // blend: always flagged
            assert_eq!(dl.recs[2].flags, 0);
            assert_eq!(dl.recs[2].group, 0);
        }
    }

    #[test]
    fn version_two_lists_pad_gradients_and_path_clips() {
        let stops = vec![
            Stop {
                offset: 0.0,
                color: Rgba {
                    r: 255,
                    g: 0,
                    b: 0,
                    a: 255,
                },
            },
            Stop {
                offset: 1.0,
                color: Rgba {
                    r: 0,
                    g: 0,
                    b: 255,
                    a: 255,
                },
            },
        ];
        let lin = |extend| ResolvedPaint::Linear {
            x1: 0.0,
            y1: 0.0,
            x2: 10.0,
            y2: 0.0,
            stops: stops.clone(),
            extend,
        };
        let mut pb = tiny_skia::PathBuilder::new();
        pb.move_to(0.0, 0.0);
        pb.line_to(10.0, 0.0);
        pb.line_to(5.0, 10.0);
        pb.close();
        let shapes = [ClipShape::Path {
            path: pb.finish().unwrap(),
            evenodd: false,
            transform: Transform::from_row(2.0, 0.0, 0.0, 2.0, 0.0, 0.0),
        }];
        let tri = Clip {
            id: 7,
            shapes: &shapes,
        };
        for v in [1u32, 2] {
            let mut b = DisplayListBackend::with_options(None, v);
            one_circle(&mut b, "pad", &lin(Extend::Pad), &no_clip());
            one_circle(&mut b, "rep", &lin(Extend::Repeat), &no_clip());
            one_circle(&mut b, "clipped", &red(), &tri);
            let dl = b.finish();
            if v == 1 {
                assert_eq!(dl.recs[0].flags, FLAG_PAINT);
                assert_eq!(dl.recs[2].flags, FLAG_CLIP);
                assert!(dl.gradients.is_empty() && dl.clip_paths.is_empty());
            } else {
                assert_eq!(dl.recs[0].flags, 0);
                assert_eq!(dl.recs[0].paint.grad, 1);
                assert_eq!(dl.recs[0].paint.fill, None);
                assert_eq!(dl.gradients.len(), 1);
                assert_eq!(
                    dl.gradients[0].stops,
                    vec![(0.0, 0xff0000ff), (1.0, 0x0000ffff)]
                );
                assert_eq!(dl.recs[2].flags, 0);
                assert_eq!(dl.recs[2].clip, 1);
                assert_eq!(dl.clip_paths, vec![(0, 1)]);
                assert_eq!(dl.cp_xy, vec![0.0, 0.0, 20.0, 0.0, 10.0, 20.0]);
                assert_eq!(dl.clips[0], [0.0, 0.0, 20.0, 20.0]);
            }
            assert_eq!(dl.recs[1].flags, FLAG_PAINT); // repeat: flagged
                                                      // a gradient-filled mark is not pick-only
            assert_eq!(dl.recs[0].flags & FLAG_PICK, 0);
        }
    }

    #[test]
    fn flagged_nodes_group_into_ordered_runs() {
        let mut b = DisplayListBackend::with_options(None, 2);
        // a masked mark: flagged, and (unlike a blend) no blend root
        let blend = |b: &mut DisplayListBackend, node: usize, key: &str| {
            b.begin_draw_node(node);
            b.begin_group(Some(mask()), 1.0, BlendKind::Normal, GroupEffect::default());
            one_circle(b, key, &red(), &no_clip());
            b.end_group();
        };
        let plain = |b: &mut DisplayListBackend, node: usize, key: &str| {
            b.begin_draw_node(node);
            one_circle(b, key, &red(), &no_clip());
        };
        plain(&mut b, 0, "a"); // exact
        blend(&mut b, 1, "b"); // run 1
        blend(&mut b, 2, "c"); // still run 1
                               // a pick-only mark does not end a run
        b.begin_draw_node(3);
        b.draw_circles(
            &[1.0],
            &[1.0],
            &[1.0],
            None,
            None,
            Transform::identity(),
            &no_clip(),
            &["p".to_string()],
        );
        blend(&mut b, 4, "d"); // run 1
        plain(&mut b, 5, "e"); // exact: ends the run
        blend(&mut b, 6, "f"); // run 2
                               // an opacity group holding one flagged mark goes whole into a run
        b.begin_group(None, 0.5, BlendKind::Normal, GroupEffect::default());
        plain(&mut b, 7, "g");
        blend(&mut b, 8, "h");
        b.end_group();
        plain(&mut b, 9, "i"); // exact
        let dl = b.finish();
        let runs: Vec<u32> = dl.recs.iter().map(|r| r.run).collect();
        assert_eq!(runs, vec![0, 1, 1, 0, 1, 0, 2, 2, 2, 0]);
        assert_eq!(dl.runs, 2);
        assert_eq!(dl.node_runs.get(&1), Some(&1));
        assert_eq!(dl.node_runs.get(&7), Some(&2)); // unflagged, but in the tainted group
        assert!(!dl.node_runs.contains_key(&0) && !dl.node_runs.contains_key(&3));
        // no flagged mark: no run
        let mut b = DisplayListBackend::with_options(None, 2);
        plain(&mut b, 0, "a");
        let dl = b.finish();
        assert_eq!(dl.runs, 0);
        assert!(dl.node_runs.is_empty());
        // every run of masked marks composites normally
        let mut b = DisplayListBackend::with_options(None, 2);
        blend(&mut b, 0, "a");
        assert_eq!(b.finish().run_blend, vec!["normal".to_string()]);
    }

    fn mask() -> MaskLayer {
        MaskLayer {
            pixmap: tiny_skia::Pixmap::new(1, 1).unwrap(),
            kind: super::super::MaskKind::Alpha,
        }
    }

    #[test]
    fn runs_split_at_blend_roots_and_report_their_mode() {
        let mut b = DisplayListBackend::with_options(None, 2);
        let group = |b: &mut DisplayListBackend, node: usize, mode: BlendKind, keys: &[&str]| {
            b.begin_draw_node(node);
            b.begin_group(None, 1.0, mode, GroupEffect::default());
            for k in keys {
                one_circle(b, k, &red(), &no_clip());
            }
            b.end_group();
        };
        let masked = |b: &mut DisplayListBackend, node: usize, key: &str| {
            b.begin_draw_node(node);
            b.begin_group(Some(mask()), 1.0, BlendKind::Normal, GroupEffect::default());
            one_circle(b, key, &red(), &no_clip());
            b.end_group();
        };
        let plain = |b: &mut DisplayListBackend, node: usize, key: &str| {
            b.begin_draw_node(node);
            one_circle(b, key, &red(), &no_clip());
        };
        plain(&mut b, 0, "a"); // exact
        masked(&mut b, 1, "b"); // run 1 (normal)
        group(&mut b, 2, BlendKind::Multiply, &["c", "d"]); // run 2: one root, both marks
        group(&mut b, 3, BlendKind::Multiply, &["e"]); // run 3: another root, same mode
        group(&mut b, 4, BlendKind::Screen, &["f"]); // run 4
        masked(&mut b, 5, "g"); // run 5 (normal)
        plain(&mut b, 6, "h"); // exact
                               // a blend nested in a root belongs to it
        b.begin_draw_node(7);
        b.begin_group(None, 1.0, BlendKind::Overlay, GroupEffect::default());
        one_circle(&mut b, "i", &red(), &no_clip());
        b.begin_group(None, 1.0, BlendKind::Difference, GroupEffect::default());
        one_circle(&mut b, "j", &red(), &no_clip());
        b.end_group();
        b.end_group(); // run 6 (overlay)
                       // a blend inside a masked group blends within its raster: normal
        b.begin_draw_node(8);
        b.begin_group(Some(mask()), 1.0, BlendKind::Normal, GroupEffect::default());
        one_circle(&mut b, "k", &red(), &no_clip());
        b.begin_group(None, 1.0, BlendKind::Multiply, GroupEffect::default());
        one_circle(&mut b, "l", &red(), &no_clip());
        b.end_group();
        b.end_group(); // run 7 (normal)
        plain(&mut b, 9, "m"); // exact
                               // a blend inside plain groups is a root like one on the page (VR-21)
        b.begin_draw_node(10);
        b.begin_group(None, 1.0, BlendKind::Normal, GroupEffect::default());
        b.begin_group(None, 1.0, BlendKind::Screen, GroupEffect::default());
        one_circle(&mut b, "n", &red(), &no_clip());
        b.end_group();
        b.end_group(); // run 8 (screen)
        let dl = b.finish();
        let runs: Vec<u32> = dl.recs.iter().map(|r| r.run).collect();
        assert_eq!(runs, vec![0, 1, 2, 2, 3, 4, 5, 0, 6, 6, 7, 7, 0, 8]);
        assert_eq!(dl.runs, 8);
        assert_eq!(
            dl.run_blend,
            vec![
                "normal", "multiply", "multiply", "screen", "normal", "overlay", "normal", "screen"
            ]
        );
        assert_eq!(dl.blend_roots.len(), 5); // c-d, e, f, i-j, n
    }
}
