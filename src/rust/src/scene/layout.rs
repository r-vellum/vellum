//! The viewport tree and its layout pass: grid-layout track solving and the
//! top-down resolution of each viewport's transform, size, gpar and clip chain.

use super::*;

/// A layout track size: an absolute extent, or a flexible (`null`) weight.
#[derive(Clone, Copy, Debug)]
pub(super) enum Track {
    Abs(f64, Unit),
    Null(f64),
}

#[derive(Clone, Debug)]
pub(super) struct Layout {
    pub(super) widths: Vec<Track>,  // columns
    pub(super) heights: Vec<Track>, // rows
    /// grid-style `respect`: equalize the physical size of a `null` width unit and
    /// a `null` height unit, centering the grid (see `solve_layout`).
    pub(super) respect: bool,
}

/// Pixel extent of one absolute track within `total` parent pixels.
fn track_abs_px(value: f64, u: Unit, total: f64, dpi: f64) -> f64 {
    match u.kind {
        UnitKind::Npc | UnitKind::Native => value * total,
        UnitKind::Mm => value / 25.4 * dpi,
        UnitKind::Inch => value * dpi,
        UnitKind::Pt => value / 72.0 * dpi,
    }
}

/// Pixel sizes of a list of tracks within `total` parent pixels: absolute tracks
/// measured directly, `null` tracks sharing the remainder by weight.
fn track_sizes(tracks: &[Track], total: f64, dpi: f64) -> Vec<f64> {
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
    sizes
}

/// Cumulative edges (length `n + 1`, starting at 0) from track sizes.
fn edges_of(sizes: &[f64]) -> Vec<f64> {
    let mut edges = vec![0.0; sizes.len() + 1];
    for i in 0..sizes.len() {
        edges[i + 1] = edges[i] + sizes[i];
    }
    edges
}

/// Total `null` weight and current `null` pixel extent of an axis.
fn null_summary(tracks: &[Track], sizes: &[f64]) -> (f64, f64) {
    let mut weight = 0.0;
    let mut px = 0.0;
    for (i, t) in tracks.iter().enumerate() {
        if let Track::Null(w) = t {
            weight += w.max(0.0);
            px += sizes[i];
        }
    }
    (weight, px)
}

/// Solve both axes of a layout into cell edges plus a centering offset per axis.
///
/// With `layout.respect`, one unit of `null` width is forced to the same physical
/// size as one unit of `null` height (grid's `respect = TRUE`): the axis whose
/// null unit is larger shrinks its `null` tracks to match, and the freed space
/// centers the whole grid via the returned offset. Absolute tracks are untouched,
/// so gutters stay attached to the panel. Without `respect` this is the plain
/// per-axis solve (offsets 0) — byte-for-byte the previous behaviour.
pub(super) fn solve_layout(
    layout: &Layout,
    total_w: f64,
    total_h: f64,
    dpi: f64,
) -> (Vec<f64>, f64, Vec<f64>, f64) {
    let mut xs = track_sizes(&layout.widths, total_w, dpi);
    let mut ys = track_sizes(&layout.heights, total_h, dpi);
    let (mut xoff, mut yoff) = (0.0, 0.0);
    if layout.respect {
        let (wweight, wpx) = null_summary(&layout.widths, &xs);
        let (hweight, hpx) = null_summary(&layout.heights, &ys);
        if wweight > 0.0 && hweight > 0.0 {
            let upw = wpx / wweight; // px per null-weight-unit, x
            let uph = hpx / hweight; // px per null-weight-unit, y
            if upw > uph {
                let scale = uph / upw;
                for (i, t) in layout.widths.iter().enumerate() {
                    if matches!(t, Track::Null(_)) {
                        xs[i] *= scale;
                    }
                }
                xoff = (total_w - xs.iter().sum::<f64>()) / 2.0;
            } else if uph > upw {
                let scale = upw / uph;
                for (i, t) in layout.heights.iter().enumerate() {
                    if matches!(t, Track::Null(_)) {
                        ys[i] *= scale;
                    }
                }
                yoff = (total_h - ys.iter().sum::<f64>()) / 2.0;
            }
        }
    }
    (edges_of(&xs), xoff, edges_of(&ys), yoff)
}

// --- viewport tree ----------------------------------------------------------

/// How a viewport is positioned within its parent.
#[derive(Clone, Copy, Debug)]
pub(super) enum Placement {
    /// Centre `(cx, cy)` and size `(w, h)` in parent coordinates, each with its
    /// own unit.
    Absolute {
        cx: f64,
        cy: f64,
        w: f64,
        h: f64,
        cxu: Unit,
        cyu: Unit,
        wu: Unit,
        hu: Unit,
    },
    /// A cell (0-based) of the parent's layout, possibly spanning.
    Cell {
        row: usize,
        col: usize,
        rowspan: usize,
        colspan: usize,
    },
}

/// An arbitrary clip-path spec attached to a viewport (its own coordinates):
/// `nper` closed sub-paths over `(x, y)`, filled by winding or even-odd.
#[derive(Clone, Debug)]
pub(super) struct ClipPathSpec {
    pub(super) x: Vec<f64>,
    pub(super) y: Vec<f64>,
    pub(super) xu: Vec<Unit>,
    pub(super) yu: Vec<Unit>,
    pub(super) nper: Vec<usize>,
    pub(super) evenodd: bool,
}

#[derive(Clone, Debug)]
pub(super) struct ViewportNode {
    pub(super) parent: Option<usize>,
    pub(super) children: Vec<usize>,
    pub(super) placement: Placement,
    pub(super) xscale: (f64, f64),
    pub(super) yscale: (f64, f64),
    pub(super) angle: f64,
    pub(super) clip: bool,
    /// An arbitrary clip path (overrides the rectangular `clip` when set).
    pub(super) clip_path: Option<ClipPathSpec>,
    pub(super) gp: PartialGpar,
    pub(super) layout: Option<Layout>,
}

/// A viewport after the layout pass: its local frame and effective context.
/// `clip_chain` is the list of clipping-ancestor shapes to intersect
/// (empty = no clip); backends turn it into a mask / `<clipPath>` / PDF clip.
#[derive(Clone)]
pub(super) struct ResolvedVp {
    pub(super) vp: Vp,
    pub(super) gp_acc: GparAcc,
    pub(super) clip_chain: Vec<ClipShape>,
}

pub(super) fn build_tracks(vals: &[f64], units: &[String]) -> Vec<Track> {
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

impl Scene {
    /// Resolve every viewport (transform, size, accumulated gpar, clip mask).
    /// DFS from the root guarantees a parent is resolved before its children.
    ///
    /// Recomputed on each of `render_to`/`pixel`/`resolved_geometry` rather than
    /// memoised: a `Scene` is built once per compile and then queried once per
    /// operation, so there is no intra-`Scene` reuse to cache today. If a
    /// display/grammar layer ever issues several queries against one `Scene`, add an
    /// interior-mutability (`OnceCell`) cache here — the method already takes `&self`.
    pub(super) fn resolve_all(&self) -> Vec<ResolvedVp> {
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
            origin: (0.0, 0.0),
            exact: Affine::IDENTITY,
        };
        let root_clip = if root.clip {
            vec![ClipShape::Rect {
                w: self.w_px as f64,
                h: self.h_px as f64,
                transform: Transform::identity(),
            }]
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
            // Borrow the (already-resolved) parent instead of deep-cloning the whole
            // ResolvedVp (gp_acc + clip_chain) just to pass a reference. The borrow
            // ends when resolve_one returns its owned result, before the write below.
            let resolved = self.resolve_one(node, out[node.parent.unwrap()].as_ref().unwrap());
            out[id] = Some(resolved);
            for &c in node.children.iter().rev() {
                stack.push(c);
            }
        }

        out.into_iter()
            .map(|r| r.expect("all viewports resolved"))
            .collect()
    }

    fn resolve_one(&self, node: &ViewportNode, parent: &ResolvedVp) -> ResolvedVp {
        // Child rectangle in PARENT-local pixels. `shifted`: the origin is in
        // the parent's (possibly rebased) resolver frame rather than its
        // unshifted local frame.
        let shifted = matches!(node.placement, Placement::Absolute { .. });
        let (x0, top, cw, ch) = match node.placement {
            Placement::Absolute {
                cx,
                cy,
                w,
                h,
                cxu,
                cyu,
                wu,
                hu,
            } => {
                let cw = parent.vp.x_len(w, wu);
                let ch = parent.vp.y_len(h, hu);
                let center_x = parent.vp.x_pos(cx, cxu);
                let center_y = parent.vp.y_pos(cy, cyu);
                (center_x - cw / 2.0, center_y - ch / 2.0, cw, ch)
            }
            Placement::Cell {
                row,
                col,
                rowspan,
                colspan,
            } => {
                // `push_viewport` rejects a cell with no layout or out of range,
                // on the R thread. This runs at render time -- on rayon workers
                // for an animation -- where an R error would longjmp across a
                // foreign thread, so nothing here throws: a cell that still slips
                // through (a raw FFI caller) with no layout is an empty box at the
                // parent's origin, and one out of range clamps to the last track.
                match self.viewports[node.parent.unwrap()].layout.as_ref() {
                    None => (0.0, 0.0, 0.0, 0.0),
                    Some(layout) => {
                        // `respect` may shrink the null axis and center the grid (offsets).
                        let (xe, xoff, ye, yoff) =
                            solve_layout(layout, parent.vp.w, parent.vp.h, self.dpi);
                        let cstart = col.min(xe.len().saturating_sub(1));
                        let cend = (col + colspan).min(xe.len().saturating_sub(1));
                        let rstart = row.min(ye.len().saturating_sub(1));
                        let rend = (row + rowspan).min(ye.len().saturating_sub(1));
                        let x_lo = xe.get(cstart).copied().unwrap_or(0.0);
                        let x_hi = xe.get(cend).copied().unwrap_or(x_lo);
                        let y_lo = ye.get(rstart).copied().unwrap_or(0.0);
                        let y_hi = ye.get(rend).copied().unwrap_or(y_lo);
                        (
                            xoff + x_lo,
                            yoff + y_lo,
                            (x_hi - x_lo).max(0.0),
                            (y_hi - y_lo).max(0.0),
                        )
                    }
                }
            }
        };

        // The placement in f64, from the parent's unshifted frame (VR-45).
        let (po, pexact) = (parent.vp.origin, parent.vp.exact);
        let (x0u, topu) = if shifted {
            (x0 + po.0, top + po.1)
        } else {
            (x0, top)
        };
        let exact = pexact
            .pre_concat(Affine::translate(x0u, topu))
            .pre_concat(Affine::rotation_about(node.angle, cw / 2.0, ch / 2.0));
        let far = exact.is_finite() && exact.tx.abs().max(exact.ty.abs()) > PRECISE_PX;
        let rebase = if far {
            exact.preimage_of_origin()
        } else {
            None
        };
        let (transform, origin) = match rebase {
            // Far from the device origin: shift the local frame so the
            // transform's offset (computed in f64) is about zero.
            Some(o) => (
                exact.pre_concat(Affine::translate(o.0, o.1)).to_transform(),
                o,
            ),
            // Under a rebased parent: narrow the f64 placement.
            None if po != (0.0, 0.0) => (exact.to_transform(), (0.0, 0.0)),
            // Every ordinary viewport: placed in f32, exactly as before.
            None => (
                parent
                    .vp
                    .transform
                    .pre_concat(Transform::from_translate(x0 as f32, top as f32))
                    .pre_concat(rotation_about(node.angle, cw / 2.0, ch / 2.0)),
                (0.0, 0.0),
            ),
        };

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
            origin,
            exact,
        };

        let mut clip_chain = parent.clip_chain.clone();
        let shape = if let Some(cp) = &node.clip_path {
            // A clip path that cannot be built (a missing vertex, or bounds that
            // overflow) clips everything away rather than nothing (VR-42).
            Some(
                build_subpaths(&cp.x, &cp.y, &cp.xu, &cp.yu, &cp.nper, &vp)
                    .map(|path| ClipShape::Path {
                        path,
                        evenodd: cp.evenodd,
                        transform,
                    })
                    .unwrap_or_else(ClipShape::nothing),
            )
        } else if node.clip && origin != (0.0, 0.0) && exact.kx == 0.0 && exact.ky == 0.0 {
            // A rebased, axis-aligned viewport keeps a rect clip, so backends
            // that special-case rects (PowerPoint regions, the display list)
            // treat it as they treat a near one. Its device box is computed in
            // f64 and cut to the page (nothing beyond it is visible), so its
            // edges are exact in f32 and a box within the page is exactly the
            // one a near viewport gets (VR-45).
            let (pw, ph) = (self.w_px as f64, self.h_px as f64);
            let (xa, xb) = (exact.tx, exact.tx + exact.sx * cw);
            let (ya, yb) = (exact.ty, exact.ty + exact.sy * ch);
            let x0 = xa.min(xb).clamp(0.0, pw);
            let x1 = xa.max(xb).clamp(0.0, pw);
            let y0 = ya.min(yb).clamp(0.0, ph);
            let y1 = ya.max(yb).clamp(0.0, ph);
            Some(ClipShape::Rect {
                w: x1 - x0,
                h: y1 - y0,
                transform: Transform::from_translate(x0 as f32, y0 as f32),
            })
        } else if node.clip && origin != (0.0, 0.0) {
            // A rotated rebased viewport's box starts at `-origin` in its
            // frame; its corners are placed in f64 first, so an edge on the
            // page is exact.
            let (l, t) = (-origin.0, -origin.1);
            let mut pb = tiny_skia::PathBuilder::new();
            pb.move_to(l as f32, t as f32);
            pb.line_to((l + cw) as f32, t as f32);
            pb.line_to((l + cw) as f32, (t + ch) as f32);
            pb.line_to(l as f32, (t + ch) as f32);
            pb.close();
            Some(
                pb.finish()
                    .map(|path| ClipShape::Path {
                        path,
                        evenodd: false,
                        transform,
                    })
                    .unwrap_or_else(ClipShape::nothing),
            )
        } else if node.clip {
            Some(ClipShape::Rect {
                w: cw,
                h: ch,
                transform,
            })
        } else {
            None
        };
        if let Some(shape) = shape {
            // Normalised here, once, so every backend (and hit-testing) sees the
            // same empty region for a clip it could not represent (VR-42).
            clip_chain.push(if shape.is_finite() {
                shape
            } else {
                ClipShape::nothing()
            });
        }

        ResolvedVp {
            vp,
            gp_acc: parent.gp_acc.apply(&node.gp),
            clip_chain,
        }
    }
}
