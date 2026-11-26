test_that("render() writes a valid PDF", {
  f <- withr::local_tempfile(fileext = ".pdf")
  s <- vl_scene(2, 1, dpi = 100) |>
    draw(rect_grob(gp = vl_gpar(fill = "red", col = NA))) |>
    draw(text_grob("hello"))
  render(s, f)
  bytes <- readBin(f, "raw", file.size(f))
  expect_equal(rawToChar(bytes[1:5]), "%PDF-")
  expect_gt(length(bytes), 500)
})

test_that("PDF clipping and nested viewports render without error", {
  f <- withr::local_tempfile(fileext = ".pdf")
  s <- vl_scene(2, 2, dpi = 100) |>
    push(vl_viewport(
      width = 0.5,
      height = 0.5,
      clip = TRUE,
      xscale = c(0, 10),
      yscale = c(0, 10)
    )) |>
    draw(circle_grob(
      vl_unit(5, "native"),
      vl_unit(5, "native"),
      r = 0.9,
      gp = vl_gpar(fill = "blue", col = NA)
    ))
  expect_no_error(render(s, f))
  expect_equal(rawToChar(readBin(f, "raw", 5)), "%PDF-")
})

test_that("PDF soft masks clip content (rasterized check)", {
  skip_if(unname(Sys.which("pdftoppm")) == "", "pdftoppm not available")
  skip_if_not_installed("png")
  f <- withr::local_tempfile(fileext = ".pdf")
  # Orange page rect masked to a centred r=0.4npc circle over a black background.
  s <- vl_scene(2, 2, dpi = 90, bg = "black") |>
    push(vl_viewport(
      mask = as_mask(circle_grob(
        r = 0.4,
        gp = vl_gpar(fill = "white", col = NA)
      ))
    )) |>
    draw(rect_grob(gp = vl_gpar(fill = "orange", col = NA))) |>
    pop()
  render(s, f)

  stem <- withr::local_tempfile()
  system2("pdftoppm", c("-png", "-r", "90", shQuote(f), shQuote(stem)))
  png <- paste0(stem, "-1.png")
  skip_if(!file.exists(png), "pdftoppm produced no output")
  img <- png::readPNG(png) # h x w x 3, 0..1
  h <- dim(img)[1]
  w <- dim(img)[2]
  corner <- img[3, 3, 1:3]
  centre <- img[round(h / 2), round(w / 2), 1:3]
  expect_lt(max(corner), 0.1) # masked-out corner is (near) black
  expect_gt(centre[1], 0.8) # centre is orange: high red...
  expect_lt(centre[3], 0.2) # ...low blue
  # the lit area approximates the mask circle: pi * 0.4^2 ~= 0.50 of the page
  lit <- mean(img[,, 1] > 0.5)
  expect_gt(lit, 0.4)
  expect_lt(lit, 0.6)
})

test_that("PDF text is embedded and selectable", {
  skip_if(unname(Sys.which("pdftotext")) == "", "pdftotext not available")
  f <- withr::local_tempfile(fileext = ".pdf")
  s <- vl_scene(3, 1, dpi = 100) |>
    draw(text_grob("VellumPDF", x = 0.5, y = 0.5, gp = vl_gpar(fontsize = 24)))
  render(s, f)
  txt <- paste(
    system2("pdftotext", c(shQuote(f), "-"), stdout = TRUE),
    collapse = " "
  )
  expect_match(txt, "VellumPDF")
})

# VR-38: a missing marker size or radius reached krilla as a NaN scale; krilla
# panicked, and the panic unwound through a destructor that asserts, which
# aborted the whole R process. Missing elements are now skipped, as the PNG
# backend always did, so the page equals one drawn without them. The renders
# run in a child process (`run_vellum_child()`), so a regression fails this
# test instead of killing the test run.
test_that("PDF skips markers and circles with a missing size (VR-38)", {
  res <- run_vellum_child(c(
    "scene <- function(size, r) {",
    "  x <- vl_unit(seq(0.2, 0.8, length.out = length(size)), 'npc')",
    "  gp <- vl_gpar(fill = 'red', col = 'black')",
    "  vl_scene(2, 2, dpi = 72) |>",
    "    draw(points_grob(x, vl_unit(0.6, 'npc'), size = vl_unit(size, 'mm'), gp = gp)) |>",
    "    draw(points_grob(x, vl_unit(0.4, 'npc'), size = vl_unit(size, 'mm'),",
    "      shape = 'square', gp = gp)) |>",
    "    draw(circle_grob(vl_unit(seq(0.2, 0.8, length.out = length(r)), 'npc'),",
    "      vl_unit(0.2, 'npc'), r = r, gp = vl_gpar(fill = 'blue', col = 'black')))",
    "}",
    "bytes <- function(s) {",
    "  f <- tempfile(fileext = '.pdf')",
    "  render(s, f)",
    "  readBin(f, 'raw', file.size(f))",
    "}",
    "ok <- bytes(scene(c(2, 3), c(0.05, 0.1)))",
    "for (bad in c(NA, NaN, Inf)) {",
    "  cat(identical(bytes(scene(c(2, bad, 3), c(0.05, bad, 0.1))), ok), '\\n')",
    "}"
  ))
  expect_identical(res$status, 0L)
  expect_identical(trimws(tail(res$output, 3)), rep("TRUE", 3))
})

test_that("a krilla failure is an R error, not a crash (VR-38)", {
  # At 36 dpi the page scale enlarges a box near the float limit past it
  # inside krilla; the walk now skips it, so the page renders.
  res <- run_vellum_child(c(
    "s <- vl_scene(3, 3, dpi = 36) |>",
    "  draw(rect_grob(x = vl_unit(3.3e38, 'pt'), width = vl_unit(3.3e38, 'pt'),",
    "    gp = vl_gpar(fill = 'red')))",
    "f <- tempfile(fileext = '.pdf')",
    "render(s, f)",
    "cat(rawToChar(readBin(f, 'raw', 5)), '\\n')"
  ))
  expect_identical(res$status, 0L)
  expect_identical(trimws(tail(res$output, 1)), "%PDF-")
})

test_that("geometry and hit testing leave out the discs that are not drawn (VR-38)", {
  s <- vl_scene(2, 2) |>
    draw(points_grob(
      c(0.3, 0.6),
      c(0.5, 0.5),
      size = vl_unit(c(2, NA), "mm"),
      key = c("a", "b")
    )) |>
    draw(circle_grob(c(0.3, 0.6), 0.2, r = c(0.1, NA), key = c("c", "d")))
  expect_setequal(element_geometry(s)$key, c("a", "c"))
  # nothing is drawn where the missing point would be
  expect_null(hit_test(s, 0.6, 0.5))
  expect_false(is.null(hit_test(s, 0.3, 0.5)))
})
