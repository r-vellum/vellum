# Phase 8: gradient strokes and dash phase. Both ride the stroke sub-record, so
# they inherit like any other stroke property, and both are absent by default.

grad <- function() linear_gradient(c("#F97316", "#22C55E"))

test_that("a gradient in col strokes with that gradient", {
  s <- vl_scene(4, 1, dpi = 150, bg = "white") |>
    draw(segments_grob(0.05, 0.5, 0.95, 0.5, gp = vl_gpar(col = grad(), lwd = 20)))
  r <- scene_raster(s)
  early <- r[1:3, 120, 75]
  late <- r[1:3, 480, 75]
  # Orange at the start, green at the end: red falls, green rises.
  expect_gt(early[1], late[1])
  expect_lt(early[2], late[2])
})

test_that("a plain colour still strokes exactly as before", {
  mk <- function(col) vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, gp = vl_gpar(col = col, lwd = 6)))
  a <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache(); render(mk("#F97316"), a)
  r <- scene_raster(mk("#F97316"))
  expect_equal(as.integer(r[1:3, 100, 50]), c(249L, 115L, 22L))
})

test_that("gradient strokes reach SVG and PDF as real paint", {
  s <- vl_scene(3, 1, dpi = 100) |>
    draw(lines_grob(c(0.1, 0.9), c(0.5, 0.5), gp = vl_gpar(col = grad(), lwd = 8)))
  expect_match(scene_svg(s), "stroke=\"url(#", fixed = TRUE)
  f <- withr::local_tempfile(fileext = ".pdf")
  vl_clear_render_cache()
  expect_no_warning(render(s, f))
  expect_gt(file.size(f), 0)
})

test_that("a gradient stroke inherits from a viewport", {
  s <- vl_scene(4, 1, dpi = 150, bg = "white") |>
    push(vl_viewport(gp = vl_gpar(col = grad(), lwd = 20))) |>
    draw(segments_grob(0.05, 0.5, 0.95, 0.5)) |>
    pop()
  r <- scene_raster(s)
  expect_gt(r[1, 120, 75], r[1, 480, 75])
})

test_that("text falls back to the gradient's first stop", {
  # A glyph run has no path to run a ramp along, so it takes one flat colour
  # rather than silently not drawing.
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(text_grob("AAAA", gp = vl_gpar(col = grad(), fontsize = 40)))
  r <- scene_raster(s)
  # Some pixel must be near the first stop (#F97316), i.e. strongly orange.
  reds <- r[1, , ]
  greens <- r[2, , ]
  expect_true(any(reds > 200 & greens > 80 & greens < 160))
})

test_that("the per-segment stroke fast path is bypassed for a gradient", {
  # Each segment would restart the ramp; the shader must see the whole path.
  # A many-segment polyline with a gradient must still ramp end to end.
  n <- 60
  x <- seq(0.05, 0.95, length.out = n)
  s <- vl_scene(4, 1, dpi = 150, bg = "white") |>
    draw(lines_grob(x, rep(0.5, n), gp = vl_gpar(col = grad(), lwd = 20)))
  r <- scene_raster(s)
  expect_gt(r[1, 120, 75], r[1, 480, 75])
})

# --- dash phase --------------------------------------------------------------

dashed <- function(...) {
  vl_scene(4, 0.6, dpi = 100, bg = "white") |>
    draw(segments_grob(0.05, 0.5, 0.95, 0.5,
                       gp = vl_gpar(col = "black", lwd = 4, lty = "dashed", ...)))
}

test_that("dash_phase shifts where the pattern starts", {
  a <- scene_raster(dashed())
  b <- scene_raster(dashed(dash_phase = 1.5))
  expect_false(identical(as.numeric(a), as.numeric(b)))
})

test_that("dash_phase defaults to no shift", {
  f1 <- withr::local_tempfile(fileext = ".png")
  f2 <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache(); render(dashed(), f1)
  vl_clear_render_cache(); render(dashed(dash_phase = 0), f2)
  expect_identical(tools::md5sum(f1)[[1]], tools::md5sum(f2)[[1]])
})

test_that("dash_phase reaches SVG as stroke-dashoffset", {
  expect_match(scene_svg(dashed(dash_phase = 2)), "stroke-dashoffset", fixed = TRUE)
  expect_false(grepl("stroke-dashoffset", scene_svg(dashed()), fixed = TRUE))
})

test_that("dash_phase is ignored on a solid line", {
  solid <- function(...) vl_scene(2, 0.5, dpi = 100) |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, gp = vl_gpar(col = "black", lwd = 3, ...)))
  f1 <- withr::local_tempfile(fileext = ".png")
  f2 <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache(); render(solid(), f1)
  vl_clear_render_cache(); render(solid(dash_phase = 3), f2)
  expect_identical(tools::md5sum(f1)[[1]], tools::md5sum(f2)[[1]])
})

test_that("dash_phase scales with lwd, like the nibbles do", {
  # Same phase in lwd-multiples on two widths gives proportionally shifted
  # patterns rather than the same absolute offset.
  wide <- scene_raster(vl_scene(4, 0.6, dpi = 100, bg = "white") |>
    draw(segments_grob(0.05, 0.5, 0.95, 0.5,
      gp = vl_gpar(col = "black", lwd = 8, lty = "dashed", dash_phase = 1))))
  narrow <- scene_raster(vl_scene(4, 0.6, dpi = 100, bg = "white") |>
    draw(segments_grob(0.05, 0.5, 0.95, 0.5,
      gp = vl_gpar(col = "black", lwd = 2, lty = "dashed", dash_phase = 1))))
  expect_false(identical(as.numeric(wide), as.numeric(narrow)))
})
