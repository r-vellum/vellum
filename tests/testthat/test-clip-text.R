# P5: text vectorisation + arbitrary path clipping.

px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

test_that("a multi-label text grob draws each label at its position", {
  s <- vl_scene(3, 1, dpi = 100, bg = "white") |>
    draw(text_grob(c("AAA", "BBB", "CCC"), x = c(0.2, 0.5, 0.8), y = 0.5,
                   gp = gpar(fontsize = 20, col = "black")))
  near <- function(cx) any(vapply(seq(cx - 12, cx + 12), function(xx) px(s, xx, 50)[1] < 128L, logical(1)))
  expect_true(near(60))  # "AAA" around x=0.2*300
  expect_true(near(150)) # "BBB"
  expect_true(near(240)) # "CCC"
})

test_that("text recycles a scalar position across labels", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(text_grob(c("X", "Y"), x = 0.5, y = c(0.3, 0.7), gp = gpar(fontsize = 20)))
  expect_no_error(.scene_to_backend(s)$pixel(1, 1))
})

test_that("a polygon clip restricts drawing to the polygon", {
  tri <- polygon_grob(x = c(0.5, 0.1, 0.9), y = c(0.9, 0.1, 0.1))
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(viewport(clip = tri)) |>
    draw(rect_grob(gp = gpar(fill = "blue", col = NA))) |>
    pop()
  expect_equal(px(s, 50, 40)[1:3], c(0L, 0L, 255L))   # inside triangle
  expect_equal(px(s, 10, 90)[1:3], c(255L, 255L, 255L)) # outside (top-left corner)
})

test_that("an even-odd path clip leaves a hole", {
  ring <- function(r, n = 48) {
    a <- seq(0, 2 * pi, length.out = n)
    list(x = 0.5 + r * cos(a), y = 0.5 + r * sin(a))
  }
  o <- ring(0.45); i <- ring(0.2)
  clip <- path_grob(c(o$x, i$x), c(o$y, i$y), id = rep(1:2, each = 48), rule = "evenodd")
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(viewport(clip = clip)) |>
    draw(rect_grob(gp = gpar(fill = "blue", col = NA))) |>
    pop()
  expect_equal(px(s, 50, 12)[1:3], c(0L, 0L, 255L))    # on the ring band
  expect_equal(px(s, 50, 50)[1:3], c(255L, 255L, 255L)) # centre hole clipped out
})

test_that("rectangular clip still works (regression)", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(viewport(width = 0.4, height = 0.4, clip = TRUE)) |>
    draw(rect_grob(gp = gpar(fill = "red", col = NA))) |>
    pop()
  expect_equal(px(s, 50, 50)[1:3], c(255L, 0L, 0L))   # centre, inside viewport
  expect_equal(px(s, 5, 5)[1:3], c(255L, 255L, 255L)) # outside the clipped viewport
})

test_that("SVG emits a clipPath for a polygon clip; PDF renders", {
  tri <- polygon_grob(x = c(0.5, 0.1, 0.9), y = c(0.9, 0.1, 0.1))
  s <- vl_scene(1, 1, dpi = 100) |>
    push(viewport(clip = tri)) |>
    draw(rect_grob(gp = gpar(fill = "blue", col = NA))) |>
    pop()
  fsvg <- withr::local_tempfile(fileext = ".svg")
  render(s, fsvg)
  expect_match(paste(readLines(fsvg, warn = FALSE), collapse = ""), "<clipPath")
  fpdf <- withr::local_tempfile(fileext = ".pdf")
  expect_no_error(render(s, fpdf))
  expect_equal(rawToChar(readBin(fpdf, "raw", 5)), "%PDF-")
})

test_that("an unsupported clip grob errors clearly", {
  s <- vl_scene(1, 1) |> push(viewport(clip = circle_grob(r = 0.4))) |> draw(rect_grob())
  expect_error(.scene_to_backend(s), "polygon_grob")
})
