# Feature C: `offset =` on segments/lines — a per-element perpendicular shift in
# absolute units, applied at render in device space (so parallel edges keep a fixed
# physical spacing that tracks mm nodes at any figure size). See handover-2.
px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

# Inked rows in a vertical scan of one device column (which y's the segment covers).
inked_rows <- function(s, x, h) {
  which(vapply(1:(h - 1), function(y) px(s, x, y)[1] < 128L, logical(1)))
}

test_that("offset shifts a segment perpendicular; sign picks the side", {
  # 2x1in @ 100dpi = 200x100; horizontal segment native y=0.5 -> device y=50.
  # +10mm (~39px): left normal of a +x segment is (0,1) in y-down -> shifts down.
  pos <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, offset = unit(10, "mm"), gp = gpar(col = "black", lwd = 4)))
  neg <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, offset = unit(-10, "mm"), gp = gpar(col = "black", lwd = 4)))
  expect_equal(px(pos, 100, 50)[1:3], c(255L, 255L, 255L)) # vacated the original line
  expect_lt(px(pos, 100, 89)[1], 128L) # +offset ~39px below
  expect_lt(px(neg, 100, 11)[1], 128L) # -offset ~39px above
})

test_that("the offset is an absolute physical distance (resolution independent)", {
  # centre of the shifted band, measured from the geometric line, doubles at 2x dpi.
  band_mid <- function(dpi) {
    h <- as.integer(dpi)
    s <- vl_scene(2, 1, dpi = dpi, bg = "white") |>
      draw(segments_grob(0.1, 0.5, 0.9, 0.5, offset = unit(10, "mm"), gp = gpar(col = "black", lwd = 3)))
    rows <- inked_rows(s, as.integer(dpi), h) # column at device x = dpi (native ~0.5)
    mean(rows) - h / 2 # px from the geometric line (device y = h/2)
  }
  d1 <- band_mid(100)
  d2 <- band_mid(200)
  expect_equal(d2 / d1, 2, tolerance = 0.05)
  expect_equal(d1 / 100 * 25.4, 10, tolerance = 1) # ~10mm physical
})

test_that("per-element offset shifts each segment by its own amount", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(
      x0 = c(0.1, 0.1), y0 = c(0.5, 0.5), x1 = c(0.9, 0.9), y1 = c(0.5, 0.5),
      offset = unit(c(-10, 10), "mm"), gp = gpar(col = "black", lwd = 4)
    ))
  rows <- inked_rows(s, 100, 100)
  expect_true(any(rows < 20)) # one shifted up (~y=11)
  expect_true(any(rows > 80)) # one shifted down (~y=89)
  expect_false(any(rows > 40 & rows < 60)) # nothing left on the original line
})

test_that("offset composes with caps and arrow (offset, then cap, then head)", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, offset = unit(10, "mm"),
      end_cap = unit(20, "mm"), arrow = arrow(type = "closed", length = unit(6, "mm")),
      gp = gpar(col = "black", lwd = 3)))
  # The whole segment sits on the shifted line (~y=89), capped ~x=101; nothing on
  # the original line, and nothing past the capped end on the shifted line.
  expect_lt(px(s, 60, 89)[1], 128L) # drawn on the shifted line
  expect_equal(px(s, 100, 50)[1:3], c(255L, 255L, 255L)) # not on the original line
  expect_equal(px(s, 150, 89)[1:3], c(255L, 255L, 255L)) # capped short of the end
})

test_that("NULL/absent offset renders byte-for-byte like before", {
  a <- scene_raster(vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, gp = gpar(col = "black", lwd = 3))))
  b <- scene_raster(vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, offset = NULL, gp = gpar(col = "black", lwd = 3))))
  expect_identical(a, b)
})

test_that("lines_grob offset rigidly translates the whole polyline", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(lines_grob(c(0.1, 0.5, 0.9), c(0.5, 0.5, 0.5), offset = unit(10, "mm"),
                    gp = gpar(col = "black", lwd = 4)))
  expect_equal(px(s, 100, 50)[1:3], c(255L, 255L, 255L)) # moved off the original line
  expect_lt(px(s, 100, 89)[1], 128L) # onto the shifted line
})

test_that("offset validates: absolute units only, negatives allowed, numeric = mm", {
  expect_error(segments_grob(0, 0, 1, 1, offset = unit(0.1, "native")), "absolute")
  expect_error(segments_grob(0, 0, 1, 1, offset = unit(0.1, "npc")), "absolute")
  expect_s3_class(segments_grob(0, 0, 1, 1, offset = unit(-3, "mm"))@offset, "vellum_unit") # signed OK
  expect_s3_class(segments_grob(0, 0, 1, 1, offset = 3)@offset, "vellum_unit") # bare numeric -> mm
  expect_error(lines_grob(c(0, 1), c(0, 1), offset = unit(c(1, 2), "mm")), "single value")
})
