# Feature D: `loop_grob()` draws a self-loop as an igraph-style cubic-Bézier
# **teardrop** (not a ring), sized in mm at a native anchor and resolved in device
# space — so it tracks an mm node at any figure size/dpi. See handover-2.
px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

# Rightmost inked column relative to the centre, on the centre row of a wxw page.
reach <- function(s, w) {
  cy <- as.integer(w / 2)
  hit <- which(vapply(1:(w - 1), function(x) px(s, x, cy)[1] < 128L, logical(1)))
  if (length(hit)) max(hit) - w / 2 else NA_integer_
}

test_that("a loop is a teardrop through the vertex, not a hollow ring", {
  s <- vl_scene(3, 3, dpi = 100, bg = "white") |>
    draw(loop_grob(0.5, 0.5, size = unit(20, "mm"), angle = 0,
                   gp = gpar(col = "black", lwd = 2)))
  # foot = 0 ⇒ both feet at the vertex, so the curve passes through it (a ring
  # would leave the centre empty). The teardrop bulges out along +x to ~0.3*size.
  expect_lt(px(s, 150, 150)[1], 128L) # vertex is inked (feet meet there)
  expect_equal(reach(s, 300), 0.3 * (20 / 25.4 * 100), tolerance = 0.1) # 0.3*size px
})

test_that("the teardrop is a fixed physical size (resolution independent)", {
  r1 <- reach(vl_scene(3, 3, dpi = 100, bg = "white") |>
    draw(loop_grob(0.5, 0.5, size = unit(20, "mm"), gp = gpar(col = "black", lwd = 2))), 300)
  r2 <- reach(vl_scene(3, 3, dpi = 200, bg = "white") |>
    draw(loop_grob(0.5, 0.5, size = unit(20, "mm"), gp = gpar(col = "black", lwd = 2))), 600)
  expect_equal(r2 / r1, 2, tolerance = 0.05) # twice the px at twice the dpi
})

test_that("angle rotates the loop's outward direction", {
  right <- vl_scene(3, 3, dpi = 100, bg = "white") |>
    draw(loop_grob(0.5, 0.5, size = unit(20, "mm"), angle = 0, gp = gpar(col = "black", lwd = 2)))
  left <- vl_scene(3, 3, dpi = 100, bg = "white") |>
    draw(loop_grob(0.5, 0.5, size = unit(20, "mm"), angle = pi, gp = gpar(col = "black", lwd = 2)))
  expect_gt(reach(right, 300), 15L) # bulges to the right (+x)
  expect_lte(reach(left, 300), 2L) # angle=pi bulges to the left, ~nothing right of centre
})

test_that("nested loops (growing size) give concentric teardrops", {
  small <- vl_scene(3, 3, dpi = 100, bg = "white") |>
    draw(loop_grob(0.5, 0.5, size = unit(15, "mm"), gp = gpar(col = "black", lwd = 2)))
  big <- vl_scene(3, 3, dpi = 100, bg = "white") |>
    draw(loop_grob(0.5, 0.5, size = unit(30, "mm"), gp = gpar(col = "black", lwd = 2)))
  expect_gt(reach(big, 300), reach(small, 300) + 10L)
})

test_that("a batch of loops draws each at its own anchor", {
  s <- vl_scene(3, 3, dpi = 100, bg = "white") |>
    draw(loop_grob(x = c(0.25, 0.75), y = c(0.5, 0.5), size = unit(12, "mm"),
                   gp = gpar(col = "black", lwd = 2)))
  # two vertices, at device x = 75 and 225, both on row y=150.
  expect_lt(px(s, 75, 150)[1], 128L)
  expect_lt(px(s, 225, 150)[1], 128L)
})

test_that("a directed loop puts an arrowhead near the returning foot", {
  mk <- function(arr, foot) vl_scene(3, 3, dpi = 100, bg = "white") |>
    draw(loop_grob(0.5, 0.5, size = unit(20, "mm"), foot = foot, angle = 0,
                   arrow = arr, gp = gpar(col = "black", lwd = 2)))
  bare <- mk(NULL, unit(0, "mm"))
  head <- mk(arrow(type = "closed", length = unit(6, "mm")), unit(0, "mm"))
  # The returning foot is near the vertex (150,150); the head adds ink around it.
  dark <- function(s) sum(vapply(seq(140, 168), function(x)
    sum(vapply(seq(136, 164), function(y) px(s, x, y)[1] < 128L, logical(1))), integer(1)))
  expect_gt(dark(head), dark(bare))
})

test_that("a positive foot lifts the feet off the vertex onto the boundary", {
  # foot = 8mm (~31px): the feet sit on the boundary, so the exact vertex pixel is
  # no longer on the curve (with foot = 0 it is).
  at_vertex <- function(foot) {
    s <- vl_scene(3, 3, dpi = 100, bg = "white") |>
      draw(loop_grob(0.5, 0.5, size = unit(20, "mm"), foot = foot, angle = 0,
                     gp = gpar(col = "black", lwd = 2)))
    px(s, 150, 150)[1] < 128L
  }
  expect_true(at_vertex(unit(0, "mm")))
  expect_false(at_vertex(unit(8, "mm")))
})

test_that("loop_grob requires absolute size/foot", {
  expect_error(loop_grob(0.5, 0.5, size = unit(0.2, "native")), "absolute")
  expect_error(loop_grob(0.5, 0.5, size = unit(-1, "mm")), "non-negative")
  g <- loop_grob(0.5, 0.5, size = 4) # bare numeric -> mm
  expect_true(S7::S7_inherits(g, grob_loop))
})
