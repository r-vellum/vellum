# A worked vellum example: text halo and OpenType features.
#
#   * `vl_gpar(halo_col =, halo_width =)` -- a "shadowtext" outline drawn UNDER
#     the glyphs, so a label stays readable over dense marks or map imagery.
#     Real stroked outlines on all three backends, not eight offset copies.
#   * `vl_gpar(features = c(tnum = 1))` -- OpenType feature tags. Tabular
#     figures, small caps, oldstyle figures, ligature and kerning control.
#
# Run with:  Rscript inst/examples/typography.R  [output.png|.svg|.pdf]

library(vellum)

out <- commandArgs(trailingOnly = TRUE)
out <- if (length(out)) out[[1]] else "typography.png"

set.seed(1)
n <- 900

label <- function(txt, x, y, fontsize = 15, ...) {
  text_grob(txt, x = x, y = y, just = c("left", "centre"),
            gp = vl_gpar(fontsize = fontsize, ...))
}

scene <- vl_scene(7, 4.4, dpi = 150, bg = "white") |>
  push(vl_viewport(name = "page", width = 0.94, height = 0.9)) |>

  # --- halo over a busy background -----------------------------------------
  push(vl_viewport(name = "cloud", y = 0.74, height = 0.44, xscale = c(0, 1), yscale = c(0, 1))) |>
  draw(rect_grob(gp = vl_gpar(fill = "grey20", col = NA))) |>
  draw(points_grob(runif(n), runif(n), size = vl_unit(1.6, "mm"),
                   gp = vl_gpar(fill = "#7FB2E5AA", col = NA))) |>
  # Without a halo the label fights the cloud behind it.
  draw(label("no halo", 0.04, 0.72, col = "white", fontsize = 20)) |>
  # With one, it reads cleanly at any density.
  draw(label("with halo", 0.04, 0.28, col = "white", fontsize = 20,
             halo_col = "black", halo_width = 2.5)) |>
  draw(text_grob("halo_width is in points, like fontsize -- about an eighth of it reads well",
                 x = 0.97, y = 0.06, just = c("right", "bottom"),
                 gp = vl_gpar(fontsize = 8, col = "grey75",
                              halo_col = "grey10", halo_width = 1))) |>
  pop() |>

  # --- OpenType features ----------------------------------------------------
  draw(label("OpenType features", 0.0, 0.42, fontface = "bold", fontsize = 13)) |>
  draw(label("kerning on  (default)", 0.0, 0.30, fontfamily = "Times New Roman", fontsize = 13,
             col = "grey40")) |>
  draw(label("AV Wa To Ty", 0.42, 0.30, fontfamily = "Times New Roman", fontsize = 22)) |>
  draw(label("kerning off  c(kern = 0)", 0.0, 0.16, fontfamily = "Times New Roman", fontsize = 13,
             col = "grey40")) |>
  draw(label("AV Wa To Ty", 0.42, 0.16, fontfamily = "Times New Roman", fontsize = 22,
             features = c(kern = 0))) |>
  draw(text_grob(
    paste("Common tags: tnum (tabular figures, so axis labels stop jittering),",
          "smcp (small caps),\nonum (oldstyle figures), liga (ligatures), kern.",
          "A tag the font lacks is ignored."),
    x = 0.0, y = 0.0, just = c("left", "bottom"),
    gp = vl_gpar(fontsize = 9, col = "grey45"))) |>
  pop()

render(scene, out)
cat(sprintf("wrote %s\n", out))

# Measurement follows the features, which is what keeps layout honest: a
# `grobwidth`-sized track reserves space for the glyphs that will actually be
# drawn, not for a differently-shaped version of the string.
w_on <- vl_strwidth("AV Wa To Ty", "Times New Roman", fontsize = 22, unit = "mm")
w_off <- vl_strwidth("AV Wa To Ty", "Times New Roman", fontsize = 22, unit = "mm",
                     features = c(kern = 0))
cat(sprintf("\n'AV Wa To Ty' at 22pt: kerned %.2f mm, unkerned %.2f mm (%.1f%% wider)\n",
            w_on, w_off, 100 * (w_off / w_on - 1)))
