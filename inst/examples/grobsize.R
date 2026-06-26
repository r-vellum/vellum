# A worked vellum example: grobwidth / grobheight (grob sizing).
#
# Size a layout to its content: the left gutter is exactly as wide as the widest
# axis label, and the title row exactly as tall as the title — via grobwidth() /
# grobheight() units, which measure a grob's drawn extent (eagerly, in mm).
#
# Run with:  Rscript inst/examples/grobsize.R  [output.png|.svg|.pdf]

library(vellum)

title <- text_grob("Sized to content", gp = gpar(fontface = "bold", fontsize = 18))
ylab <- text_grob("temperature (°C)", gp = gpar(fontsize = 13))

# Columns: [y-label gutter | panel]; rows: [title | panel]. The gutter/title
# tracks are sized to the label/title; the panel takes the rest ("null").
s <- vl_scene(width = 6, height = 4, dpi = 150, bg = "white") |>
  push(viewport(layout = grid_layout(
    widths  = c(grobheight(ylab), unit(1, "null")),  # rotated label -> its height is the gutter width
    heights = c(grobheight(title, mult = 1.8), unit(1, "null"))
  )))

# Panel (row 2, col 2)
s <- s |>
  push(viewport(row = 2, col = 2, xscale = c(0, 10), yscale = c(0, 30))) |>
  draw(rect_grob(gp = gpar(fill = "grey97", col = "grey60"))) |>
  draw(lines_grob(unit(0:10, "native"),
                  unit(15 + 10 * sin(seq(0, 6, length.out = 11)), "native"),
                  gp = gpar(col = "steelblue", lwd = 2))) |>
  pop() |>
  # Rotated y-label in the left gutter (row 2, col 1)
  push(viewport(row = 2, col = 1)) |>
  draw(text_grob("temperature (°C)", rot = 90, gp = gpar(fontsize = 13))) |>
  pop() |>
  # Title in the top row spanning both columns
  push(viewport(row = 1, col = 1, colspan = 2)) |>
  draw(title) |>
  pop() |>
  pop()

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else file.path(tempdir(), "vellum-grobsize.png")
render(s, out)
message("wrote ", out)
