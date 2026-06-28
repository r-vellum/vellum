# Public pixel accessors: scene_raster() (numeric array) and the as.raster()
# method (grDevices raster).

test_that("scene_raster() returns a c(4, w, h) integer array with correct pixels", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = gpar(fill = "red", col = NA)))
  r <- scene_raster(s)
  expect_equal(dim(r), c(4L, 200L, 100L)) # channels, x, y
  expect_equal(r[1:4, 100, 50], c(255L, 0L, 0L, 255L)) # centre is opaque red
})

test_that("scene_raster() dispatches through as_vellum_scene()", {
  Spec <- S7::new_class("Spec2", properties = list())
  S7::method(as_vellum_scene, Spec) <- function(x, ...) {
    vl_scene(1, 1, dpi = 50, bg = "blue")
  }
  r <- scene_raster(Spec())
  expect_equal(r[1:3, 25, 25], c(0L, 0L, 255L))
})

test_that("as.raster() renders correctly via grid (no shear/tiling)", {
  skip_if_not_installed("png")
  # An ASYMMETRIC scene (one corner marked) so a transpose/shear/stride bug in the
  # raster layout would change the output, not just a symmetric blob. We render the
  # raster back through grid::grid.raster() — the real consumer — and check pixels.
  s <- vl_scene(4, 2, dpi = 100, bg = "white") |>
    draw(rect_grob(x = 0.1, y = 0.85, width = 0.16, height = 0.24,
                   gp = gpar(fill = "red", col = NA))) # top-LEFT block
  ras <- as.raster(s)
  expect_s3_class(ras, "raster")
  expect_equal(dim(ras), c(200L, 400L)) # c(height, width)

  f <- withr::local_tempfile(fileext = ".png")
  grDevices::png(f, width = 400, height = 200)
  grid::grid.newpage()
  grid::grid.raster(ras, width = grid::unit(1, "npc"), height = grid::unit(1, "npc"))
  grDevices::dev.off()
  img <- png::readPNG(f) # [h, w, c]
  expect_gt(img[30, 40, 1], 0.8) # top-left IS red: high red...
  expect_lt(img[30, 40, 3], 0.2) # ...low blue
  expect_gt(min(img[170, 360, 1:3]), 0.8) # bottom-right is white (not tiled/sheared)
  expect_gt(min(img[30, 360, 1:3]), 0.8) # top-right is white (would be red if mirrored)
})
