test_that("scene dimensions follow size and dpi", {
  s <- vl_scene(width = 2, height = 1, dpi = 100)
  expect_equal(scene_dim(s), c(200L, 100L))
})

test_that("background colour fills the page", {
  s <- vl_scene(width = 1, height = 1, dpi = 50, bg = "white")
  expect_equal(px(s, 0, 0), c(255L, 255L, 255L, 255L))
  expect_equal(px(s, 25, 25), c(255L, 255L, 255L, 255L))

  s2 <- vl_scene(width = 1, height = 1, dpi = 50, bg = "red")
  expect_equal(px(s2, 25, 25), c(255L, 0L, 0L, 255L))
})

test_that("primitives accumulate in the scene", {
  s0 <- vl_scene(width = 1, height = 1, dpi = 50)
  expect_equal(scene_len(s0), 0L)
  s <- s0 |>
    draw(rect_grob(gp = vl_gpar(fill = "blue"))) |>
    draw(circle_grob(gp = vl_gpar(fill = "green")))
  expect_equal(scene_len(s), 2L)
})

test_that("a filled rect paints the centre and leaves the corner as background", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    # centred rect covering the middle half of the page
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.5, height = 0.5, gp = vl_gpar(fill = "red", col = NA)))
  expect_equal(px(s, 50, 50), c(255L, 0L, 0L, 255L)) # centre: red
  expect_equal(px(s, 5, 5), c(255L, 255L, 255L, 255L)) # corner: white
})

test_that("native coordinates map through the viewport scale", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(vl_viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
    # a rect centred at native (5, 5) spanning 4 native units = middle 40%
    draw(rect_grob(x = vl_unit(5, "native"), y = vl_unit(5, "native"),
                   width = vl_unit(4, "native"), height = vl_unit(4, "native"),
                   gp = vl_gpar(fill = "blue", col = NA)))
  expect_equal(px(s, 50, 50), c(0L, 0L, 255L, 255L)) # native (5,5) -> centre
  expect_equal(px(s, 10, 10), c(255L, 255L, 255L, 255L)) # outside the rect
})

test_that("y axis points up (R convention), not down", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    # small rect near the TOP of the page (npc y = 0.9)
    draw(rect_grob(x = 0.5, y = 0.9, width = 0.2, height = 0.2, gp = vl_gpar(fill = "red", col = NA)))
  # top of the image (small device y) should be red; bottom should be white
  expect_equal(px(s, 50, 10)[1:3], c(255L, 0L, 0L))
  expect_equal(px(s, 50, 90)[1:3], c(255L, 255L, 255L))
})

test_that("alpha is applied to fills", {
  s <- vl_scene(width = 1, height = 1, dpi = 50, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "black", col = NA, alpha = 0.5)))
  p <- px(s, 25, 25)
  # 50% black composited over opaque white -> opaque mid-grey
  expect_equal(p[4], 255L)
  expect_true(all(abs(p[1:3] - 127L) <= 2L))
})

test_that("render() writes a PNG file", {
  s <- vl_scene(width = 1, height = 1, dpi = 50, bg = "white") |>
    draw(circle_grob(gp = vl_gpar(fill = "steelblue")))
  path <- withr::local_tempfile(fileext = ".png")
  render(s, path)
  expect_true(file.exists(path))
  expect_gt(file.size(path), 0)
  # PNG magic bytes
  expect_equal(readBin(path, "raw", 4), as.raw(c(0x89, 0x50, 0x4e, 0x47)))
})

# --- in-memory output and render(scale=) (Phase 2) --------------------------

test_that("scene_png()/scene_pdf() return the same bytes as writing a file", {
  s <- vl_scene(2, 2, dpi = 100) |> draw(circle_grob(gp = vl_gpar(fill = "steelblue")))
  f <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache(); render(s, f)
  expect_identical(scene_png(s), readBin(f, "raw", file.size(f)))

  fp <- withr::local_tempfile(fileext = ".pdf")
  vl_clear_render_cache(); render(s, fp)
  expect_identical(scene_pdf(s), readBin(fp, "raw", file.size(fp)))
})

test_that("scene_png()/scene_pdf() return well-formed documents", {
  s <- vl_scene(1, 1, dpi = 72) |> draw(rect_grob(gp = vl_gpar(fill = "red")))
  png <- scene_png(s)
  expect_true(is.raw(png))
  expect_identical(rawToChar(png[2:4]), "PNG")
  pdf <- scene_pdf(s)
  expect_true(is.raw(pdf))
  expect_identical(rawToChar(pdf[1:5]), "%PDF-")
})

test_that("render(scale=) multiplies device pixels but not physical size", {
  s <- vl_scene(4, 3, dpi = 100) |>
    draw(rect_grob(width = vl_unit(2, "in"), height = vl_unit(1, "in"),
                   gp = vl_gpar(fill = "blue", col = NA)))
  blue_frac <- function(scale) {
    f <- withr::local_tempfile(fileext = ".png")
    vl_clear_render_cache()
    render(s, f, scale = scale)
    i <- png::readPNG(f)
    list(dim = dim(i)[1:2], frac = mean(i[, , 1] < 0.5 & i[, , 3] > 0.5))
  }
  skip_if_not_installed("png")
  a <- blue_frac(1); b <- blue_frac(2)
  expect_identical(b$dim, a$dim * 2L)
  # A 2x1in rect on a 4x3in page is exactly one sixth of the area, at any scale.
  expect_equal(a$frac, 1 / 6, tolerance = 1e-6)
  expect_equal(b$frac, 1 / 6, tolerance = 1e-6)
})

test_that("scale = 1 is the default and changes nothing", {
  s <- vl_scene(2, 2, dpi = 100) |> draw(circle_grob(gp = vl_gpar(fill = "grey")))
  expect_identical(scene_png(s), scene_png(s, scale = 1))
})

test_that("an invalid scale is rejected", {
  s <- vl_scene(1, 1)
  f <- withr::local_tempfile(fileext = ".png")
  expect_error(render(s, f, scale = 0), "scale")
  expect_error(render(s, f, scale = -2), "scale")
  expect_error(render(s, f, scale = c(1, 2)), "scale")
  expect_error(render(s, f, scale = NA), "scale")
})
