# A worked vellum example: colour-vision-deficiency simulation.
#
# `render(scene, path, cvd = )` and `scene_raster(scene, cvd = )` re-render the
# finished raster as a viewer with a given deficiency would see it. It turns an
# accessibility check from an export-and-upload round trip into an argument.
#
# Run with:  Rscript inst/examples/cvd.R  [output-prefix]

library(vellum)

prefix <- commandArgs(trailingOnly = TRUE)
prefix <- if (length(prefix)) prefix[[1]] else "cvd"

# The default categorical palette most plotting libraries reach for first.
pal <- c("#D62728", "#2CA02C", "#1F77B4", "#FF7F0E", "#9467BD")
names(pal) <- c("red", "green", "blue", "orange", "purple")

swatch <- function() {
  s <- vl_scene(5, 1.4, dpi = 150, bg = "white")
  n <- length(pal)
  for (i in seq_len(n)) {
    s <- draw(s, rect_grob(x = (i - 0.5) / n, width = 1 / n * 0.9, height = 0.62,
                           y = 0.58, gp = vl_gpar(fill = pal[[i]], col = NA)))
    s <- draw(s, text_grob(names(pal)[i], x = (i - 0.5) / n, y = 0.14,
                           gp = vl_gpar(fontsize = 10, col = "grey30")))
  }
  s
}

kinds <- c("none", "protanopia", "deuteranopia", "tritanopia", "achromatopsia")
for (k in kinds) {
  f <- sprintf("%s-%s.png", prefix, k)
  vl_clear_render_cache()
  render(swatch(), f, cvd = k)
  cat(sprintf("wrote %s\n", f))
}

# The interesting part is not the picture but the number: how far apart are two
# colours *after* simulation? A pair that collapses is a pair a reader cannot
# tell apart.
sep <- function(a, b, kind) {
  r <- scene_raster(swatch(), cvd = kind)
  n <- length(pal)
  at <- function(i) r[1:3, round((i - 0.5) / n * 750), 80]
  sum(abs(as.integer(at(a)) - as.integer(at(b))))
}
cat("\nchannel distance between the red and green swatches:\n")
for (k in kinds) {
  cat(sprintf("  %-14s %4d%s\n", k, sep(1, 2, k),
              if (sep(1, 2, k) < sep(1, 2, "none") / 3) "   <- effectively identical" else ""))
}
cat("\nA red/green pair is the classic failure. Check yours before shipping.\n")
