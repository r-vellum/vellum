# Tiling-pattern fills. Raster probes build a scene with the public API and read
# pixels via px(); SVG asserts the <pattern>/<image> structure; PDF checks the
# average-colour fallback renders.

test_that("vl_pattern() builds and validates", {
  p <- vl_pattern(circle_grob(r = 0.3), width = 0.2, height = 0.2)
  expect_s3_class(p, "vellum_pattern")
  expect_error(vl_pattern(circle_grob(), width = Inf), "finite")
  expect_error(vl_pattern(circle_grob(), extend = "bounce"))
})

test_that("a pattern tiles its grob across the fill (raster)", {
  tile <- list(
    rect_grob(gp = vl_gpar(fill = "red", col = NA)),
    circle_grob(r = 0.3, gp = vl_gpar(fill = "white", col = NA))
  )
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    draw(rect_grob(
      gp = vl_gpar(col = NA, fill = vl_pattern(tile, width = 0.2, height = 0.2))
    ))
  # Cell is 0.2 npc = 20 px, centred on the page -> a tile centre sits at the
  # page centre (white dot); a tile corner is the red background.
  centre <- px(s, 50, 50)
  corner <- px(s, 41, 41)
  expect_true(all(centre[1:3] > 230L)) # white dot
  expect_equal(corner[1:3], c(255L, 0L, 0L)) # red bg
})

test_that("pattern alpha fades the tile (raster)", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    draw(rect_grob(
      gp = vl_gpar(
        col = NA,
        alpha = 0.5,
        fill = vl_pattern(
          rect_grob(gp = vl_gpar(fill = "red", col = NA)),
          width = 0.5,
          height = 0.5
        )
      )
    ))
  p <- px(s, 50, 50)
  expect_equal(p[4], 255L) # opaque page
  # 50% red over white -> pink
  expect_true(p[1] > 240L && abs(p[2] - 127L) < 12L && abs(p[3] - 127L) < 12L)
})

test_that("SVG emits a <pattern> with an embedded image", {
  f <- withr::local_tempfile(fileext = ".svg")
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(
      gp = vl_gpar(
        col = NA,
        fill = vl_pattern(
          circle_grob(r = 0.3, gp = vl_gpar(fill = "red", col = NA)),
          width = 0.25,
          height = 0.25
        )
      )
    ))
  render(s, f)
  svg <- paste(readLines(f, warn = FALSE), collapse = "\n")
  expect_match(svg, "<pattern ")
  expect_match(svg, 'patternUnits="userSpaceOnUse"')
  expect_match(svg, "<image ")
  expect_match(svg, "data:image/png;base64,")
  expect_match(svg, 'fill="url\\(#vl[0-9a-f]{8}-g0\\)"')
})

test_that("PDF renders a pattern fill (average-colour fallback)", {
  f <- withr::local_tempfile(fileext = ".pdf")
  s <- vl_scene(2, 1, dpi = 100) |>
    draw(rect_grob(
      gp = vl_gpar(
        col = NA,
        fill = vl_pattern(
          circle_grob(r = 0.3, gp = vl_gpar(fill = "red", col = NA)),
          width = 0.25,
          height = 0.25
        )
      )
    ))
  expect_no_error(render(s, f))
  expect_equal(rawToChar(readBin(f, "raw", 5)), "%PDF-")
})

test_that("a pattern used outside a render context errors clearly", {
  expect_error(.encode_paint(vl_pattern(circle_grob())), "scene")
})

# VR-7: pattern paint resolves the same on every backend -- as a stroke, and
# with `extend = "reflect"` (SVG/PDF tiling patterns can only repeat, so a
# reflected pattern is a 2x2 mirrored tile everywhere).
pdf_pixel <- function(s, x, y, dpi = 100) {
  skip_if(unname(Sys.which("pdftoppm")) == "", "pdftoppm not available")
  f <- withr::local_tempfile(fileext = ".pdf")
  render(s, f)
  stem <- withr::local_tempfile()
  system2(
    "pdftoppm",
    c("-png", "-singlefile", "-r", dpi, shQuote(f), shQuote(stem))
  )
  img <- png::readPNG(paste0(stem, ".png"))
  round(img[y + 1L, x + 1L, 1:3] * 255)
}
halves <- function() {
  list(
    rect_grob(x = 0.25, width = 0.5, gp = vl_gpar(fill = "red", col = NA)),
    rect_grob(x = 0.75, width = 0.5, gp = vl_gpar(fill = "blue", col = NA))
  )
}
halves_scene <- function(extend) {
  vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(
      gp = vl_gpar(
        col = NA,
        fill = vl_pattern(halves(), width = 0.2, height = 0.2, extend = extend)
      )
    ))
}

test_that("a reflected pattern mirrors every other cell on every backend", {
  # Cell is 20 px from x = 40: red [40, 50), blue [50, 60). The next cell
  # repeats (red at 65) or mirrors (blue at 65); the one before repeats
  # (blue at 35) or mirrors (red at 35).
  rep_s <- halves_scene("repeat")
  ref_s <- halves_scene("reflect")
  expect_equal(px(rep_s, 65, 50)[1:3], c(255L, 0L, 0L))
  expect_equal(px(ref_s, 65, 50)[1:3], c(0L, 0L, 255L))
  expect_equal(px(rep_s, 35, 50)[1:3], c(0L, 0L, 255L))
  expect_equal(px(ref_s, 35, 50)[1:3], c(255L, 0L, 0L))
  # SVG tiles a mirrored tile spanning two cells from the same corner
  svg <- scene_svg(ref_s)
  expect_match(svg, 'x="40" y="40" width="40" height="40"', fixed = TRUE)
  expect_equal(pdf_pixel(ref_s, 65, 50), c(0, 0, 255))
  expect_equal(pdf_pixel(ref_s, 35, 50), c(255, 0, 0))
})

test_that('extend = "pad" is rejected for patterns', {
  expect_error(vl_pattern(circle_grob(), extend = "pad"), "pad")
})

stroke_scene <- function(col) {
  vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, gp = vl_gpar(col = col, lwd = 20)))
}
red_tile <- function() {
  vl_pattern(
    rect_grob(gp = vl_gpar(fill = "red", col = NA)),
    width = 0.2,
    height = 0.2
  )
}

test_that("a pattern in col strokes with the pattern on every backend", {
  s <- stroke_scene(red_tile())
  expect_equal(px(s, 100, 50)[1:3], c(255L, 0L, 0L)) # not the black fallback
  expect_equal(px(s, 100, 20)[1:3], c(255L, 255L, 255L)) # still only the stroke
  expect_match(scene_svg(s), 'stroke="url(#', fixed = TRUE)
  expect_equal(pdf_pixel(s, 100, 50), c(255, 0, 0))
})

test_that("a faded pattern stroke carries its opacity into SVG", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(
      0.1,
      0.5,
      0.9,
      0.5,
      gp = vl_gpar(col = red_tile(), lwd = 20, alpha = 0.5)
    ))
  expect_match(scene_svg(s), 'stroke-opacity="0.5"', fixed = TRUE)
  p <- px(s, 100, 50)
  expect_true(p[1] > 240L && abs(p[2] - 127L) < 12L)
})

test_that("a hatch in col is rejected", {
  expect_error(
    .scene_to_backend(stroke_scene(vl_hatch(col = "red"))),
    "vl_hatch"
  )
})

test_that("vl_pattern() takes vl_unit() cell sizes (VL-18)", {
  g <- circle_grob(r = 0.3, gp = vl_gpar(fill = "red", col = NA))
  # an absolute size keeps its unit; the centre stays in `units`
  p <- vl_pattern(g, width = vl_unit(5, "mm"), height = vl_unit(5, "mm"))
  expect_identical(c(p$width, p$height), c(5, 5))
  expect_identical(p$units, "npc")
  expect_identical(p$size_units, "mm")
  expect_match(cli::cli_fmt(print(p)), "5 x 5 \"mm\"", all = FALSE)
  # converted when `units` is absolute, so nothing extra is recorded
  p <- vl_pattern(g, vl_unit(1, "in"), vl_unit(36, "pt"), units = "mm")
  expect_equal(c(p$width, p$height), c(25.4, 12.7))
  expect_null(p$size_units)
  # two absolute units meet in millimetres
  p <- vl_pattern(g, vl_unit(1, "cm"), vl_unit(1, "in"))
  expect_equal(c(p$width, p$height), c(10, 25.4))
  expect_identical(p$size_units, "mm")
  # the same unit as `units` changes nothing
  expect_identical(
    vl_pattern(g, vl_unit(0.2, "npc"), vl_unit(0.2, "npc")),
    vl_pattern(g, 0.2, 0.2)
  )
  # a position converts to `units`
  p <- vl_pattern(g, 5, 5, x = vl_unit(1, "in"), units = "pt")
  expect_identical(p$x, 72)
})

test_that("a vl_unit() pattern cell renders at its physical size (VL-18)", {
  tile <- list(
    rect_grob(gp = vl_gpar(fill = "red", col = NA)),
    circle_grob(r = 0.3, gp = vl_gpar(fill = "white", col = NA))
  )
  scene <- function(fill) {
    vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
      draw(rect_grob(gp = vl_gpar(col = NA, fill = fill)))
  }
  # on a 1 in page, 0.2 in cells are 0.2 npc cells
  a <- scene(vl_pattern(tile, vl_unit(0.2, "in"), vl_unit(0.2, "in")))
  b <- scene(vl_pattern(tile, 0.2, 0.2))
  expect_identical(.scene_to_backend(a)$rgba(), .scene_to_backend(b)$rgba())
})

test_that("vl_pattern() explains a vl_unit() it can't use (VL-18)", {
  g <- circle_grob()
  expect_error(
    vl_pattern(g, vl_unit(0.1, "npc"), vl_unit(5, "mm")),
    "must share a unit"
  )
  expect_error(
    vl_pattern(g, 0.1, vl_unit(5, "mm"), units = "native"),
    "must share a unit"
  )
  expect_error(vl_pattern(g, x = vl_unit(5, "mm")), "Can't convert")
  expect_error(vl_pattern(g, vl_unit(1:2, "mm"), 0.1), "single")
  expect_error(
    vl_pattern(g, vl_unit(1, "npc") + vl_unit(2, "mm"), 0.1),
    "compound"
  )
})
