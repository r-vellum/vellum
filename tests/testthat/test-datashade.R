# PERF-5: aggregate-then-shade (datashader-style).

px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

test_that("rs_aggregate_2d counts points into the right cells (top-left origin)", {
  # weight 2 at bottom-left, weight 5 at top-right, on a 2x2 grid over [0,1]^2.
  g <- rs_aggregate_2d(c(0.1, 0.9), c(0.1, 0.9), c(2, 5), 2L, 2L, 0, 1, 0, 1)
  expect_equal(g, c(0, 5, 2, 0)) # row-major: TL, TR, BL, BR
})

test_that("rs_aggregate_2d counts (no weights) and skips out-of-range / NA", {
  g <- rs_aggregate_2d(c(0.5, 0.5, 0.5, 2, NA), c(0.5, 0.5, 0.5, 0.5, 0.5),
                       NULL, 1L, 1L, 0, 1, 0, 1)
  expect_equal(sum(g), 3) # three in-range points; the x=2 and NA are dropped
})

test_that("datashade returns a renderable raster grob", {
  set.seed(1)
  g <- datashade(rnorm(1e4), rnorm(1e4), width = 64, height = 48)
  expect_true(S7::S7_inherits(g, grob))
  expect_equal(g@iw, 64L)
  expect_equal(g@ih, 48L)
  f <- withr::local_tempfile(fileext = ".png")
  s <- vl_scene(2, 1.5, dpi = 100) |>
    push(viewport(xscale = c(-4, 4), yscale = c(-4, 4))) |>
    draw(g)
  expect_no_error(render(s, f))
})

test_that("a dense cluster shades while empty space stays transparent", {
  # All mass in one tight cluster near the centre of the data range.
  x <- c(rnorm(5000, 0, 0.01), -3, 3)
  y <- c(rnorm(5000, 0, 0.01), -3, 3)
  g <- datashade(x, y, width = 100, height = 100, xlim = c(-4, 4), ylim = c(-4, 4),
                 colors = c("#ffffff", "#000000"))
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    push(viewport(xscale = c(-4, 4), yscale = c(-4, 4))) |>
    draw(g)
  centre <- px(s, 100, 100)   # data (0,0) -> device centre: shaded (dark, high density)
  corner <- px(s, 100, 10)    # near top, away from the cluster: empty -> background
  expect_lt(centre[1], 200L)
  expect_equal(corner[1:3], c(255L, 255L, 255L))
})

test_that("the how mappings all produce a valid grob", {
  set.seed(2)
  x <- rnorm(2000); y <- rnorm(2000)
  for (h in c("eq_hist", "log", "cbrt", "linear")) {
    expect_no_error(datashade(x, y, width = 32, height = 32, how = h))
  }
})
