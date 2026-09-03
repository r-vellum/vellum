# Render-time per-vertex stroke width: `lines_grob(lwd_profile =)`.
#
# The geometry generator is `src/rust/src/ribbon.rs` (shipped with
# `stroke_to_path(lwd_profile =)`, and unit-tested there); these tests exercise
# the R surface and the render-time wiring -- the half a grammar needs, where the
# profile resolves inside its viewport at render rather than being baked against
# a page size the caller had to know.

# Non-white pixel count: the house idiom for "how much ink did this put down".
nonwhite <- function(scene) {
  r <- scene_raster(scene)
  sum(apply(r, c(2, 3), function(px) any(px < 250)))
}

zig <- function(...) {
  lines_grob(
    c(0.1, 0.4, 0.7, 0.9),
    c(0.3, 0.8, 0.3, 0.7),
    gp = vl_gpar(col = "black", lwd = 8),
    ...
  )
}
sc <- function(g) draw(vl_scene(4, 3, dpi = 96, bg = "white"), g)

test_that("lwd_profile validates its input", {
  expect_error(zig(lwd_profile = c(1, 2)), "one value per vertex")
  expect_error(zig(lwd_profile = "a"), "numeric")
  expect_error(zig(lwd_profile = numeric(0)), "non-empty")
  expect_error(zig(lwd_profile = c(1, 2, NA, 1)))
  expect_error(zig(lwd_profile = c(1, 2, -1, 1)))
  # sketch and a profile are two different pictures; refuse rather than guess
  expect_error(
    zig(lwd_profile = c(1, 1, 1, 1), sketch = sketch(seed = 1)),
    "cannot be combined"
  )
})

test_that("a single value is recycled to every vertex", {
  g <- zig(lwd_profile = 1)
  expect_length(g@lwd_profile, 4L)
  expect_true(all(g@lwd_profile == 1))
})

test_that("no profile is byte-identical to a plain polyline", {
  # The gate this feature had to pass: an unprofiled scene must not move.
  expect_identical(
    scene_raster(sc(zig())),
    scene_raster(sc(zig(lwd_profile = NULL)))
  )
})

test_that("an all-equal profile matches a plain stroke of that width", {
  # Not byte-identical -- a filled ribbon is not the rasterizer's stroker -- but
  # it must put down close to the same amount of ink in the same place.
  a <- nonwhite(sc(zig()))
  b <- nonwhite(sc(zig(lwd_profile = rep(1, 4))))
  expect_lt(abs(a - b) / a, 0.06)
})

test_that("a wider profile puts down more ink, a taper less", {
  base <- nonwhite(sc(zig(lwd_profile = rep(1, 4))))
  wide <- nonwhite(sc(zig(lwd_profile = rep(2, 4))))
  taper <- nonwhite(sc(zig(lwd_profile = c(1, 0.66, 0.33, 0))))
  expect_gt(wide, base * 1.5)
  expect_lt(taper, base)
})

test_that("the profile scales the resolved lwd, including an inherited one", {
  # `lwd` may come from the enclosing gpar stack, so the multiplier has to be
  # applied to the RESOLVED width at render -- not folded in at construction.
  inherited <- vl_scene(4, 3, dpi = 96, bg = "white") |>
    push(vl_viewport(gp = vl_gpar(lwd = 8))) |>
    draw(lines_grob(
      c(0.1, 0.4, 0.7, 0.9),
      c(0.3, 0.8, 0.3, 0.7),
      gp = vl_gpar(col = "black"),
      lwd_profile = rep(2, 4)
    ))
  explicit <- sc(zig(lwd_profile = rep(2, 4)))
  expect_equal(nonwhite(inherited), nonwhite(explicit), tolerance = 0.02)
})

test_that("the taper keeps its physical width at any figure size", {
  # The point of resolving at render: `lwd` is a PHYSICAL width (1 == 1/96 in),
  # so doubling the page doubles the ribbon's length but leaves its width alone.
  # Ink is length x width, so the ratio is ~2, not ~4 -- and a ~4 here would mean
  # the width had been baked into the coordinates instead of resolved.
  g <- zig(lwd_profile = c(1, 2, 1, 0))
  small <- nonwhite(draw(vl_scene(4, 3, dpi = 96, bg = "white"), g))
  big <- nonwhite(draw(vl_scene(8, 6, dpi = 96, bg = "white"), g))
  expect_equal(big / small, 2, tolerance = 0.05)
})

test_that("the taper scales with dpi, as a physical width must", {
  # The complement of the test above: same page, twice the dpi => twice the
  # linear size in px in BOTH directions, so ~4x the ink.
  g <- zig(lwd_profile = c(1, 2, 1, 0))
  lo <- nonwhite(draw(vl_scene(4, 3, dpi = 96, bg = "white"), g))
  hi <- nonwhite(draw(vl_scene(4, 3, dpi = 192, bg = "white"), g))
  expect_equal(hi / lo, 4, tolerance = 0.1)
})

test_that("a profile renders on all three backends", {
  g <- zig(lwd_profile = c(0, 1, 2, 0.5))
  for (ext in c("png", "svg", "pdf")) {
    f <- withr::local_tempfile(fileext = paste0(".", ext))
    render(sc(g), f)
    expect_gt(file.size(f), 0)
  }
})

test_that("SVG emits a filled path, not a stroked one", {
  # No backend can stroke one path at several widths, so the ribbon is a fill.
  # Asserted because it is the thing a reader would most reasonably doubt.
  svg <- scene_svg(sc(zig(lwd_profile = c(0, 1, 2, 0.5))))
  expect_no_match(svg, "stroke-width", fixed = TRUE)
  expect_match(svg, "fill=", fixed = TRUE)
})

test_that("an all-zero profile is rejected, as it is for stroke_to_path()", {
  # The shared validator's rule: a zero is legal (tapering to a point is the
  # usual reason to want this) but a stroke with no width anywhere is not a
  # picture. Asserted here so the two entry points cannot drift apart.
  expect_error(zig(lwd_profile = rep(0, 4)))
  expect_no_error(zig(lwd_profile = c(1, 0.5, 0, 0)))
})

test_that("a profiled line is keyed and pickable like any other", {
  s <- sc(lines_grob(
    c(0.1, 0.9),
    c(0.1, 0.9),
    gp = vl_gpar(col = "black", lwd = 8),
    lwd_profile = c(1, 3),
    key = "ribbon"
  ))
  expect_equal(element_geometry(s)$key, rep("ribbon", 2))
  expect_equal(vl_nearest(s, 0.5, 0.5)$key, "ribbon")
})
