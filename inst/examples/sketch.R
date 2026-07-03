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

scene <- vl_scene(width = unit(7, "in"), height = unit(4.5, "in"), dpi = 150) |>
  push(viewport())

# A row of the five fill styles on rectangles.
styles <- c("solid", "hachure", "crosshatch", "zigzag", "dots")
for (i in seq_along(styles)) {
  cx <- (i - 0.5) / length(styles)
  scene <- scene |>
    draw(rect_grob(
      x = cx, y = 0.82, width = 0.15, height = 0.24,
      gp = gpar(fill = "steelblue", col = "black", lwd = 1.5),
      sketch = sketch(fill_style = styles[i], seed = 5)
    )) |>
    draw(text_grob(styles[i], x = cx, y = 0.63, gp = gpar(fontsize = 10)))
}

# A filled sketch circle, an outline-only circle, and a sketch polygon.
scene <- scene |>
  draw(circle_grob(
    x = 0.15, y = 0.32, r = 0.12,
    gp = gpar(fill = "tomato", col = "black", lwd = 2),
    sketch = sketch(fill_style = "hachure", hachure_angle = 20, seed = 2)
  )) |>
  draw(circle_grob(
    x = 0.42, y = 0.32, r = 0.12,
    gp = gpar(col = "navy", lwd = 2, fill = NA),
    sketch = sketch(roughness = 1.5, seed = 9)
  )) |>
  draw(polygon_grob(
    c(0.62, 0.80, 0.88, 0.70), c(0.18, 0.20, 0.46, 0.48),
    gp = gpar(fill = "gold", col = "black", lwd = 1.5),
    sketch = sketch(fill_style = "crosshatch", seed = 3)
  )) |>
  # A wobbly polyline.
  draw(lines_grob(
    c(0.05, 0.30, 0.55, 0.95), c(0.06, 0.14, 0.08, 0.16),
    gp = gpar(col = "seagreen", lwd = 2.5),
    sketch = sketch(roughness = 2, seed = 1)
  ))

render(scene, "sketch.png")
render(scene, "sketch.svg")
render(scene, "sketch.pdf")
