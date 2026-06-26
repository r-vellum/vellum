# FW6: grid -> vellum translation (render grid/ggplot through vellum).

test_that("as_vellum translates core grid grobs (with a viewport) faithfully", {
  g <- grid::gTree(children = grid::gList(
    grid::rectGrob(gp = grid::gpar(fill = "white", col = NA)),
    grid::rectGrob(x = 0.3, y = 0.7, width = 0.2, height = 0.2, gp = grid::gpar(fill = "red", col = NA)),
    grid::circleGrob(x = 0.7, y = 0.3, r = 0.12, gp = grid::gpar(fill = "blue", col = NA))
  ), vp = grid::viewport(width = 0.8, height = 0.8))
  s <- as_vellum(g, width = 4, height = 4, dpi = 100, bg = "white")
  px <- function(x, y) .scene_to_backend(s)$pixel(x, y)
  # the 0.8 vp maps page npc 0.1..0.9; child rect at vp-npc(0.3,0.7) -> page ~ (0.34, 0.66)
  expect_equal(px(round(0.34 * 400), round((1 - 0.66) * 400))[1:3], c(255L, 0L, 0L))
  expect_equal(px(round(0.66 * 400), round((1 - 0.34) * 400))[1:3], c(0L, 0L, 255L))
})

test_that("per-element (vector) gpar is split into per-style vellum grobs", {
  # three points, three colours -> three marker grobs, each a scalar colour.
  g <- grid::pointsGrob(c(0.25, 0.5, 0.75), c(0.5, 0.5, 0.5), pch = 19,
                        gp = grid::gpar(col = c("red", "green", "blue")))
  s <- as_vellum(g, width = 3, height = 1, dpi = 100, bg = "white")
  px <- function(x, y) .scene_to_backend(s)$pixel(x, y)
  expect_gt(px(75, 50)[1], 150L) # red point (x=0.25*300)
  expect_gt(px(150, 50)[2], 100L) # green point
  expect_gt(px(225, 50)[3], 150L) # blue point
})

test_that("near-equal continuous styles are not merged into one group", {
  # two points with sizes differing below format()'s precision must stay distinct
  # (exact grouping), so each keeps its own style.
  g <- grid::pointsGrob(c(0.3, 0.7), c(0.5, 0.5), pch = 19,
                        size = grid::unit(c(2, 2 + 1e-7), "mm"),
                        gp = grid::gpar(col = c("red", "blue")))
  s <- as_vellum(g, 3, 1, dpi = 100)
  expect_equal(length(s@bstate$build$kids), 2L) # two marker grobs, not one
})

test_that("pch 25 maps to a triangle (not the circle fallback)", {
  expect_equal(.gv_pch(25)$shape, "triangle")
  expect_false(.gv_pch(25)$fill) # 21-25 use gp$fill, not col-as-fill
})

test_that("a ggplot renders through vellum without error", {
  skip_if_not_installed("ggplot2")
  p <- ggplot2::ggplot(mtcars, ggplot2::aes(wt, mpg, colour = factor(cyl))) +
    ggplot2::geom_point() +
    ggplot2::geom_smooth(method = "lm", se = FALSE, formula = y ~ x)
  f <- withr::local_tempfile(fileext = ".png")
  expect_no_error(render_grid(p, f, width = 6, height = 4, dpi = 100))
  expect_gt(file.size(f), 0)
})
