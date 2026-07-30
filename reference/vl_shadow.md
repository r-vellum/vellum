# Drop shadow for a viewport group

Describes a shadow cast by everything drawn inside a
[`vl_viewport()`](https://r-vellum.github.io/vellum/reference/vl_viewport.md):
the group's own silhouette, tinted, blurred and offset, painted
underneath it. Because it is a *group* effect, overlapping shapes inside
the viewport cast one shadow together rather than each casting its own
onto the others.

## Usage

``` r
vl_shadow(dx = 2, dy = 2, blur = 3, col = "#00000059")
```

## Arguments

- dx, dy:

  Offset in points; positive `dy` moves the shadow down.

- blur:

  Blur radius in points. `0` gives a hard offset silhouette.

- col:

  Shadow colour; usually a translucent black.

## Value

A `vellum_shadow` object, for `vl_viewport(shadow = )`.

## See also

[`vl_viewport()`](https://r-vellum.github.io/vellum/reference/vl_viewport.md)

## Examples

``` r
vl_scene(3, 2) |>
  push(vl_viewport(width = 0.6, height = 0.6, shadow = vl_shadow())) |>
  draw(circle_grob(gp = vl_gpar(fill = "steelblue", col = NA))) |>
  pop()
```
