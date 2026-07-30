# P4: raster image primitive (draw_image) + native PDF images.

px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

quad_img <- function() {
  # 2x2: TL red, TR green, BL blue, BR white.
  as.raster(matrix(c("red", "green", "blue", "white"), nrow = 2, byrow = TRUE))
}

test_that("a raster image is drawn with correct orientation", {
  s <- vl_scene(2, 2, dpi = 100, bg = "grey50") |>
    draw(raster_grob(quad_img(), x = 0.5, y = 0.5, width = 1, height = 1, interpolate = FALSE))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 0L, 0L))   # TL red
  expect_equal(px(s, 150, 50)[1:3], c(0L, 255L, 0L))  # TR green
  expect_equal(px(s, 50, 150)[1:3], c(0L, 0L, 255L))  # BL blue
  expect_equal(px(s, 150, 150)[1:3], c(255L, 255L, 255L)) # BR white
})

test_that("an image scales into its cell and leaves the rest as background", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(raster_grob(quad_img(), x = 0.5, y = 0.5, width = 0.5, height = 0.5, interpolate = FALSE))
  # cell is the central 50% (device 50..150); corner is background
  expect_equal(px(s, 5, 5)[1:3], c(255L, 255L, 255L))
  expect_equal(px(s, 75, 75)[1:3], c(255L, 0L, 0L)) # TL of the image, upper-left of cell
})

test_that("interpolate = FALSE keeps hard pixel edges (no blend at a boundary)", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(raster_grob(quad_img(), interpolate = FALSE))
  # just left of the vertical midline is pure red; just right pure green
  expect_equal(px(s, 95, 50)[1:3], c(255L, 0L, 0L))
  expect_equal(px(s, 105, 50)[1:3], c(0L, 255L, 0L))
})

test_that("the image respects clipping", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    push(vl_viewport(width = 0.4, height = 0.4, clip = TRUE)) |>
    draw(raster_grob(quad_img(), interpolate = FALSE)) |>
    pop()
  expect_equal(px(s, 5, 5)[1:3], c(255L, 255L, 255L)) # outside the viewport
})

test_that("SVG embeds an <image>; PDF renders natively", {
  s <- vl_scene(2, 2, dpi = 100) |> draw(raster_grob(quad_img()))
  fsvg <- withr::local_tempfile(fileext = ".svg")
  render(s, fsvg)
  svg <- paste(readLines(fsvg, warn = FALSE), collapse = "")
  expect_match(svg, "<image ")
  expect_match(svg, "data:image/png;base64,")
  fpdf <- withr::local_tempfile(fileext = ".pdf")
  expect_no_error(render(s, fpdf))
  expect_equal(rawToChar(readBin(fpdf, "raw", 5)), "%PDF-")
})

test_that("PDF honours the image interpolate flag (BUGFIX1 Phase 6)", {
  # krilla's from_rgba8 hard-codes non-interpolated, so interpolate was ignored in
  # PDF; an interpolated image now routes through PNG (which carries /Interpolate).
  # The two modes must produce valid but *different* PDFs (else the flag is a no-op).
  pdf_bytes <- function(interp) {
    s <- vl_scene(2, 2, dpi = 90) |>
      draw(raster_grob(quad_img(), width = 0.8, height = 0.8, interpolate = interp))
    f <- withr::local_tempfile(fileext = ".pdf")
    render(s, f)
    readBin(f, "raw", 1e6)
  }
  a <- pdf_bytes(TRUE)
  b <- pdf_bytes(FALSE)
  expect_equal(rawToChar(a[1:5]), "%PDF-")
  expect_equal(rawToChar(b[1:5]), "%PDF-")
  expect_false(identical(a, b))
})

test_that("raster_grob rejects an empty image", {
  expect_error(raster_grob(matrix(character(0), 0, 0)), "no pixels")
})

# --- array fast path + file input (Phase 2) ---------------------------------
# `.array_to_rgba()` skips the per-pixel colour-string round-trip `as.raster()`
# does. It must be byte-exact against that fallback, or images shift colour.

slow_rgba <- function(image) {
  r <- grDevices::as.raster(image)
  d <- dim(r)
  list(rgba = as.integer(grDevices::col2rgb(as.vector(r), alpha = TRUE)),
       iw = as.integer(d[2]), ih = as.integer(d[1]))
}

test_that("the numeric-array fast path is byte-exact against as.raster()", {
  set.seed(42)
  for (dims in list(c(7, 5), c(4, 9), c(1, 6), c(6, 1))) {
    for (nc in 3:4) {
      a <- array(runif(dims[1] * dims[2] * nc), dim = c(dims, nc))
      expect_identical(.array_to_rgba(a), slow_rgba(a))
    }
  }
})

test_that("the fast path rounds exactly like rgb() at the boundaries", {
  # `as.integer(255 * v + 0.5)` must reproduce R's ScaleColor, including the
  # half-way cases where a different rounding rule would differ by one.
  e <- array(c(0, 1, 0.5, 1 / 255, 0.5 / 255, 254.5 / 255, 1e-9, 1 - 1e-9, 0.2),
             dim = c(3, 3, 3))
  expect_identical(.array_to_rgba(e), slow_rgba(e))
})

test_that("the fast path declines anything as.raster() would treat differently", {
  expect_null(.array_to_rgba(array(0.5, dim = c(3, 3, 2)))) # 2 planes: as.raster errors
  expect_null(.array_to_rgba(array(0.5, dim = c(3, 3, 1))))
  expect_null(.array_to_rgba(matrix(0.5, 3, 3)))            # 2-D: greyscale path
  expect_null(.array_to_rgba(array(c(-0.1, rep(0.5, 26)), dim = c(3, 3, 3))))
  expect_null(.array_to_rgba(array(c(1.5, rep(0.5, 26)), dim = c(3, 3, 3))))
  expect_null(.array_to_rgba(array(c(NA, rep(0.5, 26)), dim = c(3, 3, 3))))
  expect_null(.array_to_rgba(quad_img()))                   # character raster
})

test_that("raster_grob() reads a PNG path identically to reading it in R", {
  skip_if_not_installed("png")
  set.seed(7)
  for (nc in 3:4) {
    a <- array(runif(6 * 4 * nc), dim = c(6, 4, nc))
    f <- withr::local_tempfile(fileext = ".png")
    png::writePNG(a, f)
    expect_identical(.image_to_rgba(f), .image_to_rgba(png::readPNG(f)))
  }
})

test_that("a PNG path and an in-memory image render to the same bytes", {
  skip_if_not_installed("png")
  set.seed(3)
  f <- withr::local_tempfile(fileext = ".png")
  png::writePNG(array(runif(20 * 15 * 3), dim = c(20, 15, 3)), f)
  out1 <- withr::local_tempfile(fileext = ".png")
  out2 <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache(); render(vl_scene(2, 2) |> draw(raster_grob(f)), out1)
  vl_clear_render_cache(); render(vl_scene(2, 2) |> draw(raster_grob(png::readPNG(f))), out2)
  expect_identical(tools::md5sum(out1)[[1]], tools::md5sum(out2)[[1]])
})

test_that("a bad image path fails with a clear error", {
  expect_error(raster_grob(file.path(tempdir(), "no-such-file.png")), "does not exist")
  bad <- withr::local_tempfile(fileext = ".png")
  writeLines("not a png", bad)
  expect_error(raster_grob(bad), "PNG")
})
