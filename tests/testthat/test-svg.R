svg_of <- function(scene) {
  f <- withr::local_tempfile(fileext = ".svg")
  render(scene, f)
  paste(readLines(f, warn = FALSE), collapse = "\n")
}

test_that("render() writes an SVG with the expected shape elements", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.5, height = 0.5,
                   gp = gpar(fill = "red", col = "blue", lwd = 2)))
  svg <- svg_of(s)
  expect_match(svg, "^<\\?xml")
  expect_match(svg, 'viewBox="0 0 100 100"')
  expect_match(svg, "<path")
  expect_match(svg, 'fill="#ff0000"') # red fill
  expect_match(svg, 'stroke="#0000ff"') # blue stroke
})

test_that("clipped viewports emit a clipPath and reference it", {
  s <- vl_scene(1, 1, dpi = 100) |>
    push(viewport(width = 0.5, height = 0.5, clip = TRUE)) |>
    draw(rect_grob(gp = gpar(fill = "red", col = NA)))
  svg <- svg_of(s)
  expect_match(svg, "<clipPath")
  expect_match(svg, 'clip-path="url\\(#')
})

test_that("a nested viewport's transform appears as a matrix", {
  s <- vl_scene(1, 1, dpi = 100) |>
    push(viewport(x = 0.7, y = 0.3, width = 0.4, height = 0.4)) |>
    draw(rect_grob(gp = gpar(fill = "red", col = NA)))
  expect_match(svg_of(s), "matrix\\(") # viewport offset -> translate matrix
})

test_that("clip on an offset viewport wraps a <g> (clip space stays in device coords)", {
  # Regression: putting clip-path on the transformed element double-transforms
  # the clip region; an off-origin clipped viewport must clip via a wrapping <g>.
  s <- vl_scene(1, 1, dpi = 100) |>
    push(viewport(x = 0.7, y = 0.3, width = 0.4, height = 0.4, clip = TRUE)) |>
    draw(rect_grob(gp = gpar(fill = "red", col = NA)))
  expect_match(svg_of(s), '<g clip-path="url\\(#[^)]+\\)"><path')
})

test_that("text becomes a <text> element carrying the label and font", {
  s <- vl_scene(2, 1, dpi = 100) |>
    draw(text_grob("hello", gp = gpar(fontsize = 20, fontface = "bold")))
  svg <- svg_of(s)
  expect_match(svg, "<text")
  expect_match(svg, ">hello</text>")
  expect_match(svg, 'font-size="')
  expect_match(svg, 'font-weight="bold"')
})

test_that("special characters in labels are XML-escaped", {
  s <- vl_scene() |> draw(text_grob("a<b&c"))
  expect_match(svg_of(s), "a&lt;b&amp;c")
})

test_that("render() rejects unknown output formats", {
  f <- withr::local_tempfile(fileext = ".bmp")
  expect_error(render(vl_scene(), f), "Unsupported")
})
