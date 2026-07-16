svg_text <- function(scene) {
  f <- tempfile(fileext = ".svg")
  on.exit(unlink(f))
  render(scene, f)
  paste(readLines(f, warn = FALSE), collapse = "")
}

test_that("a grob's id/role are emitted as SVG data-* / role attributes", {
  s <- vl_scene(2, 2) |>
    draw(circle_grob(r = 0.3, id = "pt1", role = "img", gp = vl_gpar(fill = "red", col = NA)))
  txt <- svg_text(s)
  expect_match(txt, 'data-vellum-id="pt1"')
  expect_match(txt, 'role="img"')
})

test_that("a grob's name is emitted as data-vellum-name", {
  s <- vl_scene(2, 2) |>
    draw(rect_grob(width = 0.5, height = 0.5, name = "box", gp = vl_gpar(fill = "blue")))
  expect_match(svg_text(s), 'data-vellum-name="box"')
})

test_that("grobs without metadata add no wrapping group/attributes", {
  s <- vl_scene(2, 2) |> draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "red", col = NA)))
  txt <- svg_text(s)
  expect_no_match(txt, "data-vellum-")
})

test_that("attribute values are XML-escaped", {
  s <- vl_scene(2, 2) |>
    draw(circle_grob(r = 0.3, id = 'a&b"c', gp = vl_gpar(fill = "red", col = NA)))
  txt <- svg_text(s)
  expect_match(txt, "data-vellum-id=\"a&amp;b&quot;c\"")
})

test_that("a named colourless text grob keeps following SVG output well-nested", {
  # Regression: a *named* (metadata) text grob with col = NA is a non-rich
  # label with no shared colour, so the scene walk skipped it -- but it had
  # already opened a metadata <g>. Failing to close that node left the SVG
  # backend's node buffer dangling and mis-nested every following element.
  s <- vl_scene(2, 2) |>
    draw(text_grob("hi", id = "t1", gp = vl_gpar(col = NA))) |>
    draw(rect_grob(width = 0.5, height = 0.5, name = "after", gp = vl_gpar(fill = "blue")))
  txt <- svg_text(s)
  # The following grob's metadata still lands in the document...
  expect_match(txt, 'data-vellum-name="after"')
  # ...and the whole document parses as balanced XML (unbalanced <g> throws).
  expect_no_error(xml2::read_xml(txt))
})
