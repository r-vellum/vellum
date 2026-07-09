# Repaint boundaries / subtree sub-rasters (FW4c). A `vl_viewport(cache = TRUE)`
# subtree is rasterised once to a page-sized layer, memoised on a per-subtree
# identity token (`nid`), and composited from cache on later renders when the
# subtree is unchanged (highlight/animation partial redraw). Raster-only; SVG/PDF
# render the subtree inline. `rs_subraster_stats()` is c(hits, misses, resident).

# A scene with two boundaries overlapping in the middle, so the transparency test
# also exercises source-over associativity (capture-then-composite == inline).
two_boundaries <- function(cache, fg = "blue") {
  vl_scene(2, 1, dpi = 100, bg = "white") |>
    push(vl_viewport(cache = cache, name = "bg")) |>
    draw(circle_grob(x = 0.45, y = 0.5, r = 0.25, gp = vl_gpar(fill = "red", col = NA))) |>
    pop() |>
    push(vl_viewport(cache = cache, name = "fg")) |>
    draw(circle_grob(x = 0.55, y = 0.5, r = 0.25, gp = vl_gpar(fill = fg, col = NA), name = "dot")) |>
    pop()
}

test_that("a cached repaint boundary renders byte-identical to an uncached subtree", {
  vl_clear_render_cache()
  cached <- scene_raster(two_boundaries(TRUE))
  uncached <- scene_raster(two_boundaries(FALSE))
  expect_identical(cached, uncached)
})

test_that("editing one boundary reuses the other's cached sub-raster", {
  vl_clear_render_cache()
  s <- two_boundaries(TRUE)
  scene_raster(s) # cold: both boundaries miss
  st1 <- rs_subraster_stats()
  expect_equal(st1[1:2], c(0L, 2L)) # 0 hits, 2 misses

  s2 <- edit_node(s, "dot", gp = vl_gpar(fill = "green", col = NA))
  r <- scene_raster(s2) # bg unchanged -> hit; fg edited -> miss
  st2 <- rs_subraster_stats()
  expect_equal(st2[1] - st1[1], 1L) # +1 hit (bg reused)
  expect_equal(st2[2] - st1[2], 1L) # +1 miss (fg re-rendered)
  expect_equal(r[2, 110, 50], 255L) # green foreground drawn at the fg centre
})

test_that("reused output is correct: cached partial redraw == a fresh uncached render", {
  vl_clear_render_cache()
  s <- two_boundaries(TRUE)
  scene_raster(s) # warm the cache
  s2 <- edit_node(s, "dot", gp = vl_gpar(fill = "green", col = NA))
  got <- scene_raster(s2) # bg from cache, fg fresh
  ref <- withr::with_options(
    list(vellum.cache = FALSE),
    scene_raster(two_boundaries(FALSE, fg = "green"))
  )
  expect_identical(got, ref)
})

test_that("a boundary with a non-normal blend is not cached (rendered inline)", {
  vl_clear_render_cache()
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    push(vl_viewport(cache = TRUE, blend = "multiply")) |>
    draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "red", col = NA))) |>
    pop()
  scene_raster(s)
  expect_equal(rs_subraster_stats()[1:2], c(0L, 0L)) # never bracketed
})

test_that("vector backends ignore the boundary and record no sub-raster activity", {
  vl_clear_render_cache()
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    push(vl_viewport(cache = TRUE)) |>
    draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "red", col = NA))) |>
    pop()
  svg <- withr::local_tempfile(fileext = ".svg")
  render(s, svg)
  expect_equal(rs_subraster_stats()[1:2], c(0L, 0L))
  expect_true(file.exists(svg))
})

test_that("vl_clear_render_cache empties the sub-raster cache", {
  vl_clear_render_cache()
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    push(vl_viewport(cache = TRUE)) |>
    draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "red", col = NA))) |>
    pop()
  scene_raster(s)
  expect_gt(rs_subraster_stats()[3], 0L)
  vl_clear_render_cache()
  expect_equal(rs_subraster_stats(), c(0L, 0L, 0L))
})

test_that("vl_viewport(cache=) is validated", {
  expect_error(vl_viewport(cache = NA), "cache")
  expect_error(vl_viewport(cache = "yes"), "cache")
  expect_error(vl_viewport(cache = c(TRUE, FALSE)), "cache")
})
