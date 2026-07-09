# A worked vellum example: repaint boundaries (FW4c).
#
# `vl_viewport(cache = TRUE)` marks a subtree as a repaint boundary: it is
# rasterised once, and on later renders where that subtree is unchanged the
# cached pixels are composited instead of re-drawing it. So an interactive
# highlight (edit one element with edit_node() and re-render) or an animation
# (one subtree changes, the rest static) re-rasterises only what changed.
#
# It pays when the cached subtree is expensive to *rasterise* but not to compile
# -- a dense point cloud (here), a full-page gradient, an image, or a mask. It is
# raster/display() only: SVG and PDF ignore the flag and render the subtree as
# vector (no fidelity loss). The output is byte-identical with or without it.
#
# Run with:  Rscript inst/examples/repaint.R  [output.png]

library(vellum)

out <- commandArgs(trailingOnly = TRUE)
out <- if (length(out)) out[[1]] else file.path(tempdir(), "repaint.png")

set.seed(1)
n <- 2e5
bx <- runif(n)
by <- runif(n)

# A heavy, static background cloud in a cached boundary, plus a light foreground
# marker in its own boundary -- the "highlighted" element the user moves/edits.
scene <- vl_scene(width = 6, height = 4, dpi = 150, bg = "white") |>
  push(vl_viewport(cache = TRUE, name = "cloud", xscale = c(0, 1), yscale = c(0, 1))) |>
  draw(points_grob(vl_unit(bx, "native"), vl_unit(by, "native"),
                   size = vl_unit(1.2, "mm"), gp = vl_gpar(fill = "#3a86ff30", col = NA))) |>
  pop() |>
  push(vl_viewport(cache = TRUE, name = "cursor", xscale = c(0, 1), yscale = c(0, 1))) |>
  draw(circle_grob(x = vl_unit(0.5, "native"), y = vl_unit(0.5, "native"), r = vl_unit(4, "mm"),
                   gp = vl_gpar(fill = NA, col = "firebrick", lwd = 3), name = "ring")) |>
  pop()

render(scene, out)
cat(sprintf("wrote %s\n", out))

# A "hover" update: move the cursor ring. The cloud boundary is unchanged, so its
# 200k-point raster is reused; only the small cursor boundary is re-drawn.
scene <- edit_node(scene, "ring",
                   x = vl_unit(0.7, "native"), y = vl_unit(0.6, "native"))
out2 <- sub("\\.png$", "-hover.png", out)
render(scene, out2)
cat(sprintf("wrote %s (cloud reused from cache; only the cursor re-rendered)\n", out2))
