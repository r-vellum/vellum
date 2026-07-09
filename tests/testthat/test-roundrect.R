# roundrect_grob: rounded corners, isotropic radius.

test_that("a rounded rect clips its corners but fills its centre", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(roundrect_grob(width = 1, height = 1, r = 0.4, gp = vl_gpar(fill = "red", col = NA)))
  r <- scene_raster(s)
  expect_equal(r[1:3, 4, 4], c(255L, 255L, 255L)) # corner cut away -> background
  expect_equal(r[1:3, 100, 100], c(255L, 0L, 0L)) # centre filled
  expect_equal(r[1:3, 100, 4], c(255L, 0L, 0L)) # mid-top edge is straight -> filled
})

test_that("r = 0 is a plain rectangle (corner filled)", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(roundrect_grob(width = 1, height = 1, r = 0, gp = vl_gpar(fill = "red", col = NA)))
  r <- scene_raster(s)
  expect_equal(r[1:3, 3, 3], c(255L, 0L, 0L))
})

test_that("npc radius is isotropic on a non-square rect (corners stay circular)", {
  # A wide, short rounded rect: the corner inset along x and y must be equal
  # (radius resolved against the shorter side), so the rect is symmetric.
  s <- vl_scene(4, 2, dpi = 100, bg = "white") |>
    draw(roundrect_grob(width = 1, height = 1, r = 0.3, gp = vl_gpar(fill = "blue", col = NA)))
  r <- scene_raster(s)
  d <- dim(r) # c(4, 400, 200)
  # symmetric about both axes
  expect_equal(r[3, 5, 100], r[3, d[2] - 4, 100]) # left vs right edge mid-height
  expect_equal(r[3, 200, 5], r[3, 200, d[3] - 4]) # top vs bottom mid-width
})
