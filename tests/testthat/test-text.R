test_that("rs_strwidth matches textshaping (fidelity) and scales", {
  ref <- textshaping::shape_text("Hello", size = 20)$metrics$width
  expect_equal(rs_strwidth("Hello", fontsize = 20, unit = "pt"), ref, tolerance = 1e-6)
  expect_equal(rs_strwidth("Hello", fontsize = 20, unit = "in"), ref / 72, tolerance = 1e-6)
  expect_gt(rs_strwidth("Hello", fontsize = 40), rs_strwidth("Hello", fontsize = 20))
  expect_gt(rs_strwidth("Hello", fontface = "bold"), 0)
})

test_that("empty or NA labels are a no-op", {
  s <- rs_scene(1, 1, dpi = 50)
  rs_text(s, "")
  rs_text(s, NA)
  rs_text(s, "   ") # whitespace shapes to space glyphs with no outline
  expect_equal(s$len(), 1L) # only the whitespace one adds a (blank) node
})

test_that("rs_text adds a node and paints ink, leaving the background intact", {
  s <- rs_scene(width = 2, height = 1, dpi = 100, bg = "white")
  rs_text(s, "ABC", x = 0.5, y = 0.5, fontsize = 40, col = "black")
  expect_equal(s$len(), 1L)
  r <- rs_raster(s) # dim c(4, w, h)
  expect_equal(dim(r), c(4L, 200L, 100L))
  expect_lt(min(r[1, , ]), 100L) # dark ink somewhere
  expect_equal(r[1:3, 1, 1], c(255L, 255L, 255L)) # corner still white
})

test_that("text colour reaches the raster", {
  s <- rs_scene(width = 2, height = 1, dpi = 100, bg = "white")
  rs_text(s, "ABC", fontsize = 40, col = "red")
  r <- rs_raster(s)
  green <- r[2, , ]
  idx <- which(green == min(green), arr.ind = TRUE)[1, ]
  px <- r[, idx[1], idx[2]]
  expect_gt(px[1], px[2]) # red dominates green
  expect_gt(px[1], px[3]) # red dominates blue
})

test_that("justification places text on the correct side of the anchor", {
  inked_x <- function(hjust) {
    s <- rs_scene(width = 3, height = 1, dpi = 100, bg = "white")
    rs_text(s, "WORD", x = 0.5, y = 0.5, hjust = hjust, fontsize = 30, col = "black")
    red <- rs_raster(s)[1, , ]
    which(apply(red, 1, min) < 100) # x columns containing ink
  }
  anchor_px <- 150 # x = 0.5 of a 300px-wide device
  expect_gt(mean(inked_x(0)), anchor_px) # left-justified -> ink right of anchor
  expect_lt(mean(inked_x(1)), anchor_px) # right-justified -> ink left of anchor
})
