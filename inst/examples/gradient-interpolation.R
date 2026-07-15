# Showcase: gradient colour-interpolation spaces.
#
# vellum blends gradient stops in one of three colour spaces, selected with the
# `interpolation` argument to linear_gradient() / radial_gradient():
#
#   "srgb"  - the backends' native behaviour: a straight line in gamma-encoded
#             sRGB. Fast, but a ramp between two vivid colours passes through
#             muddy, over-dark midtones and can drift in hue.
#   "oklab" - a straight line in the perceptually-uniform Oklab space (its
#             rectangular L/a/b form). Even lightness, no muddy midtone. A ramp
#             between near-complementary colours still desaturates toward grey at
#             the middle, because the straight a/b line passes near the neutral
#             axis.
#   "oklch" - a line in the *polar* form of Oklab (lightness, chroma, hue). Hue
#             and chroma move independently, so the ramp keeps its chroma through
#             the middle -- at the cost of sweeping through the intermediate hues
#             along the shorter arc (blue->yellow goes through green, not grey).
#
# All three are realised identically on the raster, SVG, and PDF backends
# (perceptual modes are pre-sampled into dense sRGB stops in the Rust core), so
# this script renders the same whichever extension you give it.
#
# Run with:  Rscript inst/examples/gradient-interpolation.R  [output.png|.svg|.pdf]

library(vellum)

modes <- c("srgb", "oklab", "oklch")

# Colour pairs chosen to make the differences legible. The neutral black->white
# pair is a control: with no hue, all three modes agree (only lightness differs
# from sRGB). The near-complementary pairs are where oklab vs oklch diverges.
pairs <- list(
  list(name = "black -> white", cols = c("black", "white")),
  list(name = "blue -> yellow", cols = c("blue", "yellow")),
  list(name = "red -> green",   cols = c("red", "green")),
  list(name = "magenta -> lime", cols = c("magenta", "#7CFC00")),
  list(name = "white -> navy",  cols = c("white", "navy"))
)

nrow <- length(pairs)
ncol <- length(modes)

# Layout in scene npc: a left column for row labels, a top band for the title and
# the per-mode column headers, then an nrow x ncol grid of swatches.
label_w <- 0.15
x0 <- label_w + 0.01
x1 <- 0.99
top <- 0.88 # swatches sit below this; title + headers live above
bot <- 0.03
colw <- (x1 - x0) / ncol
rowh <- (top - bot) / nrow
pad <- 0.006 # inset between adjacent swatches

s <- vl_scene(width = 8, height = 6, dpi = 150, bg = "white")

# Title + column headers.
s <- s |>
  draw(text_grob("Gradient interpolation spaces", x = 0.5, y = 0.965,
                 gp = vl_gpar(col = "black", fontface = "bold", fontsize = 20)))
for (j in seq_len(ncol)) {
  cx <- x0 + (j - 0.5) * colw
  s <- draw(s, text_grob(modes[[j]], x = cx, y = 0.915,
                         gp = vl_gpar(col = "grey20", fontface = "bold", fontsize = 15)))
}

# One swatch per (pair, mode): a rect filled with a left-to-right linear gradient
# spanning the swatch's own viewport (x1 = 0 .. x2 = 1 in its npc).
for (i in seq_len(nrow)) {
  p <- pairs[[i]]
  yc <- top - (i - 0.5) * rowh

  # Row label (the colour pair), left-aligned in the label column.
  s <- draw(s, text_grob(p$name, x = 0.01, y = yc, just = c("left", "centre"),
                         gp = vl_gpar(col = "grey20", fontsize = 12)))

  for (j in seq_len(ncol)) {
    cx <- x0 + (j - 0.5) * colw
    vp <- vl_viewport(x = cx, y = yc, width = colw - 2 * pad, height = rowh - 2 * pad)
    grad <- linear_gradient(p$cols, x1 = 0, y1 = 0.5, x2 = 1, y2 = 0.5,
                            interpolation = modes[[j]])
    s <- s |>
      push(vp) |>
      draw(rect_grob(gp = vl_gpar(col = "grey60", lwd = 0.5, fill = grad))) |>
      pop()
  }
}

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else file.path(tempdir(), "gradient-interpolation.png")
render(s, out)
message("wrote ", out)
