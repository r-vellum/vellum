# Object-identity render cache (the FW4 successor). A compiled backend Scene is
# memoised on a per-content-version identity token (`.new_scene_id`), so a repeat
# render of an unchanged scene at the same device size reuses the compiled Scene
# (and, via the Scene's lazy pixmap memo, its rasterisation). The cache is
# transparent: a hit is byte-identical to a miss. These tests instrument the
# hit/miss counters and the `.materialize` walk counter directly (the house
# pattern; see the shape-cache tests) rather than timing.

reset_cache <- function() {
  vl_clear_render_cache()
  .mtl_count$n <- 0L
}
hits <- function() .render_cache$.hits
misses <- function() .render_cache$.misses

demo_scene <- function(w = 2, h = 1, dpi = 100, col = "red") {
  vl_scene(w, h, dpi = dpi, bg = "white") |>
    draw(circle_grob(x = 0.5, y = 0.5, r = 0.3, gp = vl_gpar(fill = col, col = NA), name = "dot"))
}

test_that("a cached render is byte-identical to an uncached one", {
  reset_cache()
  s <- demo_scene()
  cold <- scene_raster(s) # miss, stores + fills the pixmap memo
  warm <- scene_raster(s) # hit
  expect_identical(cold, warm)
  uncached <- withr::with_options(list(vellum.cache = FALSE), scene_raster(s))
  expect_identical(cold, uncached)
})

test_that("rendering the same scene twice is one miss then one hit", {
  reset_cache()
  s <- demo_scene()
  scene_raster(s)
  expect_equal(c(misses(), hits()), c(1L, 0L))
  scene_raster(s)
  expect_equal(c(misses(), hits()), c(1L, 1L))
})

test_that("multi-format export of one scene compiles once", {
  reset_cache()
  s <- demo_scene()
  png <- withr::local_tempfile(fileext = ".png")
  svg <- withr::local_tempfile(fileext = ".svg")
  pdf <- withr::local_tempfile(fileext = ".pdf")
  render(s, png) # miss (compile)
  render(s, svg) # hit (reuse compiled Scene, different backend)
  render(s, pdf) # hit
  expect_equal(misses(), 1L)
  expect_equal(hits(), 2L)
})

test_that("editing content produces a new key (miss), not a stale hit", {
  reset_cache()
  s <- demo_scene(col = "red")
  r_red <- scene_raster(s) # miss
  s2 <- edit_node(s, "dot", gp = vl_gpar(fill = "blue", col = NA))
  r_again <- scene_raster(s) # hit: original unchanged
  r_blue <- scene_raster(s2) # miss: edited -> fresh id
  expect_identical(r_red, r_again)
  expect_false(identical(r_red, r_blue))
  expect_equal(r_blue[3, 100, 50], 255L) # blue channel lit at the dot centre (200x100 px)
  expect_equal(misses(), 2L)
  expect_equal(hits(), 1L)
})

test_that("device size participates in the key: resize misses, return-to-size hits", {
  reset_cache()
  s <- demo_scene()
  a <- S7::set_props(s, width = vl_unit(2, "in"), height = vl_unit(1, "in"))
  b <- S7::set_props(s, width = vl_unit(3, "in"), height = vl_unit(1, "in"))
  scene_raster(a) # miss (size A)
  scene_raster(b) # miss (size B)
  scene_raster(a) # hit (back to size A)
  expect_equal(misses(), 2L)
  expect_equal(hits(), 1L)
})

test_that("a device-only set_props preserves the content identity token", {
  s <- demo_scene()
  s2 <- S7::set_props(s, width = vl_unit(4, "in"), height = vl_unit(3, "in"), dpi = 150)
  expect_identical(s2@bstate$cid, s@bstate$cid) # resize keeps identity
})

test_that("keying does not walk the tree: one render = one materialise, a repeat = none", {
  reset_cache()
  s <- demo_scene()
  scene_raster(s)
  expect_equal(.mtl_count$n, 1L) # exactly one build->gtree walk for the compile
  scene_raster(s) # cache hit
  expect_equal(.mtl_count$n, 1L) # no extra walk => no O(grobs) key hashing (the FW4 tax)
})

test_that("a resize reuses the materialised tree (device-independent memo)", {
  reset_cache()
  s <- demo_scene()
  scene_raster(s) # 1 walk
  scene_raster(S7::set_props(s, width = vl_unit(3, "in"))) # new size: compiled miss, materialise hit
  expect_equal(.mtl_count$n, 1L) # still one walk
})

test_that("options(vellum.cache = FALSE) bypasses the cache", {
  reset_cache()
  s <- demo_scene()
  a <- withr::with_options(list(vellum.cache = FALSE), scene_raster(s))
  b <- withr::with_options(list(vellum.cache = FALSE), scene_raster(s))
  expect_identical(a, b)
  expect_equal(c(misses(), hits()), c(0L, 0L)) # neither stored nor served
})

test_that("debug renders bypass the cache", {
  reset_cache()
  s <- demo_scene()
  f <- withr::local_tempfile(fileext = ".png")
  render(s, f, debug = TRUE)
  expect_equal(c(misses(), hits()), c(0L, 0L))
})

test_that("a scene with no identity token bypasses the cache (fail-safe)", {
  reset_cache()
  base <- demo_scene()
  root <- .materialize(base)
  foreign <- vellum_scene(
    width = vl_unit(2, "in"), height = vl_unit(1, "in"), dpi = 100, bg = "white",
    root = root, bstate = NULL # hand-built: no cid stamped
  )
  expect_null(foreign@cid)
  r <- scene_raster(foreign) # renders fine, uncached
  expect_equal(c(misses(), hits()), c(0L, 0L))
  expect_identical(r, scene_raster(base)) # byte-identical to the built original
})

test_that("a carrier-invariant violation (both root and bstate set) fails safe, no stale hit", {
  reset_cache()
  s <- demo_scene(col = "red")
  scene_raster(s) # cache the red scene under its bstate cid
  blue_tree <- .materialize(edit_node(s, "dot", gp = vl_gpar(fill = "blue", col = NA)))
  # Unsupported: graft a new tree onto a still-building scene (both carriers set).
  bad <- S7::set_props(s, root = blue_tree)
  r <- scene_raster(bad)
  expect_equal(r[3, 100, 50], 255L) # blue drawn, NOT the cached red Scene
  expect_equal(hits(), 0L) # the corrupted scene was not served from cache
})

test_that("the LRU cap bounds resident entries", {
  reset_cache()
  withr::with_options(list(vellum.cache_size = 2L), {
    for (i in 1:4) scene_raster(demo_scene(w = 1 + i * 0.1)) # 4 distinct sizes
    # order tracks at most `cap` live entries (plus the .order/.hits/.misses fields)
    entries <- setdiff(ls(.render_cache, all.names = TRUE), c(".order", ".hits", ".misses"))
    expect_lte(length(entries), 2L)
    expect_lte(length(.render_cache$.order), 2L)
  })
})

test_that("vl_clear_render_cache empties the cache", {
  reset_cache()
  scene_raster(demo_scene())
  expect_gt(length(setdiff(ls(.render_cache, all.names = TRUE), c(".order", ".hits", ".misses"))), 0L)
  vl_clear_render_cache()
  expect_equal(length(setdiff(ls(.render_cache, all.names = TRUE), c(".order", ".hits", ".misses"))), 0L)
  expect_equal(c(misses(), hits()), c(0L, 0L))
})
