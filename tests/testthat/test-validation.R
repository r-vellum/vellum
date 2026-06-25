test_that("primitive input is validated with helpful errors", {
  s <- rs_scene(1, 1, dpi = 50)
  expect_error(rs_lines(s, x = 1:3, y = 1:2), "same length")
  expect_error(rs_polygon(s, x = 1:3, y = 1:2), "same length")
  expect_error(rs_rect(s, col = c("red", "blue")), "single value")
  expect_error(rs_rect(s, lwd = c(1, 2)), "single number")
})

test_that("scene dimensions must be finite and positive", {
  expect_error(rs_scene(width = NaN), "finite and positive")
  expect_error(rs_scene(width = -1), "finite and positive")
  expect_error(rs_scene(height = Inf), "finite and positive")
  expect_error(rs_scene(dpi = 0), "finite and positive")
})

test_that("col = NA paints nothing; col = NULL inherits from the viewport", {
  # NA -> explicit no paint: nothing is drawn
  s <- rs_scene(1, 1, dpi = 100, bg = "white")
  rs_rect(s, fill = NA, col = NA)
  expect_equal(rs_pixel(s, 50, 50)[1:3], c(255L, 255L, 255L))

  # NULL -> inherit the viewport's stroke colour
  s2 <- rs_scene(1, 1, dpi = 100, bg = "white")
  rs_push_viewport(s2, gp = rs_gpar(col = "red"))
  rs_lines(s2, x = c(0.05, 0.95), y = c(0.5, 0.5), col = NULL, lwd = 6)
  px <- rs_pixel(s2, 50, 50)
  expect_true(px[1] > 200 && px[2] < 80 && px[3] < 80) # reddish
})

test_that("lwd inherits from the enclosing viewport", {
  band <- function(vp_lwd) {
    s <- rs_scene(2, 1, dpi = 100, bg = "white") # 200 x 100
    rs_push_viewport(s, gp = rs_gpar(lwd = vp_lwd))
    rs_lines(s, x = c(0, 1), y = c(0.5, 0.5), col = "black", lwd = NULL) # inherit
    red <- rs_raster(s)[1, , ]
    sum(red[100, ] < 128) # inked rows in a central column = line thickness
  }
  expect_gt(band(10), band(2))
})
