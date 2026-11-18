# Backend parity: render one scene to PNG, SVG and PDF, rasterise the vector
# outputs back to pixels, and compare where the ink lands. vellum's promise is
# identical geometry on every backend, so a feature that one backend drops or
# draws differently (a solid line where the others dash, a black stroke where
# the others pattern) shows up as a mask mismatch rather than needing a bespoke
# test per backend.
#
# Rasterisers, in order of preference (each skips cleanly when missing):
#   SVG: the rsvg package, else magick built with librsvg.
#   PDF: the pdftools package, else the poppler `pdftoppm` binary.

# An RGB array (height x width x 3, 0-255) from the PNG backend.
parity_png <- function(scene) {
  r <- scene_raster(scene) # channels x width x height, 0-255
  aperm(r[1:3, , , drop = FALSE], c(3L, 2L, 1L))
}

# Composite straight RGBA (height x width x 4, 0-1) over white -> 0-255 RGB.
parity_over_white <- function(a) {
  alpha <- a[, , 4L]
  rgb <- a[, , 1:3, drop = FALSE]
  for (k in 1:3) {
    rgb[, , k] <- rgb[, , k] * alpha + (1 - alpha)
  }
  round(rgb * 255)
}

parity_svg <- function(scene, w, h) {
  svg <- withr::local_tempfile(fileext = ".svg")
  writeLines(scene_svg(scene, text = "outline"), svg)
  if (requireNamespace("rsvg", quietly = TRUE)) {
    return(parity_over_white(rsvg::rsvg(svg, width = w, height = h)))
  }
  if (
    requireNamespace("magick", quietly = TRUE) &&
      isTRUE(magick::magick_config()$rsvg)
  ) {
    img <- magick::image_read_svg(svg, width = w, height = h)
    img <- magick::image_background(img, "white")
    a <- as.integer(magick::image_data(img, "rgb"))
    return(a)
  }
  skip("no SVG rasteriser (rsvg, or magick with librsvg)")
}

parity_pdf <- function(scene, dpi) {
  pdf <- withr::local_tempfile(fileext = ".pdf")
  render(scene, pdf)
  if (requireNamespace("pdftools", quietly = TRUE)) {
    b <- pdftools::pdf_render_page(pdf, dpi = dpi, numeric = TRUE)
    return(parity_over_white(b))
  }
  skip_if(unname(Sys.which("pdftoppm")) == "", "no PDF rasteriser")
  skip_if_not_installed("png")
  stem <- withr::local_tempfile()
  system2(
    "pdftoppm",
    c("-png", "-singlefile", "-r", dpi, shQuote(pdf), shQuote(stem)),
    stdout = FALSE,
    stderr = FALSE
  )
  out <- paste0(stem, ".png")
  skip_if(!file.exists(out), "pdftoppm produced no output")
  a <- png::readPNG(out)
  if (dim(a)[3] == 4L) {
    return(parity_over_white(a))
  }
  round(a[, , 1:3] * 255)
}

# Ink = clearly not the white page.
parity_ink <- function(rgb, threshold = 64) {
  apply(255 - rgb, c(1L, 2L), max) > threshold
}

# Grow a mask by `r` pixels (8-connected), to forgive antialiasing.
parity_dilate <- function(m, r = 1L) {
  for (i in seq_len(r)) {
    g <- m
    nr <- nrow(m)
    nc <- ncol(m)
    g[-1L, ] <- g[-1L, ] | m[-nr, ]
    g[-nr, ] <- g[-nr, ] | m[-1L, ]
    g[, -1L] <- g[, -1L] | m[, -nc]
    g[, -nc] <- g[, -nc] | m[, -1L]
    m <- g
  }
  m
}

# Compare two RGB rasters: the share of ink pixels in either that the other
# misses even after a 1-px dilation, and the mean colour difference where both
# have ink.
parity_compare <- function(a, b) {
  h <- min(dim(a)[1], dim(b)[1])
  w <- min(dim(a)[2], dim(b)[2])
  a <- a[seq_len(h), seq_len(w), , drop = FALSE]
  b <- b[seq_len(h), seq_len(w), , drop = FALSE]
  ia <- parity_ink(a)
  ib <- parity_ink(b)
  union <- sum(ia | ib)
  miss <- sum(ia & !parity_dilate(ib)) + sum(ib & !parity_dilate(ia))
  both <- ia & ib
  col <- if (any(both)) {
    sel <- array(both, dim = c(h, w, 3L))
    mean(abs(a[sel] - b[sel]))
  } else {
    0
  }
  list(
    ink = union,
    mismatch = if (union == 0) 0 else miss / union,
    iou = if (union == 0) 1 else sum(both) / union,
    colour = col
  )
}

# Assert that SVG and PDF put ink where PNG does (and in the same colours).
expect_backend_parity <- function(
  scene,
  dpi,
  mismatch = 0.02,
  colour = 20,
  label = "scene"
) {
  png <- parity_png(scene)
  h <- dim(png)[1]
  w <- dim(png)[2]
  vec <- list(svg = parity_svg(scene, w, h), pdf = parity_pdf(scene, dpi))
  for (nm in names(vec)) {
    cmp <- parity_compare(png, vec[[nm]])
    expect(
      cmp$ink > 0,
      sprintf("%s: the PNG has no ink to compare", label)
    )
    expect(
      cmp$mismatch <= mismatch,
      sprintf(
        "%s: %s ink differs from PNG on %.2f%% of inked pixels (limit %.2f%%)",
        label,
        toupper(nm),
        100 * cmp$mismatch,
        100 * mismatch
      )
    )
    expect(
      cmp$colour <= colour,
      sprintf(
        "%s: %s colour differs from PNG by %.1f/255 on shared ink (limit %g)",
        label,
        toupper(nm),
        cmp$colour,
        colour
      )
    )
  }
  invisible(scene)
}
