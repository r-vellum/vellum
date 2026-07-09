# Gradient fills

Create a linear or radial gradient to use as a `fill` in
[`gpar()`](https://schochastics.github.io/vellum/reference/gpar.md). A
gradient interpolates between colour *stops*. Its geometry
(`x1`/`y1`/... or `cx`/`cy`/`r`) is given in the coordinate system named
by `units` and is resolved against the viewport at draw time, so the
gradient transforms with the grob just like its outline.

## Usage

``` r
linear_gradient(
  colours,
  stops = NULL,
  x1 = 0,
  y1 = 0,
  x2 = 1,
  y2 = 0,
  units = "npc",
  extend = "pad"
)

radial_gradient(
  colours,
  stops = NULL,
  cx = 0.5,
  cy = 0.5,
  r = 0.5,
  units = "npc",
  extend = "pad"
)
```

## Arguments

- colours:

  A vector of two or more colours (any R colour spec). With
  `stops = NULL` they are spread evenly across `[0, 1]`.

- stops:

  Optional offsets in `[0, 1]`, one per colour. Defaults to evenly
  spaced.

- x1, y1, x2, y2:

  Start and end points of a linear gradient (default a left-to-right
  sweep in `npc`).

- units:

  Coordinate system for the geometry: one of `"npc"`, `"native"`,
  `"mm"`, `"in"`, `"pt"`.

- extend:

  How the gradient behaves outside `[0, 1]`: `"pad"` (clamp to the end
  stops), `"repeat"`, or `"reflect"`.

- cx, cy, r:

  Centre and radius of a radial gradient (default centred, radius `0.5`
  npc).

## Value

A `vellum_gradient` object, suitable for `gpar(fill = ...)`.

## Examples

``` r
linear_gradient(c("white", "navy"))
#> $kind
#> [1] "linear"
#> 
#> $colours
#> [1] "white" "navy" 
#> 
#> $stops
#> [1] 0 1
#> 
#> $coords
#> [1] 0 0 1 0
#> 
#> $units
#> [1] "npc"
#> 
#> $extend
#> [1] "pad"
#> 
#> attr(,"class")
#> [1] "vellum_gradient"
radial_gradient(c("yellow", "red"), cx = 0.5, cy = 0.5, r = 0.5)
#> $kind
#> [1] "radial"
#> 
#> $colours
#> [1] "yellow" "red"   
#> 
#> $stops
#> [1] 0 1
#> 
#> $coords
#> [1] 0.5 0.5 0.5
#> 
#> $units
#> [1] "npc"
#> 
#> $extend
#> [1] "pad"
#> 
#> attr(,"class")
#> [1] "vellum_gradient"
```
