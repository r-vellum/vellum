# scene_stats() and profile_render().

test_that("scene_stats reports ink and element counts", {
  set.seed(1)
  s <- vl_scene(4, 3, dpi = 100) |> draw(points_grob(runif(200), runif(200)))
  st <- scene_stats(s)
  expect_equal(nrow(st), 1L)
  expect_equal(st$elements, 200L)
  expect_gt(st$ink, 0)
  expect_lt(st$ink, 1)
  expect_gte(st$colours, 2L)
})

test_that("an empty scene has no ink", {
  st <- scene_stats(vl_scene(2, 2, dpi = 50, bg = "white"))
  expect_equal(st$ink, 0)
  expect_equal(st$elements, 0L)
})

test_that("overplot ranks a crowded scene above a sparse one", {
  # The point of the metric: element *count* says nothing about overlap, so a
  # dense cluster must score far above a scattered cloud of the same marks.
  set.seed(1)
  sparse <- vl_scene(4, 3, dpi = 100) |>
    draw(points_grob(runif(2000), runif(2000)))
  dense <- vl_scene(4, 3, dpi = 100) |>
    draw(points_grob(rnorm(2000, 0.5, 0.03), rnorm(2000, 0.5, 0.03)))
  expect_gt(scene_stats(dense)$overplot, scene_stats(sparse)$overplot * 5)
})

test_that("profile_render attributes cost to the marks that caused it", {
  set.seed(1)
  s <- vl_scene(4, 3, dpi = 100) |>
    draw(points_grob(runif(4000), runif(4000), name = "cloud")) |>
    draw(text_grob("t", y = 0.95, name = "title"))
  p <- profile_render(s, reps = 1)
  expect_s3_class(p, "vellum_profile")
  expect_true(all(c("kind", "name", "n", "seconds", "pct") %in% names(p)))
  # Ordered by cost, and the 4000-point cloud must outrank a one-glyph label.
  expect_equal(p$seconds, sort(p$seconds, decreasing = TRUE))
  expect_equal(p$name[1], "cloud")
  expect_lte(p$seconds[p$name == "title"], p$seconds[p$name == "cloud"])
})

test_that("profile_render reports the three phases", {
  s <- vl_scene(2, 2, dpi = 50) |> draw(circle_grob(gp = vl_gpar(fill = "red")))
  ph <- attr(profile_render(s, reps = 1), "phases")
  expect_named(ph, c("build", "compile", "raster"))
  expect_true(all(ph >= 0))
})

test_that("profiling is disarmed afterwards, so normal renders are untimed", {
  s <- vl_scene(2, 2, dpi = 50) |> draw(circle_grob(gp = vl_gpar(fill = "red")))
  invisible(profile_render(s, reps = 1))
  vl_clear_render_cache()
  render(s, withr::local_tempfile(fileext = ".png"))
  expect_length(rs_take_node_times(), 0L)
})

test_that("profile_render validates reps", {
  s <- vl_scene(1, 1)
  expect_error(profile_render(s, reps = 0), "positive")
  expect_error(profile_render(s, reps = c(1, 2)), "positive")
})

test_that("structural nodes are excluded from the profile", {
  s <- vl_scene(2, 2, dpi = 50) |>
    push(vl_viewport(alpha = 0.5, name = "grp")) |>
    draw(circle_grob(gp = vl_gpar(fill = "red"))) |>
    pop()
  p <- profile_render(s, reps = 1)
  expect_true(all(nzchar(p$kind)))
})
