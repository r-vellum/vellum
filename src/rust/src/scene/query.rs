//! Read-only queries over a compiled scene (geometry, lint, pick, fonts,
//! elements, hit testing). Each answers from the recorded render walk, so they
//! agree with each other and with what is drawn.

use super::*;

/// Axis-aligned device-px bounding box `(min_x, min_y, max_x, max_y)` of a clip
/// shape (its local rect/path corners mapped through its own transform). Used by
/// `resolved_geometry` to draw the clip region in the debug overlay.
fn clip_shape_bbox(shape: &ClipShape) -> (f64, f64, f64, f64) {
    let (corners, t) = match shape {
        ClipShape::Rect { w, h, transform } => {
            (vec![(0.0, 0.0), (*w, 0.0), (*w, *h), (0.0, *h)], *transform)
        }
        ClipShape::Path {
            path, transform, ..
        } => {
            let b = path.bounds();
            (
                vec![
                    (b.left() as f64, b.top() as f64),
                    (b.right() as f64, b.top() as f64),
                    (b.right() as f64, b.bottom() as f64),
                    (b.left() as f64, b.bottom() as f64),
                ],
                *transform,
            )
        }
    };
    let map = |x: f64, y: f64| {
        (
            t.sx as f64 * x + t.kx as f64 * y + t.tx as f64,
            t.ky as f64 * x + t.sy as f64 * y + t.ty as f64,
        )
    };
    let (mut minx, mut miny, mut maxx, mut maxy) = (
        f64::INFINITY,
        f64::INFINITY,
        f64::NEG_INFINITY,
        f64::NEG_INFINITY,
    );
    for (x, y) in corners {
        let (dx, dy) = map(x, y);
        minx = minx.min(dx);
        miny = miny.min(dy);
        maxx = maxx.max(dx);
        maxy = maxy.max(dy);
    }
    (minx, miny, maxx, maxy)
}

/// Build the intersection clip `Mask` for a resolved clip chain (device px), or
/// `None` when there is no clip. Used by `hit_test`: the mask is built **aliased**
/// (no fractional edge coverage) to match the aliased pick fills, so a pixel
/// exactly on a clip boundary is fully in or fully out and its decoded pick id is
/// exact — a fractional edge would blend the pick colour toward the white no-hit
/// background and mis-decode. (Real rendering uses the raster backend's own
/// anti-aliased `mask_for`.)
fn build_clip_mask(w: u32, h: u32, chain: &[ClipShape]) -> Option<Mask> {
    if chain.is_empty() {
        return None;
    }
    let aa = false; // aliased: hard 0/255 coverage for exact pick decoding
    let mut m = Mask::new(w, h)?;
    if let Some(p) = rect_path(0.0, 0.0, w as f64, h as f64) {
        m.fill_path(&p, FillRule::Winding, aa, Transform::identity());
    }
    for shape in chain {
        match shape {
            ClipShape::Rect {
                w: rw,
                h: rh,
                transform,
            } => match rect_path(0.0, 0.0, *rw, *rh) {
                Some(r) => intersect_fit(&mut m, &r, FillRule::Winding, *transform),
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
                intersect_fit(&mut m, path, rule, *transform);
            }
        }
    }
    Some(m)
}

/// Intersect the (aliased) hit-test clip mask with a clip region, cut to the
/// page first when it reaches far past it, as the raster backend's own clip
/// masks are (VR-43): tiny-skia's mask fill cannot take such geometry, so a
/// far clip region used to hide every element from `hit_test()`.
fn intersect_fit(m: &mut Mask, path: &tiny_skia::Path, rule: FillRule, t: Transform) {
    match crate::render::fit::fitted_fill(path, t, m.width(), m.height()) {
        Some((p, t)) => m.intersect_path(&p, rule, false, t),
        None => m.clear(),
    }
}

/// Map a local-pixel axis-aligned bbox through a viewport's affine transform to a
/// device-pixel bbox (the min/max of the four mapped corners; handles rotation).
/// A short, stable name for a node kind, used by the linter and by
/// `profile_render()`. Empty for structural markers (group/panel/subraster
/// brackets), which draw nothing.
/// `0xRRGGBBAA` as an f64. The lint table reports colours this way because the
/// value does not fit in a signed 32-bit integer -- red >= 128 sets the sign bit
/// -- and R has no unsigned integer type to receive it.
fn pack_rgba(c: Rgba) -> f64 {
    ((c.r as u32) << 24 | (c.g as u32) << 16 | (c.b as u32) << 8 | c.a as u32) as f64
}

fn node_kind(node: &Node) -> &'static str {
    match node {
        Node::Rect { .. } | Node::Rects { .. } => "rect",
        Node::RoundRect { .. } => "roundrect",
        Node::Circle { .. } | Node::Circles { .. } => "circle",
        Node::Markers { .. } => "points",
        Node::Hexagons { .. } => "hexagon",
        Node::Sectors { .. } => "sector",
        Node::Segments { .. } => "segments",
        Node::Loop { .. } => "loop",
        Node::Lines { .. } => "lines",
        Node::Polygon { .. } => "polygon",
        Node::Path { .. } => "path",
        Node::Text { .. } => "text",
        Node::Image { .. } => "raster",
        _ => "",
    }
}

/// How many elements a node draws (1 for single-shape marks).
fn node_count(node: &Node) -> usize {
    match node {
        Node::Rects { x, .. }
        | Node::Circles { x, .. }
        | Node::Markers { x, .. }
        | Node::Hexagons { x, .. }
        | Node::Sectors { x, .. }
        | Node::Loop { x, .. } => x.len(),
        Node::Segments { x0, .. } => x0.len(),
        _ => 1,
    }
}

/// How many elements a node contributes to the element table and the pick
/// table: a batched mark one per element (over the columns that define an
/// element), a single-shape keyable mark one when keyed, anything else none.
/// Element `i` here is element `i` of the recording.
fn elem_count(node: &Node) -> usize {
    let min = |v: &[usize]| v.iter().copied().min().unwrap_or(0);
    match node {
        Node::Rects { x, y, w, h, .. } => min(&[x.len(), y.len(), w.len(), h.len()]),
        Node::Circles { x, y, r, .. } => min(&[x.len(), y.len(), r.len()]),
        Node::Markers { x, y, size, .. } => min(&[x.len(), y.len(), size.len()]),
        Node::Hexagons { x, y, .. } => min(&[x.len(), y.len()]),
        Node::Sectors {
            x,
            y,
            r0,
            r1,
            theta0,
            theta1,
            ..
        } => min(&[
            x.len(),
            y.len(),
            r0.len(),
            r1.len(),
            theta0.len(),
            theta1.len(),
        ]),
        Node::Segments { x0, y0, x1, y1, .. } => min(&[x0.len(), y0.len(), x1.len(), y1.len()]),
        Node::Text { key, .. }
        | Node::RoundRect { key, .. }
        | Node::Path { key, .. }
        | Node::Polygon { key, .. }
        | Node::Lines { key, .. } => usize::from(key.is_some()),
        _ => 0,
    }
}

/// The data key of element `i` of a node, if it has one.
fn elem_key(node: &Node, i: usize) -> Option<&str> {
    match node {
        Node::Rects { keys, .. }
        | Node::Circles { keys, .. }
        | Node::Markers { keys, .. }
        | Node::Hexagons { keys, .. }
        | Node::Sectors { keys, .. }
        | Node::Segments { keys, .. } => key_at(keys, i),
        Node::Text { key, .. }
        | Node::RoundRect { key, .. }
        | Node::Path { key, .. }
        | Node::Polygon { key, .. }
        | Node::Lines { key, .. } => key.as_deref(),
        _ => None,
    }
}

/// The `kind` the pick table (`vl_nearest()`, `element_geometry()`) reports
/// for a keyable node; empty for a node that is never picked.
fn pick_kind(node: &Node) -> &'static str {
    match node {
        Node::Segments { .. } => "segment",
        Node::Lines { .. } => "line",
        Node::Polygon { .. } => "polygon",
        Node::Path { .. } => "path",
        Node::Circles { .. } | Node::Markers { .. } => "point",
        Node::Rects { .. } => "rect",
        Node::Hexagons { .. } => "hexagon",
        Node::Sectors { .. } => "sector",
        Node::Text { .. } => "text",
        Node::RoundRect { .. } => "roundrect",
        _ => "",
    }
}

/// The device-px bounds of a clip shape (a path clip is reduced to its bbox --
/// enough for "is this entirely clipped away", which is all the linter asks).
fn clip_bbox(c: &ClipShape) -> Option<(f64, f64, f64, f64)> {
    match c {
        ClipShape::Rect { w, h, transform } => {
            let vpx = Vp {
                transform: *transform,
                w: *w,
                h: *h,
                xscale: (0.0, 1.0),
                yscale: (0.0, 1.0),
                dpi: 96.0,
                origin: (0.0, 0.0),
                exact: crate::units::Affine::from_transform(*transform),
            };
            Some(dev_bbox(&vpx, 0.0, 0.0, *w, *h))
        }
        ClipShape::Path {
            path, transform, ..
        } => {
            let b = path.bounds();
            let vpx = Vp {
                transform: *transform,
                w: 1.0,
                h: 1.0,
                xscale: (0.0, 1.0),
                yscale: (0.0, 1.0),
                dpi: 96.0,
                origin: (0.0, 0.0),
                exact: crate::units::Affine::from_transform(*transform),
            };
            Some(dev_bbox(
                &vpx,
                b.left() as f64,
                b.top() as f64,
                b.right() as f64,
                b.bottom() as f64,
            ))
        }
    }
}

pub(super) fn dev_bbox(vp: &Vp, lx0: f64, ly0: f64, lx1: f64, ly1: f64) -> (f64, f64, f64, f64) {
    let t = vp.transform;
    let (sx, ky, kx, sy, tx, ty) = (
        t.sx as f64,
        t.ky as f64,
        t.kx as f64,
        t.sy as f64,
        t.tx as f64,
        t.ty as f64,
    );
    let corners = [(lx0, ly0), (lx1, ly0), (lx1, ly1), (lx0, ly1)];
    let mut dx0 = f64::INFINITY;
    let mut dy0 = f64::INFINITY;
    let mut dx1 = f64::NEG_INFINITY;
    let mut dy1 = f64::NEG_INFINITY;
    for (px, py) in corners {
        let dx = sx * px + kx * py + tx;
        let dy = ky * px + sy * py + ty;
        dx0 = dx0.min(dx);
        dy0 = dy0.min(dy);
        dx1 = dx1.max(dx);
        dy1 = dy1.max(dy);
    }
    (dx0, dy0, dx1, dy1)
}

impl Scene {
    /// Body of the `content_bbox` R method (see the `#[extendr]` impl in `ffi.rs`).
    pub(super) fn build_content_bbox(&self) -> Vec<i32> {
        let pm = self.cached_pixmap();
        let w = self.w_px as usize;
        let (mut minx, mut miny, mut maxx, mut maxy) = (usize::MAX, usize::MAX, 0usize, 0usize);
        let mut any = false;
        for (i, p) in pm.pixels().iter().enumerate() {
            if p.alpha() > 0 {
                let (x, y) = (i % w, i / w);
                any = true;
                minx = minx.min(x);
                miny = miny.min(y);
                maxx = maxx.max(x);
                maxy = maxy.max(y);
            }
        }
        if any {
            vec![minx as i32, miny as i32, maxx as i32, maxy as i32]
        } else {
            Vec::new()
        }
    }

    /// Body of the `resolved_geometry` R method (see the `#[extendr]` impl in `ffi.rs`).
    pub(super) fn build_resolved_geometry(&self) -> List {
        let resolved = self.resolve_all();
        let n = resolved.len();
        let mut id = Vec::with_capacity(n);
        let mut parent = Vec::with_capacity(n);
        let mut w_px = Vec::with_capacity(n);
        let mut h_px = Vec::with_capacity(n);
        let mut transform: Vec<Robj> = Vec::with_capacity(n);
        let mut has_layout = Vec::with_capacity(n);
        let mut xedges: Vec<Robj> = Vec::with_capacity(n);
        let mut yedges: Vec<Robj> = Vec::with_capacity(n);
        let mut xoff = Vec::with_capacity(n);
        let mut yoff = Vec::with_capacity(n);
        let mut has_clip = Vec::with_capacity(n);
        let mut clip: Vec<Robj> = Vec::with_capacity(n);
        for (i, rv) in resolved.iter().enumerate() {
            id.push(i as i32);
            parent.push(self.viewports[i].parent.map(|p| p as i32).unwrap_or(-1));
            let vp = &rv.vp;
            w_px.push(vp.w);
            h_px.push(vp.h);
            // A rebased viewport (VR-45) reports its unshifted transform, the
            // one that maps the local frame callers compute in.
            let t = if vp.origin == (0.0, 0.0) {
                crate::units::Affine::from_transform(vp.transform)
            } else {
                vp.exact
            };
            transform.push(Robj::from(vec![t.sx, t.ky, t.kx, t.sy, t.tx, t.ty]));
            match &self.viewports[i].layout {
                Some(layout) => {
                    let (xe, xo, ye, yo) = solve_layout(layout, vp.w, vp.h, self.dpi);
                    has_layout.push(1i32);
                    xedges.push(Robj::from(xe));
                    yedges.push(Robj::from(ye));
                    xoff.push(xo);
                    yoff.push(yo);
                }
                None => {
                    has_layout.push(0i32);
                    xedges.push(Robj::from(Vec::<f64>::new()));
                    yedges.push(Robj::from(Vec::<f64>::new()));
                    xoff.push(0.0);
                    yoff.push(0.0);
                }
            }
            match rv.clip_chain.last() {
                Some(shape) => {
                    let (x0, y0, x1, y1) = clip_shape_bbox(shape);
                    has_clip.push(1i32);
                    clip.push(Robj::from(vec![x0, y0, x1, y1]));
                }
                None => {
                    has_clip.push(0i32);
                    clip.push(Robj::from(Vec::<f64>::new()));
                }
            }
        }
        list!(
            id = id,
            parent = parent,
            w_px = w_px,
            h_px = h_px,
            transform = List::from_values(transform),
            has_layout = has_layout,
            xedges = List::from_values(xedges),
            yedges = List::from_values(yedges),
            xoff = xoff,
            yoff = yoff,
            has_clip = has_clip,
            clip = List::from_values(clip)
        )
    }

    /// Body of the `lint_table` R method (see the `#[extendr]` impl in `ffi.rs`).
    pub(super) fn build_lint_table(&self) -> List {
        let resolved = self.resolve_all();
        let rec = self.recording();
        let n = self.nodes.len();
        let (mut kind, mut name, mut id) = (
            Vec::with_capacity(n),
            Vec::with_capacity(n),
            Vec::with_capacity(n),
        );
        // The node's position in the draw order. Stable within one compile, and
        // shared with `element_table()` so the per-node and per-element views of
        // the same scene can be joined.
        let mut node_ix: Vec<i32> = Vec::with_capacity(n);
        let (mut x0, mut y0, mut x1, mut y1) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        let (mut cx0, mut cy0, mut cx1, mut cy1) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        let (mut nelem, mut alpha, mut has_fill, mut has_col) =
            (Vec::new(), Vec::new(), Vec::new(), Vec::new());
        let (mut font_px, mut col_rgba, mut label) = (Vec::new(), Vec::new(), Vec::new());
        let mut notdef: Vec<i32> = Vec::new();
        // The fill as a colour, plus what kind of paint it is: a gradient or a
        // pattern has no single colour, and a rule that reasons about colour
        // (contrast, CVD confusion) must be able to tell that case apart from a
        // solid rather than silently reading a stop out of it.
        let (mut fill_rgba, mut fill_kind) = (Vec::new(), Vec::new());
        // Stroke width and viewport, in device px and viewport id respectively.
        let (mut lwd_px, mut vp_ix) = (Vec::new(), Vec::new());
        // The node's viewport extent in device px, which is NOT the clip box: an
        // unclipped viewport reports the whole page as its clip, so a mark
        // escaping its viewport is only visible by comparing against this.
        let (mut vx0, mut vy0, mut vx1, mut vy1) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());

        let mut acc_stack: Vec<GparAcc> = Vec::new();
        for (i, (vp_id, node)) in self.nodes.iter().enumerate() {
            let k = node_kind(node);
            if k.is_empty() {
                continue; // structural marker, nothing drawn
            }
            let rv = &resolved[*vp_id];
            let vp = &rv.vp;
            let acc = match node.gp() {
                Some(g) => rv.gp_acc.apply(g),
                None => rv.gp_acc.clone(),
            };
            let gp = acc.resolve();
            // The union of the node's recorded element geometry.
            let bb = match rec
                .get(i)
                .and_then(|els| els.iter().map(|p| parts_bbox(p)).fold(None, union_bbox))
            {
                Some(b) => b,
                None => continue, // nothing measurable (e.g. an empty batch)
            };
            // The innermost clip, in device px; the whole page when unclipped.
            let clip = rv
                .clip_chain
                .iter()
                .filter_map(clip_bbox)
                .fold(None::<(f64, f64, f64, f64)>, |a, c| match a {
                    None => Some(c),
                    Some(p) => Some((p.0.max(c.0), p.1.max(c.1), p.2.min(c.2), p.3.min(c.3))),
                })
                .unwrap_or((0.0, 0.0, self.w_px as f64, self.h_px as f64));

            let md = self.meta.get(i);
            kind.push(k.to_string());
            name.push(md.map(|m| m.name.clone()).unwrap_or_default());
            id.push(md.map(|m| m.id.clone()).unwrap_or_default());
            node_ix.push(i as i32);
            x0.push(bb.0);
            y0.push(bb.1);
            x1.push(bb.2);
            y1.push(bb.3);
            cx0.push(clip.0);
            cy0.push(clip.1);
            cx1.push(clip.2);
            cy1.push(clip.3);
            nelem.push(node_count(node) as i32);
            alpha.push(acc.alpha);
            has_fill.push(i32::from(gp.fill.is_some()));
            has_col.push(i32::from(gp.col.is_some_and(|c| c.a > 0)));
            // Text-only fields; 0 / "" elsewhere.
            match node {
                Node::Text {
                    gsize,
                    label: l,
                    gid,
                    ..
                } => {
                    font_px.push(gsize.iter().cloned().fold(0.0_f64, f64::max));
                    label.push(l.clone());
                    // Glyph 0 is `.notdef` by OpenType convention: the shaper
                    // found no font on this machine with the character and the
                    // renderer will draw a tofu box. Counted here because the
                    // shaped glyph stream is the only place that knows -- the
                    // label string looks perfectly fine.
                    notdef.push(gid.iter().filter(|&&g| g == 0).count() as i32);
                }
                _ => {
                    font_px.push(0.0);
                    label.push(String::new());
                    notdef.push(0);
                }
            }
            // Packed as f64, not i32: `0xRRGGBBAA` does not fit in a signed
            // 32-bit integer once red reaches 128, and the sign bit silently ate
            // the red channel of every light colour (`#EEEEEE` unpacked to -18).
            // A double holds all 32 bits exactly and R has no unsigned integer.
            let c = gp.col.unwrap_or(Rgba {
                r: 0,
                g: 0,
                b: 0,
                a: 0,
            });
            col_rgba.push(pack_rgba(c));
            let (fk, fc) = match &gp.fill {
                None => (
                    "none",
                    Rgba {
                        r: 0,
                        g: 0,
                        b: 0,
                        a: 0,
                    },
                ),
                Some(Paint::Solid(c)) => ("solid", *c),
                Some(Paint::Linear { .. }) => (
                    "linear",
                    Rgba {
                        r: 0,
                        g: 0,
                        b: 0,
                        a: 0,
                    },
                ),
                Some(Paint::Radial { .. }) => (
                    "radial",
                    Rgba {
                        r: 0,
                        g: 0,
                        b: 0,
                        a: 0,
                    },
                ),
                Some(Paint::Pattern(_)) => (
                    "pattern",
                    Rgba {
                        r: 0,
                        g: 0,
                        b: 0,
                        a: 0,
                    },
                ),
                Some(Paint::Hatch { col, .. }) => ("hatch", *col),
            };
            fill_kind.push(fk.to_string());
            fill_rgba.push(pack_rgba(fc));
            lwd_px.push(gp.lwd_px(self.dpi) as f64);
            vp_ix.push(*vp_id as i32);
            let (ox, oy) = vp.origin;
            let vb = dev_bbox(vp, -ox, -oy, vp.w - ox, vp.h - oy);
            vx0.push(vb.0);
            vy0.push(vb.1);
            vx1.push(vb.2);
            vy1.push(vb.3);
            acc_stack.clear();
        }
        list!(
            kind = kind,
            name = name,
            id = id,
            node = node_ix,
            vp = vp_ix,
            x0 = x0,
            y0 = y0,
            x1 = x1,
            y1 = y1,
            clip_x0 = cx0,
            clip_y0 = cy0,
            clip_x1 = cx1,
            clip_y1 = cy1,
            n = nelem,
            alpha = alpha,
            has_fill = has_fill,
            has_col = has_col,
            font_px = font_px,
            col = col_rgba,
            label = label,
            notdef = notdef,
            fill = fill_rgba,
            fill_kind = fill_kind,
            lwd_px = lwd_px,
            vp_x0 = vx0,
            vp_y0 = vy0,
            vp_x1 = vx1,
            vp_y1 = vy1
        )
    }

    /// Body of the `node_index` R method (see the `#[extendr]` impl in `ffi.rs`).
    pub(super) fn build_node_index(&self) -> List {
        let mut kind = Vec::with_capacity(self.nodes.len());
        let mut name = Vec::with_capacity(self.nodes.len());
        let mut n = Vec::with_capacity(self.nodes.len());
        for (i, (_, node)) in self.nodes.iter().enumerate() {
            kind.push(node_kind(node).to_string());
            name.push(self.meta.get(i).map(|m| m.name.clone()).unwrap_or_default());
            n.push(node_count(node) as i32);
        }
        list!(kind = kind, name = name, n = n)
    }

    /// Body of the `pick_table` R method (see the `#[extendr]` impl in `ffi.rs`).
    pub(super) fn build_pick_table(&self, px: f64, py: f64) -> List {
        let rec = self.recording();
        let (mut key, mut kind) = (Vec::new(), Vec::new());
        let (mut dist, mut gn) = (Vec::new(), Vec::new());
        let (mut gx, mut gy) = (Vec::new(), Vec::new());
        // Per-vertex ring index (1-based within the element): one per recorded
        // ring or polyline. Without it the concatenated `gx`/`gy` are lossy: a
        // client cannot tell where one ring ends, and joining the runs invents
        // a phantom edge from each ring's last vertex to the next ring's first.
        let mut gring: Vec<i32> = Vec::new();
        // Per element: the fill rule its rings are filled (and picked) under,
        // "evenodd" or "nonzero"; "" for geometry with no interior (a stroke,
        // a round mark's centre). A client needs it to test containment across
        // a path's rings the way this does.
        let mut rule: Vec<String> = Vec::new();

        for (ni, (_, node)) in self.nodes.iter().enumerate() {
            let knd = pick_kind(node);
            if knd.is_empty() {
                continue;
            }
            for ei in 0..elem_count(node) {
                let Some(k) = elem_key(node, ei) else {
                    continue;
                };
                let parts = rec
                    .get(ni)
                    .and_then(|e| e.get(ei))
                    .map_or(&[][..], |p| &p[..]);
                // Nothing drawn (an `NA` position, a segment its caps consumed):
                // nothing to point at.
                if parts.is_empty() {
                    continue;
                }
                // How the geometry is reported depends on the kind: a rect (or
                // rounded rect) as two opposite corners of its box, a round mark
                // as its centre, everything else as its rings / polylines.
                let runs = match knd {
                    "rect" | "roundrect" => match parts_bbox(parts) {
                        Some((x0, y0, x1, y1)) => vec![vec![(x0, y0), (x1, y1)]],
                        None => continue,
                    },
                    _ => parts_runs(parts),
                };
                key.push(k.to_string());
                kind.push(knd.to_string());
                dist.push(parts_dist(parts, px, py));
                rule.push(parts_rule(parts).unwrap_or_default().to_string());
                gn.push(runs.iter().map(Vec::len).sum::<usize>() as i32);
                for (r, run) in runs.iter().enumerate() {
                    for &(x, y) in run {
                        gx.push(x);
                        gy.push(y);
                        gring.push(r as i32 + 1);
                    }
                }
            }
        }
        list!(
            key = key,
            kind = kind,
            dist = dist,
            n = gn,
            x = gx,
            y = gy,
            ring = gring,
            rule = rule
        )
    }

    /// The spatial index over the keyed elements, built on first use from the
    /// recording and memoised until the scene is drawn into again. Items are
    /// exactly the pick table's rows, in the same (paint) order.
    pub(super) fn spatial(&self) -> Arc<SpatialIndex> {
        if let Some(s) = self.spatial_cache.borrow().as_ref() {
            return Arc::clone(s);
        }
        let rec = self.recording();
        let mut items = Vec::new();
        for (ni, (_, node)) in self.nodes.iter().enumerate() {
            if pick_kind(node).is_empty() {
                continue;
            }
            for ei in 0..elem_count(node) {
                if elem_key(node, ei).is_none() {
                    continue;
                }
                let parts = rec.get(ni).and_then(|e| e.get(ei)).map_or(&[][..], |p| &p[..]);
                if parts.is_empty() {
                    continue;
                }
                items.push(SpatialItem { node: ni, elem: ei, bbox: parts_bbox(parts) });
            }
        }
        let s = Arc::new(SpatialIndex::build(rec, items));
        *self.spatial_cache.borrow_mut() = Some(Arc::clone(&s));
        s
    }

    /// `key` and `kind` columns for a list of spatial-index items.
    fn spatial_rows(&self, idx: &SpatialIndex, hits: impl Iterator<Item = usize>) -> (Vec<String>, Vec<String>) {
        let (mut key, mut kind) = (Vec::new(), Vec::new());
        for i in hits {
            let it = &idx.items()[i];
            let node = &self.nodes[it.node].1;
            key.push(elem_key(node, it.elem).unwrap_or_default().to_string());
            kind.push(pick_kind(node).to_string());
        }
        (key, kind)
    }

    /// Body of the `nearest_table` R method: the `n` keyed elements nearest
    /// device px `(px, py)` within `max_dist`, nearest first (ties in paint
    /// order) -- the pick table's rows sorted by `dist`, without building it.
    pub(super) fn build_nearest_table(&self, px: f64, py: f64, n: usize, max_dist: f64) -> List {
        let idx = self.spatial();
        let hits = idx.nearest(px, py, n, max_dist);
        let (key, kind) = self.spatial_rows(&idx, hits.iter().map(|h| h.0));
        let dist: Vec<f64> = hits.iter().map(|h| h.1).collect();
        list!(key = key, kind = kind, dist = dist)
    }

    /// Body of the `brush_table` / `lasso_table` R methods: the keyed elements
    /// meeting a rectangle (`xs`/`ys` its two corners) or a polygon, in paint
    /// order.
    pub(super) fn build_region_table(&self, xs: &[f64], ys: &[f64], rect: bool, mode: Region) -> List {
        let idx = self.spatial();
        let hits = if rect {
            if xs.len() < 2 || ys.len() < 2 {
                Vec::new()
            } else {
                idx.brush(xs[0], ys[0], xs[1], ys[1], mode)
            }
        } else {
            let poly: Vec<(f64, f64)> = xs.iter().copied().zip(ys.iter().copied()).collect();
            idx.lasso(&poly, mode)
        };
        let (key, kind) = self.spatial_rows(&idx, hits.into_iter());
        list!(key = key, kind = kind)
    }

    /// Body of the `font_table` R method (see the `#[extendr]` impl in `ffi.rs`).
    pub(super) fn build_font_table(&self) -> List {
        use std::collections::BTreeMap;
        let mut counts: BTreeMap<(String, u32), i32> = BTreeMap::new();
        for (_, node) in self.nodes.iter() {
            if let Node::Text { gpath, gface, .. } = node {
                for i in 0..gpath.len().min(gface.len()) {
                    *counts.entry((gpath[i].clone(), gface[i])).or_insert(0) += 1;
                }
            }
        }
        let mut path = Vec::with_capacity(counts.len());
        let mut index = Vec::with_capacity(counts.len());
        let mut glyphs = Vec::with_capacity(counts.len());
        for ((p, i), n) in counts {
            path.push(p);
            index.push(i as i32);
            glyphs.push(n);
        }
        list!(path = path, index = index, glyphs = glyphs)
    }

    /// Body of the `element_table` R method (see the `#[extendr]` impl in `ffi.rs`).
    pub(super) fn build_element_table(&self) -> List {
        let rec = self.recording();
        let mut key: Vec<String> = Vec::new();
        let mut panel: Vec<String> = Vec::new();
        // Grob name and kind per element, so a caller can select elements by the
        // grob they came from. Without these, a batched mark is only reachable
        // through `lint_table()`'s per-NODE union box -- which for a 2000-point
        // scatter is the whole panel, and useless as an obstacle.
        let mut name: Vec<String> = Vec::new();
        let mut kind: Vec<String> = Vec::new();
        let mut node_ix: Vec<i32> = Vec::new();
        let mut x0: Vec<f64> = Vec::new();
        let mut y0: Vec<f64> = Vec::new();
        let mut x1: Vec<f64> = Vec::new();
        let mut y1: Vec<f64> = Vec::new();
        let mut panel_stack: Vec<String> = Vec::new();
        for (ni, (_, node)) in self.nodes.iter().enumerate() {
            match node {
                Node::PanelStart { name: pn, .. } => {
                    panel_stack.push(pn.clone());
                    continue;
                }
                Node::PanelEnd => {
                    panel_stack.pop();
                    continue;
                }
                _ => {}
            }
            // Rows come from the node's structure, never from what happened to
            // be drawn: a batched mark has one row per element, always, and a
            // single-shape mark one row when keyed. `scene_model()` zips these
            // against the R grob tree by position, so the count is the contract.
            // The box is the recorded geometry's; NA when the element drew
            // nothing (an `NA` position, a segment its caps consumed).
            let cnt = elem_count(node);
            if cnt == 0 {
                continue;
            }
            let cur_panel = panel_stack.last().cloned().unwrap_or_default();
            let cur_name = self
                .meta
                .get(ni)
                .map(|m| m.name.clone())
                .unwrap_or_default();
            let cur_kind = node_kind(node).to_string();
            let els = rec.get(ni);
            for ei in 0..cnt {
                let bb = els
                    .and_then(|e| e.get(ei))
                    .and_then(|p| parts_bbox(p))
                    .unwrap_or((f64::NAN, f64::NAN, f64::NAN, f64::NAN));
                key.push(elem_key(node, ei).unwrap_or("").to_string());
                panel.push(cur_panel.clone());
                name.push(cur_name.clone());
                kind.push(cur_kind.clone());
                node_ix.push(ni as i32);
                x0.push(bb.0);
                y0.push(bb.1);
                x1.push(bb.2);
                y1.push(bb.3);
            }
        }
        list!(
            key = key,
            panel = panel,
            name = name,
            kind = kind,
            node = node_ix,
            x0 = x0,
            y0 = y0,
            x1 = x1,
            y1 = y1
        )
    }

    /// Body of the `hit_test` R method (see the `#[extendr]` impl in `ffi.rs`).
    pub(super) fn build_hit_test(&self, x: i32, y: i32) -> i32 {
        if x < 0 || y < 0 || x as u32 >= self.w_px || y as u32 >= self.h_px {
            return -1;
        }
        let rec = self.recording();
        // The pixel's centre: what an aliased fill samples.
        let (px, py) = (x as f64 + 0.5, y as f64 + 0.5);
        let mut resolved: Option<Vec<ResolvedVp>> = None;
        let mut mask_cache: HashMap<usize, Option<Mask>> = HashMap::new();
        for (i, (vp_id, _)) in self.nodes.iter().enumerate().rev() {
            let id = self.picks.get(i).copied().unwrap_or(-1);
            if !(0..=0x00FF_FFFE).contains(&id) {
                continue; // unpickable
            }
            let Some(els) = rec.get(i) else { continue };
            if !els.iter().any(|p| parts_cover(p, px, py, 2.0)) {
                continue;
            }
            let rv = &resolved.get_or_insert_with(|| self.resolve_all())[*vp_id];
            let mask = mask_cache
                .entry(*vp_id)
                .or_insert_with(|| build_clip_mask(self.w_px, self.h_px, &rv.clip_chain));
            if let Some(m) = mask {
                if m.data()[y as usize * self.w_px as usize + x as usize] == 0 {
                    continue; // clipped away here
                }
            }
            return id;
        }
        -1
    }
}
