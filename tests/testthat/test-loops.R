# Feature B (B2): resolution-independent self-loops. `loop_grob()` / an open-arc
# `sector_grob()` with an absolute (mm) radius at a "native" centre draws a loop
# whose size tracks a node's mm radius at any page size/dpi, with an optional
# arrowhead tangent to the arc end (directed loops). See the vellumplot handover.
px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

# Rightmost inked column on a given device row (radius probe along +x from centre).
last_ink_x <- function(s, y, w) {
  hit <- which(vapply(1:(w - 1), function(x) px(s, x, y)[1] < 128L, logical(1)))
  if (length(hit)) max(hit) else NA_integer_
}

test_that("a loop's mm radius is resolved at a native centre, resolution independent", {
  # square page; centre native (0.5,0.5) -> device (w/2, w/2); r = 20mm.
  radius_px <- function(dpi) {
    w <- as.integer(3 * dpi)
    s <- vl_scene(3, 3, dpi = dpi, bg = "white") |>
      draw(loop_grob(0.5, 0.5, r = unit(20, "mm"), theta0 = 0, theta1 = 2 * pi,
                     gp = gpar(col = "black", lwd = 2)))
    last_ink_x(s, as.integer(w / 2), w) - w / 2 # arc reaches centre + r along +x
  }
  r1 <- radius_px(100)
  r2 <- radius_px(200)
  expect_equal(r2 / r1, 2, tolerance = 0.03) # twice the px at twice the dpi
  expect_equal(r1 / 100 * 25.4, 20, tolerance = 1) # ~20mm physical
})

test_that("a loop is an open arc: its centre is empty (stroke only)", {
  s <- vl_scene(3, 3, dpi = 100, bg = "white") |>
    draw(loop_grob(0.5, 0.5, r = unit(20, "mm"), theta0 = 0, theta1 = 1.5 * pi,
                   gp = gpar(col = "black", lwd = 2)))
  expect_equal(px(s, 150, 150)[1:3], c(255L, 255L, 255L)) # hollow centre
})

test_that("a directed loop adds an arrowhead at the arc end", {
  mk <- function(arr) {
    vl_scene(3, 3, dpi = 100, bg = "white") |>
      draw(loop_grob(0.5, 0.5, r = unit(20, "mm"), theta0 = 0, theta1 = 1.5 * pi,
        arrow = arr, gp = gpar(col = "black", lwd = 2)))
  }
  bare <- mk(NULL)
  head <- mk(arrow(type = "closed", length = unit(6, "mm")))
  # The arc's theta1 = 1.5*pi end is at ~device (150, 150 - 20mm) = (150, ~71)
  # (local frame is y-down). Count dark px in a box around it: the arrowhead fills
  # extra ink the bare arc does not.
  dark <- function(s) sum(vapply(seq(118, 150), function(x)
    sum(vapply(seq(55, 90), function(y) px(s, x, y)[1] < 128L, logical(1))), integer(1)))
  expect_gt(dark(head), dark(bare))
})

test_that("sector_grob open arc + arrow is the underlying primitive", {
  # r0 == r1 (open arc), absolute mm radius, with an arrow: same as loop_grob.
  s <- vl_scene(3, 3, dpi = 100, bg = "white") |>
    draw(sector_grob(0.5, 0.5, r0 = unit(20, "mm"), r1 = unit(20, "mm"),
      theta0 = 0, theta1 = pi, arrow = arrow(type = "closed"),
      gp = gpar(col = "black", lwd = 2)))
  expect_equal(px(s, 150, 150)[1:3], c(255L, 255L, 255L)) # open (no fill)
  expect_lt(px(s, 228, 150)[1], 128L) # arc ink at radius +20mm (~79px) along +x
})

test_that("loop_grob requires an absolute radius", {
  expect_error(loop_grob(0.5, 0.5, r = unit(0.2, "native")), "absolute")
  expect_error(loop_grob(0.5, 0.5, r = unit(-1, "mm")), "non-negative")
  g <- loop_grob(0.5, 0.5, r = 3) # bare numeric -> mm
  expect_true(S7::S7_inherits(g, grob_sector))
})
