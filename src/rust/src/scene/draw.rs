//! The render walk: memoised rasterisation and geometry recording, and
//! `render_nodes`, which walks the resolved scene in paint order and dispatches
//! each primitive to its `draw_*` function in `marks.rs`.

use super::*;

thread_local! {
    /// Per-node render times (seconds), indexed by node position, accumulated
    /// during the walk when profiling is on. Off by default so a normal render
    /// pays nothing -- `Instant::now()` twice per node is cheap but not free.
    static NODE_TIMES: RefCell<Option<Vec<f64>>> = const { RefCell::new(None) };
}

/// Start (or stop) collecting per-node render times on this thread.
pub fn set_profiling(on: bool) {
    NODE_TIMES.with(|t| *t.borrow_mut() = if on { Some(Vec::new()) } else { None });
}

/// Take the collected per-node times, leaving collection armed and empty.
pub fn take_node_times() -> Vec<f64> {
    NODE_TIMES.with(|t| {
        let mut b = t.borrow_mut();
        match b.as_mut() {
            Some(v) => std::mem::take(v),
            None => Vec::new(),
        }
    })
}

/// Records one node's elapsed time on drop, so every exit from the (heavily
/// `continue`-d) walk body is measured without threading a timer through each arm.
struct NodeTimer {
    idx: usize,
    start: std::time::Instant,
}

impl Drop for NodeTimer {
    fn drop(&mut self) {
        let dt = self.start.elapsed().as_secs_f64();
        let idx = self.idx;
        NODE_TIMES.with(|t| {
            if let Some(v) = t.borrow_mut().as_mut() {
                if v.len() <= idx {
                    v.resize(idx + 1, 0.0);
                }
                v[idx] += dt;
            }
        });
    }
}

impl Scene {
    /// Rasterise the whole page once and memoise it; subsequent calls return the
    /// stored pixmap (see the `raster_cache` field invariant). The raster backend
    /// produces no degradation warnings, so none are surfaced here (unlike
    /// `render_svg`/`render_pdf`, which build their own backend to keep warnings).
    /// The finished raster as it should be *output*: the cached pixmap, or a CVD
    /// simulation of it. The simulation is deliberately never stored -- the render
    /// cache is keyed without it, so caching a simulated pixmap would serve it back
    /// to a later plain render.
    pub(super) fn output_pixmap(&self) -> Pixmap {
        let pm = self.cached_pixmap().clone();
        self.simulate(pm)
    }

    pub(super) fn simulate(&self, mut pm: Pixmap) -> Pixmap {
        if let Some(kind) = cvd_mode() {
            crate::cvd::apply(&mut pm, kind);
        }
        pm
    }

    pub(super) fn cached_pixmap(&self) -> Ref<'_, Pixmap> {
        if self.raster_cache.borrow().is_none() {
            super::ffi::check_raster_area(self.w_px, self.h_px);
            let mut b = RasterBackend::new(self.w_px, self.h_px, self.bg);
            b.set_bitmap_text(self.want_bitmap_text());
            self.render_to(&mut b);
            *self.raster_cache.borrow_mut() = Some(b.into_pixmap());
        }
        Ref::map(self.raster_cache.borrow(), |o| o.as_ref().unwrap())
    }

    /// The geometry of every drawn element, recorded once from the render walk
    /// through a painting-free backend and memoised. Every query reads this, so
    /// they all agree with each other and with what is drawn.
    pub(super) fn recording(&self) -> Arc<Recording> {
        if let Some(r) = self.geom_cache.borrow().as_ref() {
            return Arc::clone(r);
        }
        let mut b = RecordBackend::new(self.nodes.len());
        self.render_to(&mut b);
        let r = Arc::new(b.sink.finish());
        *self.geom_cache.borrow_mut() = Some(Arc::clone(&r));
        r
    }

    /// Walk the resolved scene in paint order, emitting each primitive through a
    /// [`RenderBackend`]. Geometry resolution (transform, clip, gpar, path) is
    /// shared; only the per-primitive draw calls are backend-specific.
    pub(super) fn render_to<B: RenderBackend>(&self, b: &mut B) -> Vec<String> {
        self.render_layer_to(b, &LayerFilter::all())
    }

    /// [`render_to`](Self::render_to) restricted to one [`Layer`] (the split
    /// render). Same page, transforms and clips as the full walk, so the layers
    /// overlay pixel-exactly.
    pub(super) fn render_layer_to<B: RenderBackend>(
        &self,
        b: &mut B,
        layer: &LayerFilter,
    ) -> Vec<String> {
        let resolved = self.resolve_all();
        if layer.layer.needs_order() && layer.above.is_empty() {
            let layer = self.with_paint_order(layer);
            self.render_nodes(b, &resolved, &self.nodes, Some(&self.meta), &layer);
        } else if layer.layer == Layer::KeyedFlagged && layer.flagged.is_none() {
            let layer = self.with_flagged_runs(layer);
            self.render_nodes(b, &resolved, &self.nodes, Some(&self.meta), &layer);
        } else {
            self.render_nodes(b, &resolved, &self.nodes, Some(&self.meta), layer);
        }
        b.take_warnings()
    }

    /// Fill `layer.flagged` for the flagged-marks layer (VW-30): walk the scene
    /// through the display-list backend (version 2, restricted to the layer's
    /// panels, as the client's list is) and take each flagged node's run.
    pub(super) fn with_flagged_runs(&self, layer: &LayerFilter) -> LayerFilter {
        let mut d = crate::render::DisplayListBackend::with_options(layer.panels.clone(), 2);
        let _ = self.render_to(&mut d);
        let dl = d.finish();
        LayerFilter {
            layer: layer.layer,
            panels: layer.panels.clone(),
            above: layer.above.clone(),
            flagged: Some(dl.node_runs),
            run: layer.run,
        }
    }

    /// Fill `layer.above` for the paint-order split (VW-21): for each top-level
    /// node, whether a mark was painted before it within its innermost named
    /// panel. A mark counts for every panel enclosing it; a node outside every
    /// named panel compares against the first mark anywhere.
    pub(super) fn with_paint_order(&self, layer: &LayerFilter) -> LayerFilter {
        use std::collections::HashMap;
        let mut stack: Vec<&str> = Vec::new();
        let mut first: HashMap<&str, usize> = HashMap::new();
        let mut first_any: Option<usize> = None;
        let mut innermost: Vec<Option<&str>> = Vec::with_capacity(self.nodes.len());
        for (i, (_, node)) in self.nodes.iter().enumerate() {
            match node {
                Node::PanelStart { name, .. } => stack.push(name.as_str()),
                Node::PanelEnd => {
                    stack.pop();
                }
                _ => {}
            }
            let inner = stack.last().copied();
            innermost.push(inner);
            if layer.is_mark(node, inner.unwrap_or_default()) {
                first_any.get_or_insert(i);
                for p in &stack {
                    first.entry(*p).or_insert(i);
                }
            }
        }
        let above = innermost
            .iter()
            .enumerate()
            .map(|(i, p)| {
                let t = match p {
                    Some(p) => first.get(p).copied(),
                    None => first_any,
                };
                t.is_some_and(|t| t < i)
            })
            .collect();
        LayerFilter {
            layer: layer.layer,
            panels: layer.panels.clone(),
            above,
            flagged: layer.flagged.clone(),
            run: layer.run,
        }
    }

    /// Render an ordered node list (the scene, or a mask's content) onto `b`.
    /// Group markers open/close isolated layers; a closing mask is rasterized
    /// (always to a `RasterBackend`) and handed to `end_group`. `meta`, when given,
    /// is parallel to `nodes`: each non-empty entry brackets its primitive with
    /// `begin_node`/`end_node` so vector backends can attach semantic attributes
    /// (mask content is drawn without metadata).
    fn render_nodes<B: RenderBackend>(
        &self,
        b: &mut B,
        resolved: &[ResolvedVp],
        nodes: &[(usize, Node)],
        meta: Option<&[NodeMeta]>,
        layer: &LayerFilter,
    ) {
        // Innermost named panel, for a panel-restricted layer filter.
        let mut panel_stack: Vec<&str> = Vec::new();
        // Repaint-boundary state (raster backend only): `skip_depth > 0` means we
        // are skipping a cached subtree whose pixels were already composited from
        // the cache; `sub_stack` holds, per open (miss) boundary, its cache key —
        // or `None` for a path-clipped boundary rendered inline (see subraster_key).
        let mut skip_depth = 0usize;
        let mut sub_stack: Vec<Option<SubKey>> = Vec::new();
        for (i, (vp_id, node)) in nodes.iter().enumerate() {
            if skip_depth > 0 {
                match node {
                    Node::SubrasterStart { .. } => skip_depth += 1,
                    Node::SubrasterEnd => skip_depth -= 1,
                    _ => {}
                }
                continue;
            }
            // A recording walk (queries) learns which node the following
            // geometry belongs to, and in which viewport frame it arrives.
            if let Some(g) = b.geom_sink() {
                g.begin(i, resolved[*vp_id].vp.transform);
            }
            // begin_node/end_node are consumed only by the SVG backend (they are
            // no-ops on raster/PDF), so build the attribute string — two `format!`s
            // in `svg_attrs` — only when the backend actually emits it. Empty attrs
            // ⇒ has_meta false ⇒ the (no-op) bracketing is skipped downstream.
            // Profiling: time this node. Only the top-level walk is measured --
            // `meta` is `None` for the nested walks that rasterise mask content,
            // whose node indices would otherwise collide with the page's.
            let _timer = if meta.is_some()
                && b.geom_sink().is_none()
                && NODE_TIMES.with(|t| t.borrow().is_some())
            {
                Some(NodeTimer {
                    idx: i,
                    start: std::time::Instant::now(),
                })
            } else {
                None
            };
            // Both the SVG and PDF backends consume node metadata (as `<g>`
            // attributes and as structure-tree tags respectively); raster does
            // not, and should not pay to carry it.
            let node_meta = match meta.and_then(|m| m.get(i)).filter(|md| !md.is_empty()) {
                Some(md) if b.wants_node_meta() => Some(md),
                _ => None,
            };
            let has_meta = node_meta.is_some();
            let attrs = node_meta.cloned().unwrap_or_default();
            match node {
                Node::SubrasterStart { nid } => {
                    // Vector backends ignore the boundary (render subtree inline).
                    // So does a layer walk: a partial subtree must never enter
                    // the cache a full render would then reuse.
                    if b.caches_subrasters() && layer.is_all() {
                        let rv = &resolved[*vp_id];
                        match subraster_key(
                            *nid,
                            &rv.vp.transform,
                            &rv.clip_chain,
                            rv.gp_acc.fingerprint(),
                            self.w_px,
                            self.h_px,
                            self.dpi,
                        ) {
                            None => sub_stack.push(None), // path-clipped: inline, no capture
                            Some(key) => {
                                if let Some(pm) = subraster_get(&key) {
                                    b.composite_subraster(&pm); // hit: reuse; skip the subtree
                                    skip_depth = 1;
                                } else {
                                    b.subraster_begin(); // miss: capture into a fresh layer
                                    sub_stack.push(Some(key));
                                }
                            }
                        }
                    }
                    continue;
                }
                Node::SubrasterEnd => {
                    if b.caches_subrasters() && layer.is_all() {
                        if let Some(Some(key)) = sub_stack.pop() {
                            if let Some(pm) = b.subraster_end() {
                                subraster_put(key, pm.clone());
                                b.composite_subraster(&pm);
                            }
                        }
                    }
                    continue;
                }
                Node::GroupStart {
                    mask,
                    alpha,
                    blend,
                    effect,
                } => {
                    // Recording geometry paints nothing, so a mask need not be
                    // rasterised for it.
                    if b.geom_sink().is_some() {
                        continue;
                    }
                    let ml = mask.and_then(|m| self.masks.get(m)).map(|md| {
                        let mut mb = RasterBackend::new(
                            self.w_px,
                            self.h_px,
                            Rgba {
                                r: 0,
                                g: 0,
                                b: 0,
                                a: 0,
                            },
                        );
                        // A mask is the mark's own modulation, not a layer:
                        // its content is always drawn in full.
                        self.render_nodes(&mut mb, resolved, &md.nodes, None, &LayerFilter::all());
                        MaskLayer {
                            pixmap: mb.into_pixmap(),
                            kind: md.kind,
                        }
                    });
                    b.begin_group(ml, *alpha, *blend, *effect);
                    continue;
                }
                Node::GroupEnd => {
                    b.end_group();
                    continue;
                }
                Node::PanelStart { name, pannable } => {
                    panel_stack.push(name);
                    b.begin_panel(name, *pannable);
                    continue;
                }
                Node::PanelEnd => {
                    panel_stack.pop();
                    b.end_panel();
                    continue;
                }
                // Images carry no gpar; resolve geometry and draw directly.
                Node::Image {
                    rgba,
                    iw,
                    ih,
                    x,
                    y,
                    w,
                    h,
                    xu,
                    yu,
                    wu,
                    hu,
                    interpolate,
                } => {
                    if !layer.keeps(i, node, panel_stack.last().copied().unwrap_or_default()) {
                        continue;
                    }
                    let rv = &resolved[*vp_id];
                    let vp = &rv.vp;
                    let clip = Clip {
                        id: *vp_id,
                        shapes: &rv.clip_chain,
                    };
                    let cx = vp.x_pos(*x, *xu);
                    let cy = vp.y_pos(*y, *yu);
                    let pw = vp.x_extent(*w, *wu);
                    let ph = vp.y_extent(*h, *hu);
                    if let Some(g) = b.geom_sink() {
                        g.rect(0, cx - pw / 2.0, cy - ph / 2.0, pw, ph);
                    }
                    if has_meta {
                        b.begin_node(&attrs);
                    }
                    b.draw_image(
                        rgba,
                        *iw,
                        *ih,
                        cx,
                        cy,
                        pw,
                        ph,
                        *interpolate,
                        vp.transform,
                        &clip,
                    );
                    if has_meta {
                        b.end_node();
                    }
                    continue;
                }
                _ => {}
            }
            // Split render: drop drawing nodes outside the requested layer
            // (before any begin_node, so nothing needs closing).
            if !layer.keeps(i, node, panel_stack.last().copied().unwrap_or_default()) {
                continue;
            }

            let rv = &resolved[*vp_id];
            let vp = &rv.vp;
            // Drawing nodes only; a structural node with no gpar would have been
            // consumed by the match above, but skip it defensively if not (before
            // any begin_node, so nothing needs closing).
            let node_gp = match node.gp() {
                Some(g) => g,
                None => continue,
            };
            let gp = rv.gp_acc.apply(node_gp).resolve();
            // Push this node's anti-aliasing to the backend before any draw call
            // (see `render::set_antialias` for why it is a thread-local).
            crate::render::set_antialias(gp.antialias);
            let t = vp.transform;
            let clip = Clip {
                id: *vp_id,
                shapes: &rv.clip_chain,
            };

            if has_meta {
                b.begin_node(&attrs);
            }
            if meta.is_some() {
                b.begin_draw_node(i);
            }
            // Clear any per-element data key from the previous node so a keyed
            // batch never leaks its last key onto a later, keyless node.
            b.set_element_key(None);
            match node {
                Node::Rect { .. } => draw_rect(b, node, &gp, vp, t, &clip),
                Node::RoundRect { .. } => draw_round_rect(b, node, &gp, vp, t, &clip),
                Node::Lines { .. } => draw_lines(b, node, &gp, vp, t, &clip),
                Node::Polygon { .. } => draw_polygon(b, node, &gp, vp, t, &clip),
                Node::Circle { .. } => draw_circle(b, node, &gp, vp, t, &clip),
                Node::Rects { .. } => draw_rects(b, node, &gp, vp, t, &clip),
                Node::Circles { .. } => draw_circles(b, node, &gp, vp, t, &clip),
                Node::Markers { .. } => draw_markers(b, node, &gp, vp, t, &clip),
                Node::Hexagons { .. } => draw_hexagons(b, node, &gp, vp, t, &clip),
                Node::Sectors { .. } => draw_sectors(b, node, &gp, vp, t, &clip),
                Node::Text { .. } => draw_text(b, node, &gp, vp, t, &clip),
                Node::Segments { .. } => draw_segments(b, node, &gp, vp, t, &clip),
                Node::Loop { .. } => draw_loop(b, node, &gp, vp, t, &clip),
                Node::Path { .. } => draw_path(b, node, &gp, vp, t, &clip),
                Node::Image { .. }
                | Node::GroupStart { .. }
                | Node::GroupEnd
                | Node::SubrasterStart { .. }
                | Node::SubrasterEnd
                | Node::PanelStart { .. }
                | Node::PanelEnd => unreachable!("handled above"),
            }
            if has_meta {
                b.end_node();
            }
        }
    }
}
