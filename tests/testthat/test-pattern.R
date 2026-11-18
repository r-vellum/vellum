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
  expect_match(svg, 'fill="url\\(#g0\\)"')
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
