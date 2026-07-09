# FW2 expressive primitives: marker shapes, arrows, curves (Bezier / smooth
# spline), and multi-line text — the drawing vocabulary a plotting layer needs.
#
# Run with:  Rscript inst/examples/primitives.R [output.png]

library(vellum)

out <- (function() {
  a <- commandArgs(trailingOnly = TRUE)
  if (length(a) >= 1) a[[1]] else "primitives.png"
})()

s <- vl_scene(width = 7, height = 5, dpi = 150, bg = "white")

# --- marker shapes (top row) ------------------------------------------------
shapes <- c("circle", "square", "triangle", "diamond", "plus", "cross")
for (i in seq_along(shapes)) {
  s <- draw(s, points_grob(
    vl_unit(0.08 + (i - 1) / length(shapes) * 0.84, "npc"), vl_unit(0.86, "npc"),
    size = vl_unit(5, "mm"), shape = shapes[i],
    gp = vl_gpar(fill = "#6baed6", col = "#08306b", lwd = 2)
  ))
}
s <- draw(s, text_grob("marker shapes", x = 0.5, y = 0.96, gp = vl_gpar(fontsize = 12, col = "grey30")))

# --- arrows (second row) ----------------------------------------------------
s <- s |>
  draw(lines_grob(c(0.08, 0.45), c(0.66, 0.66), arrow = vl_arrow(type = "open"),
                  gp = vl_gpar(col = "black", lwd = 2))) |>
  draw(lines_grob(c(0.55, 0.92), c(0.66, 0.66), arrow = vl_arrow(type = "closed", ends = "both"),
                  gp = vl_gpar(col = "#a50f15", lwd = 2))) |>
  draw(text_grob("arrows (open / closed)", x = 0.5, y = 0.74, gp = vl_gpar(fontsize = 12, col = "grey30")))

# --- curves (third row): a Bezier and a smooth spline through points --------
s <- s |>
  draw(bezier_grob(c(0.08, 0.2, 0.35, 0.45), c(0.30, 0.50, 0.20, 0.42),
                   gp = vl_gpar(col = "#238b45", lwd = 3))) |>
  draw(spline_grob(c(0.55, 0.65, 0.75, 0.85, 0.92), c(0.30, 0.46, 0.28, 0.46, 0.32),
                   gp = vl_gpar(col = "#6a51a3", lwd = 3))) |>
  draw(points_grob(vl_unit(c(0.55, 0.65, 0.75, 0.85, 0.92), "npc"),
                   vl_unit(c(0.30, 0.46, 0.28, 0.46, 0.32), "npc"),
                   size = vl_unit(1.5, "mm"), gp = vl_gpar(fill = "#6a51a3", col = NA))) |>
  draw(text_grob("curves: Bezier  |  spline through points", x = 0.5, y = 0.54,
                 gp = vl_gpar(fontsize = 12, col = "grey30")))

# --- multi-line text (bottom) -----------------------------------------------
s <- draw(s, text_grob(
  "multi-line text\nstacks on \\n\nand inherits gpar",
  x = 0.5, y = 0.12, gp = vl_gpar(fontsize = 16, col = "#08306b")
))

render(s, out)
message("wrote ", out)
