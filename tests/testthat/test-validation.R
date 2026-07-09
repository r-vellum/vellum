test_that("primitive input is validated with helpful errors", {
  # Length mismatches are caught at grob construction.
  expect_error(lines_grob(x = 1:3, y = 1:2), "same length")
  expect_error(polygon_grob(x = 1:3, y = 1:2), "same length")
  # vl_gpar scalars are enforced at compile time (when encoded for the backend).
  expect_error(
    .scene_to_backend(vl_scene(1, 1, dpi = 50) |> draw(rect_grob(gp = vl_gpar(col = c("red", "blue"))))),
    "single value"
  )
  expect_error(
    .scene_to_backend(vl_scene(1, 1, dpi = 50) |> draw(rect_grob(gp = vl_gpar(lwd = c(1, 2))))),
    "single number"
  )
})

test_that("scene dimensions must be finite and positive", {
  expect_error(.scene_to_backend(vl_scene(width = NaN)), "finite and positive")
  expect_error(.scene_to_backend(vl_scene(width = -1)), "finite and positive")
  expect_error(.scene_to_backend(vl_scene(height = Inf)), "finite and positive")
  expect_error(.scene_to_backend(vl_scene(dpi = 0)), "finite and positive")
})

test_that("col = NA paints nothing; col = NULL inherits from the viewport", {
  # NA -> explicit no paint: nothing is drawn
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = NA, col = NA)))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 255L, 255L))

  # NULL (omitted) -> inherit the viewport's stroke colour
  s2 <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(vl_viewport(gp = vl_gpar(col = "red"))) |>
    draw(lines_grob(vl_unit(c(0.05, 0.95), "npc"), vl_unit(c(0.5, 0.5), "npc"), gp = vl_gpar(lwd = 6)))
  p <- px(s2, 50, 50)
  expect_true(p[1] > 200 && p[2] < 80 && p[3] < 80) # reddish
})

test_that("lwd inherits from the enclosing viewport", {
  band <- function(vp_lwd) {
    s <- vl_scene(2, 1, dpi = 100, bg = "white") |> # 200 x 100
      push(vl_viewport(gp = vl_gpar(lwd = vp_lwd))) |>
      draw(lines_grob(vl_unit(c(0, 1), "npc"), vl_unit(c(0.5, 0.5), "npc"), gp = vl_gpar(col = "black")))
    red <- scene_raster(s)[1, , ]
    sum(red[100, ] < 128) # inked rows in a central column = line thickness
  }
  expect_gt(band(10), band(2))
})

# FW1: correctness & validation pass.
test_that("alpha outside [0, 1] is rejected at vl_gpar construction", {
  expect_error(vl_gpar(alpha = 1.5), "alpha")
  expect_error(vl_gpar(alpha = -0.1), "alpha")
  expect_error(vl_gpar(alpha = c(0.5, 1.5)), "alpha") # any out-of-range element
  expect_no_error(vl_gpar(alpha = 0))
  expect_no_error(vl_gpar(alpha = 1))
  expect_no_error(vl_gpar(alpha = c(0.2, 0.8)))
  expect_no_error(vl_gpar(alpha = NULL)) # inherit
})

test_that("linemitre below 1 is rejected", {
  expect_error(vl_gpar(linemitre = 0.5), "linemitre")
  expect_no_error(vl_gpar(linemitre = 10))
})

test_that("negative extents are rejected", {
  expect_error(rect_grob(width = -1), "non-negative")
  expect_error(rect_grob(height = -0.5), "non-negative")
  expect_error(circle_grob(r = -0.2), "non-negative")
  expect_error(points_grob(0.5, 0.5, size = vl_unit(-2, "mm")), "non-negative")
})

test_that("gradient stops must be in [0, 1] and non-decreasing", {
  expect_error(linear_gradient(c("a", "b"), stops = c(0, 1.4)), "0, 1|\\[0, 1\\]")
  expect_error(linear_gradient(c("a", "b", "c"), stops = c(0, 1, 0.5)), "non-decreasing")
  expect_no_error(linear_gradient(c("a", "b", "c"), stops = c(0, 0.3, 1)))
})

test_that("a layout cell out of range (or with no layout) errors at render", {
  cell <- function(vp_layout, row, col) {
    s <- vl_scene(1, 1, dpi = 50)
    if (!is.null(vp_layout)) s <- push(s, vl_viewport(layout = vp_layout))
    s <- s |> push(vl_viewport(row = row, col = col)) |> draw(rect_grob())
    .scene_to_backend(s)$pixel(1, 1)
  }
  lay <- grid_layout(vl_unit(c(1, 1), "null"), vl_unit(c(1, 1), "null"))
  expect_error(cell(lay, 5, 1), "out of range")
  expect_error(cell(NULL, 1, 1), "layout") # row/col without a layout
  expect_no_error(cell(lay, 2, 2))
})

test_that("text colour inherits the enclosing viewport (not forced black)", {
  red <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(vl_viewport(gp = vl_gpar(col = "red"))) |>
    draw(text_grob("A", x = 0.5, y = 0.5, gp = vl_gpar(fontsize = 60)))
  a <- scene_raster(red)
  reddish <- a[1, , ] > a[2, , ] + 40 & a[1, , ] > 150
  expect_true(any(reddish)) # red ink present
  # default (no viewport col) still renders black
  blk <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(text_grob("A", x = 0.5, y = 0.5, gp = vl_gpar(fontsize = 60)))
  expect_lt(min(scene_raster(blk)[1, , ]), 80L)
})

test_that("page-level scales/gp on vl_scene reach the root viewport", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white", xscale = c(0, 10), yscale = c(0, 10)) |>
    draw(rect_grob(x = vl_unit(5, "native"), y = vl_unit(5, "native"),
                   width = vl_unit(4, "native"), height = vl_unit(4, "native"),
                   gp = vl_gpar(fill = "blue", col = NA)))
  expect_equal(px(s, 50, 50)[1:3], c(0L, 0L, 255L))
})

test_that("an unrecognized text justification errors instead of silently becoming NA", {
  s <- vl_scene(1, 1, dpi = 50) |> draw(text_grob("x", just = "frobnicate"))
  expect_error(.scene_to_backend(s), "just")
  # named and numeric justifications still work
  expect_no_error(.scene_to_backend(vl_scene(1, 1, dpi = 50) |> draw(text_grob("x", just = "left"))))
  expect_no_error(.scene_to_backend(vl_scene(1, 1, dpi = 50) |> draw(text_grob("x", just = c("0.2", "0.8")))))
})
