#!/usr/bin/env Rscript
# Benchmark: raster images. `raster_grob()` accepts anything `as.raster()` takes,
# and `.image_to_rgba()` converts it via `grDevices::col2rgb()` on a character
# vector -- one hex string parsed per pixel, in R. This script isolates that
# conversion from the actual draw so the cost of each is visible, and compares
# the input representations a caller might supply (character raster, numeric
# array, nativeRaster) against grid's `rasterGrob`.
#
# Run:  Rscript inst/benchmarks/image.R [px] [out_dir]
#   px       image side length in pixels (default 1000, i.e. a 1000x1000 image)
#   out_dir  where to write PNGs (default tempdir())

invisible(suppressMessages(loadNamespace("grid")))
invisible(suppressMessages(loadNamespace("vellum")))

args <- commandArgs(trailingOnly = TRUE)
px <- if (length(args) >= 1) as.integer(args[[1]]) else 1000L
out_dir <- if (length(args) >= 2) args[[2]] else tempdir()
width <- 8
height <- 6
dpi <- 100

bench <- function(label, expr) {
  t <- system.time(force(expr))[["elapsed"]]
  cat(sprintf("  %-34s %8.3f s\n", label, t))
  invisible(t)
}

set.seed(1)
# A numeric RGB array -- the form `as.raster()` and image readers (png::readPNG)
# produce, and the most common way a user supplies an image.
arr <- array(runif(px * px * 3L), dim = c(px, px, 3L))
ras <- grDevices::as.raster(arr) # character matrix of "#rrggbb"

cat(sprintf(
  "Image: %dx%d px (%s pixels) into a %dx%d in @ %d dpi page\n\n",
  px,
  px,
  format(px * px, big.mark = ",", scientific = FALSE),
  width,
  height,
  dpi
))

# --- 1. the conversion alone ------------------------------------------------
# `.image_to_rgba()` is internal; reach it through the namespace so the cost of
# the R-side conversion is visible separately from compile + raster.
to_rgba <- get(".image_to_rgba", envir = asNamespace("vellum"))

cat("1. Input conversion only (.image_to_rgba):\n")
t_arr <- bench("numeric array", to_rgba(arr))
t_ras <- bench("character raster", to_rgba(ras))
cat("\n")

# --- 2. grob construction ---------------------------------------------------
cat("2. raster_grob() construction (conversion happens here):\n")
t_grob <- bench("raster_grob(array)", vellum::raster_grob(arr))
cat("\n")

# --- 3. end to end vs grid --------------------------------------------------
cat("3. End to end (build -> draw -> write PNG):\n")
f_v <- file.path(out_dir, "image-vellum.png")
f_g <- file.path(out_dir, "image-grid.png")

draw_it <- function(img) {
  vellum::vl_clear_render_cache()
  s <- vellum::vl_scene(width, height, dpi = dpi, bg = "white") |>
    vellum::draw(vellum::raster_grob(img))
  vellum::render(s, f_v)
}
# Both input forms: a numeric array (what png::readPNG returns -- the common case)
# and an already-character raster. They differ by ~5x, all of it in the R-side
# conversion, so which one a benchmark feeds decides the headline number.
t_vellum <- bench("vellum (numeric array in)", draw_it(arr))
t_vellum_ras <- bench("vellum (character raster in)", draw_it(ras))

t_grid <- bench("grid", {
  grDevices::png(f_g, width = width * dpi, height = height * dpi, res = dpi)
  grid::grid.newpage()
  grid::grid.raster(arr)
  grDevices::dev.off()
})

cat(sprintf(
  "\n  conversion share of vellum end-to-end (array in): %.0f%%\n",
  100 * t_arr / max(t_vellum, 1e-9)
))
cat(sprintf(
  "  vs grid: array in %.2fx, raster in %.2fx  (>1 = vellum faster)\n",
  t_grid / max(t_vellum, 1e-9),
  t_grid / max(t_vellum_ras, 1e-9)
))
cat(sprintf("  wrote %s\n        %s\n", f_v, f_g))
