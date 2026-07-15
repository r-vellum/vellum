# Visual-regression snapshots. The Rust raster backend is deterministic, so a
# byte-stable PNG is a tight regression guard. We snapshot only *shape* scenes
# (no text) so they don't depend on system fonts; text fidelity is covered by the
# geometry check below and in test-text.R. Skipped on CRAN/CI since pixel-exact
# PNG bytes aren't guaranteed across platforms/zlib — review locally with
# testthat::snapshot_review().

snap <- function(scene, name) {
  path <- file.path(tempdir(), name)
  render(scene, path)
  expect_snapshot_file(path, name)
}

test_that("shape rendering is byte-stable", {
  skip_on_cran()

  snap(
    vl_scene(2.7, 1.2, dpi = 90, bg = "white") |>
      draw(points_grob(vl_unit(c(1:8) / 9, "npc"), vl_unit(0.5, "npc"), size = vl_unit(4, "mm"),
                       shape = c("circle", "square", "triangle", "diamond", "plus", "cross",
                                 "triangle_down", "star"),
                       gp = vl_gpar(fill = "steelblue", col = "navy", lwd = 2))),
    "markers.png"
  )

  snap(
    vl_scene(2, 2, dpi = 90, bg = "white") |>
      draw(rect_grob(width = 0.9, height = 0.45,
                     gp = vl_gpar(col = NA, fill = linear_gradient(c("black", "white"))))) |>
      draw(circle_grob(y = 0.25, r = 0.18,
                       gp = vl_gpar(col = NA, fill = radial_gradient(c("red", "yellow"))))),
    "gradients.png"
  )

  tile <- list(rect_grob(gp = vl_gpar(fill = "red", col = NA)),
               circle_grob(r = 0.3, gp = vl_gpar(fill = "white", col = NA)))
  snap(
    vl_scene(2, 2, dpi = 90, bg = "white") |>
      draw(rect_grob(gp = vl_gpar(col = NA, fill = vl_pattern(tile, width = 0.25, height = 0.25)))),
    "pattern.png"
  )

  snap(
    vl_scene(2, 2, dpi = 90, bg = "black") |>
      push(vl_viewport(mask = as_mask(circle_grob(r = 0.4, gp = vl_gpar(fill = "white", col = NA))))) |>
      draw(rect_grob(gp = vl_gpar(fill = "orange", col = NA))) |>
      pop(),
    "mask.png"
  )

  tri <- polygon_grob(c(0.5, 0.1, 0.9), c(0.9, 0.1, 0.1))
  snap(
    vl_scene(2, 2, dpi = 90, bg = "white") |>
      push(vl_viewport(clip = tri)) |>
      draw(circle_grob(r = 0.9, gp = vl_gpar(fill = "blue", col = NA))) |>
      pop(),
    "clip-polygon.png"
  )

  snap(
    vl_scene(3, 2, dpi = 90, bg = "white") |>
      draw(bezier_grob(c(0.1, 0.3, 0.6, 0.9), c(0.2, 0.9, 0.1, 0.8), gp = vl_gpar(col = "darkgreen", lwd = 3))) |>
      draw(spline_grob(c(0.1, 0.4, 0.7, 0.9), c(0.3, 0.6, 0.3, 0.6), gp = vl_gpar(col = "purple", lwd = 3))) |>
      draw(lines_grob(c(0.1, 0.9), c(0.95, 0.95), arrow = vl_arrow(type = "closed"), gp = vl_gpar(col = "red", lwd = 2))),
    "curves-arrows.png"
  )
})

test_that("drawn text width matches the shaped (textshaping) width", {
  # Determinism check for text that doesn't depend on exact glyph pixels: the
  # rendered ink's horizontal extent should match the shaped advance width.
  fs <- 40
  label <- "Width"
  s <- vl_scene(3, 1, dpi = 100, bg = "white") |>
    draw(text_grob(label, x = 0.5, y = 0.5, just = "centre", gp = vl_gpar(fontsize = fs, col = "black")))
  red <- scene_raster(s)[1, , ]
  inked <- which(apply(red, 1, min) < 128) # x columns with ink
  drawn_w <- diff(range(inked)) # px
  shaped_w <- vl_strwidth(label, fontsize = fs, unit = "in") * 100 # px at 100 dpi
  # ink extent ignores side bearings, so allow a few px slack
  expect_lt(abs(drawn_w - shaped_w), 8)
})
