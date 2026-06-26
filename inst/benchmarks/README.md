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

- **`scatter.R`** — a random scatterplot of N points, drawn end-to-end
  (build → draw → write PNG) with `grid` (`grid.points`) vs `vellum`
  (`points_grob`), at 8×6 in / 100 dpi. Measures total elapsed time for each and
  reports the speedup. The `grid` timing depends on the active PNG device
  (cairo/quartz/…).

Timings are wall-clock and machine/device dependent; treat them as relative, not
absolute.
