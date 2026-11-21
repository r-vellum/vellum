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
    draw(circle_grob(
      x = 0.45,
      y = 0.5,
      r = 0.25,
      gp = vl_gpar(fill = "red", col = NA)
    )) |>
    pop() |>
    push(vl_viewport(cache = cache, name = "fg")) |>
    draw(circle_grob(
      x = 0.55,
      y = 0.5,
      r = 0.25,
      gp = vl_gpar(fill = fg, col = NA),
      name = "dot"
    )) |>
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

# A boundary over a grey page holding a multiply group of a yellow square,
# optionally inside a `mid` viewport.
nested_blend <- function(cache, mid = NULL) {
  s <- vl_scene(1, 1, dpi = 72, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "grey50", col = NA))) |>
    push(vl_viewport(cache = cache))
  if (!is.null(mid)) {
    s <- push(s, mid)
  }
  s <- s |>
    push(vl_viewport(blend = "multiply")) |>
    draw(rect_grob(
      0.5,
      0.5,
      0.6,
      0.6,
      gp = vl_gpar(fill = "yellow", col = NA)
    )) |>
    pop()
  if (!is.null(mid)) {
    s <- pop(s)
  }
  pop(s)
}

test_that("a boundary holding a blend that reaches the page is not cached (VR-24)", {
  # The blend composites against the page, which a captured sub-raster lacks:
  # cached, the yellow would multiply with transparency and stay yellow.
  vl_clear_render_cache()
  plain <- nested_blend(cache = TRUE)
  got <- scene_raster(plain)
  expect_equal(rs_subraster_stats()[1:2], c(0L, 0L)) # never bracketed
  expect_identical(got, scene_raster(nested_blend(cache = FALSE)))
  # yellow x grey50 is olive, not yellow
  expect_lt(got[1, 36, 36], 160L)
  # also through a plain viewport in between (it isolates nothing, VR-21)
  vl_clear_render_cache()
  deep <- nested_blend(TRUE, vl_viewport(name = "mid"))
  scene_raster(deep)
  expect_equal(rs_subraster_stats()[1:2], c(0L, 0L))
})

test_that("a boundary whose blend sits inside its own isolated group still caches (VR-24)", {
  # An opacity group isolates the blend: it composites against that group's
  # layer, which the sub-raster holds, so caching is exact.
  vl_clear_render_cache()
  iso <- vl_viewport(alpha = 0.8)
  got <- scene_raster(nested_blend(TRUE, iso))
  expect_equal(rs_subraster_stats()[2], 1L) # bracketed (one miss)
  expect_identical(got, scene_raster(nested_blend(FALSE, iso)))
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

test_that("the sub-raster cache retains multiple generations (no full wipe at cap)", {
  # BUGFIX1 Phase 3: eviction was a full clear() at capacity, which collapsed the
  # hit rate the moment the boundary count exceeded the cap. Two-generation
  # ("retain-half") eviction keeps up to ~2x the cap resident. With 50 distinct
  # cached boundaries and a per-generation cap of 32, all 50 stay resident; the
  # old clear()-at-32 policy would leave only ~18.
  vl_clear_render_cache()
  s <- vl_scene(4, 4, dpi = 50, bg = "white")
  n <- 50L
  for (i in seq_len(n)) {
    s <- s |>
      push(vl_viewport(
        x = (i %% 8) / 8 + 0.06,
        y = (i %/% 8) / 8 + 0.06,
        width = 0.1,
        height = 0.1,
        cache = TRUE,
        name = paste0("b", i)
      )) |>
      draw(circle_grob(r = 0.4, gp = vl_gpar(fill = "red", col = NA))) |>
      pop()
  }
  scene_raster(s)
  st <- rs_subraster_stats()
  expect_equal(st[2], n) # all 50 distinct boundaries miss on the cold pass
  expect_equal(st[3], n) # ...and all 50 stay resident (retain-half, not wiped)
})

test_that("a cached boundary that inherits gpar renders byte-identical to uncached", {
  # Guards the sub-raster key's gpar fingerprint (BUGFIX1 Phase 3): a boundary
  # whose descendants inherit an ancestor's fill must still be pixel-correct.
  mk <- function(cache) {
    vl_scene(2, 1, dpi = 100, bg = "white") |>
      push(vl_viewport(name = "outer", gp = vl_gpar(fill = "darkorange"))) |>
      push(vl_viewport(cache = cache, name = "inner")) |>
      draw(rect_grob(width = 0.5, height = 0.8, gp = vl_gpar(col = NA))) |>
      pop() |>
      pop()
  }
  vl_clear_render_cache()
  expect_identical(scene_raster(mk(TRUE)), scene_raster(mk(FALSE)))
})
