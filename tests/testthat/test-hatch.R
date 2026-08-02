# Phase 8a: hatch as a paint kind. It is geometry, not a rasterised tile, and it
# is expanded in the scene walk into stroked spans -- so every backend gets it
# through primitives it already has.

hatched <- function(shape = "rect", ...) {
  g <- switch(
    shape,
    rect = rect_grob(
      width = 0.8,
      height = 0.8,
      gp = vl_gpar(fill = vl_hatch(...), col = NA)
    ),
    circle = circle_grob(r = 0.4, gp = vl_gpar(fill = vl_hatch(...), col = NA)),
    hexagon = hexagon_grob(
      size = vl_unit(10, "mm"),
      gp = vl_gpar(fill = vl_hatch(...), col = NA)
    ),
    sector = sector_grob(
      r0 = 0.1,
      r1 = 0.4,
      theta0 = 0,
      theta1 = 4,
      gp = vl_gpar(fill = vl_hatch(...), col = NA)
    )
  )
  vl_scene(2, 2, dpi = 100, bg = "white") |> draw(g)
}
inked <- function(s) sum(scene_raster(s)[1, , ] < 250)

test_that("a hatch inks part of the shape, not all of it", {
  solid <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(rect_grob(
      width = 0.8,
      height = 0.8,
      gp = vl_gpar(fill = "black", col = NA)
    ))
  h <- inked(hatched("rect", angle = 0, spacing = 4))
  expect_gt(h, 0)
  expect_lt(h, inked(solid) * 0.6) # ruled, not filled
})

test_that("spacing controls density", {
  fine <- inked(hatched("rect", angle = 0, spacing = 2))
  coarse <- inked(hatched("rect", angle = 0, spacing = 8))
  expect_gt(fine, coarse * 1.5)
})

test_that("angle changes the result", {
  a <- scene_raster(hatched("rect", angle = 0, spacing = 4))
  b <- scene_raster(hatched("rect", angle = 90, spacing = 4))
  expect_false(identical(as.numeric(a), as.numeric(b)))
})

test_that("hatch works on curved and batched shapes", {
  # Curves exercise the path flattening; hexagon/sector exercise the shared-paint
  # fallback on marks that normally carry a per-element fill colour.
  for (shape in c("circle", "hexagon", "sector")) {
    expect_gt(inked(hatched(shape, angle = 45, spacing = 3)), 0, label = shape)
  }
})

test_that("a per-element fill still beats the shared hatch", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(hexagon_grob(
      size = vl_unit(10, "mm"),
      fill = "black",
      gp = vl_gpar(fill = vl_hatch(0, 3), col = NA)
    ))
  solid <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(hexagon_grob(
      size = vl_unit(10, "mm"),
      fill = "black",
      gp = vl_gpar(col = NA)
    ))
  expect_equal(inked(s), inked(solid))
})

test_that("gradients now reach batched marks too", {
  # Fixed in passing: `gp$fill` never reached hexagons/sectors, so a gradient
  # there silently drew nothing.
  g <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(hexagon_grob(
      size = vl_unit(10, "mm"),
      gp = vl_gpar(fill = linear_gradient(c("red", "blue")), col = NA)
    ))
  expect_gt(sum(scene_raster(g)[3, , ] > 100 & scene_raster(g)[1, , ] < 250), 0)
})

test_that("bg paints behind the rules", {
  none <- inked(hatched("rect", angle = 0, spacing = 6))
  with_bg <- inked(hatched("rect", angle = 0, spacing = 6, bg = "grey80"))
  expect_gt(with_bg, none)
})

test_that("the hatch is real geometry in SVG, not an embedded image", {
  svg <- scene_svg(hatched("rect", angle = 45, spacing = 4))
  expect_false(grepl("<image", svg, fixed = TRUE))
  expect_match(svg, "stroke=")
})

test_that("a hatch renders in PDF without a degradation warning", {
  f <- withr::local_tempfile(fileext = ".pdf")
  vl_clear_render_cache()
  expect_no_warning(render(hatched("rect", angle = 45, spacing = 4), f))
  expect_gt(file.size(f), 0)
})

test_that("hatch scales with dpi, so it keeps its proportions", {
  # spacing is in points; doubling dpi must not double the number of rules.
  n_at <- function(dpi) {
    s <- vl_scene(2, 2, dpi = dpi, bg = "white") |>
      draw(rect_grob(
        width = 0.8,
        height = 0.8,
        gp = vl_gpar(fill = vl_hatch(0, 6), col = NA)
      ))
    # Count inked rows in a central column.
    v <- scene_raster(s)[1, dpi, ] < 250
    sum(diff(c(FALSE, v)) == 1)
  }
  expect_equal(n_at(100), n_at(200), tolerance = 1)
})

test_that("vl_hatch validates its arguments", {
  expect_error(vl_hatch(spacing = 0), "positive")
  expect_error(vl_hatch(spacing = -1), "positive")
  expect_error(vl_hatch(width = 0), "positive")
  expect_error(vl_hatch(angle = c(1, 2)), "single number")
})

test_that("printing a hatch is informative", {
  out <- paste(
    capture.output(print(vl_hatch(45, 3)), type = "message"),
    collapse = " "
  )
  expect_match(out, "45")
})
