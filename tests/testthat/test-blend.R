# vl_viewport(blend=): group blend modes. The viewport's contents composite as one
# isolated layer, blended against the backdrop below.

test_that("group blend 'multiply' composites against the backdrop", {
  # yellow (255,255,0) * cyan (0,255,255) = green (0,255,0)
  s <- vl_scene(1, 1, dpi = 50, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "yellow", col = NA))) |>
    push(vl_viewport(blend = "multiply")) |>
    draw(rect_grob(gp = vl_gpar(fill = "cyan", col = NA))) |>
    pop()
  expect_equal(scene_raster(s)[1:3, 25, 25], c(0L, 255L, 0L))
})

test_that("default (normal) blend just draws the top layer over the backdrop", {
  s <- vl_scene(1, 1, dpi = 50, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "yellow", col = NA))) |>
    push(vl_viewport()) |>
    draw(rect_grob(gp = vl_gpar(fill = "cyan", col = NA))) |>
    pop()
  expect_equal(scene_raster(s)[1:3, 25, 25], c(0L, 255L, 255L)) # cyan on top
})

test_that("blend is validated", {
  expect_error(vl_viewport(blend = "bogus"), "should be one of|arg")
})

test_that("SVG emits mix-blend-mode for a blended group", {
  s <- vl_scene(1, 1, dpi = 50, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "yellow", col = NA))) |>
    push(vl_viewport(blend = "screen")) |>
    draw(rect_grob(gp = vl_gpar(fill = "cyan", col = NA))) |>
    pop()
  f <- withr::local_tempfile(fileext = ".svg")
  render(s, f)
  svg <- paste(readLines(f), collapse = "")
  expect_match(svg, "mix-blend-mode:screen", fixed = TRUE)
})

test_that("PDF applies the blend mode (rasterized check)", {
  skip_if(unname(Sys.which("pdftoppm")) == "", "pdftoppm not available")
  skip_if_not_installed("png")
  s <- vl_scene(1, 1, dpi = 72, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "yellow", col = NA))) |>
    push(vl_viewport(blend = "multiply")) |>
    draw(rect_grob(gp = vl_gpar(fill = "cyan", col = NA))) |>
    pop()
  f <- withr::local_tempfile(fileext = ".pdf")
  render(s, f)
  stem <- withr::local_tempfile()
  system2("pdftoppm", c("-png", "-r", "72", shQuote(f), shQuote(stem)))
  out <- paste0(stem, "-1.png")
  skip_if(!file.exists(out), "pdftoppm produced no output")
  a <- png::readPNG(out)
  expect_lt(a[10, 10, 1], 0.1) # low red
  expect_gt(a[10, 10, 2], 0.9) # high green  (yellow * cyan = green)
  expect_lt(a[10, 10, 3], 0.1) # low blue
})
