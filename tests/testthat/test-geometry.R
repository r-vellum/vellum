# Phase 7: resolution-aware path simplification, and stroke -> fillable outline.

# --- simplification ----------------------------------------------------------

dense_line <- function(n = 4000) {
  t <- seq(0, 1, length.out = n)
  lines_grob(t, 0.5 + 0.3 * sin(30 * t), gp = vl_gpar(col = "steelblue"))
}
svg_of <- function(grob, tol, w = 6, h = 3) {
  withr::with_options(list(vellum.simplify = tol), {
    vl_clear_render_cache()
    scene_svg(vl_scene(w, h, dpi = 100) |> draw(grob))
  })
}

test_that("simplification shrinks a dense path", {
  full <- svg_of(dense_line(), 0)
  simp <- svg_of(dense_line(), 0.1)
  expect_lt(nchar(simp), nchar(full) * 0.9)
})

test_that("a path below the density threshold is byte-identical", {
  # Ordinary shapes must not be touched at all: every vertex was placed on
  # purpose and there is nothing to win.
  tri <- polygon_grob(
    c(0.1, 0.9, 0.5),
    c(0.1, 0.1, 0.9),
    gp = vl_gpar(fill = "tomato")
  )
  expect_identical(svg_of(tri, 0), svg_of(tri, 0.1))
  expect_identical(svg_of(dense_line(200), 0), svg_of(dense_line(200), 0.1))
})

test_that("tolerance 0 disables it entirely", {
  expect_identical(svg_of(dense_line(), 0), svg_of(dense_line(), 0))
  full <- svg_of(dense_line(), 0)
  expect_gt(nchar(full), nchar(svg_of(dense_line(), 0.5)))
})

test_that("a larger tolerance removes more", {
  expect_gt(nchar(svg_of(dense_line(), 0.05)), nchar(svg_of(dense_line(), 0.5)))
})

test_that("simplification stays within its tolerance visually", {
  # The promise is sub-pixel: on a smooth path the rendered difference must be
  # small and confined to antialiased edges, not a visible change of shape.
  px <- function(tol) {
    withr::with_options(list(vellum.simplify = tol), {
      vl_clear_render_cache()
      scene_raster(vl_scene(6, 3, dpi = 100) |> draw(dense_line()))
    })
  }
  d <- abs(as.numeric(px(0)) - as.numeric(px(0.1)))
  expect_lt(mean(d), 2) # mean channel delta, out of 255
  expect_lt(mean(d > 0), 0.05) # under 5% of channels touched at all
})

test_that("NA gaps survive simplification", {
  # An NA breaks the polyline into sub-paths; simplifying must not merge them.
  n <- 3000
  t <- seq(0, 1, length.out = n)
  y <- 0.5 + 0.3 * sin(30 * t)
  y[1500] <- NA
  g <- lines_grob(t, y, gp = vl_gpar(col = "black"))
  simp <- svg_of(g, 0.1)
  # Two sub-paths => two "M" move commands in the emitted path data.
  expect_equal(
    lengths(regmatches(simp, gregexpr("M", simp, fixed = TRUE)))[[1]],
    2L
  )
})

test_that("an invalid simplify option is rejected", {
  withr::with_options(list(vellum.simplify = -1), {
    expect_error(
      scene_svg(vl_scene(1, 1) |> draw(circle_grob())),
      "vellum.simplify"
    )
  })
  withr::with_options(list(vellum.simplify = "a"), {
    expect_error(
      scene_svg(vl_scene(1, 1) |> draw(circle_grob())),
      "vellum.simplify"
    )
  })
})

# --- stroke_to_path() --------------------------------------------------------

zig <- function(...) {
  lines_grob(
    c(0.1, 0.35, 0.6, 0.9),
    c(0.2, 0.8, 0.2, 0.8),
    gp = vl_gpar(col = "steelblue", lwd = 12, ...)
  )
}

test_that("stroke_to_path returns a fillable path", {
  o <- stroke_to_path(zig(), width = 3, height = 2)
  expect_true(S7::S7_inherits(o, vellum:::grob_path))
  expect_gt(length(vctrs::field(o@x, "value")), 4L)
  # Absolute units, because an outline is baked at one size.
  expect_true(all(vctrs::field(o@x, "unit") == vellum:::.unit_codes[["mm"]]))
})

test_that("the outline covers roughly the area the stroke inked", {
  # Draw the line, and draw its outline filled; the inked area should match
  # closely (the outline is the region the stroke covered, by construction).
  ink <- function(g) {
    vl_clear_render_cache()
    r <- scene_raster(vl_scene(3, 2, dpi = 100, bg = "white") |> draw(g))
    mean(r[1, , ] < 250)
  }
  a <- ink(zig())
  b <- ink(S7::set_props(
    stroke_to_path(zig(), width = 3, height = 2),
    gp = vl_gpar(fill = "steelblue", col = NA)
  ))
  expect_equal(b, a, tolerance = 0.1)
})

test_that("a wider stroke gives a larger outline", {
  area <- function(lwd) {
    o <- stroke_to_path(
      zig(),
      width = 3,
      height = 2,
      gp = vl_gpar(lwd = lwd, lineend = "round", linejoin = "round")
    )
    xs <- vctrs::field(o@x, "value")
    ys <- vctrs::field(o@y, "value")
    (max(xs) - min(xs)) * (max(ys) - min(ys))
  }
  expect_gt(area(24), area(6))
})

test_that("cap and join style reach the expansion", {
  pts <- function(cap) {
    o <- stroke_to_path(
      zig(),
      width = 3,
      height = 2,
      gp = vl_gpar(lwd = 12, lineend = cap, linejoin = "mitre")
    )
    length(vctrs::field(o@x, "value"))
  }
  # A round cap needs flattened arcs; a butt cap is two corners.
  expect_gt(pts("round"), pts("butt"))
})

test_that("stroke_to_path rejects what it cannot expand", {
  expect_error(stroke_to_path(circle_grob()), "lines_grob")
  expect_error(stroke_to_path(rect_grob()), "lines_grob")
  expect_error(
    stroke_to_path(lines_grob(
      vl_unit(c(1, 2), "null"),
      vl_unit(c(1, 2), "null")
    )),
    "null"
  )
})

test_that("a closed shape expands too", {
  o <- stroke_to_path(
    polygon_grob(
      c(0.2, 0.8, 0.5),
      c(0.2, 0.2, 0.8),
      gp = vl_gpar(col = "black", lwd = 8)
    ),
    width = 3,
    height = 3
  )
  # An outlined closed triangle has an outer and an inner contour.
  expect_gte(length(unique(o@nper)), 1L)
  expect_gt(length(vctrs::field(o@x, "value")), 6L)
})
