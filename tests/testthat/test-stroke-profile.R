# Variable-width stroke expansion: `stroke_to_path(lwd_profile =)`. The generator
# lives in src/rust/src/ribbon.rs and has its own unit tests; these exercise the
# R surface, the two parameterisations, and the wiring.

zig <- function(lwd = 12) {
  lines_grob(
    c(0.1, 0.35, 0.6, 0.9),
    c(0.2, 0.8, 0.2, 0.8),
    gp = vl_gpar(col = "black", lwd = lwd)
  )
}

bar <- function(lwd = 20, y = 0.5) {
  lines_grob(c(0.05, 0.95), c(y, y), gp = vl_gpar(col = "black", lwd = lwd))
}

filled <- function(o) S7::set_props(o, gp = vl_gpar(fill = "black", col = NA))

outline <- function(g, ..., w = 3, h = 2) {
  stroke_to_path(g, width = w, height = h, ...)
}

# Fraction of dark pixels in the whole scene.
ink <- function(o, w = 3, h = 2) {
  vl_clear_render_cache()
  r <- scene_raster(vl_scene(w, h, dpi = 100, bg = "white") |> draw(filled(o)))
  mean(r[1, , ] < 250)
}

# Dark pixels in one column, addressed as a fraction of the width.
darkcol <- function(o, frac, w = 3, h = 2) {
  vl_clear_render_cache()
  r <- scene_raster(vl_scene(w, h, dpi = 100, bg = "white") |> draw(filled(o)))
  col <- max(1L, min(dim(r)[2], round(frac * dim(r)[2])))
  sum(r[1, col, ] < 250)
}

npoints <- function(o) length(vctrs::field(o@x, "value"))

test_that("an absent profile leaves the expansion untouched", {
  # The byte-identity gate: no profile must take the old kernel, unchanged. This
  # asserts it on the coordinates rather than on a picture.
  a <- outline(zig())
  b <- outline(zig(), lwd_profile = NULL)
  expect_identical(vctrs::field(a@x, "value"), vctrs::field(b@x, "value"))
  expect_identical(vctrs::field(a@y, "value"), vctrs::field(b@y, "value"))
  expect_identical(a@nper, b@nper)
})

test_that("a constant profile reproduces the plain expansion", {
  # Not expect_identical: a profile routes through vellum's own offsetter rather
  # than tiny-skia's stroker, so the two agree as pictures, not as bytes.
  expect_equal(
    ink(outline(zig(), lwd_profile = 1)),
    ink(outline(zig())),
    tolerance = 0.02
  )
})

test_that("a length-1 profile just scales the width", {
  expect_equal(
    ink(outline(zig(24), lwd_profile = 0.5)),
    ink(outline(zig(12), lwd_profile = 1)),
    tolerance = 0.02
  )
})

test_that("a tapered ribbon inks less than a constant one", {
  full <- ink(outline(bar(), lwd_profile = 1))
  half <- ink(outline(bar(), lwd_profile = c(1, 0.5)))
  tip <- ink(outline(bar(), lwd_profile = c(1, 0)))
  expect_gt(tip, 0)
  expect_lt(tip, half)
  expect_lt(half, full)
})

test_that("the profile is oriented along the line", {
  thin_end <- outline(bar(), lwd_profile = c(1, 0.1))
  thin_start <- outline(bar(), lwd_profile = c(0.1, 1))
  expect_gt(darkcol(thin_end, 0.1), darkcol(thin_end, 0.9))
  expect_lt(darkcol(thin_start, 0.1), darkcol(thin_start, 0.9))
})

test_that("per-vertex and arc-length coincide on evenly spaced vertices", {
  g <- lines_grob(
    c(0.1, 0.36667, 0.63333, 0.9),
    c(0.5, 0.5, 0.5, 0.5),
    gp = vl_gpar(col = "black", lwd = 20)
  )
  p <- c(1, 0.4, 1, 0.4)
  expect_equal(
    ink(outline(g, lwd_profile = p, along = "vertex")),
    ink(outline(g, lwd_profile = p, along = "arclength")),
    tolerance = 0.02
  )
})

test_that("per-vertex and arc-length differ when vertices are not evenly spaced", {
  g <- lines_grob(
    c(0.05, 0.12, 0.2, 0.95),
    c(0.5, 0.5, 0.5, 0.5),
    gp = vl_gpar(col = "black", lwd = 20)
  )
  p <- c(1, 0.2, 1, 0.2)
  v <- outline(g, lwd_profile = p, along = "vertex")
  a <- outline(g, lwd_profile = p, along = "arclength")
  # Total ink can coincide; *where* the width sits is what differs. The three
  # crowded vertices put the profile's dips in the first fifth of the line under
  # `"vertex"`, while `"arclength"` spreads them over the whole length -- so at
  # a third of the way along, one is near its minimum and the other is not.
  expect_gt(darkcol(v, 0.35), 2 * darkcol(a, 0.35))
})

test_that("an arc-length profile needs no relation to the vertex count", {
  for (k in c(2L, 3L, 7L)) {
    o <- outline(zig(), lwd_profile = seq(1, 0.2, length.out = k))
    expect_gt(ink(o), 0)
  }
  # A fine profile is not thrown away on a coarse polyline: the outline gains
  # stations it did not have. It has to be a profile a straight interpolation
  # cannot reproduce -- a 50-point linear ramp *is* its own two-point form.
  wavy <- 0.6 + 0.4 * sin(seq(0, 6 * pi, length.out = 50))
  coarse <- outline(zig(), lwd_profile = wavy[c(1L, 50L)])
  fine <- outline(zig(), lwd_profile = wavy)
  expect_gt(npoints(fine), npoints(coarse))
  expect_false(isTRUE(all.equal(ink(fine), ink(coarse), tolerance = 0.01)))
})

test_that("a zero end tapers to a point rather than erroring", {
  o <- expect_no_error(outline(bar(), lwd_profile = c(1, 0)))
  expect_gt(darkcol(o, 0.1), 0)
  expect_identical(darkcol(o, 0.97), 0L)
})

test_that("an interior zero splits the stroke in two", {
  o <- outline(bar(), lwd_profile = c(1, 0, 1))
  expect_gte(length(o@nper), 2L)
  expect_gt(darkcol(o, 0.1), 0)
  expect_gt(darkcol(o, 0.9), 0)
})

test_that("a closed ring's profile wraps", {
  ring <- function(rot = 0L) {
    x <- c(0.25, 0.75, 0.75, 0.25)
    y <- c(0.25, 0.25, 0.75, 0.75)
    if (rot) {
      i <- c(seq.int(rot + 1L, 4L), seq_len(rot))
      x <- x[i]
      y <- y[i]
    }
    polygon_grob(x, y, gp = vl_gpar(col = "black", lwd = 10))
  }
  a <- outline(ring(0L), lwd_profile = c(1, 0.3))
  b <- outline(ring(1L), lwd_profile = c(1, 0.3))
  # A cyclic profile is a function of arc-length position, so rotating the input
  # order moves the pattern round the ring without changing how much it inks.
  expect_equal(ink(a), ink(b), tolerance = 0.03)
  expect_false(isTRUE(all.equal(
    vctrs::field(a@x, "value"),
    vctrs::field(b@x, "value")
  )))
})

test_that("a multi-sub-path path_grob tapers each sub-path", {
  p <- path_grob(
    c(0.1, 0.9, 0.1, 0.9),
    c(0.3, 0.3, 0.7, 0.7),
    id = c(1, 1, 2, 2),
    gp = vl_gpar(col = "black", lwd = 14)
  )
  flat <- ink(outline(p, lwd_profile = 1))
  tapered <- ink(outline(p, lwd_profile = c(1, 0)))
  expect_gt(tapered, 0)
  expect_lt(tapered, flat)
  # `along = "vertex"` wants one value per point across all sub-paths.
  expect_no_error(outline(p, lwd_profile = rep(c(1, 0.5), 2), along = "vertex"))
  expect_error(
    outline(p, lwd_profile = c(1, 0.5), along = "vertex"),
    "one value per vertex"
  )
})

test_that("a tapered outline is still an absolute-mm winding path", {
  o <- outline(zig(), lwd_profile = c(1, 0.2))
  expect_true(S7::S7_inherits(o, grob_path))
  expect_true(all(vctrs::field(o@x, "unit") == .unit_codes[["mm"]]))
  expect_identical(o@rule, "winding")
})

test_that("the gp override supplies the lwd the profile multiplies", {
  a <- outline(zig(2), gp = vl_gpar(lwd = 24), lwd_profile = 0.5)
  b <- outline(zig(12), lwd_profile = 1)
  expect_equal(ink(a), ink(b), tolerance = 0.02)
})

test_that("stroke_to_path rejects an unusable profile", {
  expect_error(outline(zig(), lwd_profile = "a"), "numeric")
  expect_error(outline(zig(), lwd_profile = numeric(0)), "numeric")
  expect_error(outline(zig(), lwd_profile = c(1, NA)), "missing")
  expect_error(outline(zig(), lwd_profile = c(1, Inf)), "missing|finite")
  expect_error(outline(zig(), lwd_profile = c(1, -0.5)), ">= 0")
  expect_error(outline(zig(), lwd_profile = c(0, 0)), "greater than zero")
  expect_error(
    outline(zig(), lwd_profile = c(1, 0.5, 0.2), along = "vertex"),
    "one value per vertex"
  )
  expect_error(outline(zig(), lwd_profile = 1, along = "bogus"))
})

test_that("a tapered outline renders on all three backends", {
  o <- filled(outline(zig(), lwd_profile = c(0.15, 1, 0.15)))
  for (ext in c("png", "svg", "pdf")) {
    f <- withr::local_tempfile(fileext = paste0(".", ext))
    render(vl_scene(3, 2, dpi = 100, bg = "white") |> draw(o), f)
    expect_gt(file.size(f), 0)
  }
})
