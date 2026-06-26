test_that("rs_strwidth matches textshaping (fidelity) and scales", {
  ref <- textshaping::shape_text("Hello", size = 20)$metrics$width
  expect_equal(rs_strwidth("Hello", fontsize = 20, unit = "pt"), ref, tolerance = 1e-6)
  expect_equal(rs_strwidth("Hello", fontsize = 20, unit = "in"), ref / 72, tolerance = 1e-6)
  expect_gt(rs_strwidth("Hello", fontsize = 40), rs_strwidth("Hello", fontsize = 20))
  expect_gt(rs_strwidth("Hello", fontface = "bold"), 0)
})

test_that("empty or NA labels are a no-op", {
  # "" and NA shape to nothing; whitespace shapes to (blank) space glyphs and
  # still emits one node.
  s <- vl_scene(1, 1, dpi = 50) |>
    draw(text_grob("")) |>
    draw(text_grob(NA)) |>
    draw(text_grob("   "))
  expect_equal(scene_len(s), 1L)
})

test_that("a text grob adds a node and paints ink, leaving the background intact", {
  s <- vl_scene(width = 2, height = 1, dpi = 100, bg = "white") |>
    draw(text_grob("ABC", x = 0.5, y = 0.5, gp = gpar(fontsize = 40, col = "black")))
  expect_equal(scene_len(s), 1L)
  r <- scene_raster(s) # dim c(4, w, h)
  expect_equal(dim(r), c(4L, 200L, 100L))
  expect_lt(min(r[1, , ]), 100L) # dark ink somewhere
  expect_equal(r[1:3, 1, 1], c(255L, 255L, 255L)) # corner still white
})

test_that("text colour reaches the raster", {
  s <- vl_scene(width = 2, height = 1, dpi = 100, bg = "white") |>
    draw(text_grob("ABC", gp = gpar(fontsize = 40, col = "red")))
  r <- scene_raster(s)
  green <- r[2, , ]
  idx <- which(green == min(green), arr.ind = TRUE)[1, ]
  p <- r[, idx[1], idx[2]]
  expect_gt(p[1], p[2]) # red dominates green
  expect_gt(p[1], p[3]) # red dominates blue
})

test_that("the shape cache is transparent: cold and warm renders are identical", {
  clear <- function() rm(
    list = setdiff(ls(.shape_cache, all.names = TRUE), ".n"), envir = .shape_cache
  )
  scene <- function() {
    vl_scene(2, 1, dpi = 100, bg = "white") |>
      draw(text_grob(c("Ab", "Ab", "cD"), x = c(0.2, 0.5, 0.8), y = 0.5, gp = gpar(fontsize = 24)))
  }
  clear()
  cold <- scene_raster(scene()) # populates the cache (one shape per distinct label)
  warm <- scene_raster(scene()) # all cache hits
  expect_identical(cold, warm)
})

test_that("the shape cache keys on size (no cross-size collision)", {
  # Same string at two sizes must produce different ink widths -> the cache key
  # includes size (otherwise the second render would reuse the first's glyphs).
  ink_w <- function(sz) {
    red <- scene_raster(
      vl_scene(3, 1, dpi = 100, bg = "white") |>
        draw(text_grob("WW", x = 0.5, y = 0.5, gp = gpar(fontsize = sz, col = "black")))
    )[1, , ]
    cols <- which(apply(red, 1, min) < 100)
    if (length(cols)) diff(range(cols)) else 0
  }
  expect_gt(ink_w(40), ink_w(12))
})

test_that("justification places text on the correct side of the anchor", {
  inked_x <- function(hjust) {
    s <- vl_scene(width = 3, height = 1, dpi = 100, bg = "white") |>
      draw(text_grob("WORD", x = 0.5, y = 0.5, just = as.character(hjust),
                     gp = gpar(fontsize = 30, col = "black")))
    red <- scene_raster(s)[1, , ]
    which(apply(red, 1, min) < 100) # x columns containing ink
  }
  anchor_px <- 150 # x = 0.5 of a 300px-wide device
  expect_gt(mean(inked_x(0)), anchor_px) # left-justified -> ink right of anchor
  expect_lt(mean(inked_x(1)), anchor_px) # right-justified -> ink left of anchor
})
