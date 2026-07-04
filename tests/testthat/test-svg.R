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

test_that("scene_svg() returns the SVG as a string, matching render()", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.5, height = 0.5,
                   gp = gpar(fill = "red")))
  svg <- scene_svg(s)
  expect_type(svg, "character")
  expect_length(svg, 1L)
  expect_match(svg, "^<\\?xml")
  expect_match(svg, "<path")
  expect_match(svg, 'fill="#ff0000"')
  # same document as writing to a file (modulo a trailing newline, which
  # readLines()/paste() in svg_of() drops)
  expect_identical(sub("\n$", "", svg), svg_of(s))
})

test_that("per-element keys emit a data-key on each batched primitive", {
  # points (circle fast path)
  s <- vl_scene(1, 1, dpi = 100) |>
    draw(points_grob(c(0.3, 0.6, 0.9), 0.5, size = unit(4, "mm"),
                     gp = gpar(fill = "red"), key = c("a", "b", "c")))
  svg <- scene_svg(s)
  expect_match(svg, 'data-key="a"')
  expect_match(svg, 'data-key="b"')
  expect_match(svg, 'data-key="c"')

  # rects
  s2 <- vl_scene(1, 1, dpi = 100) |>
    draw(rect_grob(x = c(0.3, 0.7), y = 0.5, width = 0.2, height = 0.2,
                   gp = gpar(fill = "blue"), key = c("r1", "r2")))
  expect_match(scene_svg(s2), 'data-key="r1"')
  expect_match(scene_svg(s2), 'data-key="r2"')

  # segments (combined path is split per-element when keyed)
  s3 <- vl_scene(1, 1, dpi = 100) |>
    draw(segments_grob(c(0.1, 0.5), c(0.1, 0.5), c(0.4, 0.9), c(0.4, 0.9),
                       gp = gpar(col = "black", lwd = 2), key = c("s1", "s2")))
  expect_match(scene_svg(s3), 'data-key="s1"')
  expect_match(scene_svg(s3), 'data-key="s2"')

  # markers (non-circle shapes)
  s4 <- vl_scene(1, 1, dpi = 100) |>
    draw(points_grob(c(0.3, 0.7), 0.5, shape = c("square", "triangle"),
                     size = unit(4, "mm"), gp = gpar(fill = "green"), key = c("m1", "m2")))
  expect_match(scene_svg(s4), 'data-key="m1"')
  expect_match(scene_svg(s4), 'data-key="m2"')
})

test_that("keys are gated: no keys => no data-key attribute (unchanged output)", {
  keyed <- vl_scene(1, 1, dpi = 100) |>
    draw(points_grob(c(0.3, 0.6), 0.5, gp = gpar(fill = "red"), key = c("a", "b")))
  keyless <- vl_scene(1, 1, dpi = 100) |>
    draw(points_grob(c(0.3, 0.6), 0.5, gp = gpar(fill = "red")))
  expect_match(scene_svg(keyed), "data-key")
  expect_no_match(scene_svg(keyless), "data-key")
})

test_that("a data-key never leaks from a keyed grob onto a later keyless grob", {
  s <- vl_scene(1, 1, dpi = 100) |>
    draw(points_grob(0.3, 0.5, gp = gpar(fill = "red"), key = "a")) |>
    draw(rect_grob(x = 0.7, y = 0.5, width = 0.2, height = 0.2, gp = gpar(fill = "blue")))
  svg <- scene_svg(s)
  # the point carries the key; the rect (drawn after) must not inherit it —
  # i.e. every data-key in the document is ="a" (none leaked onto the rect).
  all_keys <- regmatches(svg, gregexpr('data-key="[^"]*"', svg))[[1]]
  expect_match(svg, 'data-key="a"')
  expect_true(all(all_keys == 'data-key="a"'))
})

test_that("a named viewport becomes a <g data-vellum-panel> group", {
  s <- vl_scene(1, 1, dpi = 100) |>
    push(viewport(width = 0.8, height = 0.8, name = "panel-1-1")) |>
    draw(rect_grob(gp = gpar(fill = "red")))
  svg <- scene_svg(s)
  expect_match(svg, '<g data-vellum-panel="panel-1-1">')
})

test_that("unnamed and root viewports emit no panel group (unchanged output)", {
  # unnamed pushed viewport
  s <- vl_scene(1, 1, dpi = 100) |>
    push(viewport(width = 0.8, height = 0.8)) |>
    draw(rect_grob(gp = gpar(fill = "red")))
  expect_no_match(scene_svg(s), "data-vellum-panel")
  # a plain scene (only the implicit "root" viewport) — never a panel group
  s2 <- vl_scene(1, 1, dpi = 100) |>
    draw(rect_grob(gp = gpar(fill = "red")))
  expect_no_match(scene_svg(s2), "data-vellum-panel")
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

test_that("text = 'outline' emits glyph outlines instead of <text> (FW5)", {
  s <- vl_scene(2, 1, dpi = 100) |> draw(text_grob("Ag", x = 0.5, y = 0.5, gp = gpar(fontsize = 40)))
  f <- withr::local_tempfile(fileext = ".svg")
  render(s, f, text = "outline")
  svg <- paste(readLines(f, warn = FALSE), collapse = "\n")
  expect_no_match(svg, "<text")
  expect_match(svg, "<path d=\"M") # filled glyph outlines
})

test_that("special characters in labels are XML-escaped", {
  s <- vl_scene() |> draw(text_grob("a<b&c"))
  expect_match(svg_of(s), "a&lt;b&amp;c")
})

test_that("render() rejects unknown output formats", {
  f <- withr::local_tempfile(fileext = ".bmp")
  expect_error(render(vl_scene(), f), "Unsupported")
})

test_that("SVG image colour survives under fully-transparent texels", {
  # A transparent-but-red texel must keep its RGB in the embedded PNG (straight,
  # not premultiplied) so scaled/interpolated edges don't fringe to black.
  skip_if_not_installed("png")
  skip_if_not_installed("base64enc")
  img <- matrix("#FF000000", 2, 2) # red, alpha 0
  f <- withr::local_tempfile(fileext = ".svg")
  render(vl_scene(1, 1, dpi = 50, bg = "white") |> draw(raster_grob(img)), f)
  svg <- paste(readLines(f), collapse = "")
  b64 <- sub("^base64,", "", regmatches(svg, regexpr("base64,[A-Za-z0-9+/=]+", svg)))
  tmp <- withr::local_tempfile(fileext = ".png")
  writeBin(base64enc::base64decode(b64), tmp)
  arr <- png::readPNG(tmp) # h x w x 4, 0..1
  expect_equal(round(arr[1, 1, ], 3), c(1, 0, 0, 0)) # red preserved, alpha 0
})
