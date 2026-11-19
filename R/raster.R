# Convert an R image to a flat straight-RGBA integer vector (row-major, top-left,
# 4 ints per pixel) plus its pixel dimensions. A `raster` object stores its cells
# by row (top-left first), so `as.vector()` already gives the order we want.
.image_to_rgba <- function(image) {
  if (is.character(image) && length(image) == 1L && !grepl("^#", image)) {
    return(.png_to_rgba(image))
  }
  fast <- .array_to_rgba(image)
  if (!is.null(fast)) {
    return(fast)
  }
  r <- grDevices::as.raster(image)
  d <- dim(r)
  if (is.null(d) || any(d == 0L)) {
    cli::cli_abort("{.arg image} has no pixels.")
  }
  ih <- d[1]
  iw <- d[2]
  rgba <- grDevices::col2rgb(as.vector(r), alpha = TRUE) # 4 x N (r, g, b, alpha)
  list(rgba = as.integer(rgba), iw = as.integer(iw), ih = as.integer(ih))
}

# Fast path for a numeric array in [0, 1] -- the form `png::readPNG()` returns and
# the most common way an image reaches us. The general path above routes through
# `as.raster()`, which builds one "#rrggbb" string per pixel, and that string
# round-trip is 77-93% of the cost of drawing an image (0.21 s at 1 Mpx, 0.84 s at
# 4 Mpx). Here the channels are scaled straight to bytes and interleaved, with no
# character vector at any point.
#
# Returns NULL for anything it does not handle (colour names, factors, integer
# rasters, out-of-range or non-finite values), so the caller falls back.
#
# Byte-exactness: `as.integer(255 * v + 0.5)` reproduces R's own `ScaleColor`
# (`(unsigned int)(255 * x + 0.5)`) used by `rgb()` underneath `as.raster()`, so
# this path and the fallback agree pixel for pixel -- asserted in `test-image.R`.
.array_to_rgba <- function(image) {
  if (!is.numeric(image) || is.object(image)) {
    return(NULL)
  }
  d <- dim(image)
  # `as.raster()` accepts only 3- or 4-plane arrays; match that exactly so this
  # path never widens what `raster_grob()` accepts.
  if (length(d) != 3L || any(d[1:2] == 0L) || !(d[3] %in% c(3L, 4L))) {
    return(NULL)
  }
  if (anyNA(image) || min(image) < 0 || max(image) > 1) {
    return(NULL)
  }
  ih <- d[1]
  iw <- d[2]
  nc <- d[3]
  n <- ih * iw
  # `image` is column-major (row, col, channel); the general path flattens the
  # raster the same way, so channel slices line up element for element.
  # `as.raster.array()` transposes each plane before building its strings, so the
  # flattened raster runs across rows; transpose here to match element for element.
  ch <- function(k) as.integer(255 * t(image[,, k]) + 0.5)
  px <- if (nc == 3L) {
    list(ch(1), ch(2), ch(3), rep.int(255L, n))
  } else {
    list(ch(1), ch(2), ch(3), ch(4))
  }
  out <- integer(4L * n)
  out[seq.int(1L, by = 4L, length.out = n)] <- px[[1]]
  out[seq.int(2L, by = 4L, length.out = n)] <- px[[2]]
  out[seq.int(3L, by = 4L, length.out = n)] <- px[[3]]
  out[seq.int(4L, by = 4L, length.out = n)] <- px[[4]]
  list(rgba = out, iw = as.integer(iw), ih = as.integer(ih))
}

# Read a PNG file straight to RGBA in Rust. The `png` crate is already vendored
# for the SVG/pattern encode path, so a file path needs no R image package.
.png_to_rgba <- function(path) {
  path <- path.expand(path)
  if (!file.exists(path)) {
    cli::cli_abort("{.arg image} file does not exist: {.path {path}}.")
  }
  v <- rs_read_png(path)
  iw <- v[1]
  ih <- v[2]
  if (iw <= 0L || ih <= 0L) {
    cli::cli_abort("{.arg image} has no pixels.")
  }
  # Rust emits row-major RGBA, top-left first -- already the order the scene wants.
  # (`as.raster.array()` transposes each plane before building its strings, so the
  # `as.raster()` path flattens row-major too; no permutation is needed here.)
  list(rgba = as.integer(v[-(1:2)]), iw = as.integer(iw), ih = as.integer(ih))
}
