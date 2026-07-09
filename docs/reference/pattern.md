# Tiling-pattern fills

Create a pattern that fills a shape by tiling a grob. The grob is drawn
once into a tile occupying the unit square (`0..1` npc), then repeated
across a cell of size `width` x `height` (in `units`) anchored at
`(x, y)`. Like gradients, the cell geometry is resolved against the
viewport at draw time.

## Usage

``` r
pattern(
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
  [`linear_gradient()`](https://schochastics.github.io/vellum/reference/gradients.md).

- extend:

  Tiling mode: `"repeat"` (default), `"reflect"`, or `"pad"`. (SVG
  renders all modes as `repeat`.)

## Value

A `vellum_pattern` object, suitable for `gpar(fill = ...)`.

## Details

The tile is rendered to a raster image (sized from `width`/`height` at
the scene's resolution) and embedded: PNG raster, SVG `<image>` in a
`<pattern>`. The PDF backend has no image support yet, so a pattern
degrades to the tile's average colour there.

## Examples

``` r
dots <- circle_grob(r = 0.25, gp = gpar(fill = "white", col = NA))
pattern(dots, width = 0.08, height = 0.08)
#> $grob
#> <vellum::grob_circle>
#>  @ name  : NULL
#>  @ gp    : <vellum::gpar>
#>  .. @ col       : logi NA
#>  .. @ fill      : chr "white"
#>  .. @ lwd       : NULL
#>  .. @ alpha     : NULL
#>  .. @ lty       : NULL
#>  .. @ lineend   : NULL
#>  .. @ linejoin  : NULL
#>  .. @ linemitre : NULL
#>  .. @ fontfamily: NULL
#>  .. @ fontface  : NULL
#>  .. @ fontsize  : NULL
#>  .. @ lineheight: NULL
#>  @ vp    : NULL
#>  @ id    : NULL
#>  @ role  : NULL
#>  @ keys  : NULL
#>  @ meta  : NULL
#>  @ x     : unit [1:1] 0.5npc
#>  @ y     : unit [1:1] 0.5npc
#>  @ r     : unit [1:1] 0.25npc
#>  @ sketch: NULL
#> 
#> $width
#> [1] 0.08
#> 
#> $height
#> [1] 0.08
#> 
#> $x
#> [1] 0.5
#> 
#> $y
#> [1] 0.5
#> 
#> $units
#> [1] "npc"
#> 
#> $extend
#> [1] "repeat"
#> 
#> attr(,"class")
#> [1] "vellum_pattern"
```
