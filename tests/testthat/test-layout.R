test_that("a 2x2 null grid places a cell in the right quadrant", {
  s <- rs_scene(width = 1, height = 1, dpi = 100, bg = "white")
  rs_layout(s, widths = c(1, 1), heights = c(1, 1))
  rs_push_viewport(s, row = 2, col = 2) # bottom-right
  rs_rect(s, fill = "red", col = NA)
  expect_equal(rs_pixel(s, 75, 75)[1:3], c(255L, 0L, 0L)) # bottom-right painted
  expect_equal(rs_pixel(s, 25, 25)[1:3], c(255L, 255L, 255L)) # top-left empty
})

test_that("mixed absolute + null tracks size columns correctly", {
  # 4in wide at 100 dpi = 400px. Column 1 = 1in (100px) absolute; column 2 =
  # null, takes the remaining 300px.
  s <- rs_scene(width = 4, height = 1, dpi = 100, bg = "white")
  rs_layout(s, widths = rs_unit(c(1, 1), c("in", "null")), heights = c(1))
  rs_push_viewport(s, row = 1, col = 1)
  rs_rect(s, fill = "red", col = NA)
  rs_pop_viewport(s)
  rs_push_viewport(s, row = 1, col = 2)
  rs_rect(s, fill = "blue", col = NA)
  expect_equal(rs_pixel(s, 50, 50)[1:3], c(255L, 0L, 0L)) # within first 100px
  expect_equal(rs_pixel(s, 250, 50)[1:3], c(0L, 0L, 255L)) # in the null column
})

test_that("a cell can span multiple columns", {
  s <- rs_scene(width = 3, height = 1, dpi = 100, bg = "white") # 300px, 3 cols of 100
  rs_layout(s, widths = c(1, 1, 1), heights = c(1))
  rs_push_viewport(s, row = 1, col = 1, colspan = 2) # first two cells
  rs_rect(s, fill = "red", col = NA)
  expect_equal(rs_pixel(s, 50, 50)[1:3], c(255L, 0L, 0L)) # col 1
  expect_equal(rs_pixel(s, 150, 50)[1:3], c(255L, 0L, 0L)) # col 2 (spanned)
  expect_equal(rs_pixel(s, 250, 50)[1:3], c(255L, 255L, 255L)) # col 3 empty
})

test_that("layout is resolution-independent (resize recompute)", {
  draw <- function(dpi) {
    s <- rs_scene(width = 1, height = 1, dpi = dpi, bg = "white")
    rs_layout(s, widths = c(1, 1), heights = c(1, 1))
    rs_push_viewport(s, row = 1, col = 2) # top-right
    rs_rect(s, fill = "red", col = NA)
    s
  }
  lo <- draw(100)
  hi <- draw(200)
  # same fractional position is painted at both resolutions
  expect_equal(rs_pixel(lo, 75, 25)[1:3], c(255L, 0L, 0L))
  expect_equal(rs_pixel(hi, 150, 50)[1:3], c(255L, 0L, 0L))
  # and the opposite quadrant is empty at both
  expect_equal(rs_pixel(lo, 25, 75)[1:3], c(255L, 255L, 255L))
  expect_equal(rs_pixel(hi, 50, 150)[1:3], c(255L, 255L, 255L))
})
