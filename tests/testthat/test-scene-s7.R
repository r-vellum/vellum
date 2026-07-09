# Probe a compiled S7 scene at the pixel level (px() lives in helper-probe.R).

test_that("a filled rect renders via the S7 API", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.5, height = 0.5,
                   gp = vl_gpar(fill = "red", col = NA)))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 0L, 0L))
  expect_equal(px(s, 5, 5)[1:3], c(255L, 255L, 255L))
})

test_that("native coordinates use the pushed viewport's scale", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(vl_viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
    draw(rect_grob(x = vl_unit(5, "native"), y = vl_unit(5, "native"),
                   width = vl_unit(4, "native"), height = vl_unit(4, "native"),
                   gp = vl_gpar(fill = "blue", col = NA)))
  expect_equal(px(s, 50, 50)[1:3], c(0L, 0L, 255L))
})

test_that("vectorised circle_grob draws N circles", {
  s <- vl_scene(width = 2, height = 1, dpi = 100, bg = "white") |>
    draw(circle_grob(x = c(0.25, 0.75), y = 0.5, r = vl_unit(6, "mm"),
                     gp = vl_gpar(fill = "darkgreen", col = NA)))
  # both centres (device x 50 and 150) are green
  expect_equal(px(s, 50, 50)[1:3], c(0L, 100L, 0L))
  expect_equal(px(s, 150, 50)[1:3], c(0L, 100L, 0L))
})

test_that("nested viewports compose; clip confines drawing", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(vl_viewport(x = 0.5, y = 0.5, width = 0.4, height = 0.4, clip = TRUE)) |>
    draw(circle_grob(r = 0.9, gp = vl_gpar(fill = "blue", col = NA)))
  expect_equal(px(s, 50, 50)[1:3], c(0L, 0L, 255L)) # inside viewport
  expect_equal(px(s, 50, 20)[1:3], c(255L, 255L, 255L)) # clipped away
})

test_that("grid_layout places a cell viewport", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(vl_viewport(layout = grid_layout(widths = vl_unit(c(1, 1), "null"),
                                       heights = vl_unit(c(1, 1), "null")))) |>
    push(vl_viewport(row = 2, col = 2)) |>
    draw(rect_grob(gp = vl_gpar(fill = "red", col = NA)))
  expect_equal(px(s, 75, 75)[1:3], c(255L, 0L, 0L)) # bottom-right cell
  expect_equal(px(s, 25, 25)[1:3], c(255L, 255L, 255L))
})

test_that("vl_gpar inherits from an enclosing viewport", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(vl_viewport(gp = vl_gpar(fill = "red"))) |>
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.4, height = 0.4,
                   gp = vl_gpar(col = NA))) # fill NULL -> inherit red
  expect_equal(px(s, 50, 50)[1:3], c(255L, 0L, 0L))
})
