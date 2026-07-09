# Glyph-bitmap cache for high-distinct-label text. The raster backend rasterises
# each (glyph, size, colour, sub-pixel phase) once into a sprite and blits it,
# above a per-render glyph threshold. It is NOT byte-identical to the exact
# outline fill (phase quantisation), so it is gated: small/large/rotated text and
# all vector output stay exact. `rs_glyph_sprite_stats()` = c(hits, misses, resident).

# reset both the render cache (forces re-rasterisation) and the glyph/sprite cache
# (resets sprite stats and forces cold sprite builds).
reset <- function() {
  vl_clear_render_cache()
  rs_clear_glyph_cache()
}

# A deterministic scene of `n` distinct short labels (so the glyph alphabet is a
# small reused set) at random positions, one shared font/size/colour.
dense <- function(n = 800, size = 10, rot = 0, w = 6, h = 6, dpi = 100) {
  set.seed(1)
  vl_scene(w, h, dpi = dpi, bg = "white") |>
    draw(text_grob(format(seq_len(n)), x = runif(n), y = runif(n), rot = rot,
                   gp = vl_gpar(fontsize = size, col = "black")))
}

on_raster <- function(s) withr::with_options(list(vellum.glyph_bitmap = "on"), scene_raster(s))
off_raster <- function(s) withr::with_options(list(vellum.glyph_bitmap = "off"), scene_raster(s))
auto_raster <- function(s) withr::with_options(list(vellum.glyph_bitmap = "auto"), scene_raster(s))

test_that("below the threshold, auto mode is byte-identical to off (exact path)", {
  reset()
  s <- dense(n = 50) # ~150 glyphs, below the 2000 threshold
  a <- auto_raster(s)
  reset()
  o <- off_raster(s)
  expect_identical(a, o)
})

test_that("auto mode engages the sprite cache above the glyph threshold", {
  reset()
  auto_raster(dense(n = 1500, size = 9)) # ~5000 glyphs > threshold
  st <- rs_glyph_sprite_stats()
  expect_gt(st[1] + st[2], 0L) # sprites were used
  expect_gt(st[1], 0L) # and reused (distinct digits recur across labels)
})

test_that("large glyphs stay exact even above the threshold (size gate)", {
  reset()
  s <- dense(n = 800, size = 60) # >2000 glyphs, but each ~83px > SIZE_MAX
  a <- on_raster(s)
  reset()
  o <- off_raster(s)
  expect_identical(a, o)
  reset()
  on_raster(s)
  expect_equal(rs_glyph_sprite_stats()[1:2], c(0L, 0L)) # no sprites built
})

test_that("rotated text falls back to the exact path (no sprites)", {
  reset()
  s <- dense(n = 800, size = 10, rot = 90)
  a <- on_raster(s)
  reset()
  o <- off_raster(s)
  expect_identical(a, o)
  reset()
  on_raster(s)
  expect_equal(rs_glyph_sprite_stats()[1:2], c(0L, 0L)) # rot != 0 -> base not a pure translation
})

test_that("text in a rotated viewport falls back to the exact path", {
  reset()
  mk <- function() {
    set.seed(2)
    vl_scene(6, 6, dpi = 100, bg = "white") |>
      push(vl_viewport(angle = 30)) |>
      draw(text_grob(format(1:800), x = runif(800), y = runif(800),
                     gp = vl_gpar(fontsize = 10, col = "black"))) |>
      pop()
  }
  a <- on_raster(mk())
  reset()
  o <- off_raster(mk())
  expect_identical(a, o) # rotated viewport -> base has rotation -> exact
})

test_that("text inside a luminance mask is unaffected by the glyph-bitmap mode", {
  reset()
  mk <- function() {
    m <- as_mask(text_grob("MASK", x = 0.5, y = 0.5, gp = vl_gpar(fontsize = 20)), type = "luminance")
    vl_scene(4, 2, dpi = 100, bg = "black") |>
      push(vl_viewport(mask = m)) |>
      draw(rect_grob(gp = vl_gpar(fill = "white", col = NA))) |>
      pop()
  }
  on <- on_raster(mk())
  reset()
  off <- off_raster(mk())
  expect_identical(on, off) # mask backend never sprites -> luminance coverage unchanged
})

test_that("dense sprite render is deterministic and close to the exact fill", {
  reset()
  s <- dense(n = 1500, size = 9)
  cold <- on_raster(s) # builds sprites
  expect_gt(rs_glyph_sprite_stats()[1], 0L)
  vl_clear_render_cache() # drop the pixmap memo but keep sprites
  warm <- on_raster(s) # re-rasterise reusing sprites
  expect_identical(cold, warm) # sprite path is deterministic

  reset()
  exact <- off_raster(s)
  d <- abs(cold - exact)
  # Loose bounds: a gross positioning/sign bug gives max ~255 and mean in the
  # tens. Phase quantisation + AA-corner effects on heavily overlapped text
  # measure ~114 max / ~2.4 mean here; the vast majority of pixels are identical.
  expect_lt(max(d), 160L)
  expect_lt(mean(d), 6.0)
})

test_that("descenders and caps place correctly under the y-flip", {
  reset()
  s <- vl_scene(3, 1, dpi = 100, bg = "white") |>
    draw(text_grob("gjpqyTHE", x = 0.5, y = 0.5, gp = vl_gpar(fontsize = 24, col = "black")))
  on <- on_raster(s) # forced on (one label, below threshold)
  vl_clear_render_cache()
  off <- off_raster(s)
  d <- abs(on - off)
  expect_lt(max(d), 100L) # a y-flip sign error would misplace glyphs -> ~255 diff, huge mean
  expect_lt(mean(d), 1.0) # measured ~64 max / ~0.17 mean for this clean single label
})

test_that("rs_clear_glyph_cache resets the sprite cache and stats", {
  reset()
  on_raster(dense(n = 1500, size = 9))
  expect_gt(rs_glyph_sprite_stats()[3], 0L)
  rs_clear_glyph_cache()
  expect_equal(rs_glyph_sprite_stats(), c(0L, 0L, 0L))
})
