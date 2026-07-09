# FW3: hit-testing / picking.

test_that("hit_test finds the named grob under a point, NULL when none", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(rect_grob(x = 0.25, y = 0.25, width = 0.3, height = 0.3, gp = vl_gpar(fill = "red", col = NA), name = "A")) |>
    draw(circle_grob(x = 0.75, y = 0.75, r = 0.15, gp = vl_gpar(fill = "blue", col = NA), name = "B")) |>
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.2, height = 0.2, gp = vl_gpar(fill = "green", col = NA), name = "C"))
  expect_equal(hit_test(s, 0.25, 0.25), "A")
  expect_equal(hit_test(s, 0.75, 0.75), "B")
  expect_equal(hit_test(s, 0.5, 0.5), "C")
  expect_null(hit_test(s, 0.05, 0.95)) # empty corner
  # outside the circle's radius but inside its bounding box -> no hit (exact shape)
  expect_null(hit_test(s, 0.63, 0.63))
})

test_that("hit_test returns the topmost grob on overlap", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "red", col = NA), name = "under")) |>
    draw(rect_grob(width = 0.4, height = 0.4, gp = vl_gpar(fill = "blue", col = NA), name = "over"))
  expect_equal(hit_test(s, 0.5, 0.5), "over") # centre: top grob
  expect_equal(hit_test(s, 0.1, 0.1), "under") # corner: only the bottom grob
})

test_that("hit_test reports NA for an unnamed grob, and respects viewports/clips", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |> draw(rect_grob(gp = vl_gpar(fill = "red", col = NA)))
  expect_true(is.na(hit_test(s, 0.5, 0.5)))

  nested <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(vl_viewport(x = 0.75, y = 0.75, width = 0.4, height = 0.4)) |>
    draw(circle_grob(r = 0.4, gp = vl_gpar(fill = "purple", col = NA), name = "inner"))
  expect_equal(hit_test(nested, 0.75, 0.75), "inner")
  expect_null(hit_test(nested, 0.25, 0.25))

  # a clipped viewport: drawing outside the clip is not hittable
  clipped <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(vl_viewport(x = 0.5, y = 0.5, width = 0.3, height = 0.3, clip = TRUE)) |>
    draw(circle_grob(r = 0.9, gp = vl_gpar(fill = "blue", col = NA), name = "big"))
  expect_equal(hit_test(clipped, 0.5, 0.5), "big") # inside the clip
  expect_null(hit_test(clipped, 0.5, 0.9)) # circle reaches here but clipped away
})

test_that("hit_test accepts device-pixel coordinates", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |> # 200x100
    draw(rect_grob(x = 0.25, y = 0.5, width = 0.2, height = 0.6, gp = vl_gpar(fill = "red", col = NA), name = "L"))
  expect_equal(hit_test(s, 50, 50, units = "px"), "L") # device (50,50)
  expect_null(hit_test(s, 150, 50, units = "px"))
})
