#!/usr/bin/env Rscript
# Benchmark: many short, disjoint line segments (the `segments` aspect). Each
# segment is stroked independently on the raster backend's per-segment fast path
# (opaque, solid, round cap/join). grid draws these through its dedicated device
# polyline rasterizer, which is hard to beat; vellum's residual cost is per-call
# stroke setup (a fresh `PathStroker` per segment). PERF-8 hoists one stroker
# across the whole batch.
#
# Run:  Rscript inst/benchmarks/segments.R [N] [out_dir]
#   N        number of segments (default 3e4)
#   out_dir  where to write the PNGs (default tempdir())

invisible(suppressMessages(loadNamespace("grid")))
invisible(suppressMessages(loadNamespace("vellum")))

args <- commandArgs(trailingOnly = TRUE)
n <- if (length(args) >= 1) as.numeric(args[[1]]) else 3e4
out_dir <- if (length(args) >= 2) args[[2]] else tempdir()
width <- 8
height <- 6
dpi <- 100

set.seed(1)
x0 <- runif(n)
y0 <- runif(n)
# Short segments so the ink (and per-segment fill area) stays modest; the cost
# under test is per-segment setup, not fill area.
x1 <- x0 + rnorm(n, 0, 0.02)
y1 <- y0 + rnorm(n, 0, 0.02)

bench <- function(label, expr) {
  el <- system.time(force(expr))[["elapsed"]]
  cat(sprintf("  %-8s %8.3f s\n", label, el))
  el
}

cat(sprintf(
  "Segments: %s segments  (%dx%d in @ %d dpi)\n",
  format(n, big.mark = ",", scientific = FALSE), width, height, dpi
))

grid_png <- file.path(out_dir, "segments-grid.png")
t_grid <- bench("grid", {
  grDevices::png(grid_png, width = width * dpi, height = height * dpi, res = dpi)
  grid::grid.segments(x0, y0, x1, y1, gp = grid::gpar(col = "darkred"))
  grDevices::dev.off()
})

vellum_png <- file.path(out_dir, "segments-vellum.png")
t_vellum <- bench("vellum", {
  s <- vellum::vl_scene(width, height, dpi = dpi, bg = "white") |>
    vellum::draw(vellum::segments_grob(
      vellum::vl_unit(x0, "npc"), vellum::vl_unit(y0, "npc"),
      vellum::vl_unit(x1, "npc"), vellum::vl_unit(y1, "npc"),
      gp = vellum::vl_gpar(col = "darkred")
    ))
  vellum::render(s, vellum_png)
})

cat(sprintf("\n  speedup (grid / vellum): %.2fx\n", t_grid / t_vellum))
cat(sprintf("  wrote %s\n        %s\n", grid_png, vellum_png))
