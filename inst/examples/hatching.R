# A worked vellum example: hatch fills.
#
# `vl_hatch()` fills a shape with ruled lines. Unlike `vl_pattern()`, which
# rasterises a tile, a hatch is GEOMETRY: crisp at any zoom, correct in print,
# and -- the reason it matters -- it survives being seen without colour.
#
# Run with:  Rscript inst/examples/hatching.R  [output.png|.svg|.pdf]

library(vellum)

out <- commandArgs(trailingOnly = TRUE)
out <- if (length(out)) out[[1]] else "hatching.png"

# Four categories encoded by colour alone -- the default most people reach for.
pal <- c("#D62728", "#2CA02C", "#1F77B4", "#FF7F0E")
# The same four, encoded by colour AND texture.
angles <- c(0, 45, 90, 135)

bar <- function(i, y, h, fill, col = "grey25") {
  rect_grob(x = (i - 0.5) / 4, y = y, width = 0.20, height = h,
            gp = vl_gpar(fill = fill, col = col, lwd = 0.8))
}

scene <- vl_scene(6, 3, dpi = 150, bg = "white") |>
  draw(text_grob("colour only", x = 0.02, y = 0.93, just = c("left", "top"),
                 gp = vl_gpar(fontsize = 11, fontface = "bold")))
for (i in 1:4) scene <- draw(scene, bar(i, 0.70, 0.28, pal[i]))

scene <- draw(scene, text_grob("colour + hatch", x = 0.02, y = 0.46, just = c("left", "top"),
                               gp = vl_gpar(fontsize = 11, fontface = "bold")))
for (i in 1:4) {
  scene <- draw(scene, bar(i, 0.24, 0.28,
                           vl_hatch(angle = angles[i], spacing = 3.2, col = pal[i], bg = "white")))
}

render(scene, out)
cat(sprintf("wrote %s\n", out))

# The point, measured rather than asserted: under deuteranopia the red and green
# bars become the same colour. The hatch angle still tells them apart.
if (identical(tolower(tools::file_ext(out)), "png")) {
  sim <- sub("\\.png$", "-deuteranopia.png", out)
  render(scene, sim, cvd = "deuteranopia")
  cat(sprintf("wrote %s\n", sim))

  r <- scene_raster(scene, cvd = "deuteranopia")
  at <- function(i, y) as.integer(r[1:3, round((i - 0.5) / 4 * dim(r)[2]), y])
  # y in the upper (colour-only) band vs the lower (hatched) band.
  cat(sprintf("\nred vs green under deuteranopia, colour-only band: distance %d\n",
              sum(abs(at(1, 120) - at(2, 120)))))
  cat("The two bars are now the same colour. In the hatched band the rules run\n")
  cat("at 0 and 45 degrees, so the categories stay distinguishable.\n")
}

cat("\nA hatch is vector geometry on every backend:\n")
svg <- scene_svg(scene)
cat(sprintf("  SVG contains an embedded raster tile: %s\n", grepl("<image", svg, fixed = TRUE)))
cat(sprintf("  SVG size: %s bytes\n", format(nchar(svg), big.mark = ",")))
