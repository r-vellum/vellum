# A worked vellum example: gradient fills (F1).
#
# Linear and radial gradients used as `vl_gpar(fill = ...)`. Gradient geometry is
# given in the named units and resolved against the enclosing viewport, so it
# transforms with the grob. Renders identically to PNG, SVG, and PDF — pass an
# output path with the extension you want.
#
# Run with:  Rscript inst/examples/gradients.R  [output.png|.svg|.pdf]

library(vellum)

s <- vl_scene(width = 7, height = 4, dpi = 150, bg = "white") |>
  # Sky: vertical linear gradient across the whole page.
  draw(rect_grob(gp = vl_gpar(
    col = NA,
    fill = linear_gradient(c("#0b1e3b", "#4a76b8", "#cce0f5"),
                           x1 = 0.5, y1 = 1, x2 = 0.5, y2 = 0)
  ))) |>
  # Sun: radial gradient, opaque yellow core fading out.
  draw(circle_grob(x = 0.78, y = 0.72, r = 0.16, gp = vl_gpar(
    col = NA,
    fill = radial_gradient(c("#fff6b0", "#ffd23f", "#ffd23f00"),
                           cx = 0.78, cy = 0.72, r = 0.16)
  ))) |>
  # Three "buildings": left-to-right gradients, reflected to look lit.
  draw(rect_grob(x = 0.20, y = 0.28, width = 0.12, height = 0.46, gp = vl_gpar(
    col = NA,
    fill = linear_gradient(c("#10202a", "#3d5a6c"), extend = "reflect",
                           x1 = 0.14, y1 = 0.5, x2 = 0.26, y2 = 0.5)
  ))) |>
  draw(rect_grob(x = 0.36, y = 0.36, width = 0.12, height = 0.62, gp = vl_gpar(
    col = NA,
    fill = linear_gradient(c("#102a22", "#3d6c58"), extend = "reflect",
                           x1 = 0.30, y1 = 0.5, x2 = 0.42, y2 = 0.5)
  ))) |>
  draw(rect_grob(x = 0.52, y = 0.24, width = 0.12, height = 0.38, gp = vl_gpar(
    col = NA,
    fill = linear_gradient(c("#2a1020", "#6c3d58"), extend = "reflect",
                           x1 = 0.46, y1 = 0.5, x2 = 0.58, y2 = 0.5)
  ))) |>
  draw(text_grob("vellum gradients", x = 0.5, y = 0.06,
                 gp = vl_gpar(col = "white", fontface = "bold", fontsize = 16)))

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else file.path(tempdir(), "vellum-gradients.png")
render(s, out)
message("wrote ", out)
