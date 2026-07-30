# Ink and overplotting statistics for a scene

How much of the canvas a scene actually covers, and how hard it is
working to do it. `overplot` is the honest signal for "should this be
[`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)-ed?":
a count of marks says nothing about whether they overlap, whereas thirty
thousand well-separated points are fine and eight thousand piled on top
of each other are not.

## Usage

``` r
scene_stats(scene)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method.

## Value

A one-row data frame:

- `elements`:

  total drawn elements.

- `ink`:

  fraction of canvas pixels differing from the background.

- `colours`:

  distinct colours in the rendered image.

- `overplot`:

  summed element-box area divided by inked area — an estimate of how
  many times an average inked pixel was drawn over. `1` means no
  overlap. It is computed from bounding boxes, so it over-estimates for
  non-rectangular marks (a circle fills ~79% of its box); treat it as an
  index, not a measurement. Marks the element table does not cover —
  text, and unkeyed lines/polygons/paths — contribute to `ink` but not
  to `overplot`.

## See also

[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md),
[`profile_render()`](https://r-vellum.github.io/vellum/reference/profile_render.md),
[`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)

## Examples

``` r
set.seed(1)
sparse <- vl_scene(4, 3) |> draw(points_grob(runif(200), runif(200)))
dense <- vl_scene(4, 3) |> draw(points_grob(rnorm(20000, 0.5, 0.05),
                                            rnorm(20000, 0.5, 0.05)))
rbind(sparse = scene_stats(sparse), dense = scene_stats(dense))
#>        elements       ink colours   overplot
#> sparse      200 0.1416016     256   2.918994
#> dense     20000 0.1258681     256 328.386864
```
