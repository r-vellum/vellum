#!/usr/bin/env Rscript
# Benchmark: a random scatterplot of N points, drawn end-to-end (build -> draw ->
# write PNG) with base `grid` vs `vellum`, timed.
#
# Run:  Rscript inst/benchmarks/scatter.R [N] [out_dir]
#   N        number of points (default 1e6)
#   out_dir  where to write the two PNGs (default tempdir())
#
# Notes:
#  - the grid time depends on the active PNG device (cairo/quartz/etc.).
#  - marker-size semantics differ slightly (grid `pch` size ~ glyph diameter;
#    vellum `points_grob` size = radius), so the two images aren't pixel-identical;
#    the comparison is of end-to-end time to draw N markers, not of fidelity.

# grid and vellum share many names (viewport/unit/gpar/push/pop), so qualify
# every call explicitly rather than relying on load order.
invisible(suppressMessages(loadNamespace("grid")))
invisible(suppressMessages(loadNamespace("vellum")))

args <- commandArgs(trailingOnly = TRUE)
n <- if (length(args) >= 1) as.numeric(args[[1]]) else 1e6
out_dir <- if (length(args) >= 2) args[[2]] else tempdir()
width <- 8
height <- 6
dpi <- 100

set.seed(1)
x <- runif(n)
y <- runif(n)
col <- "#3a86ff80" # semi-transparent blue (so overplotting is visible)

bench <- function(label, expr) {
  t <- system.time(force(expr))[["elapsed"]]
  cat(sprintf("  %-8s %8.3f s\n", label, t))
  t
}

cat(sprintf(
  "Scatter of %s points  (%dx%d in @ %d dpi)\n",
  format(n, big.mark = ",", scientific = FALSE), width, height, dpi
))

# --- grid (base PNG device) -------------------------------------------------
grid_png <- file.path(out_dir, "scatter-grid.png")
t_grid <- bench("grid", {
  grDevices::png(grid_png, width = width * dpi, height = height * dpi, res = dpi)
  grid::grid.newpage()
  grid::pushViewport(grid::viewport(xscale = c(0, 1), yscale = c(0, 1)))
  grid::grid.points(x, y, pch = 16, size = grid::unit(1, "mm"), gp = grid::gpar(col = col))
  grid::popViewport()
  grDevices::dev.off()
})

# --- vellum -----------------------------------------------------------------
vellum_png <- file.path(out_dir, "scatter-vellum.png")
t_vellum <- bench("vellum", {
  s <- vellum::vl_scene(width, height, dpi = dpi, bg = "white") |>
    vellum::push(vellum::viewport(xscale = c(0, 1), yscale = c(0, 1))) |>
    vellum::draw(vellum::points_grob(
      vellum::unit(x, "native"), vellum::unit(y, "native"),
      size = vellum::unit(1, "mm"), gp = vellum::gpar(fill = col, col = NA)
    )) |>
    vellum::pop()
  vellum::render(s, vellum_png)
})

cat(sprintf("\n  speedup (grid / vellum): %.1fx\n", t_grid / t_vellum))
cat(sprintf("  wrote %s\n        %s\n", grid_png, vellum_png))
