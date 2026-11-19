# FW3: hit-testing / picking.

test_that("hit_test finds the named grob under a point, NULL when none", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(rect_grob(
      x = 0.25,
      y = 0.25,
      width = 0.3,
      height = 0.3,
      gp = vl_gpar(fill = "red", col = NA),
      name = "A"
    )) |>
    draw(circle_grob(
      x = 0.75,
      y = 0.75,
      r = 0.15,
      gp = vl_gpar(fill = "blue", col = NA),
      name = "B"
    )) |>
    draw(rect_grob(
      x = 0.5,
      y = 0.5,
      width = 0.2,
      height = 0.2,
      gp = vl_gpar(fill = "green", col = NA),
      name = "C"
    ))
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
    draw(rect_grob(
      width = 0.4,
      height = 0.4,
      gp = vl_gpar(fill = "blue", col = NA),
      name = "over"
    ))
  expect_equal(hit_test(s, 0.5, 0.5), "over") # centre: top grob
  expect_equal(hit_test(s, 0.1, 0.1), "under") # corner: only the bottom grob
})

test_that("hit_test reports NA for an unnamed grob, and respects viewports/clips", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "red", col = NA)))
  expect_true(is.na(hit_test(s, 0.5, 0.5)))

  nested <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(vl_viewport(x = 0.75, y = 0.75, width = 0.4, height = 0.4)) |>
    draw(circle_grob(
      r = 0.4,
      gp = vl_gpar(fill = "purple", col = NA),
      name = "inner"
    ))
  expect_equal(hit_test(nested, 0.75, 0.75), "inner")
  expect_null(hit_test(nested, 0.25, 0.25))

  # a clipped viewport: drawing outside the clip is not hittable
  clipped <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(vl_viewport(
      x = 0.5,
      y = 0.5,
      width = 0.3,
      height = 0.3,
      clip = TRUE
    )) |>
    draw(circle_grob(
      r = 0.9,
      gp = vl_gpar(fill = "blue", col = NA),
      name = "big"
    ))
  expect_equal(hit_test(clipped, 0.5, 0.5), "big") # inside the clip
  expect_null(hit_test(clipped, 0.5, 0.9)) # circle reaches here but clipped away
})

test_that("hit_test accepts device-pixel coordinates", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |> # 200x100
    draw(rect_grob(
      x = 0.25,
      y = 0.5,
      width = 0.2,
      height = 0.6,
      gp = vl_gpar(fill = "red", col = NA),
      name = "L"
    ))
  expect_equal(hit_test(s, 50, 50, units = "px"), "L") # device (50,50)
  expect_null(hit_test(s, 150, 50, units = "px"))
})

test_that("hit_test reuses one pick compile per scene and misses after an edit", {
  vl_clear_render_cache()
  withr::defer(vl_clear_render_cache())
  s <- vl_scene(2, 2, dpi = 72, bg = "white") |>
    draw(rect_grob(name = "bg", gp = vl_gpar(fill = "white", col = NA))) |>
    draw(points_grob(
      0.5,
      0.5,
      size = vl_unit(20, "pt"),
      name = "dot",
      gp = vl_gpar(fill = "red", col = NA)
    ))
  pk1 <- .pick_backend(s)
  pk2 <- .pick_backend(s)
  expect_identical(pk1, pk2) # cache hit: the same compiled backend
  expect_equal(length(.pick_cache$.order), 1L)
  expect_equal(hit_test(s, 0.5, 0.5), "dot")
  expect_equal(length(.pick_cache$.order), 1L)

  # An edit is new content: a fresh compile, and the answer follows the edit.
  s2 <- edit_node(s, "dot", x = vl_unit(0.1, "npc"))
  expect_false(identical(.pick_backend(s2)$scene, pk1$scene))
  expect_equal(hit_test(s2, 0.1, 0.5), "dot")
  expect_equal(hit_test(s2, 0.5, 0.5), "bg")
  expect_equal(hit_test(s, 0.5, 0.5), "dot") # the original is untouched

  # A device-size change keeps the content id but must not reuse the backend.
  s3 <- S7::set_props(s, width = vl_unit(4, "in"))
  expect_false(identical(.pick_backend(s3)$scene, pk1$scene))
  expect_equal(hit_test(s3, 0.5, 0.5), "dot")

  # The LRU is bounded by the render-cache cap.
  withr::local_options(vellum.cache_size = 2L)
  for (i in 1:4) {
    hit_test(draw(s, points_grob(0.2, 0.2, name = paste0("p", i))), 0.5, 0.5)
  }
  expect_lte(length(.pick_cache$.order), 2L)

  # vl_clear_render_cache() empties it, and vellum.cache = FALSE bypasses it.
  vl_clear_render_cache()
  expect_equal(length(.pick_cache$.order), 0L)
  withr::local_options(vellum.cache = FALSE)
  expect_equal(hit_test(s, 0.5, 0.5), "dot")
  expect_equal(length(.pick_cache$.order), 0L)
})
