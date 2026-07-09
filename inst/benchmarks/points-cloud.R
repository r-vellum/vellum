#!/usr/bin/env Rscript
# Benchmark: a dense cloud of N small, semi-transparent points — the big-data
# scatter regime where vellum's batched compile + marker sprite-stamping clearly
# beat grid's per-marker device path. Drawn end-to-end (build -> draw -> write
# PNG) and timed.
#
# Run:  Rscript inst/benchmarks/points-cloud.R [N] [out_dir]
#   N        number of points (default 5e6)
#   out_dir  where to write the two PNGs (default tempdir())
#
# Marker sizes are matched: grid `pch` size 1 mm ~= a 1 mm-diameter dot, so vellum
# (whose size is the radius) uses 0.5 mm. The grid time depends on the active PNG
# device (cairo/quartz/…).

invisible(suppressMessages(loadNamespace("grid")))
invisible(suppressMessages(loadNamespace("vellum")))

args <- commandArgs(trailingOnly = TRUE)
n <- if (length(args) >= 1) as.numeric(args[[1]]) else 5e6
out_dir <- if (length(args) >= 2) args[[2]] else tempdir()
width <- 8
height <- 6
dpi <- 100

set.seed(1)
x <- runif(n)
y <- runif(n)
col <- "#3a86ff60" # semi-transparent blue

bench <- function(label, expr) {
  t <- system.time(force(expr))[["elapsed"]]
  cat(sprintf("  %-8s %8.3f s\n", label, t))
  t
}

cat(sprintf(
  "Dense point cloud: %s points  (%dx%d in @ %d dpi)\n",
  format(n, big.mark = ",", scientific = FALSE), width, height, dpi
))

grid_png <- file.path(out_dir, "points-cloud-grid.png")
t_grid <- bench("grid", {
  grDevices::png(grid_png, width = width * dpi, height = height * dpi, res = dpi)
  grid::grid.points(x, y, pch = 16, size = grid::unit(1, "mm"), gp = grid::gpar(col = col))
  grDevices::dev.off()
})

vellum_png <- file.path(out_dir, "points-cloud-vellum.png")
t_vellum <- bench("vellum", {
  s <- vellum::vl_scene(width, height, dpi = dpi, bg = "white") |>
    vellum::draw(vellum::points_grob(
      vellum::vl_unit(x, "npc"), vellum::vl_unit(y, "npc"),
      size = vellum::vl_unit(0.5, "mm"), gp = vellum::vl_gpar(fill = col, col = NA)
    ))
  vellum::render(s, vellum_png)
})

cat(sprintf("\n  speedup (grid / vellum): %.1fx\n", t_grid / t_vellum))
cat(sprintf("  wrote %s\n        %s\n", grid_png, vellum_png))
