# Phase 12: boolean path operations, contours, SVG path import.

# Signed-area magnitude of a set of rings, summed. Rings wound opposite (holes)
# subtract, which is exactly what makes this a good test of a boolean result.
ring_area <- function(x, y, nper) {
  at <- 0L
  total <- 0
  for (len in nper) {
    i <- at + seq_len(len)
    j <- at + c(seq_len(len)[-1], 1L)
    total <- total + sum(x[i] * y[j] - x[j] * y[i]) / 2
    at <- at + len
  }
  abs(total)
}
grob_area <- function(g) {
  ring_area(as.numeric(vctrs::field(g@x, "value")),
            as.numeric(vctrs::field(g@y, "value")),
            as.integer(g@nper %||% length(g@x)))
}
sq <- function(x0, y0, s = 1) {
  list(x = c(x0, x0 + s, x0 + s, x0), y = c(y0, y0, y0 + s, y0 + s))
}

test_that("boolean operations produce the right areas", {
  # Two unit squares overlapping in a 0.5 x 1 strip.
  a <- sq(0, 0)
  b <- sq(0.5, 0)
  expect_equal(grob_area(vl_path_op(a, b, "union")), 1.5, tolerance = 1e-9)
  expect_equal(grob_area(vl_path_op(a, b, "intersect")), 0.5, tolerance = 1e-9)
  expect_equal(grob_area(vl_path_op(a, b, "difference")), 0.5, tolerance = 1e-9)
  expect_equal(grob_area(vl_path_op(a, b, "xor")), 1.0, tolerance = 1e-9)
})

test_that("difference is not symmetric, union and intersection are", {
  a <- sq(0, 0)
  b <- sq(0.5, 0, s = 2)
  expect_equal(grob_area(vl_path_op(a, b, "difference")), 0.5, tolerance = 1e-9)
  expect_equal(grob_area(vl_path_op(b, a, "difference")), 3.5, tolerance = 1e-9)
  expect_equal(grob_area(vl_path_op(a, b, "union")),
               grob_area(vl_path_op(b, a, "union")), tolerance = 1e-9)
  expect_equal(grob_area(vl_path_op(a, b, "intersect")),
               grob_area(vl_path_op(b, a, "intersect")), tolerance = 1e-9)
})

test_that("cutting a hole gives an outer ring and a hole", {
  outer_sq <- sq(0, 0, 4)
  inner_sq <- sq(1, 1, 2)
  g <- vl_path_op(outer_sq, inner_sq, "difference")
  expect_length(g@nper, 2L)
  # The signed areas cancel to the annulus, which is what proves the hole is
  # wound the opposite way rather than being a second solid island.
  expect_equal(grob_area(g), 16 - 4, tolerance = 1e-9)
})

test_that("disjoint shapes union to two rings and intersect to nothing", {
  a <- sq(0, 0)
  b <- sq(5, 0)
  expect_length(vl_path_op(a, b, "union")@nper, 2L)
  empty <- vl_path_op(a, b, "intersect")
  expect_length(empty@x, 0L)
  # And an empty result is drawable -- it just draws nothing.
  s <- vl_scene(2, 1, dpi = 96, bg = "white") |>
    draw(empty)
  expect_gt(length(scene_png(s)), 50)
})

test_that("booleans accept grobs as well as lists, and compose", {
  a <- polygon_grob(sq(0, 0)$x, sq(0, 0)$y)
  b <- polygon_grob(sq(0.5, 0)$x, sq(0.5, 0)$y)
  u <- vl_path_op(a, b, "union")
  expect_equal(grob_area(u), 1.5, tolerance = 1e-9)
  # The result is an ordinary path, so it can be an operand again -- the point
  # of producing geometry rather than a mask.
  again <- vl_path_op(u, sq(0, 0), "difference")
  expect_equal(grob_area(again), 0.5, tolerance = 1e-9)
})

test_that("mixed or offset units are refused with a reason", {
  a <- list(x = vl_unit(c(0, 1, 1, 0), c("npc", "npc", "mm", "npc")),
            y = vl_unit(c(0, 0, 1, 1)))
  expect_error(vl_path_op(a, sq(0, 0), "union"), "single, offset-free unit")
  b <- list(x = vl_unit(c(0, 1, 1, 0)) + vl_unit(1, "mm"),
            y = vl_unit(c(0, 0, 1, 1)))
  expect_error(vl_path_op(b, sq(0, 0), "union"), "single, offset-free unit")
  expect_error(vl_path_op(42, sq(0, 0), "union"), "closed rings")
})

test_that("the fill rule changes how nested input rings are read", {
  # An outer ring with an inner ring wound the same way. Under even-odd the
  # inner one is a hole; under non-zero it is filled over.
  rings <- list(x = c(sq(0, 0, 4)$x, sq(1, 1, 2)$x),
                y = c(sq(0, 0, 4)$y, sq(1, 1, 2)$y),
                nper = c(4L, 4L))
  far <- sq(20, 20)
  eo <- vl_path_op(rings, far, "difference", rule = "evenodd")
  nz <- vl_path_op(rings, far, "difference", rule = "nonzero")
  expect_equal(grob_area(eo), 12, tolerance = 1e-9) # the hole is a hole
  expect_equal(grob_area(nz), 16, tolerance = 1e-9) # the hole is filled over
})

# --- contours ----------------------------------------------------------------

bump <- function(n = 60, span = 3) {
  s <- seq(-span, span, length.out = n)
  outer(s, s, function(a, b) exp(-(a^2 + b^2) / 2))
}

test_that("the matrix convention matches base R: rows are x, columns are y", {
  # Regression. `vl_contour()` assumed rows were y, so every contour came back
  # reflected across the diagonal -- and the docs cited `image()` as the
  # authority for the opposite of what `image()` does.
  #
  # It survived because every other test here uses a grid that is SYMMETRIC in
  # its two arguments, where a transpose changes nothing. This one is
  # deliberately asymmetric, and is checked against base R rather than against
  # our own expectation.
  gs <- seq(-4, 4, length.out = 121)
  z <- outer(gs, gs, function(x, y) exp(-((x - 2)^2 + (y + 1)^2) / 0.5))

  cl <- vl_contour(z, levels = 0.5, xlim = c(-4, 4), ylim = c(-4, 4))
  expect_equal(mean(range(cl$x)), 2, tolerance = 0.05)
  expect_equal(mean(range(cl$y)), -1, tolerance = 0.05)

  # The authority: base R takes dim(z) == c(length(x), length(y)).
  ref <- grDevices::contourLines(gs, gs, z, levels = 0.5)[[1]]
  expect_equal(mean(range(cl$x)), mean(range(ref$x)), tolerance = 0.05)
  expect_equal(mean(range(cl$y)), mean(range(ref$y)), tolerance = 0.05)
})

test_that("two contours over a datashade grid land on their modes", {
  # The case that exposed it: contours drawn over an aggregated point cloud,
  # where a transpose is instantly visible because there is a reference layer.
  gs <- seq(-4, 4, length.out = 120)
  dens <- outer(gs, gs, function(x, y) {
    exp(-((x + 1)^2 / 0.8 + (y - 0.5)^2 / 0.7)) +
      exp(-((x - 1.2)^2 / 0.5 + (y + 0.8)^2 / 1.2))
  })
  cl <- vl_contour(dens, levels = 0.5, xlim = c(-4, 4), ylim = c(-4, 4))
  ctr <- do.call(rbind, lapply(split(cl, cl$id), function(d) {
    data.frame(x = mean(range(d$x)), y = mean(range(d$y)))
  }))
  ctr <- ctr[order(ctr$x), ]
  expect_equal(nrow(ctr), 2L)
  expect_equal(ctr$x, c(-1, 1.2), tolerance = 0.1)
  expect_equal(ctr$y, c(0.5, -0.8), tolerance = 0.1)
})

test_that("contours of a Gaussian bump are closed rings of the right radius", {
  z <- bump()
  cl <- vl_contour(z, levels = 0.5, xlim = c(-3, 3), ylim = c(-3, 3))
  expect_equal(length(unique(cl$id)), 1L)
  expect_true(all(cl$closed))
  # exp(-r^2/2) = 0.5  =>  r = sqrt(2 ln 2) ~ 1.177
  r <- sqrt(cl$x^2 + cl$y^2)
  expect_equal(mean(r), sqrt(2 * log(2)), tolerance = 0.02)
  expect_lt(diff(range(r)), 0.05)
})

test_that("higher levels give smaller rings", {
  z <- bump()
  radius <- function(l) {
    cl <- vl_contour(z, levels = l, xlim = c(-3, 3), ylim = c(-3, 3))
    mean(sqrt(cl$x^2 + cl$y^2))
  }
  expect_lt(radius(0.8), radius(0.5))
  expect_lt(radius(0.5), radius(0.2))
})

test_that("contours are chained, not returned as loose segments", {
  # The distinguishing property: consecutive rows of one id are neighbours.
  cl <- vl_contour(bump(), levels = 0.5, xlim = c(-3, 3), ylim = c(-3, 3))
  d <- sqrt(diff(cl$x)^2 + diff(cl$y)^2)
  expect_lt(max(d), 0.3)
  # A ring of k points came from k marching-squares segments: nothing dropped
  # and nothing duplicated.
  expect_gt(nrow(cl), 50L)
})

test_that("two separate features give two contour lines", {
  s <- seq(-6, 6, length.out = 90)
  z <- outer(s, s, function(a, b) exp(-((a - 3)^2 + b^2) / 2) + exp(-((a + 3)^2 + b^2) / 2))
  cl <- vl_contour(z, levels = 0.5, xlim = c(-6, 6), ylim = c(-6, 6))
  expect_equal(length(unique(cl$id)), 2L)
})

test_that("ids stay distinct across levels", {
  cl <- vl_contour(bump(), levels = c(0.2, 0.5, 0.8), xlim = c(-3, 3), ylim = c(-3, 3))
  per_level <- tapply(cl$id, cl$level, function(i) unique(i))
  expect_equal(length(unique(unlist(per_level))), 3L)
  # No id is shared between two levels, or `lines_grob(id=)` would join them.
  expect_false(anyDuplicated(unlist(lapply(per_level, unique))) > 0)
})

test_that("xlim and ylim place the grid", {
  z <- bump()
  a <- vl_contour(z, levels = 0.5, xlim = c(-3, 3), ylim = c(-3, 3))
  b <- vl_contour(z, levels = 0.5, xlim = c(0, 60), ylim = c(0, 60))
  expect_equal(mean(a$x), 0, tolerance = 0.05)
  expect_equal(mean(b$x), 30, tolerance = 0.5)
})

test_that("default levels span the data and exclude the extremes", {
  cl <- vl_contour(bump())
  expect_gt(length(unique(cl$level)), 1L)
  expect_gt(min(cl$level), min(bump()))
  expect_lt(max(cl$level), max(bump()))
})

test_that("degenerate grids give an empty frame rather than an error", {
  expect_equal(nrow(vl_contour(matrix(1, 1, 1))), 0L)
  expect_equal(nrow(vl_contour(matrix(1, 5, 5))), 0L) # flat: no level crosses it
  expect_equal(nrow(vl_contour(matrix(1, 5, 5), levels = 0.5)), 0L)
})

test_that("missing data breaks a contour instead of crossing it", {
  s <- seq(0, 1, length.out = 40)
  z <- outer(s, s, function(a, b) a) # a clean ramp: one contour across the grid
  full <- vl_contour(z, levels = 0.5)
  z[10:30, 20] <- NA
  gapped <- vl_contour(z, levels = 0.5)
  expect_true(all(is.finite(gapped$x)), label = "no NaN coordinates")
  expect_lt(nrow(gapped), nrow(full))
  expect_gt(nrow(gapped), 0L)
})

test_that("contour_grob makes one grob per contour, and does not join them", {
  cl <- vl_contour(bump(), levels = c(0.2, 0.5, 0.8), xlim = c(-3, 3), ylim = c(-3, 3))
  g <- contour_grob(cl)
  expect_length(g, length(unique(cl$id)))
  # Closed contours get their first point repeated so the stroke closes.
  n_closed <- sum(tapply(cl$closed, cl$id, `[`, 1L))
  expect_equal(sum(vapply(g, function(x) length(x@x), integer(1))),
               nrow(cl) + n_closed)
  expect_equal(length(contour_grob(cl, close = FALSE)[[1]]@x),
               sum(cl$id == cl$id[1]))
})

test_that("lines_grob rejects a grouping vector passed as `id`", {
  # `path_grob(id=)` groups; `lines_grob(id=)` is the accessibility identifier.
  # Passing one for the other used to draw a single polyline joining every
  # group with a straight line, which is silent and looks like a solver bug.
  expect_error(lines_grob(c(0, 1, 0, 1), c(0, 1, 1, 0), id = c(1, 1, 2, 2)),
               "single value")
  expect_no_error(lines_grob(c(0, 1), c(0, 1), id = "one-line"))
})

test_that("contours draw", {
  cl <- vl_contour(bump(), levels = c(0.2, 0.5, 0.8), xlim = c(-3, 3), ylim = c(-3, 3))
  s <- vl_scene(3, 3, dpi = 96, bg = "white") |>
    push(vl_viewport(xscale = c(-3, 3), yscale = c(-3, 3))) |>
    draw(contour_grob(cl, gp = vl_gpar(col = "steelblue", lwd = 2))) |>
    pop()
  r <- scene_raster(s)
  expect_gt(sum(r[3, , ] > r[1, , ] + 20), 200) # blue ink on the page
})

# --- SVG path data -----------------------------------------------------------

STAR <- "M12 2 L15 9 L22 9.3 L16.5 13.8 L18.5 21 L12 17 L5.5 21 L7.5 13.8 L2 9.3 L9 9 Z"

test_that("SVG path data parses to rings", {
  p <- vl_svg_path(STAR)
  expect_equal(nrow(p), 10L)
  expect_true(all(p$closed))
  expect_equal(length(unique(p$id)), 1L)
})

test_that("relative and absolute path data agree", {
  expect_equal(vl_svg_path("M0 0 L10 0 L10 10 Z")$x,
               vl_svg_path("m0 0 l10 0 l0 10 z")$x)
})

test_that("curves and arcs are flattened", {
  cubic <- vl_svg_path("M0 0 C0 10 10 10 10 0")
  expect_gt(nrow(cubic), 5L)
  expect_equal(cubic$x[nrow(cubic)], 10)
  arc <- vl_svg_path("M0 0 A1 1 0 0 1 2 0")
  expect_gt(nrow(arc), 5L)
  # Every arc point is on the unit circle centred at (1, 0).
  expect_equal(sqrt((arc$x - 1)^2 + arc$y^2), rep(1, nrow(arc)), tolerance = 1e-6)
})

test_that("several subpaths become several ids", {
  p <- vl_svg_path("M0 0 L1 0 L1 1 Z M5 5 L6 5 L6 6 Z")
  expect_equal(length(unique(p$id)), 2L)
})

test_that("malformed path data yields what parsed, not an error", {
  expect_equal(nrow(vl_svg_path("")), 0L)
  expect_equal(nrow(vl_svg_path("nonsense")), 0L)
  expect_equal(nrow(vl_svg_path("M0 0 L10 0 L10 10 L")), 3L)
  expect_error(vl_svg_path(c("a", "b")), "single string")
})

test_that("svg_grob flips y, fits the size, and centres", {
  g <- svg_grob(STAR, x = 0.5, y = 0.5, size = vl_unit(20, "mm"))
  xs <- as.numeric(vctrs::field(g@x, "value"))
  ys <- as.numeric(vctrs::field(g@y, "value"))
  ox <- as.numeric(vctrs::field(g@x, "offset"))
  oy <- as.numeric(vctrs::field(g@y, "offset"))
  # The base is npc 0.5 and the shape lives entirely in the mm offset.
  expect_equal(unique(xs), 0.5)
  expect_equal(unique(ys), 0.5)
  # Longer side is exactly `size`, and the shape is centred on the anchor.
  expect_equal(max(max(ox) - min(ox), max(oy) - min(oy)), 20, tolerance = 1e-9)
  expect_equal(mean(range(ox)), 0, tolerance = 1e-9)
  expect_equal(mean(range(oy)), 0, tolerance = 1e-9)

  # Flipping is on by default: SVG y grows down, so the star's point (the
  # smallest SVG y) must end up at the LARGEST vellum y.
  raw <- vl_svg_path(STAR)
  tip <- which.min(raw$y)
  expect_equal(oy[tip], max(oy), tolerance = 1e-9)
  # ...and turning it off puts it back at the bottom.
  g2 <- svg_grob(STAR, flip_y = FALSE)
  oy2 <- as.numeric(vctrs::field(g2@y, "offset"))
  expect_equal(oy2[tip], min(oy2), tolerance = 1e-9)
})

test_that("svg_grob draws, and scales without losing shape", {
  ink <- function(mm) {
    s <- vl_scene(2, 2, dpi = 96, bg = "white") |>
      draw(svg_grob(STAR, size = vl_unit(mm, "mm"), gp = vl_gpar(fill = "black", col = NA)))
    sum(scene_raster(s)[1, , ] < 128)
  }
  small <- ink(8)
  big <- ink(24)
  expect_gt(small, 20)
  # Area scales with the square of the size, give or take antialiasing.
  expect_equal(big / small, 9, tolerance = 0.15)
})

test_that("an empty path gives a grob that draws nothing", {
  g <- svg_grob("")
  expect_length(g@x, 0L)
  s <- vl_scene(2, 1, dpi = 96, bg = "white") |> draw(g)
  expect_equal(sum(scene_raster(s)[1, , ] < 250), 0L)
})

test_that("SVG geometry composes with the rest of the engine", {
  # The payoff of importing as geometry rather than as a bitmap: it is an
  # ordinary path, so it takes a gradient fill and a boolean operand.
  g <- svg_grob(STAR, size = vl_unit(30, "mm"),
                gp = vl_gpar(fill = linear_gradient(c("gold", "tomato"))))
  s <- vl_scene(2, 2, dpi = 96, bg = "white") |> draw(g)
  px <- scene_raster(s)
  expect_gt(length(unique(as.vector(px[1, , ]))), 5L) # a ramp, not one flat fill

  p <- vl_svg_path(STAR)
  cut <- vl_path_op(list(x = p$x, y = p$y, nper = nrow(p)),
                    list(x = c(0, 24, 24, 0), y = c(0, 0, 12, 12)),
                    "difference", rule = "evenodd")
  expect_gt(length(cut@x), 0L)
})
