# Phase 8: gradient strokes and dash phase. Both ride the stroke sub-record, so
# they inherit like any other stroke property, and both are absent by default.

grad <- function() linear_gradient(c("#F97316", "#22C55E"))

test_that("a gradient in col strokes with that gradient", {
  s <- vl_scene(4, 1, dpi = 150, bg = "white") |>
    draw(segments_grob(
      0.05,
      0.5,
      0.95,
      0.5,
      gp = vl_gpar(col = grad(), lwd = 20)
    ))
  r <- scene_raster(s)
  early <- r[1:3, 120, 75]
  late <- r[1:3, 480, 75]
  # Orange at the start, green at the end: red falls, green rises.
  expect_gt(early[1], late[1])
  expect_lt(early[2], late[2])
})

test_that("a plain colour still strokes exactly as before", {
  mk <- function(col) {
    vl_scene(2, 1, dpi = 100, bg = "white") |>
      draw(segments_grob(0.1, 0.5, 0.9, 0.5, gp = vl_gpar(col = col, lwd = 6)))
  }
  a <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache()
  render(mk("#F97316"), a)
  r <- scene_raster(mk("#F97316"))
  expect_equal(as.integer(r[1:3, 100, 50]), c(249L, 115L, 22L))
})

test_that("gradient strokes reach SVG and PDF as real paint", {
  s <- vl_scene(3, 1, dpi = 100) |>
    draw(lines_grob(
      c(0.1, 0.9),
      c(0.5, 0.5),
      gp = vl_gpar(col = grad(), lwd = 8)
    ))
  expect_match(scene_svg(s), "stroke=\"url(#", fixed = TRUE)
  f <- withr::local_tempfile(fileext = ".pdf")
  vl_clear_render_cache()
  expect_no_warning(render(s, f))
  expect_gt(file.size(f), 0)
})

test_that("a gradient stroke inherits from a viewport", {
  s <- vl_scene(4, 1, dpi = 150, bg = "white") |>
    push(vl_viewport(gp = vl_gpar(col = grad(), lwd = 20))) |>
    draw(segments_grob(0.05, 0.5, 0.95, 0.5)) |>
    pop()
  r <- scene_raster(s)
  expect_gt(r[1, 120, 75], r[1, 480, 75])
})

test_that("text falls back to the gradient's first stop", {
  # A glyph run has no path to run a ramp along, so it takes one flat colour
  # rather than silently not drawing.
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(text_grob("AAAA", gp = vl_gpar(col = grad(), fontsize = 40)))
  r <- scene_raster(s)
  # Some pixel must be near the first stop (#F97316), i.e. strongly orange.
  reds <- r[1, , ]
  greens <- r[2, , ]
  expect_true(any(reds > 200 & greens > 80 & greens < 160))
})

test_that("a gradient stroke ramps across a circle outline (not one flat stop)", {
  # The batched-circle fast path draws a unit circle placed by an affine
  # transform; a gradient stroke resolved in viewport px would collapse to a
  # single stop on it. A gradient col must instead ramp along the outline like
  # it does on rects and polylines.
  g <- linear_gradient(c("#F97316", "#22C55E"), x1 = 0, x2 = 1) # orange -> green
  s <- vl_scene(4, 4, dpi = 150, bg = "white") |>
    draw(circle_grob(r = 0.4, gp = vl_gpar(fill = NA, col = g, lwd = 20)))
  r <- scene_raster(s)
  # first inked pixel scanning outward from each side crossing, at mid-height
  ink_x <- function(from, to, y) {
    step <- if (to >= from) 1L else -1L
    for (x in seq(from, to, by = step)) {
      if (r[1, x, y] < 240 || r[2, x, y] < 240) {
        return(x)
      }
    }
    NA_integer_
  }
  west <- ink_x(35, 90, 300)
  east <- ink_x(565, 510, 300)
  # west of the ramp is orange (red high, green mid); east is green (red low).
  expect_gt(r[1, west, 300], r[1, east, 300]) # red falls west -> east
  expect_lt(r[2, west, 300], r[2, east, 300]) # green rises west -> east
})

test_that("a gradient-stroked circle reaches SVG as real paint, not a unit stamp", {
  g <- linear_gradient(c("#F97316", "#22C55E"), x1 = 0, x2 = 1)
  svg <- scene_svg(
    vl_scene(3, 3, dpi = 100) |>
      draw(circle_grob(r = 0.3, gp = vl_gpar(fill = NA, col = g, lwd = 8)))
  )
  # the outline references the gradient...
  expect_match(svg, "stroke=\"url(#", fixed = TRUE)
  # ...as a real-coordinate circle (r = 0.3 of 300px = 90px radius about the
  # centre 150, so its east point is at x = 240), not the unit-circle fast path
  # (which stamped a [-1, 1] path under a matrix() transform).
  expect_match(svg, "d=\"M240 150", fixed = TRUE)
  expect_no_match(svg, "matrix(", fixed = TRUE)
})

test_that("the per-segment stroke fast path is bypassed for a gradient", {
  # Each segment would restart the ramp; the shader must see the whole path.
  # A many-segment polyline with a gradient must still ramp end to end.
  n <- 60
  x <- seq(0.05, 0.95, length.out = n)
  s <- vl_scene(4, 1, dpi = 150, bg = "white") |>
    draw(lines_grob(x, rep(0.5, n), gp = vl_gpar(col = grad(), lwd = 20)))
  r <- scene_raster(s)
  expect_gt(r[1, 120, 75], r[1, 480, 75])
})

# --- dash phase --------------------------------------------------------------

dashed <- function(...) {
  vl_scene(4, 0.6, dpi = 100, bg = "white") |>
    draw(segments_grob(
      0.05,
      0.5,
      0.95,
      0.5,
      gp = vl_gpar(col = "black", lwd = 4, lty = "dashed", ...)
    ))
}

test_that("dash_phase shifts where the pattern starts", {
  a <- scene_raster(dashed())
  b <- scene_raster(dashed(dash_phase = 1.5))
  expect_false(identical(as.numeric(a), as.numeric(b)))
})

test_that("dash_phase defaults to no shift", {
  f1 <- withr::local_tempfile(fileext = ".png")
  f2 <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache()
  render(dashed(), f1)
  vl_clear_render_cache()
  render(dashed(dash_phase = 0), f2)
  expect_identical(tools::md5sum(f1)[[1]], tools::md5sum(f2)[[1]])
})

test_that("dash_phase reaches SVG as stroke-dashoffset", {
  expect_match(
    scene_svg(dashed(dash_phase = 2)),
    "stroke-dashoffset",
    fixed = TRUE
  )
  expect_false(grepl("stroke-dashoffset", scene_svg(dashed()), fixed = TRUE))
})

test_that("dash_phase is ignored on a solid line", {
  solid <- function(...) {
    vl_scene(2, 0.5, dpi = 100) |>
      draw(segments_grob(
        0.1,
        0.5,
        0.9,
        0.5,
        gp = vl_gpar(col = "black", lwd = 3, ...)
      ))
  }
  f1 <- withr::local_tempfile(fileext = ".png")
  f2 <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache()
  render(solid(), f1)
  vl_clear_render_cache()
  render(solid(dash_phase = 3), f2)
  expect_identical(tools::md5sum(f1)[[1]], tools::md5sum(f2)[[1]])
})

test_that("dash_phase scales with lwd, like the nibbles do", {
  # Same phase in lwd-multiples on two widths gives proportionally shifted
  # patterns rather than the same absolute offset.
  wide <- scene_raster(
    vl_scene(4, 0.6, dpi = 100, bg = "white") |>
      draw(segments_grob(
        0.05,
        0.5,
        0.95,
        0.5,
        gp = vl_gpar(col = "black", lwd = 8, lty = "dashed", dash_phase = 1)
      ))
  )
  narrow <- scene_raster(
    vl_scene(4, 0.6, dpi = 100, bg = "white") |>
      draw(segments_grob(
        0.05,
        0.5,
        0.95,
        0.5,
        gp = vl_gpar(col = "black", lwd = 2, lty = "dashed", dash_phase = 1)
      ))
  )
  expect_false(identical(as.numeric(wide), as.numeric(narrow)))
})

# --- per-element stroke style on segments_grob (Phase 8a) --------------------
# Mirrors the per-element `fill` that hexagon_grob()/sector_grob() carry. Absent
# by default, and the batch then draws in one combined stroke exactly as before.

seg_scene <- function(...) {
  n <- 6
  x <- seq(0.1, 0.9, length.out = n)
  vl_scene(4, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(
      x,
      0.2,
      x,
      0.8,
      gp = vl_gpar(col = "grey20", lwd = 4),
      ...
    ))
}

test_that("per-segment lwd varies the drawn width", {
  s <- seg_scene(lwd = c(1, 3, 5, 7, 9, 11))
  r <- scene_raster(s)
  col_at <- function(i) {
    x <- round(seq(0.1, 0.9, length.out = 6)[i] * dim(r)[2])
    sum(r[1, x, ] < 200)
  }
  # Thin first, thick last: the inked column height grows.
  expect_lt(col_at(1), col_at(6))
})

test_that("per-segment col varies the drawn colour", {
  s <- seg_scene(col = c("red", "red", "red", "blue", "blue", "blue"))
  r <- scene_raster(s)
  at <- function(i) {
    x <- round(seq(0.1, 0.9, length.out = 6)[i] * dim(r)[2])
    as.integer(r[1:3, x, 50])
  }
  expect_gt(at(1)[1], at(6)[1]) # red channel higher on the left
  expect_lt(at(1)[3], at(6)[3]) # blue channel higher on the right
})

test_that("absent per-element style is byte-identical to before", {
  a <- withr::local_tempfile(fileext = ".png")
  b <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache()
  render(seg_scene(), a)
  vl_clear_render_cache()
  render(seg_scene(col = NULL, lwd = NULL), b)
  expect_identical(tools::md5sum(a)[[1]], tools::md5sum(b)[[1]])
})

test_that("per-element style is recycled to the segment count", {
  expect_no_error(scene_raster(seg_scene(col = "red")))
  expect_no_error(scene_raster(seg_scene(lwd = 2)))
  expect_no_error(scene_raster(seg_scene(col = c("red", "blue"))))
})

test_that("one grob with per-element style matches many grobs without", {
  # The whole point: this replaces building one grob per segment.
  n <- 5
  x <- seq(0.1, 0.9, length.out = n)
  w <- c(2, 4, 6, 8, 10)
  one <- vl_scene(4, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(x, 0.2, x, 0.8, lwd = w, gp = vl_gpar(col = "black")))
  many <- vl_scene(4, 1, dpi = 100, bg = "white")
  for (i in seq_len(n)) {
    many <- draw(
      many,
      segments_grob(
        x[i],
        0.2,
        x[i],
        0.8,
        gp = vl_gpar(col = "black", lwd = w[i])
      )
    )
  }
  a <- withr::local_tempfile(fileext = ".png")
  b <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache()
  render(one, a)
  vl_clear_render_cache()
  render(many, b)
  expect_identical(tools::md5sum(a)[[1]], tools::md5sum(b)[[1]])
})

test_that("a per-segment NA colour draws nothing for that segment", {
  s <- seg_scene(col = c("black", NA, "black", NA, "black", NA))
  r <- scene_raster(s)
  at <- function(i) {
    x <- round(seq(0.1, 0.9, length.out = 6)[i] * dim(r)[2])
    sum(r[1, x, ] < 200)
  }
  expect_gt(at(1), 0)
  expect_equal(at(2), 0)
})

test_that("per-element style composes with keys and caps", {
  expect_no_error(scene_raster(seg_scene(
    col = c("red", "blue"),
    lwd = c(2, 6),
    key = paste0("k", 1:6)
  )))
  expect_no_error(scene_raster(seg_scene(
    lwd = 1:6,
    start_cap = vl_unit(1, "mm"),
    end_cap = vl_unit(1, "mm")
  )))
})
