# P3: segments + general path (winding / even-odd, holes).

px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

ring <- function(cx, cy, r, n = 64) {
  a <- seq(0, 2 * pi, length.out = n)
  list(x = cx + r * cos(a), y = cy + r * sin(a))
}

test_that("segments_grob draws each segment", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(
      x0 = c(0.1, 0.5), y0 = c(0.5, 0.1), x1 = c(0.9, 0.5), y1 = c(0.5, 0.9),
      gp = vl_gpar(col = "black", lwd = 3)
    ))
  expect_equal(px(s, 50, 50)[1:3], c(0L, 0L, 0L)) # both segments cross the centre
  expect_equal(px(s, 20, 80)[1:3], c(255L, 255L, 255L)) # empty corner
})

test_that("an even-odd path leaves a hole that winding fills", {
  o <- ring(0.5, 0.5, 0.4)
  i <- ring(0.5, 0.5, 0.18)
  donut <- function(rule) {
    vl_scene(1, 1, dpi = 100, bg = "white") |>
      draw(path_grob(c(o$x, i$x), c(o$y, i$y), id = rep(1:2, each = 64),
                     rule = rule, gp = vl_gpar(fill = "steelblue", col = NA)))
  }
  eo <- donut("evenodd")
  expect_equal(px(eo, 50, 12)[1:3], c(70L, 130L, 180L)) # on the ring: filled
  expect_equal(px(eo, 50, 50)[1:3], c(255L, 255L, 255L)) # centre: hole
  wn <- donut("winding")
  expect_equal(px(wn, 50, 50)[1:3], c(70L, 130L, 180L)) # centre: filled
})

test_that("a single-subpath path fills (no id)", {
  tri <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(path_grob(c(0.5, 0.1, 0.9), c(0.9, 0.1, 0.1), gp = vl_gpar(fill = "red", col = NA)))
  expect_equal(px(tri, 50, 40)[1:3], c(255L, 0L, 0L))
})

test_that("path strokes its outline with the vl_gpar col + lty", {
  o <- ring(0.5, 0.5, 0.4)
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(path_grob(o$x, o$y, gp = vl_gpar(fill = NA, col = "black", lwd = 3)))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 255L, 255L)) # unfilled interior
  expect_true(px(s, 50, 11)[1] < 128L) # stroked boundary near top of ring
})

test_that("SVG path emits fill-rule for even-odd; PDF renders", {
  o <- ring(0.5, 0.5, 0.4); i <- ring(0.5, 0.5, 0.18)
  s <- vl_scene(1, 1, dpi = 100) |>
    draw(path_grob(c(o$x, i$x), c(o$y, i$y), id = rep(1:2, each = 64),
                   rule = "evenodd", gp = vl_gpar(fill = "steelblue", col = NA)))
  fsvg <- withr::local_tempfile(fileext = ".svg")
  render(s, fsvg)
  expect_match(paste(readLines(fsvg, warn = FALSE), collapse = ""), 'fill-rule="evenodd"')
  fpdf <- withr::local_tempfile(fileext = ".pdf")
  expect_no_error(render(s, fpdf))
  expect_equal(rawToChar(readBin(fpdf, "raw", 5)), "%PDF-")
})

test_that("path_grob rejects an id of the wrong length", {
  expect_error(path_grob(c(0, 1, 1), c(0, 0, 1), id = c(1, 1)), "one value per point")
})

test_that("path_grob groups non-consecutive ids into one sub-path (grid-style)", {
  px <- function(s, x, y) .scene_to_backend(s)$pixel(x, y)
  ring <- function(r, n = 32) { a <- seq(0, 2 * pi, length.out = n); list(x = 0.5 + r * cos(a), y = 0.5 + r * sin(a)) }
  o <- ring(0.4); i <- ring(0.18)
  # interleave the outer ring around the inner ring; ids are non-consecutive
  xv <- c(o$x[1:16], i$x, o$x[17:32]); yv <- c(o$y[1:16], i$y, o$y[17:32])
  idv <- c(rep(1, 16), rep(2, 32), rep(1, 16))
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(path_grob(xv, yv, id = idv, rule = "evenodd", gp = vl_gpar(fill = "steelblue", col = NA)))
  expect_equal(px(s, 50, 12)[1:3], c(70L, 130L, 180L))   # ring filled
  expect_equal(px(s, 50, 50)[1:3], c(255L, 255L, 255L))  # hole (would fill if mis-grouped)
})
