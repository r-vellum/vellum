test_that("render() writes a valid PDF", {
  f <- withr::local_tempfile(fileext = ".pdf")
  s <- vl_scene(2, 1, dpi = 100) |>
    draw(rect_grob(gp = gpar(fill = "red", col = NA))) |>
    draw(text_grob("hello"))
  render(s, f)
  bytes <- readBin(f, "raw", file.size(f))
  expect_equal(rawToChar(bytes[1:5]), "%PDF-")
  expect_gt(length(bytes), 500)
})

test_that("PDF clipping and nested viewports render without error", {
  f <- withr::local_tempfile(fileext = ".pdf")
  s <- vl_scene(2, 2, dpi = 100) |>
    push(viewport(width = 0.5, height = 0.5, clip = TRUE, xscale = c(0, 10), yscale = c(0, 10))) |>
    draw(circle_grob(unit(5, "native"), unit(5, "native"), r = 0.9,
                     gp = gpar(fill = "blue", col = NA)))
  expect_no_error(render(s, f))
  expect_equal(rawToChar(readBin(f, "raw", 5)), "%PDF-")
})

test_that("PDF text is embedded and selectable", {
  skip_if(unname(Sys.which("pdftotext")) == "", "pdftotext not available")
  f <- withr::local_tempfile(fileext = ".pdf")
  s <- vl_scene(3, 1, dpi = 100) |>
    draw(text_grob("VellumPDF", x = 0.5, y = 0.5, gp = gpar(fontsize = 24)))
  render(s, f)
  txt <- paste(system2("pdftotext", c(shQuote(f), "-"), stdout = TRUE), collapse = " ")
  expect_match(txt, "VellumPDF")
})
