test_that("render(debug = TRUE) adds overlay content and still renders", {
  s <- vl_scene(4, 3) |>
    push(vl_viewport(name = "panel", width = vl_unit(2, "in"), height = vl_unit(1, "in"))) |>
    draw(rect_grob(gp = vl_gpar(fill = "grey90", col = NA)))
  plain <- tempfile(fileext = ".png")
  dbg <- tempfile(fileext = ".png")
  on.exit(unlink(c(plain, dbg)))
  render(s, plain)
  render(s, dbg, debug = TRUE)
  # The overlay draws extra ink, so the debug PNG differs from (and is generally
  # larger than) the plain one, and both are non-empty.
  expect_gt(file.info(plain)$size, 0)
  expect_gt(file.info(dbg)$size, 0)
  expect_false(identical(readBin(plain, "raw", file.info(plain)$size),
                         readBin(dbg, "raw", file.info(dbg)$size)))
})

test_that("debug overlay labels named viewports in SVG", {
  s <- vl_scene(4, 3) |>
    push(vl_viewport(name = "panel", width = vl_unit(2, "in"), height = vl_unit(1, "in")))
  f <- tempfile(fileext = ".svg")
  on.exit(unlink(f))
  render(s, f, debug = TRUE)
  expect_match(paste(readLines(f, warn = FALSE), collapse = ""), "panel")
})

test_that("why_size() reports a size-placed viewport's resolved extent", {
  s <- vl_scene(4, 3) |>
    push(vl_viewport(name = "panel", width = vl_unit(2, "in"), height = vl_unit(1, "in")))
  w <- why_size(s, "panel")
  expect_s3_class(w, "vellum_why_size")
  expect_equal(w$width_mm, 50.8, tolerance = 1e-6)  # 2 in
  expect_equal(w$height_mm, 25.4, tolerance = 1e-6) # 1 in
  expect_match(w$determined_by, "width = 2in")
})

test_that("why_size() names the layout track for a cell-placed viewport", {
  lay <- grid_layout(widths = c(vl_unit(30, "mm"), vl_unit(1, "null")), heights = vl_unit(1, "null"))
  s <- vl_scene(4, 3) |>
    push(vl_viewport(name = "grid", layout = lay)) |>
    push(vl_viewport(name = "panelB", row = 1, col = 2))
  w <- why_size(s, "panelB")
  # page 4 in = 101.6 mm; col 1 = 30 mm; col 2 (null) = 71.6 mm
  expect_equal(w$width_mm, 71.6, tolerance = 1e-3)
  expect_match(w$determined_by, "column 2")
  expect_match(w$determined_by, "null")
})

test_that("why_size() errors on an unknown name", {
  s <- vl_scene(2, 2)
  expect_error(why_size(s, "nope"), "No node named")
})

test_that("why_size() returns the documented record shape", {
  s <- vl_scene(4, 3) |>
    push(vl_viewport(name = "panel", width = vl_unit(2, "in"), height = vl_unit(1, "in")))
  w <- why_size(s, "panel")
  expect_named(w, c("name", "width_mm", "height_mm", "determined_by"))
  expect_match(w$determined_by, "width = 2in")
  # The print method runs cleanly (dispatch mirrors the package's other internal
  # `print.vellum_*` methods; cli writes via its own connection).
  expect_no_error(vellum:::print.vellum_why_size(w))
})
