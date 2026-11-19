//! Repaint-boundary (FW4c) sub-raster cache: a process-lifetime memo of a
//! `cache = TRUE` viewport's rasterised subtree.

use super::*;

// --- repaint-boundary (FW4c) sub-raster cache -------------------------------
// Persistent (thread-local, process-lifetime) memo of a `cache = TRUE`
// viewport's rasterised subtree, keyed on the subtree content-identity token
// (`nid`, from R) plus everything else that determines the produced pixels given
// fixed subtree content: the boundary's resolved device transform, a fingerprint
// of its (rectangular) clip chain, the page size, and the dpi. Mirrors the glyph
// cache (font.rs). A captured layer is page-sized (position baked), so a moved
// boundary keys differently and re-renders, while an unchanged, unmoved boundary
// hits across renders — what makes highlight/animation partial redraw cheap.
#[derive(PartialEq, Eq, Hash, Clone)]
pub(super) struct SubKey {
    nid: u64,
    tx: [u32; 6],
    clip: u64,
    /// Fingerprint of the gpar the boundary *inherits* (not captured by `nid`,
    /// which only identifies the subtree's own content). Without it, two
    /// boundaries sharing every other field but differing in inherited style
    /// would collide and return stale pixels.
    gp: u64,
    w: u32,
    h: u32,
    dpi: u64,
}

thread_local! {
    static SUBRASTER_CACHE: RefCell<TwoGenCache<SubKey, Pixmap>> = RefCell::new(TwoGenCache::new(SUBRASTER_CAP));
    static SUBRASTER_STATS: RefCell<(i64, i64)> = const { RefCell::new((0, 0)) }; // (hits, misses)
}
/// Per-generation cap for the sub-raster cache; each entry is a page-sized RGBA
/// layer. Two-generation eviction keeps up to ~2x this resident (see `cache.rs`).
const SUBRASTER_CAP: usize = 32;

// Exact fingerprint of a rectangular clip chain, or `None` if the chain contains
// an arbitrary *path* clip. A path-clipped boundary is left uncached (rendered
// inline) rather than risk a fingerprint collision — path-clipped repaint
// boundaries are a rare edge and correctness beats the optimisation there.
fn rect_clip_fingerprint(shapes: &[ClipShape]) -> Option<u64> {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    for s in shapes {
        match s {
            ClipShape::Rect { w, h, transform } => {
                0u8.hash(&mut hasher);
                w.to_bits().hash(&mut hasher);
                h.to_bits().hash(&mut hasher);
                for f in [
                    transform.sx,
                    transform.ky,
                    transform.kx,
                    transform.sy,
                    transform.tx,
                    transform.ty,
                ] {
                    f.to_bits().hash(&mut hasher);
                }
            }
            ClipShape::Path { .. } => return None, // uncacheable boundary
        }
    }
    Some(hasher.finish())
}

pub(super) fn subraster_key(
    nid: f64,
    t: &Transform,
    clip: &[ClipShape],
    gp: u64,
    w: u32,
    h: u32,
    dpi: f64,
) -> Option<SubKey> {
    Some(SubKey {
        nid: nid.to_bits(),
        tx: [
            t.sx.to_bits(),
            t.ky.to_bits(),
            t.kx.to_bits(),
            t.sy.to_bits(),
            t.tx.to_bits(),
            t.ty.to_bits(),
        ],
        clip: rect_clip_fingerprint(clip)?,
        gp,
        w,
        h,
        dpi: dpi.to_bits(),
    })
}

pub(super) fn subraster_get(key: &SubKey) -> Option<Pixmap> {
    SUBRASTER_CACHE.with(|c| {
        let hit = c.borrow_mut().get(key);
        SUBRASTER_STATS.with(|s| {
            let mut st = s.borrow_mut();
            if hit.is_some() {
                st.0 += 1;
            } else {
                st.1 += 1;
            }
        });
        hit
    })
}

pub(super) fn subraster_put(key: SubKey, pm: Pixmap) {
    SUBRASTER_CACHE.with(|c| c.borrow_mut().insert(key, pm));
}

/// Empty the repaint-boundary sub-raster cache and reset its hit/miss counters.
pub fn clear_subraster_cache() {
    SUBRASTER_CACHE.with(|c| c.borrow_mut().clear());
    SUBRASTER_STATS.with(|s| *s.borrow_mut() = (0, 0));
}

/// `c(hits, misses, resident_entries)` for the sub-raster cache (tests/diagnostics).
pub fn subraster_stats() -> Vec<i64> {
    let (h, m) = SUBRASTER_STATS.with(|s| *s.borrow());
    let len = SUBRASTER_CACHE.with(|c| c.borrow().len()) as i64;
    vec![h, m, len]
}
