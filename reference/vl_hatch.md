# Hatch fill

Fills a shape with ruled parallel lines. Unlike
[`vl_pattern()`](https://r-vellum.github.io/vellum/reference/vl_pattern.md),
which rasterises a tile, a hatch is **geometry**: it stays crisp at any
zoom, prints correctly, and survives being converted to greyscale.

## Usage

``` r
vl_hatch(angle = 45, spacing = 3, width = 0.75, col = "black", bg = NA)
```

## Arguments

- angle:

  Direction of the rules, in degrees counter-clockwise from horizontal.
  Distinct angles (0, 45, 90, 135) read as distinct categories.

- spacing:

  Distance between rules, in points.

- width:

  Rule width, in points.

- col:

  Rule colour.

- bg:

  Optional background painted behind the rules. `NA` (default) leaves
  whatever is underneath showing through.

## Value

A `vellum_hatch` object, usable anywhere a `fill` is.

## Details

That last point is the reason to reach for it. A colour encoding that
fails for a red/green-blind reader — which
[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)'s
`cvd` argument will show you and
[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)
will flag — is fixed by encoding with *texture* as well as hue. Hatching
is the standard way to do that.

## See also

[`vl_pattern()`](https://r-vellum.github.io/vellum/reference/vl_pattern.md)
for a tiled grob,
[`linear_gradient()`](https://r-vellum.github.io/vellum/reference/gradients.md),
[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)

## Examples

``` r
vl_scene(3, 2) |>
  draw(rect_grob(width = 0.8, height = 0.8, gp = vl_gpar(
    fill = vl_hatch(angle = 45, spacing = 4), col = "grey30"
  )))
```
