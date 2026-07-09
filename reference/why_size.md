# Explain why a node has its resolved size

Reports the resolved width and height of a named viewport (or grob) and
what determined them — the layout track it was placed in, or the units
of its own width/height. The layout companion to the visual
`render(scene, debug = TRUE)` overlay; together they make coordinate
debugging first-class rather than an exercise in archaeology.

## Usage

``` r
why_size(scene, name)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  (or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method).

- name:

  A node name (set via the `name` argument of a viewport/grob).

## Value

A `vellum_why_size` record (a list with `name`, `width_mm`, `height_mm`,
and `determined_by`), printed legibly.

## Examples

``` r
s <- vl_scene(4, 3) |>
  push(vl_viewport(name = "panel", width = vl_unit(2, "in"), height = vl_unit(1, "in")))
why_size(s, "panel")
#> $name
#> [1] "panel"
#> 
#> $width_mm
#> [1] 50.8
#> 
#> $height_mm
#> [1] 25.4
#> 
#> $determined_by
#> [1] "placed by size: width = 2in, height = 1in"
#> 
#> attr(,"class")
#> [1] "vellum_why_size"
```
