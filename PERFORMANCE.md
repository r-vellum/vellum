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
| points, large marker (6 mm) | 3e5 | 1.71 | 2.55 | 0.67× | raster (big sprite blits) |
| points, medium marker (3 mm) | 3e5 | 1.75 | 0.97 | **1.8× ✓** | raster (sprite stamp) |
| polyline, self-intersecting | 1e5 | 3.73 | 1.35 | **2.8× ✓** (was 0.3×) | raster (per-segment stroke) |
| segments | 3e4 | 0.56 | 1.37 | 0.41× (was 0.2×) | raster (per-segment stroke overhead) |
| **datashade** | 1e7 | 9.04 | 0.25 | **36× ✓✓** | aggregate-then-shade (vs grid dots) |
| **text** | 5e3 | 0.03 | 1.87 | **0.02× ✗✗** | **compile (per-label shaping)** |
| viewports (faceting) | 2500 | 0.57 | 2.64 | 0.2× (was 0.003×) | build now O(n); per-op overhead |

vellum wins the dense-marker, line, and (with `datashade()`) big-data cases
(batched FFI + sprite stamping + per-segment strokes + one rasterize pass). The
remaining losses (text; large markers; segments; tiny-grob faceting) and their
status are tracked below.

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

### PERF-2 — O(1) scene builder (build) — ✅ **done**
`draw()`/`push()`/`pop()` now append in amortised **O(1)**. The builder is backed
by mutable "build nodes" (`.bnode`: an environment whose `kids` env is a hashed
dict keyed by append index — O(1) insert), kept on `scene@build`/`scene@open`. The
immutable `gtree` is materialised lazily (`.materialize`) only when needed — at
`render()`/`.scene_to_backend()` and at any query/edit (`node_names`/`get_node`/
`edit_node`). `edit_node` returns a materialised (immutable) scene and clears the
build env, so editing never mutates a shared builder. (`R/api.R`.)
Result: builder is a flat **~4.5 µs/draw regardless of N** (10k/20k/40k all 4.4–4.7
µs). Faceting 2500 panels: **182 s → 2.64 s** (~70×); now linear in grob count
(500/2500/10k → 0.5/2.6/11.8 s). The residual ~5× vs grid at this op count is
per-call grob construction (S7 + vctrs `unit`) and compile dispatch — not the
builder; a separate, lower-priority concern.

### PERF-3 — Cheap strokes (raster) — ✅ **done** (lines win; segments improved)
`stroke_lines()` (a new `RenderBackend` method) replaces the single combined
stroke for `Lines`/`Segments`. The raster backend takes a **per-segment fast
path** for grid's *default* line style — opaque, solid (no dash), round cap +
round join: each segment is stroked independently. When the colour is opaque,
drawing overlaps twice is idempotent, and a round cap covers the same disc as a
round join, so the result is **pixel-identical** to the combined stroke for that
style — but each tiny fill touches only its own few scanlines, avoiding the
`O(active_edges × height)` winding-fill of a self-overlapping / page-spanning
outline. Non-default styles (dashed, butt/square cap, translucent) fall back to
the combined stroke. (`src/rust/src/render.rs`, `scene.rs` Lines/Segments arms.)
Result: **self-intersecting polyline 1e5: 18.3 s → 1.35 s (0.3× → 2.8×, now
wins)**; **segments 3e4: 2.73 s → 1.37 s (0.2× → 0.41×)**. Monotone lines (already
winning) unaffected. Segments still trail grid (see "remaining" below): ~45 µs per
segment of per-call stroke setup vs grid's dedicated polyline rasterizer.

### PERF-4 — Marker threshold (raster) — ✅ **done** (measured; sprite kept)
The premise ("per-element fill wins for large markers") turned out **false** when
measured. For uniform solid markers the sprite blit beats both alternatives across
the whole radius range: at 6 mm (r≈24 px, 3e5 pts) sprite = 0.67×, per-element
circle fill = 0.51×, single combined-path fill of all discs = 0.25×. So the sprite
is kept for the entire uniform small-to-large range (`SPRITE_MAX_R` only guards
absurd per-blit areas). Medium markers (3 mm) already **win at 1.8×**. The residual
~0.67× at large markers is raster throughput — grid's device circle fill is hard to
beat per-pixel; the real lever for huge overplotted clouds is PERF-5. Net code: the
threshold is now a documented knob; no regression. (`src/rust/src/render.rs`
`draw_circles`.)

### PERF-5 — Aggregate-then-shade (datashader fold-in) — ✅ **done**
`datashade(x, y, …)` (R) bins points into a `width × height` grid in one O(N) Rust
pass (`rs_aggregate_2d`, `src/rust/src/aggregate.rs`), shades the grid (`eq_hist`
histogram-equalisation by default, plus `log`/`cbrt`/`linear`) through a colour
ramp, and returns a single `raster_grob` you draw like any other grob (drawn via
the existing `draw_image` path). Aggregation decouples cost from point count *and*
overplotting — the Rust tight loop is our analog of datashader's Numba kernel
(GPU/Dask out of scope). Result: **1e7 points: grid dots 9.04 s → datashade
0.25 s (~36×)**, and overplotting-honest. Optional per-point `weight` sums instead
of counting. (`R/datashade.R`, `inst/benchmarks/datashade.R`.)

### PERF-6 — Tiled parallel rasterization (optional)
tiny-skia is single-threaded; tile the page and rasterize tiles across cores with
`rayon` for raster-bound fills (large markers, big polygons, full-page gradients).
A new vendored dep and real complexity — revisit only if PERF-1..5 leave a
raster-bound gap that matters.

### PERF-6 — Tiled parallel rasterization (optional)
tiny-skia is single-threaded; tile the page and rasterize tiles across cores with
`rayon` for raster-bound fills (large markers, big polygons, full-page gradients).
A new vendored dep and real complexity — revisit only if the gaps below matter.

## Remaining improvements (what's left, by size)

After PERF-1..5, four gaps to grid remain. None is catastrophic; here is what each
would take.

**Major (real engineering, possible fidelity trade-offs):**

- **Text at high *distinct*-label counts** (~3–9× behind grid). Two costs: shaping
  goes through `textshaping` (R/HarfBuzz wrapper, slower than the device's internal
  C path), and the raster backend fills crisp **glyph outlines** rather than
  blitting cached glyph bitmaps. *Fix:* a sub-pixel **glyph-bitmap cache** (rasterize
  each (glyph, size, subpixel-phase) once, blit thereafter) — would close most of
  the raster half, but risks the font fidelity that is a core goal, so it needs a
  careful AA/hinting story. The shaping half needs caching shaped runs across
  identical (string, font) or a faster shaper. Biggest remaining user-visible gap.

- **Large markers** (~0.67× at 6 mm). Pure raster throughput: the sprite blit is
  already the best of the strategies tried, but grid's device circle fill writes
  fewer pixels per marker. *Fix options:* (a) SIMD/word-at-a-time sprite blit for
  the opaque no-clip case; (b) PERF-6 tiled parallel raster; (c) steer users to
  `datashade()` when the cloud is large enough that markers overplot anyway. Modest
  upside; only matters for many *large* markers (an unusual combination).

**Minor (mechanical, no fidelity risk):**

- **Segments** (~0.41×). The per-segment fast path fixed the asymptotics but pays
  ~per-call stroke-setup overhead (a `PathBuilder` + stroker per segment). *Fix:*
  reuse one `PathBuilder`/`Stroke` across the batch, or hand-roll a thin
  round-capped-quad rasterizer for the width≤~2 px case — bounded win, since grid's
  dedicated polyline rasterizer is genuinely fast here.

- **Tiny-grob faceting** (~0.2× at 2500 panels of trivial content). The builder is
  now O(n); the residual is per-grob **construction** (S7 object + vctrs `unit`
  records) and per-node `compile` dispatch on the R side, not drawing. *Fix:*
  lighter-weight unit construction (avoid a vctrs record per coordinate where a
  bare numeric + code would do), or a batched compile path for homogeneous
  children. Pure R-side overhead; scales fine, just a constant.

**Cross-cutting / smaller ideas (unchanged):**
- **Rect sprite/uniform fast path** for equal-size solid rects (geom_tile-like),
  mirroring circles — would lift the ~1.0× rects tie.
- **Render-result caching**: memoise the compiled backend `Scene`/`Pixmap` for
  repeated renders (resize, animation); the tree is immutable so a content hash
  keys it.
- **datashade line/area aggregation**: extend `rs_aggregate_2d` to rasterize line
  segments into the grid (Bresenham/​DDA) for the dense-timeseries case, mirroring
  datashader's line canvas.
- **Audit per-draw allocations** (clip-mask clones for deep clip trees).

## Reproduce
```sh
Rscript inst/benchmarks/scatter.R          # general 1e6 scatter
Rscript inst/benchmarks/points-cloud.R     # dense small-marker cloud (vellum win)
Rscript inst/benchmarks/lines.R            # self-intersecting polyline (PERF-3 win)
Rscript inst/benchmarks/datashade.R        # 1e7 aggregate-then-shade (PERF-5 win)
# the full cross-primitive probe used for the table above lives in this doc's
# history; re-run by adapting inst/benchmarks/*.R per aspect.
```

## Status
**PERF-1..5 are ✅ done.** Text batching (PERF-1) and the O(1) scene builder
(PERF-2) moved the most plots; per-segment strokes (PERF-3) turned the worst case
(self-intersecting lines) into a win; the marker threshold (PERF-4) was measured
and the sprite kept; `datashade()` (PERF-5) is the big-data lever (~36× at 1e7).
Remaining gaps and their cost are catalogued under *Remaining improvements* above;
PERF-6 (tiled parallel raster) stays optional, pursued only if those gaps bite.
