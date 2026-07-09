# Arrowheads

Describe arrowheads to draw on the ends of a
[`lines_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
or
[`segments_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
(pass as their `arrow =` argument).

## Usage

``` r
arrow(
  angle = 30,
  length = unit(0.25, "in"),
  ends = c("last", "first", "both"),
  type = c("open", "closed")
)
```

## Arguments

- angle:

  Half-angle of the head at the tip, in degrees (default 30).

- length:

  Head length as an absolute
  [`unit()`](https://schochastics.github.io/vellum/reference/unit.md)
  (default `unit(0.25, "in")`).

- ends:

  Which ends get a head: `"last"` (default), `"first"`, or `"both"`.

- type:

  `"open"` (a two-barb V) or `"closed"` (a filled triangle).

## Value

A `vellum_arrow` object.

## Examples

``` r
lines_grob(c(0.1, 0.9), c(0.1, 0.9), arrow = arrow(type = "closed"))
#> <vellum::grob_lines>
#>  @ name     : NULL
#>  @ gp       : <vellum::gpar>
#>  .. @ col       : NULL
#>  .. @ fill      : NULL
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
#>  @ vp       : NULL
#>  @ id       : NULL
#>  @ role     : NULL
#>  @ keys     : NULL
#>  @ meta     : NULL
#>  @ x        : unit [1:2] 0.1native, 0.9native
#>  @ y        : unit [1:2] 0.1native, 0.9native
#>  @ arrow    :List of 4
#>  .. $ angle : num 30
#>  .. $ length: unit [1:1] 0.25in
#>  .. $ ends  : chr "last"
#>  .. $ type  : chr "closed"
#>  .. - attr(*, "class")= chr "vellum_arrow"
#>  @ start_cap: NULL
#>  @ end_cap  : NULL
#>  @ offset   : NULL
#>  @ sketch   : NULL
```
