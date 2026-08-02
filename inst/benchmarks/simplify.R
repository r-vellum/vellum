#!/usr/bin/env Rscript
# Benchmark: resolution-aware path simplification.
#
# A dense path -- a coastline, a long time series -- carries far more vertices
# than the canvas has pixels to distinguish. Simplifying at RENDER RESOLUTION,
# which only the renderer knows, drops the ones that cannot change a pixel.
#
# Controlled by `options(vellum.simplify)`: a Douglas-Peucker tolerance in device
# pixels, default 0.1, `0` to disable. It engages only above 1000 points per
# sub-path, so ordinary shapes are untouched and byte-identical.
#
# Run:  Rscript inst/benchmarks/simplify.R [n] [out_dir]

invisible(suppressMessages(loadNamespace("vellum")))

args <- commandArgs(trailingOnly = TRUE)
n <- if (length(args) >= 1) as.numeric(args[[1]]) else 50000
out_dir <- if (length(args) >= 2) args[[2]] else tempdir()

med <- function(f, reps = 5) {
  stats::median(replicate(reps, {
    vellum::vl_clear_render_cache()
    system.time(f())[["elapsed"]]
  }))
}

report <- function(label, mk) {
  with_tol <- function(tol, f) {
    withr::with_options(list(vellum.simplify = tol), f())
  }
  t_off <- with_tol(0, function() {
    med(function() vellum::render(mk(), file.path(out_dir, "s.png")))
  })
  t_on <- with_tol(0.1, function() {
    med(function() vellum::render(mk(), file.path(out_dir, "s.png")))
  })
  svg_off <- with_tol(0, function() nchar(vellum::scene_svg(mk())))
  svg_on <- with_tol(0.1, function() nchar(vellum::scene_svg(mk())))
  cat(sprintf(
    "  %-24s render %6.3f -> %6.3f s (%4.2fx)   svg %8s -> %8s (%2.0f%% smaller)\n",
    label,
    t_off,
    t_on,
    t_off / max(t_on, 1e-9),
    format(svg_off, big.mark = ","),
    format(svg_on, big.mark = ","),
    100 * (1 - svg_on / svg_off)
  ))
}

cat(sprintf(
  "Path simplification at %s vertices (tolerance 0.1 device px)\n\n",
  format(n, big.mark = ",", scientific = FALSE)
))

set.seed(2)
th <- seq(0, 2 * pi, length.out = n)
r <- 0.4 + 0.03 * sin(7 * th) + cumsum(stats::rnorm(n, 0, 0.4 / sqrt(n)))
report("coastline (polygon)", function() {
  vellum::vl_scene(6, 6, dpi = 100) |>
    vellum::draw(vellum::polygon_grob(
      0.5 + r * cos(th),
      0.5 + r * sin(th),
      gp = vellum::vl_gpar(fill = "#BBD8B3", col = "grey30")
    ))
})

tt <- seq(0, 1, length.out = n)
yy <- 0.5 + 0.3 * sin(60 * tt) * exp(-2 * tt) + stats::rnorm(n, 0, 0.004)
report("time series (polyline)", function() {
  vellum::vl_scene(8, 3, dpi = 100) |>
    vellum::draw(vellum::lines_grob(
      tt,
      yy,
      gp = vellum::vl_gpar(col = "steelblue")
    ))
})

# A shape below the threshold must be untouched, byte for byte.
small <- function() {
  vellum::vl_scene(2, 2, dpi = 100) |>
    vellum::draw(vellum::polygon_grob(
      c(.1, .9, .5),
      c(.1, .1, .9),
      gp = vellum::vl_gpar(fill = "tomato")
    ))
}
a <- withr::with_options(list(vellum.simplify = 0), {
  vellum::vl_clear_render_cache()
  vellum::scene_svg(small())
})
b <- withr::with_options(list(vellum.simplify = 0.1), {
  vellum::vl_clear_render_cache()
  vellum::scene_svg(small())
})
cat(sprintf(
  "\n  a 3-point polygon is byte-identical either way: %s\n",
  identical(a, b)
))
