# Feature A: absolute-length `start_cap`/`end_cap` on segments and lines. The cap
# shortens the drawn geometry inward by a physical (mm/in/pt) amount, resolved in
# device space at render, so an arrowhead can land on a node boundary rather than
# under it. See _docs handover in the sibling vellumplot repo.
px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

# Rightmost inked column on the centre row of a 2x1in @ dpi page (h/2 device y).
last_ink_x <- function(s, y, w) {
  hit <- which(vapply(1:(w - 1), function(x) px(s, x, y)[1] < 128L, logical(1)))
  if (length(hit)) max(hit) else NA_integer_
}
first_ink_x <- function(s, y, w) {
  hit <- which(vapply(1:(w - 1), function(x) px(s, x, y)[1] < 128L, logical(1)))
  if (length(hit)) min(hit) else NA_integer_
}

test_that("end_cap shortens a segment inward from its geometric end", {
  # 2x1in @ 100dpi = 200x100; native x 0.1..0.9 -> device 20..180, y=0.5 -> 50.
  base <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, gp = gpar(col = "black", lwd = 4)))
  capped <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, end_cap = unit(20, "mm"),
                       gp = gpar(col = "black", lwd = 4)))
  # Uncapped runs to ~180; a 20mm (=~79px) cap pulls the drawn end back to ~101.
  expect_gt(last_ink_x(base, 50, 200), 175L)
  expect_lt(last_ink_x(capped, 50, 200), 110L)
  expect_gt(last_ink_x(capped, 50, 200), 92L)
  # The start is untouched.
  expect_lt(first_ink_x(capped, 50, 200), 28L)
})

test_that("start_cap shortens a segment inward from its start", {
  capped <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, start_cap = unit(20, "mm"),
                       gp = gpar(col = "black", lwd = 4)))
  # start 20 -> ~99; end untouched at ~180.
  expect_gt(first_ink_x(capped, 50, 200), 90L)
  expect_lt(first_ink_x(capped, 50, 200), 108L)
  expect_gt(last_ink_x(capped, 50, 200), 175L)
})

test_that("the cap gap is an absolute physical length (resolution independent)", {
  # Same 20mm cap at 100 and 200 dpi. The gap from the geometric end to the drawn
  # end must be the same physical size, i.e. twice the pixels at twice the dpi.
  cap_at <- function(dpi) {
    w <- as.integer(2 * dpi)
    s <- vl_scene(2, 1, dpi = dpi, bg = "white") |>
      draw(segments_grob(0.1, 0.5, 0.9, 0.5, end_cap = unit(20, "mm"),
                         gp = gpar(col = "black", lwd = 4)))
    geom_end <- 0.9 * w # native 0.9 -> device px
    geom_end - last_ink_x(s, as.integer(dpi / 2), w) # gap in px
  }
  g1 <- cap_at(100)
  g2 <- cap_at(200)
  # 20mm = 78.7px @100dpi, 157.5px @200dpi. Ratio ~2 (allow AA slack).
  expect_equal(g2 / g1, 2, tolerance = 0.05)
  expect_equal(g1 / 100 * 25.4, 20, tolerance = 1.5) # ~20mm physical
})

test_that("an arrowhead lands on the capped end, not the geometric end", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5,
      arrow = arrow(type = "closed", length = unit(6, "mm")),
      end_cap = unit(20, "mm"), gp = gpar(col = "black", lwd = 3)
    ))
  # Closed head: a filled triangle whose tip sits at the capped end (~x=101) and
  # widens backward along the edge. A point ~13px back and above the line is
  # inside it; the geometric end (~x=180) has no ink at all.
  expect_lt(px(s, 88, 46)[1], 128L) # ink inside the head at the capped end
  expect_equal(px(s, 178, 50)[1:3], c(255L, 255L, 255L)) # nothing at the geom end
  expect_equal(px(s, 178, 44)[1:3], c(255L, 255L, 255L))
})

test_that("per-element caps shorten each segment independently", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(
      x0 = c(0.1, 0.1), y0 = c(0.3, 0.7), x1 = c(0.9, 0.9), y1 = c(0.3, 0.7),
      end_cap = unit(c(0, 40), "mm"), gp = gpar(col = "black", lwd = 4)
    ))
  # y=0.3 -> device 70 (no cap, runs to ~180); y=0.7 -> device 30 (40mm cap ~157px
  # -> drawn end ~23, i.e. almost nothing beyond the start).
  expect_gt(last_ink_x(s, 70, 200), 175L)
  expect_lt(last_ink_x(s, 30, 200), 60L)
})

test_that("degenerate caps do not error and draw nothing beyond bounds", {
  # A cap longer than the segment consumes it entirely (no ink), no error.
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, end_cap = unit(500, "mm"),
                       gp = gpar(col = "black", lwd = 4)))
  expect_true(is.na(last_ink_x(s, 50, 200)))
  # A zero-length segment with a cap: skipped, no divide-by-zero.
  s2 <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.5, 0.5, 0.5, 0.5, end_cap = unit(5, "mm"),
                       gp = gpar(col = "black", lwd = 4)))
  expect_true(is.na(last_ink_x(s2, 50, 200)))
})

test_that("NULL caps render byte-for-byte like no caps at all", {
  a <- scene_raster(vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5,
      arrow = arrow(type = "closed"), gp = gpar(col = "black", lwd = 3))))
  b <- scene_raster(vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5,
      arrow = arrow(type = "closed"), start_cap = NULL, end_cap = NULL,
      gp = gpar(col = "black", lwd = 3))))
  expect_identical(a, b)
})

test_that("lines_grob caps trim the whole-path ends", {
  capped <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(lines_grob(c(0.1, 0.5, 0.9), c(0.5, 0.5, 0.5), end_cap = unit(20, "mm"),
                    gp = gpar(col = "black", lwd = 4)))
  expect_lt(last_ink_x(capped, 50, 200), 110L)
  expect_lt(first_ink_x(capped, 50, 200), 28L) # start untouched
})

test_that("caps validate: absolute units only, non-negative, numeric = mm", {
  # native/npc caps are rejected (not resolvable to a device length up front).
  expect_error(segments_grob(0, 0, 1, 1, end_cap = unit(0.1, "native")), "absolute")
  expect_error(segments_grob(0, 0, 1, 1, start_cap = unit(0.1, "npc")), "absolute")
  # negative is an error.
  expect_error(segments_grob(0, 0, 1, 1, end_cap = unit(-2, "mm")), "non-negative")
  # a bare numeric cap is taken as mm (no error, builds a grob).
  g <- segments_grob(0, 0, 1, 1, end_cap = 5)
  expect_s3_class(g@end_cap, "vellum_unit")
  # a length-n cap on a single line (whole-path) is rejected.
  expect_error(lines_grob(c(0, 1), c(0, 1), end_cap = unit(c(1, 2), "mm")), "single value")
})
