# Masks

Wrap a grob (or list of grobs) as a mask for `vl_viewport(mask = ...)`.
The mask content is rendered to an isolated layer; its coverage then
modulates the visibility of the viewport's contents.

## Usage

``` r
as_mask(grob, type = c("alpha", "luminance"))
```

## Arguments

- grob:

  A grob, or a list of grobs, drawn in the masked viewport's coordinate
  system.

- type:

  `"alpha"` (default) uses the mask's opacity as coverage; `"luminance"`
  uses its brightness (white shows, black hides).

## Value

A `vellum_mask` object.

## Examples

``` r
as_mask(circle_grob(r = 0.4, gp = vl_gpar(fill = "white", col = NA)))
#> <vellum_mask> type = "alpha", 1 grob
```
