#!/usr/bin/env Rscript
# Benchmark: a long self-intersecting polyline — the worst case for a naive
# stroke-to-fill backend, because the stroked outline overlaps itself and a
# winding fill then pays O(active_edges x height). vellum's per-segment stroke
# (for the opaque, solid, round-cap/join default) sidesteps that: each tiny
# segment fill touches only its own scanlines, so cost is O(n).
#
# Run:  Rscript inst/benchmarks/lines.R [N] [out_dir]
#   N        number of vertices (default 1e5)
#   out_dir  where to write the PNGs (default tempdir())

invisible(suppressMessages(loadNamespace("grid")))
invisible(suppressMessages(loadNamespace("vellum")))

args <- commandArgs(trailingOnly = TRUE)
n <- if (length(args) >= 1) as.numeric(args[[1]]) else 1e5
out_dir <- if (length(args) >= 2) args[[2]] else tempdir()
width <- 8
height <- 6
dpi <- 100

set.seed(1)
t <- seq(0, 40 * pi, length.out = n)
x <- 0.5 + 0.45 * cos(t) * runif(n)
y <- 0.5 + 0.45 * sin(t) * runif(n)

bench <- function(label, expr) {
  el <- system.time(force(expr))[["elapsed"]]
  cat(sprintf("  %-8s %8.3f s\n", label, el))
  el
}

cat(sprintf(
  "Self-intersecting polyline: %s vertices  (%dx%d in @ %d dpi)\n",
  format(n, big.mark = ",", scientific = FALSE), width, height, dpi
))

grid_png <- file.path(out_dir, "lines-grid.png")
t_grid <- bench("grid", {
  grDevices::png(grid_png, width = width * dpi, height = height * dpi, res = dpi)
  grid::grid.lines(x, y, gp = grid::gpar(col = "darkred"))
  grDevices::dev.off()
})

vellum_png <- file.path(out_dir, "lines-vellum.png")
t_vellum <- bench("vellum", {
  s <- vellum::vl_scene(width, height, dpi = dpi, bg = "white") |>
    vellum::draw(vellum::lines_grob(
      vellum::unit(x, "npc"), vellum::unit(y, "npc"),
      gp = vellum::gpar(col = "darkred")
    ))
  vellum::render(s, vellum_png)
})

cat(sprintf("\n  speedup (grid / vellum): %.1fx\n", t_grid / t_vellum))
cat(sprintf("  wrote %s\n        %s\n", grid_png, vellum_png))
