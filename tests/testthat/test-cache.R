# Render-result cache (FW4): repeated renders of identical content reuse a single
# compiled backend Scene, and changing content produces a distinct result.

clear_scene_cache <- function() {
  rm(list = setdiff(ls(.scene_cache, all.names = TRUE), ".n"), envir = .scene_cache)
  .scene_cache$.n <- 0L
}

test_that("structurally identical scenes share one compiled Scene", {
  clear_scene_cache()
  mk <- function() {
    vl_scene(2, 1, dpi = 80, bg = "white") |>
      draw(rect_grob(gp = gpar(fill = "red", col = NA))) |>
      draw(circle_grob(r = 0.3))
  }
  a <- scene_raster(mk())
  expect_equal(.scene_cache$.n, 1L)
  b <- scene_raster(mk()) # distinct S7 object, identical content -> cache hit
  expect_equal(.scene_cache$.n, 1L)
  expect_identical(a, b)
})

test_that("different content is not served from cache and renders differently", {
  clear_scene_cache()
  red <- scene_raster(vl_scene(2, 1, dpi = 80, bg = "white") |>
    draw(rect_grob(gp = gpar(fill = "red", col = NA))))
  blue <- scene_raster(vl_scene(2, 1, dpi = 80, bg = "white") |>
    draw(rect_grob(gp = gpar(fill = "blue", col = NA))))
  expect_equal(.scene_cache$.n, 2L)
  expect_false(identical(red, blue))
})

test_that("the cache is transparent: cached output matches an uncached render", {
  s <- vl_scene(2, 2, dpi = 90, bg = "white") |>
    draw(rect_grob(width = 0.6, height = 0.6, gp = gpar(fill = "seagreen", col = "black", lwd = 2)))
  clear_scene_cache()
  warm <- scene_raster(s) # populates then (on a second call) would hit
  clear_scene_cache()
  cold <- scene_raster(s) # fresh compile
  expect_identical(cold, warm)
})
