test_that("style() is a vl_gpar subclass carrying an optional name", {
  st <- style(col = "firebrick", lwd = 2, name = "accent")
  expect_true(S7::S7_inherits(st, vl_gpar))
  expect_true(S7::S7_inherits(st, style))
  expect_equal(st@col, "firebrick")
  expect_equal(st@lwd, 2)
  expect_equal(st@name, "accent")
})

test_that("a style attached to a viewport cascades to children", {
  # Red style on the viewport; the rect inherits col (drawn as a stroked outline).
  accent <- style(col = "red", name = "accent")
  s <- vl_scene(2, 2, bg = "white") |>
    push(vl_viewport(gp = accent)) |>
    draw(rect_grob(width = 0.5, height = 0.5, gp = vl_gpar(fill = NA, lwd = 4)))
  px <- scene_raster(s)
  # Somewhere on the page a strongly-red pixel exists (the inherited stroke).
  red <- px[1, , ] > 180 & px[2, , ] < 80 & px[3, , ] < 80
  expect_true(any(red))
})

test_that("a child gp overrides an inherited style (more-specific wins)", {
  accent <- style(col = "red", name = "accent")
  s <- vl_scene(2, 2, bg = "white") |>
    push(vl_viewport(gp = accent)) |>
    draw(rect_grob(width = 0.5, height = 0.5, gp = vl_gpar(fill = NA, col = "blue", lwd = 4)))
  px <- scene_raster(s)
  blue <- px[3, , ] > 180 & px[1, , ] < 80 & px[2, , ] < 80
  red <- px[1, , ] > 180 & px[2, , ] < 80 & px[3, , ] < 80
  expect_true(any(blue))
  expect_false(any(red))
})
