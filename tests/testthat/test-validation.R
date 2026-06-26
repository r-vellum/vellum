test_that("primitive input is validated with helpful errors", {
  # Length mismatches are caught at grob construction.
  expect_error(lines_grob(x = 1:3, y = 1:2), "same length")
  expect_error(polygon_grob(x = 1:3, y = 1:2), "same length")
  # gpar scalars are enforced at compile time (when encoded for the backend).
  expect_error(
    .scene_to_backend(vl_scene(1, 1, dpi = 50) |> draw(rect_grob(gp = gpar(col = c("red", "blue"))))),
    "single value"
  )
  expect_error(
    .scene_to_backend(vl_scene(1, 1, dpi = 50) |> draw(rect_grob(gp = gpar(lwd = c(1, 2))))),
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
    draw(rect_grob(gp = gpar(fill = NA, col = NA)))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 255L, 255L))

  # NULL (omitted) -> inherit the viewport's stroke colour
  s2 <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(viewport(gp = gpar(col = "red"))) |>
    draw(lines_grob(unit(c(0.05, 0.95), "npc"), unit(c(0.5, 0.5), "npc"), gp = gpar(lwd = 6)))
  p <- px(s2, 50, 50)
  expect_true(p[1] > 200 && p[2] < 80 && p[3] < 80) # reddish
})

test_that("lwd inherits from the enclosing viewport", {
  band <- function(vp_lwd) {
    s <- vl_scene(2, 1, dpi = 100, bg = "white") |> # 200 x 100
      push(viewport(gp = gpar(lwd = vp_lwd))) |>
      draw(lines_grob(unit(c(0, 1), "npc"), unit(c(0.5, 0.5), "npc"), gp = gpar(col = "black")))
    red <- scene_raster(s)[1, , ]
    sum(red[100, ] < 128) # inked rows in a central column = line thickness
  }
  expect_gt(band(10), band(2))
})

test_that("an unrecognized text justification errors instead of silently becoming NA", {
  s <- vl_scene(1, 1, dpi = 50) |> draw(text_grob("x", just = "frobnicate"))
  expect_error(.scene_to_backend(s), "just")
  # named and numeric justifications still work
  expect_no_error(.scene_to_backend(vl_scene(1, 1, dpi = 50) |> draw(text_grob("x", just = "left"))))
  expect_no_error(.scene_to_backend(vl_scene(1, 1, dpi = 50) |> draw(text_grob("x", just = c("0.2", "0.8")))))
})
