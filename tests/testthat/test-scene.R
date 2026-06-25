test_that("scene dimensions follow size and dpi", {
  s <- rs_scene(width = 2, height = 1, dpi = 100)
  expect_equal(rs_dim(s), c(200L, 100L))
})

test_that("background colour fills the page", {
  s <- rs_scene(width = 1, height = 1, dpi = 50, bg = "white")
  expect_equal(rs_pixel(s, 0, 0), c(255L, 255L, 255L, 255L))
  expect_equal(rs_pixel(s, 25, 25), c(255L, 255L, 255L, 255L))

  s2 <- rs_scene(width = 1, height = 1, dpi = 50, bg = "red")
  expect_equal(rs_pixel(s2, 25, 25), c(255L, 0L, 0L, 255L))
})

test_that("primitives accumulate in the scene", {
  s <- rs_scene(width = 1, height = 1, dpi = 50)
  expect_equal(s$len(), 0L)
  rs_rect(s, fill = "blue")
  rs_circle(s, fill = "green")
  expect_equal(s$len(), 2L)
})

test_that("a filled rect paints the centre and leaves the corner as background", {
  s <- rs_scene(width = 1, height = 1, dpi = 100, bg = "white")
  # centred rect covering the middle half of the page
  rs_rect(s, x = 0.5, y = 0.5, width = 0.5, height = 0.5, fill = "red", col = NA)
  expect_equal(rs_pixel(s, 50, 50), c(255L, 0L, 0L, 255L)) # centre: red
  expect_equal(rs_pixel(s, 5, 5), c(255L, 255L, 255L, 255L)) # corner: white
})

test_that("native coordinates map through the viewport scale", {
  s <- rs_scene(width = 1, height = 1, dpi = 100, bg = "white")
  rs_viewport(s, xscale = c(0, 10), yscale = c(0, 10))
  # a rect centred at native (5, 5) spanning 4 native units = middle 40%
  rs_rect(s, x = 5, y = 5, width = 4, height = 4, units = "native", fill = "blue", col = NA)
  expect_equal(rs_pixel(s, 50, 50), c(0L, 0L, 255L, 255L)) # native (5,5) -> centre
  expect_equal(rs_pixel(s, 10, 10), c(255L, 255L, 255L, 255L)) # outside the rect
})

test_that("y axis points up (R convention), not down", {
  s <- rs_scene(width = 1, height = 1, dpi = 100, bg = "white")
  # small rect near the TOP of the page (npc y = 0.9)
  rs_rect(s, x = 0.5, y = 0.9, width = 0.2, height = 0.2, fill = "red", col = NA)
  # top of the image (small device y) should be red; bottom should be white
  expect_equal(rs_pixel(s, 50, 10)[1:3], c(255L, 0L, 0L))
  expect_equal(rs_pixel(s, 50, 90)[1:3], c(255L, 255L, 255L))
})

test_that("alpha is applied to fills", {
  s <- rs_scene(width = 1, height = 1, dpi = 50, bg = "white")
  rs_rect(s, fill = "black", col = NA, alpha = 0.5)
  px <- rs_pixel(s, 25, 25)
  # 50% black composited over opaque white -> opaque mid-grey
  expect_equal(px[4], 255L)
  expect_true(all(abs(px[1:3] - 127L) <= 2L))
})

test_that("rs_render writes a PNG file", {
  s <- rs_scene(width = 1, height = 1, dpi = 50, bg = "white")
  rs_circle(s, fill = "steelblue")
  path <- withr::local_tempfile(fileext = ".png")
  rs_render(s, path)
  expect_true(file.exists(path))
  expect_gt(file.size(path), 0)
  # PNG magic bytes
  expect_equal(readBin(path, "raw", 4), as.raw(c(0x89, 0x50, 0x4e, 0x47)))
})
