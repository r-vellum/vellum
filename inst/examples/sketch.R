# Hand-drawn ("sketch") rendering — the Rough.js look, generated in the engine.
#
# `sketch()` attaches to a grob's `sketch` argument and renders it wobbly, with a
# hachure (or solid / crosshatch / zigzag / dots) fill. Supported by rect_grob(),
# polygon_grob(), lines_grob(), circle_grob(), and path_grob(). Output is
# deterministic given `seed`, and identical across the PNG / SVG / PDF backends.
#
# Text is never sketched; pair a sketch scene with a handwriting font for the
# full XKCD look.

library(vellum)

scene <- vl_scene(width = vl_unit(7, "in"), height = vl_unit(4.5, "in"), dpi = 150) |>
  push(vl_viewport())

# A row of the five fill styles on rectangles.
styles <- c("solid", "hachure", "crosshatch", "zigzag", "dots")
for (i in seq_along(styles)) {
  cx <- (i - 0.5) / length(styles)
  scene <- scene |>
    draw(rect_grob(
      x = cx, y = 0.82, width = 0.15, height = 0.24,
      gp = vl_gpar(fill = "steelblue", col = "black", lwd = 1.5),
      sketch = sketch(fill_style = styles[i], seed = 5)
    )) |>
    draw(text_grob(styles[i], x = cx, y = 0.63, gp = vl_gpar(fontsize = 10)))
}

# A filled sketch circle, an outline-only circle, and a sketch polygon.
scene <- scene |>
  draw(circle_grob(
    x = 0.15, y = 0.32, r = 0.12,
    gp = vl_gpar(fill = "tomato", col = "black", lwd = 2),
    sketch = sketch(fill_style = "hachure", hachure_angle = 20, seed = 2)
  )) |>
  draw(circle_grob(
    x = 0.42, y = 0.32, r = 0.12,
    gp = vl_gpar(col = "navy", lwd = 2, fill = NA),
    sketch = sketch(roughness = 1.5, seed = 9)
  )) |>
  draw(polygon_grob(
    c(0.62, 0.80, 0.88, 0.70), c(0.18, 0.20, 0.46, 0.48),
    gp = vl_gpar(fill = "gold", col = "black", lwd = 1.5),
    sketch = sketch(fill_style = "crosshatch", seed = 3)
  )) |>
  # A wobbly polyline.
  draw(lines_grob(
    c(0.05, 0.30, 0.55, 0.95), c(0.06, 0.14, 0.08, 0.16),
    gp = vl_gpar(col = "seagreen", lwd = 2.5),
    sketch = sketch(roughness = 2, seed = 1)
  ))

render(scene, "sketch.png")
render(scene, "sketch.svg")
render(scene, "sketch.pdf")

# ---------------------------------------------------------------------------
# Every geometry element can be hand-drawn (SK7-SK10): sketchy gridlines
# (segments), pie/donut wedges (sectors), rounded panels (roundrect), and the
# full marker vocabulary (points) — the pieces a grammar needs for a fully
# hand-drawn plot.
# ---------------------------------------------------------------------------

elems <- vl_scene(width = vl_unit(7, "in"), height = vl_unit(4, "in"), dpi = 150) |>
  push(vl_viewport())

# gridlines as sketchy segments
elems <- elems |>
  draw(segments_grob(
    x0 = rep(0.04, 4), y0 = seq(0.58, 0.94, length.out = 4),
    x1 = rep(0.30, 4), y1 = seq(0.58, 0.94, length.out = 4),
    gp = vl_gpar(col = "grey40", lwd = 1.5), sketch = sketch(seed = 1)
  )) |>
  draw(segments_grob(
    x0 = seq(0.06, 0.28, length.out = 4), y0 = rep(0.55, 4),
    x1 = seq(0.06, 0.28, length.out = 4), y1 = rep(0.97, 4),
    gp = vl_gpar(col = "grey40", lwd = 1.5), sketch = sketch(seed = 2)
  )) |>
  draw(text_grob("segments", x = 0.17, y = 0.50, gp = vl_gpar(fontsize = 10)))

# a pie from two sectors
elems <- elems |>
  draw(sector_grob(x = 0.52, y = 0.76, r0 = 0, r1 = 0.16, theta0 = 0, theta1 = 1.4,
                   fill = "tomato", gp = vl_gpar(col = "black", lwd = 1.5), sketch = sketch(seed = 3))) |>
  draw(sector_grob(x = 0.52, y = 0.76, r0 = 0, r1 = 0.16, theta0 = 1.4, theta1 = 2 * pi,
                   fill = "gold", gp = vl_gpar(col = "black", lwd = 1.5), sketch = sketch(seed = 4))) |>
  draw(text_grob("sectors", x = 0.52, y = 0.50, gp = vl_gpar(fontsize = 10)))

# a rounded panel
elems <- elems |>
  draw(roundrect_grob(x = 0.84, y = 0.76, width = 0.24, height = 0.32, r = 0.05,
                      gp = vl_gpar(fill = "mediumpurple", col = "black", lwd = 2),
                      sketch = sketch(fill_style = "hachure", seed = 5))) |>
  draw(text_grob("roundrect", x = 0.84, y = 0.50, gp = vl_gpar(fontsize = 10)))

# the marker vocabulary
elems <- elems |>
  draw(points_grob(
    x = seq(0.12, 0.88, length.out = 5), y = rep(0.22, 5), size = vl_unit(6, "mm"),
    shape = c("square", "triangle", "diamond", "plus", "cross"),
    gp = vl_gpar(fill = "seagreen", col = "black", lwd = 1.5), sketch = sketch(seed = 6)
  )) |>
  draw(text_grob("markers", x = 0.5, y = 0.07, gp = vl_gpar(fontsize = 10)))

render(elems, "sketch-elements.png")
