# A worked vellum example: gradient strokes and dash phase.
#
#   * `vl_gpar(col = linear_gradient(...))` -- stroke WITH a gradient. The same
#     paint model as `fill`, applied to the stroked region instead of the
#     enclosed one, on all three backends.
#   * `vl_gpar(dash_phase = )` -- how far into the dash pattern a line starts,
#     in multiples of `lwd`. Aligns dashes across strokes; animate it for
#     marching ants.
#
# Run with:  Rscript inst/examples/strokes-paint.R  [output.png|.svg|.pdf]

library(vellum)

out <- commandArgs(trailingOnly = TRUE)
out <- if (length(out)) out[[1]] else "strokes-paint.png"

warm <- linear_gradient(c("#F97316", "#FACC15", "#22C55E"))
cool <- linear_gradient(c("#1F77B4", "#9467BD"), interpolation = "oklab")

t <- seq(0, 1, length.out = 120)
wave <- function(y, amp) y + amp * sin(6 * pi * t)

scene <- vl_scene(6.5, 3.4, dpi = 150, bg = "white") |>
  draw(text_grob("Gradient strokes", x = 0.04, y = 0.95, just = c("left", "top"),
                 gp = vl_gpar(fontsize = 13, fontface = "bold"))) |>

  # A trajectory whose colour runs along it -- previously faked by emitting
  # hundreds of one-segment lines, each a slightly different flat colour.
  draw(lines_grob(0.04 + 0.92 * t, wave(0.72, 0.07),
                  gp = vl_gpar(col = warm, lwd = 9))) |>
  draw(lines_grob(0.04 + 0.92 * t, wave(0.56, 0.05),
                  gp = vl_gpar(col = cool, lwd = 5))) |>

  # It works on any stroked path, not just polylines: an outline too.
  draw(circle_grob(x = 0.12, y = 0.30, r = 0.09,
                   gp = vl_gpar(fill = NA, col = warm, lwd = 7))) |>
  draw(rect_grob(x = 0.32, y = 0.30, width = 0.14, height = 0.18,
                 gp = vl_gpar(fill = NA, col = cool, lwd = 7))) |>

  draw(text_grob("Dash phase", x = 0.50, y = 0.42, just = c("left", "top"),
                 gp = vl_gpar(fontsize = 13, fontface = "bold")))

# Four rules, same dash pattern, phase stepped: the dashes walk. Animate the
# phase and this is marching ants.
for (i in 0:3) {
  scene <- draw(scene, segments_grob(
    0.50, 0.32 - i * 0.07, 0.96, 0.32 - i * 0.07,
    gp = vl_gpar(col = "grey15", lwd = 5, lty = "dashed", dash_phase = i * 1.5)
  ))
}

render(scene, out)
cat(sprintf("wrote %s\n", out))

# The gradient is real paint on every backend, not a rasterised approximation.
svg <- scene_svg(scene)
cat(sprintf("SVG strokes with a gradient reference: %s\n",
            grepl('stroke="url(#', svg, fixed = TRUE)))
cat(sprintf("SVG carries a dash offset:             %s\n",
            grepl("stroke-dashoffset", svg, fixed = TRUE)))
