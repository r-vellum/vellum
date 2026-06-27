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

test_that("as.raster() returns a grDevices raster oriented top-left", {
  # top half red, bottom half white -> raster row 1 (top) is red
  s <- vl_scene(1, 2, dpi = 50, bg = "white") |>
    draw(rect_grob(y = 0.75, height = 0.5, gp = gpar(fill = "red", col = NA)))
  ras <- as.raster(s)
  expect_s3_class(ras, "raster")
  expect_equal(dim(ras), c(100L, 50L)) # c(height, width)
  m <- unclass(ras) # plain matrix [row = y (top->bottom), col = x]
  expect_match(m[5, 25], "^#FF0000") # near the top -> red
  expect_match(m[95, 25], "^#FFFFFF") # near the bottom -> white
})
