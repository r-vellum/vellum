# Gradient fills

Create a linear or radial gradient to use as a `fill` in
[`vl_gpar()`](https://r-vellum.github.io/vellum/reference/vl_gpar.md). A
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
  extend = "pad",
  interpolation = "srgb"
)

radial_gradient(
  colours,
  stops = NULL,
  cx = 0.5,
  cy = 0.5,
  r = 0.5,
  units = "npc",
  extend = "pad",
  interpolation = "srgb"
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

- interpolation:

  Colour space the stops are blended in: `"srgb"` (default), `"oklab"`
  (perceptually uniform), or `"oklch"` (perceptual, hue-preserving). See
  Details.

- cx, cy, r:

  Centre and radius of a radial gradient (default centred, radius `0.5`
  npc).

## Value

A `vellum_gradient` object, suitable for `vl_gpar(fill = ...)`.

## Details

By default stops are blended in sRGB (each backend's native behaviour).
Set `interpolation = "oklab"` to blend in the perceptually-uniform Oklab
space instead, which removes the muddy, over-dark midtones and hue drift
of sRGB blending — the ramp stays even and vivid.
`interpolation = "oklch"` blends in the polar form of the same space
(lightness, chroma, hue): hue and chroma move independently, so a ramp
between two saturated colours keeps its chroma through the middle
instead of dipping toward grey the way a straight line in Oklab can — at
the cost of sweeping through the intermediate hues along the shorter arc
(e.g. blue→yellow passes through green). All modes work identically on
the raster, SVG, and PDF backends.

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
#> $interpolation
#> [1] "srgb"
#> 
#> attr(,"class")
#> [1] "vellum_gradient"
linear_gradient(c("blue", "yellow"), interpolation = "oklab")
#> $kind
#> [1] "linear"
#> 
#> $colours
#> [1] "blue"   "yellow"
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
#> $interpolation
#> [1] "oklab"
#> 
#> attr(,"class")
#> [1] "vellum_gradient"
linear_gradient(c("blue", "yellow"), interpolation = "oklch")
#> $kind
#> [1] "linear"
#> 
#> $colours
#> [1] "blue"   "yellow"
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
#> $interpolation
#> [1] "oklch"
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
#> $interpolation
#> [1] "srgb"
#> 
#> attr(,"class")
#> [1] "vellum_gradient"
```
