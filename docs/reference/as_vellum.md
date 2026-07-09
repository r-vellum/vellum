# Render grid graphics (ggplot2 / lattice / grid) through vellum

`as_vellum()` converts a grid grob tree — or a ggplot2 plot — into a
[`vl_scene()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
by letting an offscreen grid device resolve all coordinates to absolute
units, then emitting vellum grobs. `render_grid()` does that and writes
the result. This is the interop path (grid-based graphics rendered by
vellum's deterministic backend); a native graphics device is future
work.

## Usage

``` r
as_vellum(x, width = 7, height = 7, dpi = 96, bg = "white")

render_grid(
  x,
  path,
  width = 7,
  height = 7,
  dpi = 96,
  bg = "white",
  text = c("native", "outline")
)
```

## Arguments

- x:

  A grid grob/gTree/gtable, or a ggplot object.

- width, height:

  Page size in inches.

- dpi, bg:

  As in
  [`vl_scene()`](https://schochastics.github.io/vellum/reference/vl_scene.md).

- path:

  Output file (`.png`/`.svg`/`.pdf`).

- text:

  Passed to
  [`render()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
  (SVG text mode).

## Value

`as_vellum()`: a `vellum_scene`. `render_grid()`: `path`, invisibly.

## Examples

``` r
if (FALSE) { # \dontrun{
library(ggplot2)
p <- ggplot(mtcars, aes(wt, mpg)) + geom_point()
render_grid(p, "plot.png", width = 6, height = 4)
} # }
```
