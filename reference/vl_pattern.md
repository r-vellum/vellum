# Tiling-pattern fills

Create a pattern that fills a shape by tiling a grob. The grob is drawn
once into a tile occupying the unit square (`0..1` npc), then repeated
across a cell of size `width` x `height` (in `units`) anchored at
`(x, y)`. Like gradients, the cell geometry is resolved against the
viewport at draw time.

## Usage

``` r
vl_pattern(
  grob,
  width = 0.1,
  height = 0.1,
  x = 0.5,
  y = 0.5,
  units = "npc",
  extend = "repeat"
)
```

## Arguments

- grob:

  A grob, or a list of grobs, drawn into the tile (their `0..1` npc
  coordinates map to the tile, painted in order).

- width, height:

  Size of one tile cell (default `0.1` npc).

- x, y:

  Cell centre (default centred).

- units:

  Coordinate system for the geometry; see
  [`linear_gradient()`](https://r-vellum.github.io/vellum/reference/gradients.md).

- extend:

  Tiling mode: `"repeat"` (default), `"reflect"`, or `"pad"`. (SVG
  renders all modes as `repeat`.)

## Value

A `vellum_pattern` object, suitable for `vl_gpar(fill = ...)`.

## Details

The tile is rendered to a raster image (sized from `width`/`height` at
the scene's resolution) and embedded on every backend: PNG raster, SVG
`<image>` in a `<pattern>`, and a PDF tiling pattern with the tile as an
embedded image XObject. Only a degenerate tile or cell size fails,
leaving the shape unfilled with a degrade warning.

## Examples

``` r
dots <- circle_grob(r = 0.25, gp = vl_gpar(fill = "white", col = NA))
vl_pattern(dots, width = 0.08, height = 0.08)
#> <vellum_pattern> cell 0.08 x 0.08 "npc", extend = "repeat"
```
