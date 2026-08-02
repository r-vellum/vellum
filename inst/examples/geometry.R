# A worked vellum example: path geometry.
#
#   * Resolution-aware simplification -- automatic, invisible, and worth 2-3x on
#     dense paths. Controlled by `options(vellum.simplify)`.
#   * `stroke_to_path()` -- turn a stroke into a fillable outline, so a line can
#     carry a gradient, or be sent to a cutting plotter.
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

ribbon <- stroke_to_path(zig, width = 6, height = 2.6)

scene <- vl_scene(6, 2.6, dpi = 150, bg = "white") |>
  # The same geometry, now filled with a gradient across the ribbon it traced.
  draw(S7::set_props(
    ribbon,
    gp = vl_gpar(
      fill = linear_gradient(c("#F97316", "#FACC15", "#22C55E")),
      col = "grey25",
      lwd = 0.6
    )
  )) |>
  draw(text_grob(
    "stroke_to_path(): a line you can fill",
    x = 0.5,
    y = 0.07,
    gp = vl_gpar(fontsize = 11, col = "grey35")
  ))

render(scene, out)
cat(sprintf("wrote %s\n", out))

cat(sprintf(
  "\nThe outline has %d points in %d sub-path(s).\n",
  length(vctrs::field(ribbon@x, "value")),
  length(ribbon@nper)
))
cat("It is in absolute mm: an outline is a shape baked at one size, not a\n")
cat("stroke that rescales with the page. That is inherent, not a limitation.\n")
