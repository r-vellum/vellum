svg_of <- function(scene) {
  f <- withr::local_tempfile(fileext = ".svg")
  render(scene, f)
  paste(readLines(f, warn = FALSE), collapse = "\n")
}

test_that("render() writes an SVG with the expected shape elements", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(
      x = 0.5,
      y = 0.5,
      width = 0.5,
      height = 0.5,
      gp = vl_gpar(fill = "red", col = "blue", lwd = 2)
    ))
  svg <- svg_of(s)
  expect_match(svg, "^<\\?xml")
  expect_match(svg, 'viewBox="0 0 100 100"')
  expect_match(svg, "<path")
  expect_match(svg, 'fill="#ff0000"') # red fill
  expect_match(svg, 'stroke="#0000ff"') # blue stroke
})

test_that("scene_svg() returns the SVG as a string, matching render()", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(
      x = 0.5,
      y = 0.5,
      width = 0.5,
      height = 0.5,
      gp = vl_gpar(fill = "red")
    ))
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
    draw(points_grob(
      c(0.3, 0.6, 0.9),
      0.5,
      size = vl_unit(4, "mm"),
      gp = vl_gpar(fill = "red"),
      key = c("a", "b", "c")
    ))
  svg <- scene_svg(s)
  expect_match(svg, 'data-key="a"')
  expect_match(svg, 'data-key="b"')
  expect_match(svg, 'data-key="c"')

  # rects
  s2 <- vl_scene(1, 1, dpi = 100) |>
    draw(rect_grob(
      x = c(0.3, 0.7),
      y = 0.5,
      width = 0.2,
      height = 0.2,
      gp = vl_gpar(fill = "blue"),
      key = c("r1", "r2")
    ))
  expect_match(scene_svg(s2), 'data-key="r1"')
  expect_match(scene_svg(s2), 'data-key="r2"')

  # segments (combined path is split per-element when keyed)
  s3 <- vl_scene(1, 1, dpi = 100) |>
    draw(segments_grob(
      c(0.1, 0.5),
      c(0.1, 0.5),
      c(0.4, 0.9),
      c(0.4, 0.9),
      gp = vl_gpar(col = "black", lwd = 2),
      key = c("s1", "s2")
    ))
  expect_match(scene_svg(s3), 'data-key="s1"')
  expect_match(scene_svg(s3), 'data-key="s2"')

  # markers (non-circle shapes)
  s4 <- vl_scene(1, 1, dpi = 100) |>
    draw(points_grob(
      c(0.3, 0.7),
      0.5,
      shape = c("square", "triangle"),
      size = vl_unit(4, "mm"),
      gp = vl_gpar(fill = "green"),
      key = c("m1", "m2")
    ))
  expect_match(scene_svg(s4), 'data-key="m1"')
  expect_match(scene_svg(s4), 'data-key="m2"')
})

test_that("keys are gated: no keys => no data-key attribute (unchanged output)", {
  keyed <- vl_scene(1, 1, dpi = 100) |>
    draw(points_grob(
      c(0.3, 0.6),
      0.5,
      gp = vl_gpar(fill = "red"),
      key = c("a", "b")
    ))
  keyless <- vl_scene(1, 1, dpi = 100) |>
    draw(points_grob(c(0.3, 0.6), 0.5, gp = vl_gpar(fill = "red")))
  expect_match(scene_svg(keyed), "data-key")
  expect_no_match(scene_svg(keyless), "data-key")
})

test_that("a data-key never leaks from a keyed grob onto a later keyless grob", {
  s <- vl_scene(1, 1, dpi = 100) |>
    draw(points_grob(0.3, 0.5, gp = vl_gpar(fill = "red"), key = "a")) |>
    draw(rect_grob(
      x = 0.7,
      y = 0.5,
      width = 0.2,
      height = 0.2,
      gp = vl_gpar(fill = "blue")
    ))
  svg <- scene_svg(s)
  # the point carries the key; the rect (drawn after) must not inherit it —
  # i.e. every data-key in the document is ="a" (none leaked onto the rect).
  all_keys <- regmatches(svg, gregexpr('data-key="[^"]*"', svg))[[1]]
  expect_match(svg, 'data-key="a"')
  expect_true(all(all_keys == 'data-key="a"'))
})

test_that("single-shape grobs (path/lines/polygon) carry a data-key when keyed", {
  mk <- function(g) {
    g@keys <- "feat1"
    scene_svg(vl_scene(1, 1, dpi = 100) |> draw(g))
  }
  expect_match(
    mk(path_grob(c(0.2, 0.8, 0.8), c(0.2, 0.2, 0.8), gp = vl_gpar(fill = "red"))),
    'data-key="feat1"'
  )
  expect_match(
    mk(polygon_grob(c(0.2, 0.8, 0.8), c(0.2, 0.2, 0.8), gp = vl_gpar(fill = "red"))),
    'data-key="feat1"'
  )
  expect_match(
    mk(lines_grob(c(0.2, 0.8), c(0.2, 0.8), gp = vl_gpar(col = "black", lwd = 2))),
    'data-key="feat1"'
  )
  # unkeyed single-shape grobs emit no data-key (unchanged output)
  expect_no_match(
    scene_svg(
      vl_scene(1, 1, dpi = 100) |>
        draw(path_grob(
          c(0.2, 0.8, 0.8),
          c(0.2, 0.2, 0.8),
          gp = vl_gpar(fill = "red")
        ))
    ),
    "data-key"
  )
})

test_that("a named viewport becomes a <g data-vellum-panel> group", {
  s <- vl_scene(1, 1, dpi = 100) |>
    push(vl_viewport(width = 0.8, height = 0.8, name = "panel-1-1")) |>
    draw(rect_grob(gp = vl_gpar(fill = "red")))
  svg <- scene_svg(s)
  expect_match(svg, '<g data-vellum-panel="panel-1-1">')
})

test_that("unnamed and root viewports emit no panel group (unchanged output)", {
  # unnamed pushed viewport
  s <- vl_scene(1, 1, dpi = 100) |>
    push(vl_viewport(width = 0.8, height = 0.8)) |>
    draw(rect_grob(gp = vl_gpar(fill = "red")))
  expect_no_match(scene_svg(s), "data-vellum-panel")
  # a plain scene (only the implicit "root" viewport) — never a panel group
  s2 <- vl_scene(1, 1, dpi = 100) |>
    draw(rect_grob(gp = vl_gpar(fill = "red")))
  expect_no_match(scene_svg(s2), "data-vellum-panel")
})

test_that("clipped viewports emit a clipPath and reference it", {
  s <- vl_scene(1, 1, dpi = 100) |>
    push(vl_viewport(width = 0.5, height = 0.5, clip = TRUE)) |>
    draw(rect_grob(gp = vl_gpar(fill = "red", col = NA)))
  svg <- svg_of(s)
  expect_match(svg, "<clipPath")
  expect_match(svg, 'clip-path="url\\(#')
})

test_that("a nested viewport's transform places solid geometry in device px", {
  s <- vl_scene(1, 1, dpi = 100) |>
    push(vl_viewport(x = 0.7, y = 0.3, width = 0.4, height = 0.4)) |>
    draw(rect_grob(gp = vl_gpar(fill = "red", col = NA)))
  # A solid fill is transform-invariant, so the viewport offset is baked into
  # the coordinates rather than carried as a per-element matrix.
  svg <- svg_of(s)
  expect_match(svg, 'd="M50 50 L90 50 L90 90 L50 90 Z"', fixed = TRUE)
  expect_no_match(svg, "matrix(", fixed = TRUE)
})

test_that("a gradient fill keeps local geometry and the element's matrix", {
  # The gradient is laid out in local px (userSpaceOnUse), so baking the
  # transform into the path would move the shape off its ramp.
  g <- linear_gradient(c("red", "blue"), x1 = 0, x2 = 1)
  s <- vl_scene(1, 1, dpi = 100) |>
    push(vl_viewport(x = 0.7, y = 0.3, width = 0.4, height = 0.4)) |>
    draw(rect_grob(gp = vl_gpar(fill = g, col = NA)))
  svg <- svg_of(s)
  expect_match(svg, 'fill="url(#', fixed = TRUE)
  expect_match(svg, "transform=\"matrix(", fixed = TRUE)
})

test_that("a filled + stroked point is one keyed <circle> carrying both paints (VW-12)", {
  # vellumwidget's DOM contract: every drawn element of a keyed datum carries
  # its own data-key. A solid fill with an undashed solid stroke is one element
  # (SVG paints fill, then stroke: what the fill + fill="none" twin drew).
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(points_grob(
      x = c(0.25, 0.5, 0.75),
      y = c(0.25, 0.5, 0.75),
      key = c("a", "b", "c"),
      gp = vl_gpar(fill = "#336699", col = "#112233", lwd = 1)
    ))
  svg <- scene_svg(s)
  circles <- regmatches(svg, gregexpr("<circle[^>]*>", svg))[[1]]
  expect_length(circles, 3L)
  keys <- sub('.*data-key="([^"]*)".*', "\\1", circles)
  expect_identical(keys, c("a", "b", "c"))
  expect_true(all(grepl(
    'fill="#336699" stroke="#112233" stroke-width="',
    circles,
    fixed = TRUE
  )))
  expect_no_match(svg, 'fill="none"', fixed = TRUE)
  # a circle has no ends or corners: no cap/join/miter attributes
  expect_no_match(svg, "stroke-line|stroke-miter")
  expect_no_match(svg, "<circle[^>]*transform=")
  # coordinates are rounded to 2 decimals; opaque paint omits its opacity
  geom <- sub('.*(cx="[^"]*" cy="[^"]*" r="[^"]*").*', "\\1", circles)
  nums <- regmatches(geom, gregexpr("[0-9.]+", geom))
  expect_false(any(grepl("\\.[0-9]{3}", unlist(nums))))
  expect_no_match(paste(circles, collapse = ""), "fill-opacity|stroke-opacity")
})

test_that("a dashed or gradient-stroked point keeps the fill + stroke twin (VW-12)", {
  pts <- function(gp) {
    vl_scene(2, 2, dpi = 100) |>
      draw(points_grob(
        x = c(0.25, 0.75),
        y = c(0.25, 0.75),
        key = c("a", "b"),
        gp = gp
      )) |>
      scene_svg()
  }
  twin <- function(svg) {
    els <- regmatches(svg, gregexpr("<(circle|path)[^>]*data-key[^>]*>", svg))[[1]]
    keys <- sub('.*data-key="([^"]*)".*', "\\1", els)
    expect_identical(keys, rep(c("a", "b"), each = 2L))
    expect_true(all(grepl('fill="none"', els[c(2L, 4L)], fixed = TRUE)))
    expect_false(any(grepl("stroke=", els[c(1L, 3L)], fixed = TRUE)))
  }
  twin(pts(vl_gpar(fill = "#336699", col = "black", lwd = 2, lty = "dashed")))
  twin(pts(vl_gpar(
    fill = "#336699",
    col = linear_gradient(c("red", "blue")),
    lwd = 2
  )))
  twin(pts(vl_gpar(
    fill = linear_gradient(c("red", "blue")),
    col = "black",
    lwd = 2
  )))
})

test_that("a filled + stroked rect is one element too (VW-12)", {
  svg <- vl_scene(1, 1, dpi = 100) |>
    draw(rect_grob(
      width = 0.5,
      height = 0.5,
      gp = vl_gpar(fill = "red", col = "blue", lwd = 2)
    )) |>
    scene_svg()
  els <- regmatches(svg, gregexpr("<path[^>]*>", svg))[[1]]
  expect_length(els, 1L)
  expect_match(els, 'fill="#ff0000" stroke="#0000ff"', fixed = TRUE)
  # a path keeps its cap and join
  expect_match(els, "stroke-linejoin=", fixed = TRUE)
})

test_that("an unkeyed point batch is drawn as circles too", {
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(points_grob(
      x = c(0.25, 0.75),
      y = c(0.25, 0.75),
      gp = vl_gpar(fill = "black", col = "black", lwd = 1)
    ))
  svg <- scene_svg(s)
  expect_length(regmatches(svg, gregexpr("<circle", svg))[[1]], 2L)
  expect_no_match(svg, "<path", fixed = TRUE)
})

test_that("translucent paint still writes its opacity", {
  s <- vl_scene(1, 1, dpi = 100) |>
    draw(rect_grob(gp = vl_gpar(fill = "#FF000080", col = "#0000FF80", lwd = 2)))
  svg <- scene_svg(s)
  expect_match(svg, 'fill-opacity="0.5', fixed = TRUE)
  expect_match(svg, 'stroke-opacity="0.5', fixed = TRUE)
})

test_that("clip on an offset viewport wraps a <g> (clip space stays in device coords)", {
  # Regression: putting clip-path on the transformed element double-transforms
  # the clip region; an off-origin clipped viewport must clip via a wrapping <g>.
  s <- vl_scene(1, 1, dpi = 100) |>
    push(vl_viewport(
      x = 0.7,
      y = 0.3,
      width = 0.4,
      height = 0.4,
      clip = TRUE
    )) |>
    draw(rect_grob(gp = vl_gpar(fill = "red", col = NA)))
  expect_match(svg_of(s), '<g clip-path="url\\(#[^)]+\\)"><path')
})

test_that("text becomes a <text> element carrying the label and font", {
  s <- vl_scene(2, 1, dpi = 100) |>
    draw(text_grob("hello", gp = vl_gpar(fontsize = 20, fontface = "bold")))
  svg <- svg_of(s)
  expect_match(svg, "<text")
  expect_match(svg, ">hello</text>")
  expect_match(svg, 'font-size="')
  expect_match(svg, 'font-weight="bold"')
})

test_that("text = 'outline' emits glyph outlines instead of <text> (FW5)", {
  s <- vl_scene(2, 1, dpi = 100) |>
    draw(text_grob("Ag", x = 0.5, y = 0.5, gp = vl_gpar(fontsize = 40)))
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
  b64 <- sub(
    "^base64,",
    "",
    regmatches(svg, regexpr("base64,[A-Za-z0-9+/=]+", svg))
  )
  tmp <- withr::local_tempfile(fileext = ".png")
  writeBin(base64enc::base64decode(b64), tmp)
  arr <- png::readPNG(tmp) # h x w x 4, 0..1
  expect_equal(round(arr[1, 1, ], 3), c(1, 0, 0, 0)) # red preserved, alpha 0
})

test_that("a compositing group inside a named panel wraps its own content in SVG", {
  # The group's buffer used to lose to the panel's: its marks were written
  # before an empty `<g style="mix-blend-mode:…">` (or opacity / mask group).
  for (pan in c(FALSE, TRUE)) {
    vps <- list(
      blend = vl_viewport(blend = "screen"),
      alpha = vl_viewport(alpha = 0.5),
      mask = vl_viewport(mask = as_mask(rect_grob(width = 0.5, gp = vl_gpar(fill = "black"))))
    )
    pattern <- c(
      blend = '<g style="mix-blend-mode:screen"><g data-vellum-id="lay1">(<g clip-path="[^"]*">)?<path data-key="m"',
      alpha = '<g opacity="0.5"><g data-vellum-id="lay1">(<g clip-path="[^"]*">)?<path data-key="m"',
      mask = '<g mask="url\\(#[^"]+\\)"><g data-vellum-id="lay1">(<g clip-path="[^"]*">)?<path data-key="m"'
    )
    for (nm in names(vps)) {
      s <- vl_scene(2, 2, dpi = 72) |>
        push(vl_viewport(name = "panel-1", pannable = pan, clip = TRUE)) |>
        draw(rect_grob(gp = vl_gpar(fill = "grey"))) |>
        push(vps[[nm]]) |>
        draw(circle_grob(0.5, 0.5, r = 0.2, gp = vl_gpar(fill = "orange"), key = "m", id = "lay1")) |>
        pop() |>
        pop()
      svg <- gsub("\n", "", scene_svg(s))
      expect_match(svg, pattern[[nm]], info = paste(nm, "pannable =", pan))
      expect_false(grepl("<g (style|opacity|mask)=\"[^\"]*\"></g>", svg), info = paste(nm, "pannable =", pan))
    }
  }
  # the group's own clip-path and the panel's hoisted clip still nest
  s <- vl_scene(2, 2, dpi = 72) |>
    push(vl_viewport(name = "panel-1", pannable = TRUE, clip = TRUE)) |>
    push(vl_viewport(blend = "multiply")) |>
    draw(circle_grob(0.5, 0.5, r = 0.2, key = "m", id = "lay1")) |>
    pop() |>
    pop()
  svg <- gsub("\n", "", scene_svg(s))
  expect_match(svg, '<g data-vellum-panel="panel-1"[^>]*><g data-vellum-pan="panel-1"><g style="mix-blend-mode:multiply">')
})
