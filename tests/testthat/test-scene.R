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
    draw(rect_grob(gp = gpar(fill = "blue"))) |>
    draw(circle_grob(gp = gpar(fill = "green")))
  expect_equal(scene_len(s), 2L)
})

test_that("a filled rect paints the centre and leaves the corner as background", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    # centred rect covering the middle half of the page
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.5, height = 0.5, gp = gpar(fill = "red", col = NA)))
  expect_equal(px(s, 50, 50), c(255L, 0L, 0L, 255L)) # centre: red
  expect_equal(px(s, 5, 5), c(255L, 255L, 255L, 255L)) # corner: white
})

test_that("native coordinates map through the viewport scale", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
    # a rect centred at native (5, 5) spanning 4 native units = middle 40%
    draw(rect_grob(x = unit(5, "native"), y = unit(5, "native"),
                   width = unit(4, "native"), height = unit(4, "native"),
                   gp = gpar(fill = "blue", col = NA)))
  expect_equal(px(s, 50, 50), c(0L, 0L, 255L, 255L)) # native (5,5) -> centre
  expect_equal(px(s, 10, 10), c(255L, 255L, 255L, 255L)) # outside the rect
})

test_that("y axis points up (R convention), not down", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    # small rect near the TOP of the page (npc y = 0.9)
    draw(rect_grob(x = 0.5, y = 0.9, width = 0.2, height = 0.2, gp = gpar(fill = "red", col = NA)))
  # top of the image (small device y) should be red; bottom should be white
  expect_equal(px(s, 50, 10)[1:3], c(255L, 0L, 0L))
  expect_equal(px(s, 50, 90)[1:3], c(255L, 255L, 255L))
})

test_that("alpha is applied to fills", {
  s <- vl_scene(width = 1, height = 1, dpi = 50, bg = "white") |>
    draw(rect_grob(gp = gpar(fill = "black", col = NA, alpha = 0.5)))
  p <- px(s, 25, 25)
  # 50% black composited over opaque white -> opaque mid-grey
  expect_equal(p[4], 255L)
  expect_true(all(abs(p[1:3] - 127L) <= 2L))
})

test_that("render() writes a PNG file", {
  s <- vl_scene(width = 1, height = 1, dpi = 50, bg = "white") |>
    draw(circle_grob(gp = gpar(fill = "steelblue")))
  path <- withr::local_tempfile(fileext = ".png")
  render(s, path)
  expect_true(file.exists(path))
  expect_gt(file.size(path), 0)
  # PNG magic bytes
  expect_equal(readBin(path, "raw", 4), as.raw(c(0x89, 0x50, 0x4e, 0x47)))
})
