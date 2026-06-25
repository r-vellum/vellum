test_that("a nested viewport places drawing in the right region", {
  s <- rs_scene(width = 1, height = 1, dpi = 100, bg = "white")
  # child centred in the top-left quadrant (npc y=0.75 is near the top)
  rs_push_viewport(s, x = 0.25, y = 0.75, width = 0.5, height = 0.5)
  rs_rect(s, fill = "red", col = NA)
  expect_equal(rs_pixel(s, 25, 25)[1:3], c(255L, 0L, 0L)) # inside child
  expect_equal(rs_pixel(s, 75, 75)[1:3], c(255L, 255L, 255L)) # opposite quadrant
})

test_that("viewport rotation turns a square into a diamond", {
  s <- rs_scene(width = 1, height = 1, dpi = 100, bg = "white")
  rs_push_viewport(s, x = 0.5, y = 0.5, width = 0.5, height = 0.5, angle = 45)
  rs_rect(s, fill = "red", col = NA)
  expect_equal(rs_pixel(s, 50, 50)[1:3], c(255L, 0L, 0L)) # centre painted
  # a corner of the *unrotated* bounding box is outside the diamond
  expect_equal(rs_pixel(s, 70, 70)[1:3], c(255L, 255L, 255L))
})

test_that("clip=TRUE confines drawing to the viewport rectangle", {
  s <- rs_scene(width = 1, height = 1, dpi = 100, bg = "white")
  rs_push_viewport(s, x = 0.5, y = 0.5, width = 0.4, height = 0.4, clip = TRUE)
  rs_circle(s, r = 0.9, fill = "blue", col = NA) # bigger than the viewport
  expect_equal(rs_pixel(s, 50, 50)[1:3], c(0L, 0L, 255L)) # inside viewport
  # the circle reaches here, but it is above the viewport (top edge ~ y=30)
  expect_equal(rs_pixel(s, 50, 20)[1:3], c(255L, 255L, 255L))
})

test_that("nested clips intersect", {
  s <- rs_scene(width = 1, height = 1, dpi = 100, bg = "white")
  rs_push_viewport(s, x = 0.5, y = 0.5, width = 0.6, height = 0.6, clip = TRUE)
  rs_push_viewport(s, x = 0.5, y = 0.5, width = 0.5, height = 1.5, clip = TRUE)
  rs_rect(s, fill = "blue", col = NA) # fills inner vp, but clipped to intersection
  # vertically inside both, horizontally inside both -> painted
  expect_equal(rs_pixel(s, 50, 50)[1:3], c(0L, 0L, 255L))
  # near top: inside the tall inner vp but OUTSIDE the outer vp (clipped away)
  expect_equal(rs_pixel(s, 50, 10)[1:3], c(255L, 255L, 255L))
})

test_that("gpar fill inherits from the enclosing viewport and can be overridden", {
  s <- rs_scene(width = 1, height = 1, dpi = 100, bg = "white")
  rs_push_viewport(s, gp = rs_gpar(fill = "red"))
  rs_rect(s, x = 0.25, width = 0.4, fill = NULL, col = NA) # inherit -> red
  rs_rect(s, x = 0.75, width = 0.4, fill = "blue", col = NA) # override -> blue
  expect_equal(rs_pixel(s, 25, 50)[1:3], c(255L, 0L, 0L))
  expect_equal(rs_pixel(s, 75, 50)[1:3], c(0L, 0L, 255L))
})

test_that("alpha multiplies down the viewport tree", {
  s <- rs_scene(width = 1, height = 1, dpi = 100, bg = "white")
  rs_push_viewport(s, gp = rs_gpar(alpha = 0.5))
  rs_rect(s, fill = "black", col = NA, alpha = 0.5) # 0.5 * 0.5 = 0.25
  px <- rs_pixel(s, 50, 50)
  expect_equal(px[4], 255L) # opaque over white
  # 0.25 black over white -> ~191 grey
  expect_true(all(abs(px[1:3] - 191L) <= 2L))
})

test_that("native positions account for a non-zero / negative scale origin", {
  s <- rs_scene(width = 1, height = 1, dpi = 100, bg = "white")
  rs_push_viewport(s, xscale = c(-10, 10), yscale = c(-10, 10))
  # native (0, 0) is the centre of a symmetric scale -> device centre
  rs_rect(s, x = 0, y = 0, width = 4, height = 4, units = "native", fill = "red", col = NA)
  expect_equal(rs_pixel(s, 50, 50)[1:3], c(255L, 0L, 0L))
  # native y = 8 -> npc (8+10)/20 = 0.9 -> near the top of the device
  rs_rect(s, x = 0, y = 8, width = 4, height = 2, units = "native", fill = "blue", col = NA)
  expect_equal(rs_pixel(s, 50, 10)[1:3], c(0L, 0L, 255L))
})

test_that("existing single-viewport API still works (backward compat)", {
  s <- rs_scene(width = 1, height = 1, dpi = 100, bg = "white")
  rs_viewport(s, xscale = c(0, 10), yscale = c(0, 10))
  rs_rect(s, x = 5, y = 5, width = 4, height = 4, units = "native", fill = "blue", col = NA)
  expect_equal(rs_pixel(s, 50, 50)[1:3], c(0L, 0L, 255L))
})
