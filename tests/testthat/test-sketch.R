# SK1-SK6: hand-drawn ("sketch") rendering. The generator lives in
# src/rust/src/sketch.rs; these tests exercise the R surface + wiring.

nonwhite <- function(scene) {
  a <- scene_raster(scene) # channels x X x Y
  # count pixels that are not pure white across the RGB channels
  sum(!(a[1, , ] == 255L & a[2, , ] == 255L & a[3, , ] == 255L))
}

test_that("sketch() validates its arguments", {
  expect_error(sketch(roughness = -1), "roughness")
  expect_error(sketch(fill_style = "scribble"))
  s <- sketch()
  expect_s3_class(s, "vellum_sketch")
})

test_that("a sketched rect renders and differs from crisp", {
  mk <- function(sk) {
    vl_scene(1, 1, dpi = 100, bg = "white") |>
      draw(rect_grob(width = 0.6, height = 0.6,
                     gp = gpar(fill = "steelblue", col = "black", lwd = 2),
                     sketch = sk))
  }
  crisp <- mk(NULL)
  drawn <- mk(sketch(seed = 1))
  expect_gt(nonwhite(drawn), 0)
  # the wobbly render differs from the crisp one
  expect_false(identical(scene_raster(crisp), scene_raster(drawn)))
})

test_that("NULL sketch is byte-identical to a plain grob", {
  a <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = gpar(fill = "grey50")))
  b <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = gpar(fill = "grey50"), sketch = NULL))
  expect_identical(scene_raster(a), scene_raster(b))
})

test_that("sketch is deterministic given a seed", {
  mk <- function() {
    vl_scene(1, 1, dpi = 100, bg = "white") |>
      draw(circle_grob(r = 0.4, gp = gpar(fill = "tomato", col = "black"),
                       sketch = sketch(seed = 42)))
  }
  expect_identical(scene_raster(mk()), scene_raster(mk()))
})

test_that("different seeds give different output", {
  mk <- function(seed) {
    vl_scene(1, 1, dpi = 100, bg = "white") |>
      draw(polygon_grob(c(0.2, 0.8, 0.5), c(0.2, 0.3, 0.9),
                        gp = gpar(fill = "gold", col = "black"),
                        sketch = sketch(seed = seed)))
  }
  expect_false(identical(scene_raster(mk(1)), scene_raster(mk(2))))
})

test_that("all fill styles produce ink", {
  for (fs in c("solid", "hachure", "crosshatch", "zigzag", "dots")) {
    s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
      draw(rect_grob(width = 0.8, height = 0.8,
                     gp = gpar(fill = "steelblue", col = "black"),
                     sketch = sketch(fill_style = fs, seed = 3)))
    expect_gt(nonwhite(s), 50) # some fill work reached the canvas
  }
})

test_that("sketch works on every supported grob", {
  base <- function(g) {
    s <- vl_scene(1, 1, dpi = 100, bg = "white") |> draw(g)
    expect_gt(nonwhite(s), 0)
  }
  base(rect_grob(width = 0.6, height = 0.6, gp = gpar(fill = "steelblue", col = "black"), sketch = sketch(seed = 1)))
  base(circle_grob(r = 0.4, gp = gpar(fill = "tomato", col = "black"), sketch = sketch(seed = 1)))
  base(polygon_grob(c(0.2, 0.8, 0.5), c(0.2, 0.3, 0.9), gp = gpar(fill = "gold", col = "black"), sketch = sketch(seed = 1)))
  base(lines_grob(c(0.1, 0.5, 0.9), c(0.1, 0.8, 0.2), gp = gpar(col = "seagreen", lwd = 2), sketch = sketch(seed = 1)))
  base(path_grob(c(0.2, 0.8, 0.8, 0.2), c(0.2, 0.2, 0.8, 0.8), gp = gpar(fill = "plum", col = "black"), sketch = sketch(seed = 1)))
  # SK7-SK10:
  base(segments_grob(c(0.1, 0.2), c(0.1, 0.9), c(0.9, 0.8), c(0.9, 0.1), gp = gpar(col = "grey30", lwd = 2), sketch = sketch(seed = 1)))
  base(sector_grob(x = 0.5, y = 0.5, r0 = 0, r1 = 0.4, theta0 = 0, theta1 = 4, fill = "tomato", gp = gpar(col = "black"), sketch = sketch(seed = 1)))
  base(roundrect_grob(width = 0.6, height = 0.5, r = 0.1, gp = gpar(fill = "mediumpurple", col = "black"), sketch = sketch(seed = 1)))
  for (shp in c("square", "triangle", "diamond", "plus", "cross")) {
    base(points_grob(0.5, 0.5, size = unit(6, "mm"), shape = shp, gp = gpar(fill = "seagreen", col = "black", lwd = 1.5), sketch = sketch(seed = 1)))
  }
})

test_that("sketched gridlines wobble (segments != crisp)", {
  mk <- function(sk) {
    vl_scene(1, 1, dpi = 100, bg = "white") |>
      draw(segments_grob(x0 = rep(0.1, 3), y0 = c(0.2, 0.5, 0.8),
                         x1 = rep(0.9, 3), y1 = c(0.2, 0.5, 0.8),
                         gp = gpar(col = "black", lwd = 2), sketch = sk))
  }
  expect_false(identical(scene_raster(mk(NULL)), scene_raster(mk(sketch(roughness = 2, seed = 1)))))
})

test_that("sketch renders on all three backends", {
  scene <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(rect_grob(width = 0.6, height = 0.6,
                   gp = gpar(fill = "steelblue", col = "black"),
                   sketch = sketch(fill_style = "hachure", seed = 7)))
  for (ext in c("png", "svg", "pdf")) {
    f <- withr::local_tempfile(fileext = paste0(".", ext))
    render(scene, f)
    expect_gt(file.size(f), 0)
  }
})
