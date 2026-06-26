# vellum benchmarks

Standalone scripts comparing `vellum` against base `grid` (and, over time, other
backends). Each prints wall-clock timings and writes its output(s) so results can
be eyeballed.

Run a benchmark with `Rscript` against an installed `vellum`:

```sh
Rscript inst/benchmarks/scatter.R            # 1,000,000 points (default)
Rscript inst/benchmarks/scatter.R 100000     # smaller N
Rscript inst/benchmarks/scatter.R 1e6 /tmp   # choose N and output dir
```

## Benchmarks

- **`scatter.R`** — a random scatterplot of N points (default 1e6), drawn
  end-to-end (build → draw → write PNG) with `grid` (`grid.points`) vs `vellum`
  (`points_grob`), at 8×6 in / 100 dpi. A general head-to-head.

- **`points-cloud.R`** — a dense cloud of N *small, semi-transparent* points
  (default 5e6) with **matched marker sizes** — the big-data scatter regime where
  vellum's batched compile + marker sprite-stamping clearly win. On the author's
  machine: ~**2.7–2.9× faster** than grid across 1e6–5e6 points (e.g. 5M: grid
  ~7.5 s, vellum ~2.6 s). (Note: vellum's edge here is *small* markers — for large
  markers the per-blit cost erodes it.)

- **`lines.R`** — a long *self-intersecting* polyline (default 1e5 vertices). The
  worst case for a naive stroke-to-fill backend; vellum's per-segment stroke fast
  path makes it O(n). On the author's machine ~**2.8× faster** than grid (1e5).

- **`datashade.R`** — an overplotted scatter (default 1e7 points) drawn by
  aggregate-then-shade ([`datashade()`]) vs grid drawing tiny dots. Aggregation
  decouples cost from point count and overplotting; on the author's machine
  ~**35× faster** than grid at 1e7, and overplotting-honest.

The `grid` timing depends on the active PNG device (cairo/quartz/…).

Timings are wall-clock and machine/device dependent; treat them as relative, not
absolute.
