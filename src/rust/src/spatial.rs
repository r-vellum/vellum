//! A uniform-grid spatial index over a scene's keyed elements (F-6).
//!
//! `vl_nearest()` used to rebuild the whole pick table -- every keyed element's
//! distance and vertices -- on each probe, so a hover-rate caller paid O(n) per
//! mouse move. This index is built once per compiled scene from the recorded
//! geometry (`geom.rs`), cached next to the recording, and answers three
//! queries by visiting only the grid cells near the probe:
//!
//! * [`SpatialIndex::nearest`] -- the `n` elements nearest a point, measured to
//!   their true geometry (the same `parts_dist` the pick table reports);
//! * [`SpatialIndex::brush`] -- the elements meeting an axis-aligned rectangle;
//! * [`SpatialIndex::lasso`] -- the elements meeting a polygon (even-odd rule,
//!   the way vellumwidget's client-side lasso tests it).
//!
//! Every answer is exact: the grid only narrows the candidates, and each
//! candidate is then tested against its recorded parts.

use std::sync::Arc;

use crate::geom::{parts_dist, Part, Recording};
use crate::pick::{inside_rings, seg_dist2};

type Bbox = (f64, f64, f64, f64);

/// How an element must meet a brush or lasso region to be selected.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Region {
    /// Any part of the element's geometry touches the region (default).
    Intersect,
    /// All of the element's geometry lies inside the region.
    Contain,
    /// The centre of the element's bounding box lies inside the region
    /// (vellumwidget's client-side lasso rule).
    Centre,
}

impl Region {
    pub fn parse(s: &str) -> Option<Region> {
        match s {
            "intersect" => Some(Region::Intersect),
            "contain" => Some(Region::Contain),
            "centre" | "center" => Some(Region::Centre),
            _ => None,
        }
    }
}

/// One indexed element: where its parts live in the recording, and its box.
#[derive(Clone, Debug)]
pub struct Item {
    pub node: usize,
    pub elem: usize,
    /// `None` when nothing finite was recorded (never selected by a region; a
    /// nearest query still measures it, as the pick table did).
    pub bbox: Option<Bbox>,
}

/// Items covering more cells than this go to the always-checked list instead
/// of being copied into every cell they span.
const MAX_SPAN: usize = 256;

#[derive(Debug)]
pub struct SpatialIndex {
    rec: Arc<Recording>,
    items: Vec<Item>,
    x0: f64,
    y0: f64,
    cell: f64,
    nx: usize,
    ny: usize,
    /// CSR cell lists: the items of cell `c` are `ids[start[c]..start[c + 1]]`.
    start: Vec<u32>,
    ids: Vec<u32>,
    /// Items checked by every query: no finite box, or too big for the grid.
    always: Vec<u32>,
}

impl SpatialIndex {
    /// Build the grid over `items` (in paint order; their position is the id
    /// every query reports). Cells are square, sized for about one item each.
    pub fn build(rec: Arc<Recording>, items: Vec<Item>) -> SpatialIndex {
        let mut ext: Option<Bbox> = None;
        let mut boxed = 0usize;
        for it in &items {
            if let Some(b) = it.bbox {
                boxed += 1;
                ext = Some(match ext {
                    None => b,
                    Some(e) => (e.0.min(b.0), e.1.min(b.1), e.2.max(b.2), e.3.max(b.3)),
                });
            }
        }
        let (x0, y0, x1, y1) = ext.unwrap_or((0.0, 0.0, 1.0, 1.0));
        let (w, h) = ((x1 - x0).max(0.0), (y1 - y0).max(0.0));
        let k = boxed.max(1) as f64;
        let mut cell = if w * h > 0.0 {
            (w * h / k).sqrt()
        } else {
            w.max(h) / k
        };
        if !(cell.is_finite() && cell > 0.0) {
            cell = 1.0;
        }
        // Keep the cell count bounded by ~4 per item (a very elongated extent
        // would otherwise give one long row of empty cells).
        let cap = 4 * boxed + 16;
        let dims = |c: f64| (((w / c).ceil() as usize).max(1), ((h / c).ceil() as usize).max(1));
        let (mut nx, mut ny) = dims(cell);
        while nx.saturating_mul(ny) > cap {
            cell *= 1.5;
            (nx, ny) = dims(cell);
        }
        let mut idx = SpatialIndex {
            rec,
            items,
            x0,
            y0,
            cell,
            nx,
            ny,
            start: Vec::new(),
            ids: Vec::new(),
            always: Vec::new(),
        };
        // Two passes: count per cell, then fill (CSR).
        let ncell = nx * ny;
        let mut count = vec![0u32; ncell + 1];
        let mut spans: Vec<Option<(usize, usize, usize, usize)>> = Vec::with_capacity(idx.items.len());
        for (i, it) in idx.items.iter().enumerate() {
            let span = it.bbox.map(|b| idx.cell_span(b));
            match span {
                Some((ix0, iy0, ix1, iy1)) if (ix1 - ix0 + 1) * (iy1 - iy0 + 1) <= MAX_SPAN => {
                    for iy in iy0..=iy1 {
                        for ix in ix0..=ix1 {
                            count[iy * nx + ix] += 1;
                        }
                    }
                    spans.push(span);
                }
                _ => {
                    idx.always.push(i as u32);
                    spans.push(None);
                }
            }
        }
        let mut start = vec![0u32; ncell + 1];
        for c in 0..ncell {
            start[c + 1] = start[c] + count[c];
        }
        let mut fill = start.clone();
        let mut ids = vec![0u32; start[ncell] as usize];
        for (i, span) in spans.iter().enumerate() {
            if let Some((ix0, iy0, ix1, iy1)) = *span {
                for iy in iy0..=iy1 {
                    for ix in ix0..=ix1 {
                        let c = iy * nx + ix;
                        ids[fill[c] as usize] = i as u32;
                        fill[c] += 1;
                    }
                }
            }
        }
        idx.start = start;
        idx.ids = ids;
        idx
    }

    pub fn items(&self) -> &[Item] {
        &self.items
    }

    fn parts(&self, i: usize) -> &[Part] {
        let it = &self.items[i];
        self.rec
            .get(it.node)
            .and_then(|e| e.get(it.elem))
            .map_or(&[][..], |p| &p[..])
    }

    /// The cell column/row holding a coordinate, clamped into the grid.
    fn col(&self, x: f64) -> usize {
        let c = ((x - self.x0) / self.cell).floor();
        if c.is_nan() || c < 0.0 {
            0
        } else {
            (c as usize).min(self.nx - 1)
        }
    }
    fn row(&self, y: f64) -> usize {
        let c = ((y - self.y0) / self.cell).floor();
        if c.is_nan() || c < 0.0 {
            0
        } else {
            (c as usize).min(self.ny - 1)
        }
    }

    fn cell_span(&self, b: Bbox) -> (usize, usize, usize, usize) {
        (self.col(b.0), self.row(b.1), self.col(b.2), self.row(b.3))
    }

    fn cell_items(&self, ix: usize, iy: usize) -> &[u32] {
        let c = iy * self.nx + ix;
        &self.ids[self.start[c] as usize..self.start[c + 1] as usize]
    }

    /// The `n` items nearest `(px, py)` within `max_dist`, as `(item, dist)`
    /// sorted by distance and then paint order -- exactly the rows (and order)
    /// a full pick-table scan sorted by distance would give.
    pub fn nearest(&self, px: f64, py: f64, n: usize, max_dist: f64) -> Vec<(usize, f64)> {
        let mut best: Vec<(usize, f64)> = Vec::new();
        if n == 0 || self.items.is_empty() || !(px.is_finite() && py.is_finite()) {
            return best;
        }
        let consider = |best: &mut Vec<(usize, f64)>, i: usize| {
            if let Some(b) = self.items[i].bbox {
                let lb = bbox_dist(b, px, py);
                if lb > max_dist || (best.len() == n && lb > best[n - 1].1) {
                    return;
                }
            }
            let d = parts_dist(self.parts(i), px, py);
            if d.is_nan() || d > max_dist {
                return;
            }
            let pos = best.partition_point(|&(j, dj)| dj < d || (dj == d && j < i));
            if pos < n {
                best.insert(pos, (i, d));
                best.truncate(n);
            }
        };
        if n >= self.items.len() {
            for i in 0..self.items.len() {
                consider(&mut best, i);
            }
            return best;
        }
        for &i in &self.always {
            consider(&mut best, i as usize);
        }
        let mut seen = vec![false; self.items.len()];
        let (cx, cy) = (self.col(px), self.row(py));
        let reach = cx.max(self.nx - 1 - cx).max(cy).max(self.ny - 1 - cy);
        for r in 0..=reach {
            // Anything not seen yet lies in cells at least `r` rings out, so at
            // least `(r - 1)` cells away along some axis.
            if r > 0 {
                let floor = (r - 1) as f64 * self.cell;
                if floor > max_dist || (best.len() == n && best[n - 1].1 < floor) {
                    break;
                }
            }
            let (lo_y, hi_y) = (cy.saturating_sub(r), (cy + r).min(self.ny - 1));
            let (lo_x, hi_x) = (cx.saturating_sub(r), (cx + r).min(self.nx - 1));
            for iy in lo_y..=hi_y {
                let edge_row = iy + r == cy || iy == cy + r;
                let mut ix = lo_x;
                while ix <= hi_x {
                    let on_ring = edge_row || ix + r == cx || ix == cx + r;
                    if on_ring {
                        for &i in self.cell_items(ix, iy) {
                            let i = i as usize;
                            if !seen[i] {
                                seen[i] = true;
                                consider(&mut best, i);
                            }
                        }
                        ix += 1;
                    } else {
                        // Interior of the ring: jump to its right edge.
                        ix = cx + r;
                    }
                }
            }
        }
        best
    }

    /// Candidate items whose box meets `q`, in paint order, deduplicated.
    fn candidates(&self, q: Bbox) -> Vec<usize> {
        let mut out: Vec<usize> = Vec::new();
        let ext = (
            self.x0,
            self.y0,
            self.x0 + self.nx as f64 * self.cell,
            self.y0 + self.ny as f64 * self.cell,
        );
        let mut seen = vec![false; self.items.len()];
        if boxes_meet(q, ext) {
            let (ix0, iy0, ix1, iy1) = self.cell_span(q);
            for iy in iy0..=iy1 {
                for ix in ix0..=ix1 {
                    for &i in self.cell_items(ix, iy) {
                        let i = i as usize;
                        if !seen[i] {
                            seen[i] = true;
                            out.push(i);
                        }
                    }
                }
            }
        }
        for &i in &self.always {
            let i = i as usize;
            if !seen[i] {
                seen[i] = true;
                out.push(i);
            }
        }
        out.retain(|&i| self.items[i].bbox.is_some_and(|b| boxes_meet(b, q)));
        out.sort_unstable();
        out
    }

    /// Items meeting the rectangle `[x0, x1] x [y0, y1]` under `mode`, in
    /// paint order.
    pub fn brush(&self, x0: f64, y0: f64, x1: f64, y1: f64, mode: Region) -> Vec<usize> {
        let q = (x0.min(x1), y0.min(y1), x0.max(x1), y0.max(y1));
        if !(q.0.is_finite() && q.1.is_finite() && q.2.is_finite() && q.3.is_finite()) {
            return Vec::new();
        }
        let mut out = self.candidates(q);
        out.retain(|&i| {
            let b = self.items[i].bbox.expect("candidates have boxes");
            match mode {
                Region::Centre => in_rect(q, (b.0 + b.2) / 2.0, (b.1 + b.3) / 2.0),
                Region::Contain => b.0 >= q.0 && b.1 >= q.1 && b.2 <= q.2 && b.3 <= q.3,
                Region::Intersect => {
                    // A box inside the rectangle is a hit without looking closer.
                    (b.0 >= q.0 && b.1 >= q.1 && b.2 <= q.2 && b.3 <= q.3)
                        || self.parts(i).iter().any(|p| part_meets_rect(p, q))
                }
            }
        });
        out
    }

    /// Items meeting the polygon `poly` (closed implicitly, even-odd rule)
    /// under `mode`, in paint order. Fewer than three vertices select nothing.
    pub fn lasso(&self, poly: &[(f64, f64)], mode: Region) -> Vec<usize> {
        let poly: Vec<(f64, f64)> = poly
            .iter()
            .copied()
            .filter(|p| p.0.is_finite() && p.1.is_finite())
            .collect();
        if poly.len() < 3 {
            return Vec::new();
        }
        let q = poly.iter().fold(
            (f64::INFINITY, f64::INFINITY, f64::NEG_INFINITY, f64::NEG_INFINITY),
            |a, &(x, y)| (a.0.min(x), a.1.min(y), a.2.max(x), a.3.max(y)),
        );
        let (xs, ys): (Vec<f64>, Vec<f64>) = poly.iter().copied().unzip();
        let inside = |x: f64, y: f64| crate::pick::point_in_ring(x, y, &xs, &ys);
        let mut out = self.candidates(q);
        out.retain(|&i| {
            let b = self.items[i].bbox.expect("candidates have boxes");
            match mode {
                Region::Centre => inside((b.0 + b.2) / 2.0, (b.1 + b.3) / 2.0),
                Region::Contain => {
                    b.0 >= q.0
                        && b.1 >= q.1
                        && b.2 <= q.2
                        && b.3 <= q.3
                        && self.parts(i).iter().all(|p| part_in_poly(p, &poly, &inside))
                }
                Region::Intersect => self
                    .parts(i)
                    .iter()
                    .any(|p| part_meets_poly(p, &poly, &inside)),
            }
        });
        out
    }
}

/// Distance from a point to a box (zero inside): a lower bound on the distance
/// to anything inside the box.
fn bbox_dist(b: Bbox, px: f64, py: f64) -> f64 {
    let dx = (b.0 - px).max(0.0).max(px - b.2);
    let dy = (b.1 - py).max(0.0).max(py - b.3);
    (dx * dx + dy * dy).sqrt()
}

fn boxes_meet(a: Bbox, b: Bbox) -> bool {
    a.0 <= b.2 && b.0 <= a.2 && a.1 <= b.3 && b.1 <= a.3
}

fn in_rect(q: Bbox, x: f64, y: f64) -> bool {
    x >= q.0 && x <= q.2 && y >= q.1 && y <= q.3
}

fn finite(p: (f64, f64)) -> bool {
    p.0.is_finite() && p.1.is_finite()
}

/// The edges of a closed ring (the last vertex joins the first), skipping any
/// with a non-finite end.
fn ring_edges(r: &[(f64, f64)]) -> impl Iterator<Item = ((f64, f64), (f64, f64))> + '_ {
    let n = r.len();
    (0..if n > 2 { n } else { n.saturating_sub(1) })
        .map(move |i| (r[i], r[(i + 1) % n]))
        .filter(|&(a, b)| finite(a) && finite(b))
}

/// The segments of an open polyline, skipping breaks (non-finite vertices).
fn line_edges(pts: &[(f64, f64)]) -> impl Iterator<Item = ((f64, f64), (f64, f64))> + '_ {
    pts.windows(2)
        .map(|w| (w[0], w[1]))
        .filter(|&(a, b)| finite(a) && finite(b))
}

/// Does the segment `a`-`b` meet the rectangle `q`? (Liang-Barsky clip.)
fn seg_meets_rect(a: (f64, f64), b: (f64, f64), q: Bbox) -> bool {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let (mut t0, mut t1) = (0.0f64, 1.0f64);
    for (p, d) in [
        (-dx, a.0 - q.0),
        (dx, q.2 - a.0),
        (-dy, a.1 - q.1),
        (dy, q.3 - a.1),
    ] {
        if p == 0.0 {
            if d < 0.0 {
                return false;
            }
        } else {
            let t = d / p;
            if p < 0.0 {
                t0 = t0.max(t);
            } else {
                t1 = t1.min(t);
            }
            if t0 > t1 {
                return false;
            }
        }
    }
    true
}

fn part_meets_rect(p: &Part, q: Bbox) -> bool {
    match p {
        Part::Disc { cx, cy, r } => {
            let x = cx.clamp(q.0, q.2);
            let y = cy.clamp(q.1, q.3);
            (x - cx).powi(2) + (y - cy).powi(2) <= r * r
        }
        Part::Stroke { pts, .. } => {
            pts.iter().any(|&v| finite(v) && in_rect(q, v.0, v.1))
                || line_edges(pts).any(|(a, b)| seg_meets_rect(a, b, q))
        }
        Part::Fill { rings, evenodd } => {
            rings.iter().flatten().any(|&v| finite(v) && in_rect(q, v.0, v.1))
                || rings
                    .iter()
                    .any(|r| ring_edges(r).any(|(a, b)| seg_meets_rect(a, b, q)))
                // No vertex inside and no edge crossing: the rectangle is
                // wholly inside or wholly outside the fill; test one point.
                || inside_rings((q.0 + q.2) / 2.0, (q.1 + q.3) / 2.0, rings, *evenodd)
        }
    }
}

fn orient(a: (f64, f64), b: (f64, f64), c: (f64, f64)) -> f64 {
    (b.0 - a.0) * (c.1 - a.1) - (b.1 - a.1) * (c.0 - a.0)
}

fn on_seg(a: (f64, f64), b: (f64, f64), c: (f64, f64)) -> bool {
    c.0 >= a.0.min(b.0) && c.0 <= a.0.max(b.0) && c.1 >= a.1.min(b.1) && c.1 <= a.1.max(b.1)
}

/// Do segments `a`-`b` and `c`-`d` meet (touching counts)?
fn segs_meet(a: (f64, f64), b: (f64, f64), c: (f64, f64), d: (f64, f64)) -> bool {
    let (d1, d2) = (orient(c, d, a), orient(c, d, b));
    let (d3, d4) = (orient(a, b, c), orient(a, b, d));
    if ((d1 > 0.0 && d2 < 0.0) || (d1 < 0.0 && d2 > 0.0))
        && ((d3 > 0.0 && d4 < 0.0) || (d3 < 0.0 && d4 > 0.0))
    {
        return true;
    }
    (d1 == 0.0 && on_seg(c, d, a))
        || (d2 == 0.0 && on_seg(c, d, b))
        || (d3 == 0.0 && on_seg(a, b, c))
        || (d4 == 0.0 && on_seg(a, b, d))
}

fn crosses_poly(a: (f64, f64), b: (f64, f64), poly: &[(f64, f64)]) -> bool {
    ring_edges(poly).any(|(c, d)| segs_meet(a, b, c, d))
}

/// Distance from a point to the polygon's boundary.
fn poly_boundary_dist(x: f64, y: f64, poly: &[(f64, f64)]) -> f64 {
    ring_edges(poly)
        .map(|(a, b)| seg_dist2(x, y, a.0, a.1, b.0, b.1))
        .fold(f64::INFINITY, f64::min)
        .sqrt()
}

fn part_meets_poly(p: &Part, poly: &[(f64, f64)], inside: &impl Fn(f64, f64) -> bool) -> bool {
    match p {
        Part::Disc { cx, cy, r } => inside(*cx, *cy) || poly_boundary_dist(*cx, *cy, poly) <= *r,
        Part::Stroke { pts, .. } => {
            pts.iter().any(|&v| finite(v) && inside(v.0, v.1))
                || line_edges(pts).any(|(a, b)| crosses_poly(a, b, poly))
        }
        Part::Fill { rings, evenodd } => {
            rings.iter().flatten().any(|&v| finite(v) && inside(v.0, v.1))
                || rings
                    .iter()
                    .any(|r| ring_edges(r).any(|(a, b)| crosses_poly(a, b, poly)))
                // The lasso wholly inside the fill: its vertices are inside.
                || poly.iter().any(|&(x, y)| inside_rings(x, y, rings, *evenodd))
        }
    }
}

fn part_in_poly(p: &Part, poly: &[(f64, f64)], inside: &impl Fn(f64, f64) -> bool) -> bool {
    match p {
        Part::Disc { cx, cy, r } => inside(*cx, *cy) && poly_boundary_dist(*cx, *cy, poly) >= *r,
        Part::Stroke { pts, .. } => {
            pts.iter().any(|&v| finite(v))
                && pts.iter().all(|&v| !finite(v) || inside(v.0, v.1))
                && !line_edges(pts).any(|(a, b)| crosses_poly(a, b, poly))
        }
        Part::Fill { rings, .. } => {
            rings.iter().flatten().any(|&v| finite(v))
                && rings.iter().flatten().all(|&v| !finite(v) || inside(v.0, v.1))
                && !rings
                    .iter()
                    .any(|r| ring_edges(r).any(|(a, b)| crosses_poly(a, b, poly)))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geom::parts_bbox as item_bbox;

    /// A recording of one node whose elements are discs at the given centres.
    fn discs(pts: &[(f64, f64)], r: f64) -> SpatialIndex {
        let elems: Vec<Vec<Part>> = pts.iter().map(|&(cx, cy)| vec![Part::Disc { cx, cy, r }]).collect();
        let items = (0..elems.len())
            .map(|i| Item { node: 0, elem: i, bbox: item_bbox(&elems[i]) })
            .collect();
        SpatialIndex::build(Arc::new(vec![elems]), items)
    }

    fn lcg(seed: &mut u64) -> f64 {
        *seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        (*seed >> 11) as f64 / (1u64 << 53) as f64
    }

    #[test]
    fn nearest_matches_a_full_scan() {
        let mut s = 7u64;
        let pts: Vec<(f64, f64)> = (0..2000).map(|_| (lcg(&mut s) * 800.0, lcg(&mut s) * 600.0)).collect();
        let idx = discs(&pts, 2.0);
        for _ in 0..200 {
            let (px, py) = (lcg(&mut s) * 900.0 - 50.0, lcg(&mut s) * 700.0 - 50.0);
            for &n in &[1usize, 5] {
                let got = idx.nearest(px, py, n, f64::INFINITY);
                let mut all: Vec<(usize, f64)> = (0..pts.len())
                    .map(|i| (i, parts_dist(idx.parts(i), px, py)))
                    .collect();
                all.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap().then(a.0.cmp(&b.0)));
                all.truncate(n);
                assert_eq!(got, all, "probe ({px}, {py}) n = {n}");
            }
        }
        // max_dist cuts off; n = 0 is empty
        assert!(idx.nearest(-500.0, -500.0, 1, 10.0).is_empty());
        assert!(idx.nearest(10.0, 10.0, 0, f64::INFINITY).is_empty());
    }

    #[test]
    fn ties_break_by_paint_order() {
        // three overlapping discs: a probe inside all of them is at distance 0
        let idx = discs(&[(10.0, 10.0), (11.0, 10.0), (10.5, 10.0)], 5.0);
        let got: Vec<usize> = idx.nearest(10.5, 10.0, 2, f64::INFINITY).iter().map(|x| x.0).collect();
        assert_eq!(got, vec![0, 1]);
    }

    #[test]
    fn brush_and_lasso_modes() {
        let idx = discs(&[(10.0, 10.0), (20.0, 10.0), (30.0, 10.0)], 3.0);
        // a box covering x 15..25 contains disc 1, touches discs 0 and 2
        assert_eq!(idx.brush(15.0, 0.0, 25.0, 20.0, Region::Contain), vec![1]);
        assert_eq!(idx.brush(12.0, 0.0, 28.0, 20.0, Region::Intersect), vec![0, 1, 2]);
        assert_eq!(idx.brush(12.0, 0.0, 28.0, 20.0, Region::Contain), vec![1]);
        assert_eq!(idx.brush(14.0, 0.0, 26.0, 20.0, Region::Centre), vec![1]);
        // a triangle around disc 1 only
        let tri = [(20.0, -20.0), (45.0, 25.0), (-5.0, 25.0)];
        assert_eq!(idx.lasso(&tri, Region::Centre), vec![0, 1, 2]);
        let small = [(15.0, 0.0), (25.0, 0.0), (25.0, 20.0), (15.0, 20.0)];
        assert_eq!(idx.lasso(&small, Region::Contain), vec![1]);
        assert_eq!(idx.lasso(&small[..2], Region::Intersect), Vec::<usize>::new());
    }

    #[test]
    fn region_tests_follow_the_true_geometry() {
        // a diagonal segment whose box covers the probe rectangle but whose
        // line does not reach it, and a polygon with a hole
        let seg = vec![Part::Stroke { pts: vec![(0.0, 0.0), (100.0, 100.0)], width: 1.0 }];
        let outer = vec![(200.0, 0.0), (300.0, 0.0), (300.0, 100.0), (200.0, 100.0)];
        let hole = vec![(240.0, 40.0), (240.0, 60.0), (260.0, 60.0), (260.0, 40.0)];
        let donut = vec![Part::Fill { rings: vec![outer, hole], evenodd: true }];
        let elems = vec![seg, donut];
        let items = (0..2).map(|i| Item { node: 0, elem: i, bbox: item_bbox(&elems[i]) }).collect();
        let idx = SpatialIndex::build(Arc::new(vec![elems]), items);
        assert!(idx.brush(70.0, 5.0, 95.0, 20.0, Region::Intersect).is_empty());
        assert_eq!(idx.brush(40.0, 40.0, 60.0, 60.0, Region::Intersect), vec![0]);
        // a box in the hole does not meet the donut; one inside the ring does
        assert!(idx.brush(245.0, 45.0, 255.0, 55.0, Region::Intersect).is_empty());
        assert_eq!(idx.brush(205.0, 5.0, 215.0, 15.0, Region::Intersect), vec![1]);
        // a lasso inside the donut's solid part, with no vertex of it inside
        let inner = [(210.0, 10.0), (230.0, 10.0), (220.0, 30.0)];
        assert_eq!(idx.lasso(&inner, Region::Intersect), vec![1]);
        // a concave lasso whose vertices all surround the segment's ends but
        // whose notch cuts the line: not contained
        let notch = [(-10.0, -10.0), (110.0, -10.0), (110.0, 110.0), (50.0, 40.0), (-10.0, 110.0)];
        assert!(idx.lasso(&notch, Region::Contain).is_empty());
        assert_eq!(idx.lasso(&notch, Region::Intersect), vec![0]);
    }
}
