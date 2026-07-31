# Find the largest empty rectangle in a scene

Answers "where is there room?" — for a legend, an annotation, a
watermark, or anything else that has to go somewhere the marks are not.

## Usage

``` r
vl_empty_region(
  scene,
  avoid = NULL,
  within = NULL,
  grid = 200,
  unit = c("npc", "mm")
)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  (or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method).

- avoid:

  Names of the grobs to treat as obstacles. `NULL` (default) takes every
  node that is not a label.

- within:

  Region to search, as `c(x0, y0, x1, y1)` in `npc` of the page.
  Defaults to the whole page.

- grid:

  Grid resolution (cells across the longer side).

- unit:

  Unit of the returned rectangle: `"npc"` (default) or `"mm"`.

## Value

A named numeric `c(x0, y0, x1, y1)`, in `unit`, using the usual
y-grows-up convention. All zeros if there is no free space.

## Details

Occupancy is rasterised onto a grid and the answer is exact *on that
grid*. The approximation is deliberate: the exact maximal empty
rectangle over n boxes is superquadratic, and nothing is placed to
sub-pixel tolerance. Raise `grid` to trade time for precision. Boxes are
rounded outward, so the result is conservative — it will never claim
space that is in fact occupied.

## Examples

``` r
set.seed(1)
s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
  draw(points_grob(runif(40) * 0.5, runif(40),
                   gp = vl_gpar(fill = "steelblue", col = NA)))
vl_empty_region(s)
#>   x0   y0   x1   y1 
#> 0.52 0.00 1.00 1.00 
```
