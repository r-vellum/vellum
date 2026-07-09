#!/usr/bin/env Rscript
# Benchmark: repaint boundaries (FW4c). A `vl_viewport(cache = TRUE)` subtree is
# rasterised once and reused on later renders when unchanged, so a partial redraw
# (highlight/hover: edit one element and re-render) re-rasterises only the changed
# subtree, not the whole scene.
#
# The scene is a heavy static background (N grobs) in a cached boundary, plus a
# light foreground marker in its own boundary. We edit the foreground and
# re-render M times, timing the loop with the background boundary cached
# (`cache = TRUE`) vs not (`cache = FALSE`).
#
# The background is chosen raster-heavy but compile-cheap (a dense point cloud in
# one batched call): FW4c caches the *rasterisation*, not the compile, so it pays
# when the cached subtree is costly to draw (dense clouds, gradients, images,
# masks) — not when it is many cheap-to-raster grobs (that cost is re-compile,
# which this cache does not remove).
#
# Run:  Rscript inst/benchmarks/repaint-cache.R [N] [M]
#   N  background point count (default 400000)
#   M  number of highlight edits to time (default 20)

invisible(suppressMessages(loadNamespace("vellum")))

args <- commandArgs(trailingOnly = TRUE)
n <- if (length(args) >= 1) as.numeric(args[[1]]) else 4e5
m <- if (length(args) >= 2) as.numeric(args[[2]]) else 20
width <- 8
height <- 6
dpi <- 100

bench <- function(label, expr) {
  t <- system.time(force(expr))[["elapsed"]]
  cat(sprintf("  %-30s %8.3f s\n", label, t))
  invisible(t)
}

# Raster-heavy static background (a dense point cloud, one batched call -> cheap
# compile, costly raster) in one boundary + a movable foreground dot in another.
# `cache` toggles whether the background is a cached repaint boundary.
build <- function(n, cache) {
  set.seed(1)
  bx <- runif(n)
  by <- runif(n)
  vellum::vl_scene(width, height, dpi = dpi, bg = "white") |>
    vellum::push(vellum::vl_viewport(cache = cache, name = "bg", xscale = c(0, 1), yscale = c(0, 1))) |>
    vellum::draw(vellum::points_grob(
      vellum::vl_unit(bx, "native"), vellum::vl_unit(by, "native"),
      size = vellum::vl_unit(1.5, "mm"), gp = vellum::vl_gpar(fill = "#3a86ff30", col = NA)
    )) |>
    vellum::pop() |>
    vellum::push(vellum::vl_viewport(cache = TRUE, name = "fg")) |>
    vellum::draw(vellum::circle_grob(
      x = 0.5, y = 0.5, r = 0.03,
      gp = vellum::vl_gpar(fill = "black", col = NA), name = "dot"
    )) |>
    vellum::pop()
}

# M highlight edits: recolour the foreground dot and re-render each time.
highlight_loop <- function(s, m, out) {
  cols <- grDevices::hcl.colors(m, "Reds")
  for (k in seq_len(m)) {
    s <- vellum::edit_node(s, "dot", gp = vellum::vl_gpar(fill = cols[k], col = NA))
    vellum::render(s, out)
  }
}

cat(sprintf("Repaint boundaries: %s-point static background, %d highlight edits (%dx%d @ %d dpi)\n\n",
            format(n, big.mark = ",", scientific = FALSE), m, width, height, dpi))

out <- file.path(tempdir(), "repaint.png")

vellum::vl_clear_render_cache()
s_off <- build(n, FALSE)
vellum::render(s_off, out) # warm fonts etc.
t_off <- bench("background NOT cached", highlight_loop(s_off, m, out))

vellum::vl_clear_render_cache()
s_on <- build(n, TRUE)
vellum::render(s_on, out) # warm: populate the background sub-raster
t_on <- bench("background cached (FW4c)", highlight_loop(s_on, m, out))

cat(sprintf("\n  speedup over %d edits: %.1fx\n", m, t_off / max(t_on, 1e-6)))
cat(sprintf("  per-edit: %.1f ms (cached) vs %.1f ms (uncached)\n",
            1000 * t_on / m, 1000 * t_off / m))
