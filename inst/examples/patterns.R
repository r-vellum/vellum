# A worked vellum example: tiling-pattern fills (F2).
#
# A pattern tiles a grob (or list of grobs) across a shape. The tile occupies the
# unit square; `width`/`height` set the cell size (resolved against the viewport,
# like gradients). Renders to PNG and SVG with the tile embedded as an image; the
# PDF backend falls back to the tile's average colour.
#
# Run with:  Rscript inst/examples/patterns.R  [output.png|.svg|.pdf]

library(vellum)

# Polka dots: white dots on a coloured ground.
dots <- function(ground) {
  list(
    rect_grob(gp = vl_gpar(fill = ground, col = NA)),
    circle_grob(r = 0.28, gp = vl_gpar(fill = "white", col = NA))
  )
}

# Diagonal stripes via a rotated thick line through the tile.
stripes <- function(a, b) {
  list(
    rect_grob(gp = vl_gpar(fill = a, col = NA)),
    lines_grob(x = vl_unit(c(-0.2, 1.2), "npc"), y = vl_unit(c(-0.2, 1.2), "npc"),
               gp = vl_gpar(col = b, lwd = 10))
  )
}

# A checkerboard: two cells filled, two empty.
checker <- function(a, b) {
  list(
    rect_grob(gp = vl_gpar(fill = a, col = NA)),
    rect_grob(x = 0.25, y = 0.75, width = 0.5, height = 0.5, gp = vl_gpar(fill = b, col = NA)),
    rect_grob(x = 0.75, y = 0.25, width = 0.5, height = 0.5, gp = vl_gpar(fill = b, col = NA))
  )
}

s <- vl_scene(width = 7, height = 3, dpi = 150, bg = "grey97") |>
  push(vl_viewport(layout = grid_layout(widths = vl_unit(c(1, 1, 1), "null"),
                                     heights = vl_unit(1, "null")))) |>
  # Panel 1: polka dots
  push(vl_viewport(row = 1, col = 1)) |>
  draw(circle_grob(x = 0.5, y = 0.55, r = 0.4, gp = vl_gpar(
    col = "grey40", lwd = 2,
    fill = vl_pattern(dots("firebrick"), width = 0.16, height = 0.16)
  ))) |>
  draw(text_grob("dots", x = 0.5, y = 0.08, gp = vl_gpar(fontface = "bold"))) |>
  pop() |>
  # Panel 2: diagonal stripes
  push(vl_viewport(row = 1, col = 2)) |>
  draw(rect_grob(x = 0.5, y = 0.55, width = 0.8, height = 0.7, gp = vl_gpar(
    col = "grey40", lwd = 2,
    fill = vl_pattern(stripes("#1f4e79", "#9dc3e6"), width = 0.18, height = 0.18)
  ))) |>
  draw(text_grob("stripes", x = 0.5, y = 0.08, gp = vl_gpar(fontface = "bold"))) |>
  pop() |>
  # Panel 3: checkerboard
  push(vl_viewport(row = 1, col = 3)) |>
  draw(rect_grob(x = 0.5, y = 0.55, width = 0.8, height = 0.7, gp = vl_gpar(
    col = "grey40", lwd = 2,
    fill = vl_pattern(checker("#2d6a4f", "#b7e4c7"), width = 0.2, height = 0.2)
  ))) |>
  draw(text_grob("checker", x = 0.5, y = 0.08, gp = vl_gpar(fontface = "bold"))) |>
  pop() |>
  pop()

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else file.path(tempdir(), "vellum-patterns.png")
render(s, out)
message("wrote ", out)
