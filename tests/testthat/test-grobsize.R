# grobwidth / grobheight units (grob sizing). Extents resolve eagerly to mm.

mm <- function(u) vctrs::field(u, "value")
code <- function(u) vctrs::field(u, "unit")

test_that("grobwidth/grobheight resolve to an mm unit", {
  u <- grobwidth(text_grob("hi"))
  expect_true(is_unit(u))
  expect_equal(code(u), 2L) # mm
})

test_that("grobwidth of text matches strwidth of its label", {
  g <- grobwidth(text_grob("Wide label", gp = vl_gpar(fontsize = 20)))
  s <- vl_unit(1, "strwidth", data = list(label = "Wide label", fontsize = 20))
  expect_equal(mm(g), mm(s), tolerance = 1e-6)
})

test_that("text extent scales with font size", {
  big <- mm(grobwidth(text_grob("Label", gp = vl_gpar(fontsize = 20))))
  small <- mm(grobwidth(text_grob("Label", gp = vl_gpar(fontsize = 10))))
  expect_gt(big, small)
  expect_gt(mm(grobheight(text_grob("Ag", gp = vl_gpar(fontsize = 20)))), 0)
})

test_that("an absolute-sized grob measures (device-independently) to its size", {
  r <- rect_grob(width = vl_unit(20, "mm"), height = vl_unit(8, "mm"))
  expect_true(abs(mm(grobwidth(r)) - 20) < 2)  # ~20mm (AA edge tolerance)
  expect_true(abs(mm(grobheight(r)) - 8) < 2)  # ~8mm
})

test_that("mult scales the measured extent", {
  r <- rect_grob(width = vl_unit(20, "mm"))
  expect_equal(mm(grobwidth(r, mult = 2)), mm(grobwidth(r)) * 2, tolerance = 1e-9)
})

test_that("the generic vl_unit() form works, with a grob or list(grob=)", {
  r <- rect_grob(width = vl_unit(20, "mm"))
  expect_equal(mm(vl_unit(1, "grobwidth", data = r)), mm(grobwidth(r)), tolerance = 1e-9)
  expect_equal(mm(vl_unit(1, "grobwidth", data = list(grob = r))), mm(grobwidth(r)), tolerance = 1e-9)
})

test_that("grobwidth without a grob errors clearly", {
  expect_error(vl_unit(1, "grobwidth", data = list(label = "x")), "need a grob")
  expect_error(vl_unit(1, "grobwidth"), "need a grob")
})

test_that("a viewport sized by grobwidth holds a box matching the label", {
  px <- function(s, x, y) .scene_to_backend(s)$pixel(x, y)
  lab <- text_grob("MMMM", gp = vl_gpar(fontsize = 30))
  s <- vl_scene(4, 2, dpi = 100, bg = "white") |>
    push(vl_viewport(x = 0.5, y = 0.5, width = grobwidth(lab), height = grobheight(lab))) |>
    draw(rect_grob(gp = vl_gpar(fill = "red", col = NA))) |>
    pop()
  # the red box is centred; its half-width in px ~ grobwidth/2 mm * dpi/25.4
  half_w <- mm(grobwidth(lab)) / 2 / 25.4 * 100
  expect_equal(px(s, 200, 100)[1:3], c(255L, 0L, 0L))             # centre: in the box
  expect_equal(px(s, round(200 + half_w + 8), 100)[1:3], c(255L, 255L, 255L)) # past the box edge
})

test_that("text extent is rotation-aware (90 degrees swaps width and height)", {
  g <- text_grob("Wide label", gp = vl_gpar(fontsize = 20))
  g90 <- text_grob("Wide label", rot = 90, gp = vl_gpar(fontsize = 20))
  w0 <- mm(grobwidth(g)); h0 <- mm(grobheight(g))
  expect_equal(mm(grobwidth(g90)), h0, tolerance = 1e-6) # rotated width = upright height
  expect_equal(mm(grobheight(g90)), w0, tolerance = 1e-6) # rotated height = upright width
})

test_that("a 45-degree label has a larger bounding box than upright", {
  g <- text_grob("Wide label", gp = vl_gpar(fontsize = 20))
  g45 <- text_grob("Wide label", rot = 45, gp = vl_gpar(fontsize = 20))
  expect_gt(mm(grobheight(g45)), mm(grobheight(g))) # slanted text is taller
})
