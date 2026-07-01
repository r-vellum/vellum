svg_text <- function(scene) {
  f <- tempfile(fileext = ".svg")
  on.exit(unlink(f))
  render(scene, f)
  paste(readLines(f, warn = FALSE), collapse = "")
}

test_that("a grob's id/role are emitted as SVG data-* / role attributes", {
  s <- vl_scene(2, 2) |>
    draw(circle_grob(r = 0.3, id = "pt1", role = "img", gp = gpar(fill = "red", col = NA)))
  txt <- svg_text(s)
  expect_match(txt, 'data-vellum-id="pt1"')
  expect_match(txt, 'role="img"')
})

test_that("a grob's name is emitted as data-vellum-name", {
  s <- vl_scene(2, 2) |>
    draw(rect_grob(width = 0.5, height = 0.5, name = "box", gp = gpar(fill = "blue")))
  expect_match(svg_text(s), 'data-vellum-name="box"')
})

test_that("grobs without metadata add no wrapping group/attributes", {
  s <- vl_scene(2, 2) |> draw(circle_grob(r = 0.3, gp = gpar(fill = "red", col = NA)))
  txt <- svg_text(s)
  expect_no_match(txt, "data-vellum-")
})

test_that("attribute values are XML-escaped", {
  s <- vl_scene(2, 2) |>
    draw(circle_grob(r = 0.3, id = 'a&b"c', gp = gpar(fill = "red", col = NA)))
  txt <- svg_text(s)
  expect_match(txt, "data-vellum-id=\"a&amp;b&quot;c\"")
})
