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
#> $grobs
#> $grobs[[1]]
#> <vellum::grob_circle>
#>  @ name  : NULL
#>  @ gp    : <vellum::vl_gpar>
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
#>  @ r     : unit [1:1] 0.4npc
#>  @ sketch: NULL
#> 
#> 
#> $type
#> [1] "alpha"
#> 
#> attr(,"class")
#> [1] "vellum_mask"
```
