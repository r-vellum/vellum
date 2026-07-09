#!/usr/bin/env Rscript
# Benchmark: datashader-style aggregate-then-shade vs drawing N markers. For
# heavily overplotted data, binning the points into a canvas-sized grid in one
# O(N) Rust pass and colour-mapping the grid is far cheaper than emitting N
# markers — and it is overplotting-honest (the grid records true density). The
# baseline is grid drawing the same points as tiny dots.
#
# Run:  Rscript inst/benchmarks/datashade.R [N] [out_dir]
#   N        number of points (default 1e7)
#   out_dir  where to write the PNGs (default tempdir())

invisible(suppressMessages(loadNamespace("grid")))
invisible(suppressMessages(loadNamespace("vellum")))

args <- commandArgs(trailingOnly = TRUE)
n <- if (length(args) >= 1) as.numeric(args[[1]]) else 1e7
out_dir <- if (length(args) >= 2) args[[2]] else tempdir()
width <- 8
height <- 6
dpi <- 100

set.seed(1)
x <- rnorm(n)
y <- x * 0.5 + rnorm(n)

bench <- function(label, expr) {
  t <- system.time(force(expr))[["elapsed"]]
  cat(sprintf("  %-18s %8.3f s\n", label, t))
  t
}

cat(sprintf(
  "Overplotted scatter: %s points  (%dx%d in @ %d dpi)\n",
  format(n, big.mark = ",", scientific = FALSE), width, height, dpi
))

grid_png <- file.path(out_dir, "datashade-grid.png")
t_grid <- bench("grid.points", {
  grDevices::png(grid_png, width = width * dpi, height = height * dpi, res = dpi)
  grid::grid.points(x, y, pch = ".", gp = grid::gpar(col = grDevices::rgb(0, 0, 0, 0.2)))
  grDevices::dev.off()
})

vellum_png <- file.path(out_dir, "datashade-vellum.png")
t_vellum <- bench("vellum.datashade", {
  g <- vellum::datashade(x, y, width = width * dpi, height = height * dpi, how = "eq_hist")
  s <- vellum::vl_scene(width, height, dpi = dpi, bg = "white") |>
    vellum::push(vellum::vl_viewport(xscale = range(x), yscale = range(y))) |>
    vellum::draw(g)
  vellum::render(s, vellum_png)
})

cat(sprintf("\n  speedup (grid / vellum): %.1fx\n", t_grid / t_vellum))
cat(sprintf("  wrote %s\n        %s\n", grid_png, vellum_png))
