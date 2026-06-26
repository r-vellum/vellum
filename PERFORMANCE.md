# vellum performance

Goal: **be at least as fast as base `grid` in every drawing aspect**, and
decisively faster where vellum's batched-Rust architecture allows. This file is a
living record of measurements, root causes, and the speed-up plan. Benchmarks live
in `inst/benchmarks/`.

## How these numbers were taken

- **grid**: draw to the default PNG device (`grDevices::png`, cairo/quartz), timed
  end-to-end (open device → draw → `dev.off`).
- **vellum**: `render()` to PNG, split into **build** (construct the `vl_scene`
  value), **compile** (`.scene_to_backend`, the R→Rust replay), and **raster**
  (rasterize + write).
- 8×6 in @ 100 dpi; one run each; wall-clock; one laptop. Treat ratios as
  indicative, not absolute. `ratio = grid / vellum` (>1 = vellum faster).

## Findings (current state)

| aspect | N | grid (s) | vellum (s) | ratio | vellum bottleneck |
|---|---:|---:|---:|---:|---|
| points, small marker | 1e6 | 1.39 | 0.52 | **2.7×** ✓ | raster |
| circles, filled | 1e5 | 0.20 | 0.06 | **3.3×** ✓ | raster |
| polyline, monotone | 5e5 | 0.94 | 0.23 | **4.1×** ✓ | raster |
| raster image | 1e6 px | 0.05 | 0.04 | **1.3×** ✓ | build (RGBA encode) |
| rects, solid | 2e5 | 0.21 | 0.22 | ~1.0× | raster (per-elem path) |
| points, large marker (6 mm) | 3e5 | 0.52 | 0.84 | 0.6× ✗ | raster (big sprite blits) |
| polyline, self-intersecting | 1e5 | 5.80 | 18.3 | 0.3× ✗ | raster (tiny-skia stroke→fill) |
| segments | 3e4 | 0.62 | 2.73 | 0.2× ✗ | raster (stroke of many sub-paths) |
| **text** | 5e3 | 0.03 | 1.87 | **0.02× ✗✗** | **compile (per-label shaping)** |
| viewports (faceting) | 2500 | 0.60 | 182 | 0.003× ✗✗ | **build (O(n²) scene builder)** |

vellum already wins the dense-marker and line cases (batched FFI + sprite
stamping + one rasterize pass). The losses cluster in four root causes below.

## Root causes

1. **Text is per-label (compile-bound).** `compile(grob_text)` loops over labels,
   calling `textshaping::shape_text` **once per label** and `scene$text` once per
   label. Measured: 1000 labels ≈ 0.36 s of shaping. But `shape_text` is
   *vectorised* — shaping all 5000 labels in **one** call is **10× faster**
   (1.46 s → 0.14 s) and returns per-string metrics + all glyph runs; repeated
   labels shape in ~0 s. Today every text-heavy plot (axis ticks, labels, facets)
   pays the per-label tax. *Biggest, clearest fix.*

2. **The R scene builder is O(n²).** `draw()`/`push()` do
   `.modify_at(root, focus, \(nd) nd@children <- c(nd@children, list(x)))`, and
   `c(children, list(x))` copies the whole children vector on every append → O(n²)
   over n grobs. 2500 panels = 182 s (vs grid 0.6 s); also hits any plot built
   from many grobs (faceting, many polygons, per-element annotations).

3. **Stroke of many / self-intersecting paths is superlinear.** `segments` builds
   one path of N disjoint sub-paths and strokes it; a self-intersecting polyline
   strokes to a self-overlapping outline. tiny-skia converts a stroke to a filled
   outline and scanline-fills it — the fill cost explodes with edge/overlap count.
   grid draws lines/segments as device polylines (effectively hairlines), which is
   far cheaper. (Monotone, non-overlapping lines are fine — vellum wins those.)

4. **Large markers: sprite blits cost more than device fills.** The sprite fast
   path stamps a cached AA marble per point; for big markers each blit composites
   many pixels, and grid's device circle fill wins. The win is *small* markers.

Secondary: **rects** only tie — each element builds a `tiny_skia::Path` and fills
it (no sprite reuse, since rects vary in size). Acceptable but improvable.

## Speed-up plan (prioritised)

Ordered by impact × breadth. Each is independently shippable + benchmark-gated
(must not regress the wins; must reach ≥ grid on its target aspect).

### PERF-1 — Batched text (compile) — ✅ **done**
`compile(grob_text)` now shapes **all** labels in one `textshaping::shape_text`
call (repeats shaped once — `unique()`), flattens the glyphs, and emits them in
**one** FFI via a new `Scene::texts()` that builds one text node per label in
Rust. (`R/text.R` `.draw_text_batch`, `R/api.R`, `src/rust/src/scene.rs`.)
Result (5e3 labels): **1.87 s → 0.13 s repeated / 0.50 s distinct** (≈4–14×); at
realistic counts (≤500 labels) text is now tens of ms (100 repeated ≈ grid).
**Residual gap to grid** (still ~3–9× at high *distinct*-label counts): shaping
goes through `textshaping` (R/HarfBuzz wrapper, slower than the device's C path)
and vellum fills crisp **glyph outlines** rather than blitting cached glyph
bitmaps. A sub-pixel glyph-bitmap cache would close the raster part but risks the
font fidelity that is a core goal — deliberately *not* done; left as a possible
future PERF-1b if profiling of real plots demands it.

### PERF-2 — O(1) scene builder (build) — *highest priority*
Make `draw()`/`push()`/`pop()` append in amortised O(1) instead of copying the
children vector each time. Options: (a) back the builder with a mutable
accumulator (an environment-held list per open node) and materialise the immutable
`gtree` once at `render()`; (b) keep immutability but store children in a
structure with O(1) append (e.g. a growable list / pairlist reversed at the end).
Target: 2500 panels from 182 s → < 1 s; linear in grob count. Files: `R/api.R`
(`vl_scene`/`push`/`draw`/`pop`/`.modify_at`, builder internals).

### PERF-3 — Cheap strokes (raster)
Get line/segment stroking to grid-class. Investigate, in order: (a) a **hairline
fast path** — when the device stroke width ≤ ~1 px, use tiny-skia's hairline
stroker (no outline fill) instead of stroke→fill; (b) draw `segments`/multi-group
lines as many cheap sub-strokes rather than one giant filled outline, or chunk the
fill; (c) for very dense/​overlapping line data, **line aggregation** (see PERF-5).
Target: segments and self-intersecting polylines ≥ grid. Files: `src/rust/src/render.rs`
(stroke path), maybe `scene.rs` (segments arm).

### PERF-4 — Marker threshold tuning (raster)
Pick sprite-stamp vs per-element fill by *marker pixel size* (sprite wins small,
fill wins large), and reuse the marker sprite across a batch. Restores ≥ grid for
large markers without losing the small-marker win. Files: `src/rust/src/render.rs`
(`draw_circles`).

### PERF-5 — Aggregate-then-shade (datashader fold-in) — *the big-data lever*
For data beyond per-glyph practicality (overplotted, ≫1e6), the win is not "draw
markers faster" but **don't draw markers at all**: bin points (and lines) into a
canvas-sized aggregate grid in one O(N) Rust pass, then colormap the grid to a
raster (embedded via P4's `draw_image`). This is what makes datashader fast —
aggregation decouples cost from point count *and* overplotting; the Rust tight
loop is our analog of its Numba kernel (GPU/Dask out of scope). It beats *both*
grid and per-marker vellum for huge scatter/line/heatmap data, and is
overplotting-honest. Bring the perceptual colormapping with it (histogram
equalization `eq_hist`, log, percentile clamp) so dense structure is visible.
(Design already sketched in DESIGN §11.) Likely lives in a `datashade()`-style
helper / future stat layer, not the core primitives. Larger, higher-level work —
sequence after PERF-1..4.

### PERF-6 — Tiled parallel rasterization (optional)
tiny-skia is single-threaded; tile the page and rasterize tiles across cores with
`rayon` for raster-bound fills (large markers, big polygons, full-page gradients).
A new vendored dep and real complexity — revisit only if PERF-1..5 leave a
raster-bound gap that matters.

## Cross-cutting / smaller ideas
- **Rect sprite/uniform fast path** for equal-size solid rects (geom_tile-like),
  mirroring circles.
- **Render-result caching**: memoise the compiled backend `Scene`/`Pixmap` for
  repeated renders (resize, animation); the tree is immutable so a content hash
  keys it.
- **Avoid the redundant transparent page-fill** already done; audit other
  per-draw allocations (clip-mask clones for deep clip trees).
- **Lower-precision measure dpi** is already used for grobwidth; keep measurement
  paths cheap.

## Reproduce
```sh
Rscript inst/benchmarks/scatter.R          # general 1e6 scatter
Rscript inst/benchmarks/points-cloud.R     # dense small-marker cloud (vellum win)
# the full cross-primitive probe used for the table above lives in this doc's
# history; re-run by adapting inst/benchmarks/*.R per aspect.
```

## Status
Findings captured (this pass). Implementation not started — PERF-1 (text) and
PERF-2 (builder) are the two that move the most plots and should go first.
