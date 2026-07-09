# A non-finite (NA) coordinate breaks a line / drops a primitive, matching grid.

test_that("NA in a line breaks it into separate segments", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(lines_grob(c(0.1, 0.45, NA, 0.55, 0.9), 0.5, gp = vl_gpar(col = "black", lwd = 3)))
  red <- scene_raster(s)[1, , ]
  expect_lt(min(red[40, ]), 100L) # ink in the left half
  expect_lt(min(red[160, ]), 100L) # ink in the right half
  expect_gt(min(red[100, ]), 200L) # gap across the NA break (no connecting ink)
})

test_that("NA splits a polygon into independent sub-polygons", {
  # Two separate filled triangles in one polygon_grob, separated by NA.
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(polygon_grob(
      c(0.05, 0.2, 0.35, NA, 0.65, 0.8, 0.95),
      c(0.1, 0.9, 0.1, NA, 0.1, 0.9, 0.1),
      gp = vl_gpar(fill = "black", col = NA)
    ))
  red <- scene_raster(s)[1, , ]
  expect_lt(red[40, 50], 100L) # left triangle filled
  expect_lt(red[160, 50], 100L) # right triangle filled
  expect_gt(red[100, 50], 200L) # gap between them is background
})

test_that("NA-positioned markers and segments are dropped, not drawn at 0", {
  # A marker at NA must not appear at the origin / corner.
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(points_grob(c(0.5, NA), c(0.5, NA), size = vl_unit(5, "mm"),
                     gp = vl_gpar(fill = "black", col = NA)))
  r <- scene_raster(s)
  expect_lt(r[1, 100, 100], 100L) # the valid point is drawn
  expect_equal(r[1:3, 3, 197], c(255L, 255L, 255L)) # bottom-left stays background
})
