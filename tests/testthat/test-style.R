test_that("style() is a vl_gpar subclass carrying an optional name", {
  st <- style(col = "firebrick", lwd = 2, name = "accent")
  expect_true(S7::S7_inherits(st, vl_gpar))
  expect_true(S7::S7_inherits(st, style))
  expect_equal(st@col, "firebrick")
  expect_equal(st@lwd, 2)
  expect_equal(st@name, "accent")
})

test_that("a style attached to a viewport cascades to children", {
  # Red style on the viewport; the rect inherits col (drawn as a stroked outline).
  accent <- style(col = "red", name = "accent")
  s <- vl_scene(2, 2, bg = "white") |>
    push(vl_viewport(gp = accent)) |>
    draw(rect_grob(width = 0.5, height = 0.5, gp = vl_gpar(fill = NA, lwd = 4)))
  px <- scene_raster(s)
  # Somewhere on the page a strongly-red pixel exists (the inherited stroke).
  red <- px[1, , ] > 180 & px[2, , ] < 80 & px[3, , ] < 80
  expect_true(any(red))
})

test_that("a child gp overrides an inherited style (more-specific wins)", {
  accent <- style(col = "red", name = "accent")
  s <- vl_scene(2, 2, bg = "white") |>
    push(vl_viewport(gp = accent)) |>
    draw(rect_grob(
      width = 0.5,
      height = 0.5,
      gp = vl_gpar(fill = NA, col = "blue", lwd = 4)
    ))
  px <- scene_raster(s)
  blue <- px[3, , ] > 180 & px[1, , ] < 80 & px[2, , ] < 80
  red <- px[1, , ] > 180 & px[2, , ] < 80 & px[3, , ] < 80
  expect_true(any(blue))
  expect_false(any(red))
})

# --- gpar cex (Phase 2) ------------------------------------------------------
# `cex` multiplies `fontsize` (grid semantics). It must be exactly equivalent to
# having supplied the product as `fontsize`, everywhere size is consumed.

test_that("cex is exactly equivalent to scaling fontsize", {
  a <- text_grob("hello", gp = vl_gpar(fontsize = 12, cex = 2))
  b <- text_grob("hello", gp = vl_gpar(fontsize = 24))
  expect_equal(format(grobwidth(a)), format(grobwidth(b)))
  expect_equal(format(grobheight(a)), format(grobheight(b)))
})

test_that("cex scales char and line units", {
  expect_equal(
    format(vl_unit(1, "line", data = list(fontsize = 10, cex = 2))),
    format(vl_unit(1, "line", data = list(fontsize = 20)))
  )
  expect_equal(
    format(vl_unit(1, "char", data = list(fontsize = 6, cex = 3))),
    format(vl_unit(1, "char", data = list(fontsize = 18)))
  )
})

test_that("cex renders identically to the equivalent fontsize", {
  mk <- function(gp) vl_scene(2, 1, dpi = 100) |> draw(text_grob("Wg", gp = gp))
  f1 <- withr::local_tempfile(fileext = ".png")
  f2 <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache()
  render(mk(vl_gpar(fontsize = 10, cex = 1.5)), f1)
  vl_clear_render_cache()
  render(mk(vl_gpar(fontsize = 15)), f2)
  expect_identical(tools::md5sum(f1)[[1]], tools::md5sum(f2)[[1]])
})

test_that("an absent cex leaves output unchanged", {
  a <- text_grob("hello", gp = vl_gpar(fontsize = 12))
  b <- text_grob("hello", gp = vl_gpar(fontsize = 12, cex = 1))
  expect_equal(format(grobwidth(a)), format(grobwidth(b)))
})

test_that("a negative cex is rejected", {
  expect_error(vl_gpar(cex = -1), "cex")
})
