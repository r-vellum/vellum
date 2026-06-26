# FW2: arrows (b) and curves (c).
px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

# 2x1in @ 100dpi = 200x100px; line y=0.5 -> device y=50, x 0.1..0.9 -> 20..180.
# An 8mm/30deg closed head at the right end fills roughly x in [153,180].
test_that("a closed arrowhead fills a triangle off the line; open does not", {
  closed <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(lines_grob(c(0.1, 0.9), c(0.5, 0.5),
      arrow = arrow(type = "closed", length = unit(8, "mm")), gp = gpar(col = "black", lwd = 2)
    ))
  open <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(lines_grob(c(0.1, 0.9), c(0.5, 0.5),
      arrow = arrow(type = "open", length = unit(8, "mm")), gp = gpar(col = "black", lwd = 2)
    ))
  # A point inside the head triangle, above the centre line.
  expect_lt(px(closed, 165, 44)[1], 128L) # closed: filled there
  expect_equal(px(open, 165, 44)[1:3], c(255L, 255L, 255L)) # open: empty there
})

test_that("arrow ends control which end gets a head", {
  head_dark <- function(ends, xq) {
    s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
      draw(lines_grob(c(0.1, 0.9), c(0.5, 0.5),
        arrow = arrow(type = "closed", ends = ends, length = unit(8, "mm")),
        gp = gpar(col = "black", lwd = 2)
      ))
    px(s, xq, 44)[1] < 128L # filled head ink above the line at xq
  }
  expect_true(head_dark("last", 165)) # head at the right
  expect_false(head_dark("last", 35)) # not at the left
  expect_true(head_dark("first", 35)) # head at the left
  expect_true(head_dark("both", 165) && head_dark("both", 35))
})

test_that("a Bezier bows away from the straight chord", {
  # Control points pull the curve up; its midpoint sits well above the chord.
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(bezier_grob(c(0.1, 0.5, 0.9), c(0.2, 0.9, 0.2), gp = gpar(col = "black", lwd = 3)))
  # On the chord line (y = 0.2 -> device y = 80) at the middle x: no ink (curve bowed up)
  expect_equal(px(s, 50, 80)[1:3], c(255L, 255L, 255L))
  # Above the chord, near the curve's apex, there is ink
  inked <- any(vapply(20:60, function(yy) px(s, 50, yy)[1] < 128L, logical(1)))
  expect_true(inked)
})

test_that("a smooth spline passes through its control points", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(spline_grob(c(0.2, 0.5, 0.8), c(0.5, 0.5, 0.5), gp = gpar(col = "black", lwd = 3)))
  expect_lt(px(s, 50, 50)[1], 128L) # ink along the (here straight) spline
  # curve/spline coords on one axis must share a unit
  expect_error(bezier_grob(unit(c(0, 1), c("npc", "native")), c(0, 1)), "single unit")
})
