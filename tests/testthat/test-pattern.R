# Tiling-pattern fills. Raster probes build a scene with the public API and read
# pixels via px(); SVG asserts the <pattern>/<image> structure; PDF checks the
# average-colour fallback renders.

test_that("pattern() builds and validates", {
  p <- pattern(circle_grob(r = 0.3), width = 0.2, height = 0.2)
  expect_s3_class(p, "vellum_pattern")
  expect_error(pattern(circle_grob(), width = Inf), "finite")
  expect_error(pattern(circle_grob(), extend = "bounce"))
})

test_that("a pattern tiles its grob across the fill (raster)", {
  tile <- list(
    rect_grob(gp = gpar(fill = "red", col = NA)),
    circle_grob(r = 0.3, gp = gpar(fill = "white", col = NA))
  )
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = gpar(col = NA, fill = pattern(tile, width = 0.2, height = 0.2))))
  # Cell is 0.2 npc = 20 px, centred on the page -> a tile centre sits at the
  # page centre (white dot); a tile corner is the red background.
  centre <- px(s, 50, 50)
  corner <- px(s, 41, 41)
  expect_true(all(centre[1:3] > 230L)) # white dot
  expect_equal(corner[1:3], c(255L, 0L, 0L)) # red bg
})

test_that("pattern alpha fades the tile (raster)", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = gpar(
      col = NA, alpha = 0.5,
      fill = pattern(rect_grob(gp = gpar(fill = "red", col = NA)), width = 0.5, height = 0.5)
    )))
  p <- px(s, 50, 50)
  expect_equal(p[4], 255L) # opaque page
  # 50% red over white -> pink
  expect_true(p[1] > 240L && abs(p[2] - 127L) < 12L && abs(p[3] - 127L) < 12L)
})

test_that("SVG emits a <pattern> with an embedded image", {
  f <- withr::local_tempfile(fileext = ".svg")
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = gpar(col = NA, fill = pattern(
      circle_grob(r = 0.3, gp = gpar(fill = "red", col = NA)),
      width = 0.25, height = 0.25
    ))))
  render(s, f)
  svg <- paste(readLines(f, warn = FALSE), collapse = "\n")
  expect_match(svg, "<pattern ")
  expect_match(svg, 'patternUnits="userSpaceOnUse"')
  expect_match(svg, "<image ")
  expect_match(svg, "data:image/png;base64,")
  expect_match(svg, 'fill="url\\(#g0\\)"')
})

test_that("PDF renders a pattern fill (average-colour fallback)", {
  f <- withr::local_tempfile(fileext = ".pdf")
  s <- vl_scene(2, 1, dpi = 100) |>
    draw(rect_grob(gp = gpar(col = NA, fill = pattern(
      circle_grob(r = 0.3, gp = gpar(fill = "red", col = NA)),
      width = 0.25, height = 0.25
    ))))
  expect_no_error(render(s, f))
  expect_equal(rawToChar(readBin(f, "raw", 5)), "%PDF-")
})

test_that("a pattern used outside a render context errors clearly", {
  expect_error(.encode_paint(pattern(circle_grob())), "scene")
})
