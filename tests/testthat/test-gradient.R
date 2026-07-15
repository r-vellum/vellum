# Gradient fills across the three backends. Raster probes build a scene with the
# public API and read pixels via px(); SVG/PDF assert structure. The cross-backend
# pixel equivalence is exercised in the worked example.

test_that("linear_gradient/radial_gradient validate their inputs", {
  expect_s3_class(linear_gradient(c("black", "white")), "vellum_gradient")
  expect_error(linear_gradient(character(0)), "at least one colour")
  expect_error(linear_gradient(c("red", "blue"), stops = 0.5), "one offset per colour")
  expect_error(radial_gradient("red", units = "furlong"))
  expect_error(linear_gradient("red", x1 = Inf), "finite")
})

test_that("a horizontal linear gradient blends left to right (raster)", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(
      col = NA,
      fill = linear_gradient(c("black", "white"), x1 = 0, y1 = 0.5, x2 = 1, y2 = 0.5)
    )))
  left <- px(s, 3, 50)
  right <- px(s, 97, 50)
  mid <- px(s, 50, 50)
  expect_true(all(left[1:3] < 30L)) # near black
  expect_true(all(right[1:3] > 225L)) # near white
  expect_true(all(abs(mid[1:3] - 127L) < 40L)) # blend
  # No horizontal variation along the gradient axis at a fixed x: rows agree.
  expect_equal(px(s, 50, 20)[1:3], px(s, 50, 80)[1:3])
})

test_that("a radial gradient runs from centre colour to edge colour (raster)", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(
      col = NA,
      fill = radial_gradient(c("red", "yellow"), cx = 0.5, cy = 0.5, r = 0.5)
    )))
  centre <- px(s, 50, 50)
  edge <- px(s, 50, 2)
  expect_true(centre[1] > 200L && centre[2] < 60L) # red-ish
  expect_true(edge[1] > 200L && edge[2] > 200L) # yellow-ish
})

test_that("radial gradient radii must be non-negative", {
  expect_error(radial_gradient(c("red", "yellow"), r = -0.1), "non-negative")
  expect_error(radial_gradient(c("red", "yellow"), fr = -0.1), "non-negative")
})

test_that("a focal offset moves the radial highlight off-centre (raster)", {
  # White (offset 0) sits at the focal circle; navy (offset 1) at the outer edge.
  # With the focus pushed to the left, the white highlight follows it.
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(
      col = NA,
      fill = radial_gradient(c("white", "navy"), cx = 0.5, cy = 0.5, r = 0.6,
                             fx = 0.25, fy = 0.5)
    )))
  near <- px(s, 25, 50) # at the focal point -> ~white
  far <- px(s, 85, 50) # opposite side -> toward navy
  expect_true(all(near[1:3] > 230L)) # focal point is ~white (offset 0)
  expect_true(sum(far[1:3]) < sum(near[1:3]) - 150L) # far side clearly darker
})

test_that("SVG emits fx/fy/fr only for a focal (non-concentric) radial", {
  svg_of <- function(g) {
    f <- withr::local_tempfile(fileext = ".svg")
    render(vl_scene(1, 1, dpi = 100, bg = "white") |>
             draw(rect_grob(gp = vl_gpar(col = NA, fill = g))), f)
    paste(readLines(f, warn = FALSE), collapse = "\n")
  }
  focal <- svg_of(radial_gradient(c("white", "navy"), fx = 0.3, fy = 0.4))
  conc <- svg_of(radial_gradient(c("white", "navy"))) # concentric default
  # Coords are baked to device px (userSpaceOnUse): fx 0.3 npc -> 30; fy 0.4 npc
  # -> 60 after the y-flip on a 100px page.
  expect_match(focal, 'fx="30"')
  expect_match(focal, 'fy="60"')
  expect_match(focal, "fr=")
  # Concentric output is unchanged: no focal attributes emitted.
  expect_false(grepl("fx=", conc, fixed = TRUE))
})

test_that("vl_gpar alpha fades a gradient's stops (raster)", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(
      col = NA, alpha = 0.5,
      fill = linear_gradient(c("black", "black")) # solid-black gradient at 50%
    )))
  p <- px(s, 50, 50)
  expect_equal(p[4], 255L) # opaque page
  expect_true(all(abs(p[1:3] - 127L) <= 3L)) # half-black over white
})

test_that("gradient geometry transforms with a nested, scaled viewport (raster)", {
  # In a viewport occupying the left half, a full-width 0..1 npc linear gradient
  # spans only that half: its white end lands at the viewport's right edge
  # (device x ~ 50), not the page's.
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(vl_viewport(x = 0.25, y = 0.5, width = 0.5, height = 1)) |>
    draw(rect_grob(gp = vl_gpar(
      col = NA,
      fill = linear_gradient(c("black", "white"), x1 = 0, y1 = 0.5, x2 = 1, y2 = 0.5)
    )))
  expect_true(all(px(s, 2, 50)[1:3] < 30L)) # left edge: black end
  expect_true(all(px(s, 48, 50)[1:3] > 220L)) # viewport right edge: white end
})

test_that("SVG emits gradient defs referenced by the fill", {
  f <- withr::local_tempfile(fileext = ".svg")
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(
      gp = vl_gpar(col = NA, fill = linear_gradient(c("black", "white")))
    )) |>
    draw(circle_grob(
      r = 0.3, gp = vl_gpar(col = NA, fill = radial_gradient(c("red", "yellow")))
    ))
  render(s, f)
  svg <- paste(readLines(f, warn = FALSE), collapse = "\n")
  expect_match(svg, "<linearGradient")
  expect_match(svg, "<radialGradient")
  expect_match(svg, 'gradientUnits="userSpaceOnUse"')
  expect_match(svg, "<stop ")
  expect_match(svg, 'fill="url\\(#g0\\)"')
})

test_that("identical gradient fills share a single SVG def", {
  f <- withr::local_tempfile(fileext = ".svg")
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(x = 0.25, width = 0.4, gp = vl_gpar(col = NA, fill = linear_gradient(c("black", "white"))))) |>
    draw(rect_grob(x = 0.75, width = 0.4, gp = vl_gpar(col = NA, fill = linear_gradient(c("black", "white")))))
  render(s, f)
  svg <- paste(readLines(f, warn = FALSE), collapse = "\n")
  # Two shapes, one shared <linearGradient> def (deduplicated by signature).
  expect_equal(lengths(regmatches(svg, gregexpr("<linearGradient", svg))), 1L)
})

test_that("PDF with gradient fills renders without error", {
  f <- withr::local_tempfile(fileext = ".pdf")
  s <- vl_scene(2, 1, dpi = 100) |>
    draw(rect_grob(gp = vl_gpar(col = NA, fill = linear_gradient(c("navy", "white"))))) |>
    draw(circle_grob(r = 0.3, gp = vl_gpar(col = NA, fill = radial_gradient(c("red", "yellow")))))
  expect_no_error(render(s, f))
  expect_equal(rawToChar(readBin(f, "raw", 5)), "%PDF-")
})
