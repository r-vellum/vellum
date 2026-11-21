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
  expect_error(vl_viewport(blend = "bogus"), "must be one of")
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

# PDF rasterised by pdftoppm next to the PNG backend, at the same size.
pdf_vs_png <- function(s) {
  f <- withr::local_tempfile(fileext = ".pdf", .local_envir = parent.frame())
  render(s, f)
  stem <- withr::local_tempfile(.local_envir = parent.frame())
  system2("pdftoppm", c("-png", "-r", "72", shQuote(f), shQuote(stem)))
  out <- paste0(stem, "-1.png")
  if (!file.exists(out)) {
    return(NULL)
  }
  list(pdf = png::readPNG(out), png = png::readPNG(scene_png(s)))
}

test_that("PDF blends a group as a unit: overlapping marks inside composite first (VR-23)", {
  skip_if(unname(Sys.which("pdftoppm")) == "", "pdftoppm not available")
  skip_if_not_installed("png")
  # two overlapping squares in one multiply group over grey: where they
  # overlap the later one covers the earlier (normal, inside the group), and
  # only that result multiplies with the grey
  s <- vl_scene(1, 1, dpi = 72, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "grey50", col = NA))) |>
    push(vl_viewport(blend = "multiply")) |>
    draw(rect_grob(
      0.35,
      0.5,
      0.5,
      0.5,
      gp = vl_gpar(fill = "#ff8080", col = NA)
    )) |>
    draw(rect_grob(
      0.65,
      0.5,
      0.5,
      0.5,
      gp = vl_gpar(fill = "#80c0ff", col = NA)
    )) |>
    pop()
  r <- pdf_vs_png(s)
  skip_if(is.null(r), "pdftoppm produced no output")
  px <- function(a) a[36, 36, 1:3] # the middle: inside both squares
  expect_equal(px(r$pdf), px(r$png), tolerance = 0.03)
  # grey x the blue square, not grey x red x blue
  expect_gt(px(r$pdf)[3], 0.4)
})

test_that("PDF nests blend groups as PNG does (VR-23)", {
  skip_if(unname(Sys.which("pdftoppm")) == "", "pdftoppm not available")
  skip_if_not_installed("png")
  # a multiply group inside a screen group: its yellow multiplies with the
  # screen group's own (transparent) backdrop, not with the page's grey
  s <- vl_scene(1, 1, dpi = 72, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "grey50", col = NA))) |>
    push(vl_viewport(blend = "screen")) |>
    draw(rect_grob(
      0.25,
      0.5,
      0.5,
      1,
      gp = vl_gpar(fill = "darkred", col = NA)
    )) |>
    push(vl_viewport(blend = "multiply")) |>
    draw(rect_grob(
      0.75,
      0.5,
      0.5,
      1,
      gp = vl_gpar(fill = "yellow", col = NA)
    )) |>
    pop() |>
    pop()
  r <- pdf_vs_png(s)
  skip_if(is.null(r), "pdftoppm produced no output")
  px <- function(a) a[36, 60, 1:3] # inside the yellow, outside the dark red
  expect_equal(px(r$pdf), px(r$png), tolerance = 0.03)
})
