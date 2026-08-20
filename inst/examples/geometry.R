# A worked vellum example: path geometry.
#
#   * Resolution-aware simplification -- automatic, invisible, and worth 2-3x on
#     dense paths. Controlled by `options(vellum.simplify)`.
#   * `stroke_to_path()` -- turn a stroke into a fillable outline, so a line can
#     carry a gradient, or be sent to a cutting plotter.
#   * `stroke_to_path(lwd_profile =)` -- a width that varies *along* the line: a
#     taper, a swell, a pressure envelope. Per-segment `lwd` steps and shows its
#     joins; this is one continuous outline.
#
# Run with:  Rscript inst/examples/geometry.R  [output.png|.svg|.pdf]

library(vellum)

out <- commandArgs(trailingOnly = TRUE)
out <- if (length(out)) out[[1]] else "geometry.png"

# --- simplification ----------------------------------------------------------
# A dense path carries far more vertices than the canvas has pixels to tell
# apart. Simplifying at render resolution drops the ones that cannot change a
# pixel -- which only the renderer is in a position to know.
set.seed(2)
n <- 40000
th <- seq(0, 2 * pi, length.out = n)
r <- 0.4 + 0.03 * sin(7 * th) + cumsum(rnorm(n, 0, 0.4 / sqrt(n)))
coast <- function() {
  vl_scene(5, 5, dpi = 100) |>
    draw(polygon_grob(
      0.5 + r * cos(th),
      0.5 + r * sin(th),
      gp = vl_gpar(fill = "#BBD8B3", col = "grey30")
    ))
}
size <- function(tol) {
  withr::with_options(list(vellum.simplify = tol), {
    vl_clear_render_cache()
    nchar(scene_svg(coast()))
  })
}
cat(sprintf("A %s-vertex coastline:\n", format(n, big.mark = ",")))
cat(sprintf(
  "  SVG with simplification off : %s bytes\n",
  format(size(0), big.mark = ",")
))
cat(sprintf(
  "  SVG at the 0.1 px default   : %s bytes (%.0f%% smaller)\n",
  format(size(0.1), big.mark = ","),
  100 * (1 - size(0.1) / size(0))
))
cat(
  "  Set options(vellum.simplify = 0) to disable, or raise it to trade more.\n"
)
cat("  Paths under 1000 points are never touched.\n\n")

# --- stroke_to_path ----------------------------------------------------------
# A stroke is a colour along a path; an outline is a region with an interior.
# Only the second can be filled.
zig <- lines_grob(
  c(0.08, 0.3, 0.52, 0.74, 0.94),
  c(0.30, 0.78, 0.28, 0.76, 0.34),
  gp = vl_gpar(col = "steelblue", lwd = 16)
)

ribbon <- stroke_to_path(zig, width = 6, height = 4.2)

# The same shape in three horizontal bands, so the profiles sit side by side.
zig_at <- function(lo, hi) {
  y <- c(lo, hi, lo, hi, lo) + (hi - lo) * 0.15
  lines_grob(
    c(0.08, 0.3, 0.52, 0.74, 0.94),
    y,
    gp = vl_gpar(col = "steelblue", lwd = 16)
  )
}

# --- variable width ----------------------------------------------------------
# The comparison is the point: same polyline, same lwd, three width profiles.
# `lwd_profile` multiplies `lwd`, so c(1, 0) tapers to nothing and c(0.15, 1,
# 0.15) swells in the middle. A zero is a legal width, not an error.
taper <- stroke_to_path(
  zig_at(0.42, 0.60),
  width = 6,
  height = 4.2,
  lwd_profile = c(1, 0)
)
leaf <- stroke_to_path(
  zig_at(0.12, 0.30),
  width = 6,
  height = 4.2,
  lwd_profile = c(0.15, 1, 0.15)
)

# The bands come from the polylines' own coordinates, not from viewports: an
# outline is absolute mm baked at one page size, so nesting it in a shorter
# viewport would offset it rather than scale it -- which is the closing note of
# this script, demonstrated the hard way.
band <- function(scene, grob, label, y) {
  scene |>
    draw(grob) |>
    draw(text_grob(
      label,
      x = 0.5,
      y = y,
      gp = vl_gpar(fontsize = 10, col = "grey35")
    ))
}

top <- stroke_to_path(zig_at(0.72, 0.90), width = 6, height = 4.2)

scene <- vl_scene(6, 4.2, dpi = 150, bg = "white")
scene <- band(
  scene,
  # The same geometry, now filled with a gradient across the ribbon it traced.
  S7::set_props(
    top,
    gp = vl_gpar(
      fill = linear_gradient(c("#F97316", "#FACC15", "#22C55E")),
      col = "grey25",
      lwd = 0.6
    )
  ),
  "constant width -- a line you can fill",
  0.66
)
scene <- band(
  scene,
  S7::set_props(taper, gp = vl_gpar(fill = "#3B6EA5", col = NA)),
  "lwd_profile = c(1, 0) -- tapered to a point",
  0.36
)
scene <- band(
  scene,
  S7::set_props(leaf, gp = vl_gpar(fill = "#1B7837", col = NA)),
  "lwd_profile = c(0.15, 1, 0.15) -- a leaf",
  0.06
)

render(scene, out)
cat(sprintf("wrote %s\n", out))

cat(sprintf(
  "\nThe outline has %d points in %d sub-path(s); the tapered one %d in %d.\n",
  length(vctrs::field(ribbon@x, "value")),
  length(ribbon@nper),
  length(vctrs::field(taper@x, "value")),
  length(taper@nper)
))
cat("It is in absolute mm: an outline is a shape baked at one size, not a\n")
cat("stroke that rescales with the page. That is inherent, not a limitation.\n")
