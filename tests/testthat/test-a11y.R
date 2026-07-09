# Accessibility: a scene title/description makes the SVG an accessible image
# (role="img" + <title>/<desc> + aria-labelledby). Additive — no title/desc
# leaves the output byte-identical.

test_that("a titled scene emits role=img + aria-labelledby + <title>/<desc>", {
  s <- vl_scene(2, 2, bg = "white", title = "Two dots", desc = "Two red points.") |>
    draw(points_grob(c(0.3, 0.7), 0.5, gp = vl_gpar(fill = "red")))
  svg <- scene_svg(s)
  expect_match(svg, 'role="img"', fixed = TRUE)
  expect_match(svg, "aria-labelledby=")
  expect_match(svg, '<title id="vl[0-9]+-t">Two dots</title>')
  expect_match(svg, '<desc id="vl[0-9]+-d">Two red points.</desc>')
  # the aria-labelledby ids reference the emitted title + desc
  ids <- sub('.*aria-labelledby="([^"]*)".*', "\\1", svg)
  expect_length(strsplit(ids, " ")[[1]], 2L)
})

test_that("a scene with no title/desc emits no accessibility markup", {
  s <- vl_scene(2, 2, bg = "white") |>
    draw(points_grob(c(0.3, 0.7), 0.5, gp = vl_gpar(fill = "red")))
  svg <- scene_svg(s)
  expect_no_match(svg, "role=", fixed = TRUE)
  expect_no_match(svg, "<title", fixed = TRUE)
  expect_no_match(svg, "<desc", fixed = TRUE)
  expect_no_match(svg, "aria-", fixed = TRUE)
})

test_that("desc-only or title-only still labels the image", {
  s <- vl_scene(2, 2) |>
    draw(points_grob(0.5, 0.5, gp = vl_gpar(fill = "red"))) |>
    describe(desc = "A single red point.")
  svg <- scene_svg(s)
  expect_match(svg, 'role="img"', fixed = TRUE)
  expect_match(svg, "<desc")
  expect_no_match(svg, "<title", fixed = TRUE)
})

test_that("title/desc are XML-escaped (no markup injection)", {
  s <- vl_scene(2, 2) |>
    draw(points_grob(0.5, 0.5, gp = vl_gpar(fill = "red"))) |>
    describe(title = "a < b & c", desc = "x > y")
  svg <- scene_svg(s)
  expect_match(svg, "a &lt; b &amp; c", fixed = TRUE)
  expect_match(svg, "x &gt; y", fixed = TRUE)
})

test_that("a described scene renders a tagged PDF (structure tree + Alt)", {
  has <- function(f, s) {
    length(grepRaw(charToRaw(s), readBin(f, "raw", file.info(f)$size), fixed = TRUE)) > 0
  }
  f <- withr::local_tempfile(fileext = ".pdf")
  s <- vl_scene(2, 2, bg = "white", title = "Dots", desc = "Two red points on white.") |>
    draw(points_grob(c(0.3, 0.7), 0.5, gp = vl_gpar(fill = "red")))
  render(s, f)
  expect_true(has(f, "StructTreeRoot")) # tagged (has a structure tree)
  expect_true(has(f, "MarkInfo"))
  expect_true(has(f, "Figure")) # the chart is a Figure
  expect_true(has(f, "Two red points on white.")) # the Alt text

  # an undescribed scene is an ordinary, untagged PDF
  f2 <- withr::local_tempfile(fileext = ".pdf")
  render(vl_scene(2, 2, bg = "white") |> draw(points_grob(0.5, 0.5, gp = vl_gpar(fill = "red"))), f2)
  expect_false(has(f2, "StructTreeRoot"))
})

test_that("describe() sets accessibility on an existing scene", {
  base <- vl_scene(2, 2) |> draw(points_grob(0.5, 0.5, gp = vl_gpar(fill = "red")))
  expect_no_match(scene_svg(base), "role=", fixed = TRUE)
  labelled <- describe(base, title = "T", desc = "D")
  expect_match(scene_svg(labelled), 'role="img"', fixed = TRUE)
  # the drawn geometry is unchanged (a11y is additive metadata only)
  expect_equal(scene_raster(base), scene_raster(labelled))
})
