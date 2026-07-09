# A worked vellum example: masks (F3).
#
# A mask renders a viewport's contents as an isolated layer, then modulates their
# visibility by another grob's coverage. `as_mask(grob, type = "alpha")` uses the
# mask's opacity; `type = "luminance"` uses its brightness (white shows, black
# hides) -- so a gradient makes a soft mask.
#
# Renders to PNG and SVG (the PDF backend has no image support yet, so a masked
# group renders unmasked there).
#
# Run with:  Rscript inst/examples/masks.R  [output.png|.svg|.pdf]

library(vellum)

s <- vl_scene(width = 7, height = 3, dpi = 150, bg = "grey97") |>
  push(vl_viewport(layout = grid_layout(widths = vl_unit(c(1, 1), "null"),
                                     heights = vl_unit(1, "null")))) |>
  # Panel 1: a horizontal colour gradient cut into a ring of discs (alpha mask).
  push(vl_viewport(row = 1, col = 1)) |>
  push(vl_viewport(
    width = 0.85, height = 0.7,
    mask = as_mask(lapply(seq(0.15, 0.85, length.out = 5), function(cx) {
      circle_grob(x = cx, y = 0.5, r = 0.13, gp = vl_gpar(fill = "white", col = NA))
    }))
  )) |>
  draw(rect_grob(gp = vl_gpar(
    col = NA,
    fill = linear_gradient(c("#ff006e", "#ffbe0b", "#3a86ff"))
  ))) |>
  pop() |>
  draw(text_grob("alpha mask: discs", x = 0.5, y = 0.07, gp = vl_gpar(fontface = "bold"))) |>
  pop() |>
  # Panel 2: a gradient softly faded by a radial luminance mask (a vignette).
  push(vl_viewport(row = 1, col = 2)) |>
  push(vl_viewport(
    width = 0.85, height = 0.7,
    mask = as_mask(
      rect_grob(gp = vl_gpar(col = NA, fill = radial_gradient(
        c("white", "white", "black"), stops = c(0, 0.6, 1),
        cx = 0.5, cy = 0.5, r = 0.6
      ))),
      type = "luminance"
    )
  )) |>
  draw(rect_grob(gp = vl_gpar(
    col = NA,
    fill = linear_gradient(c("#06d6a0", "#118ab2"), x1 = 0, y1 = 0, x2 = 1, y2 = 1)
  ))) |>
  pop() |>
  draw(text_grob("luminance mask: vignette", x = 0.5, y = 0.07, gp = vl_gpar(fontface = "bold"))) |>
  pop() |>
  pop()

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else file.path(tempdir(), "vellum-masks.png")
render(s, out)
message("wrote ", out)
