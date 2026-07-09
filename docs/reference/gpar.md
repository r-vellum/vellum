# Graphical parameters

Builds a set of graphical parameters attached to a grob or viewport. Any
field left `NULL` is inherited from the enclosing viewport; `alpha`
multiplies down the viewport tree. A colour value sets it; `NA` means
"no paint".

## Usage

``` r
gpar(
  col = NULL,
  fill = NULL,
  lwd = NULL,
  alpha = NULL,
  lty = NULL,
  lineend = NULL,
  linejoin = NULL,
  linemitre = NULL,
  fontfamily = NULL,
  fontface = NULL,
  fontsize = NULL,
  lineheight = NULL
)
```

## Arguments

- col:

  Stroke/text colour.

- fill:

  Fill colour, or a gradient from
  [`linear_gradient()`](https://schochastics.github.io/vellum/reference/gradients.md)
  /
  [`radial_gradient()`](https://schochastics.github.io/vellum/reference/gradients.md).

- lwd:

  Line width (1 == 1/96 inch).

- alpha:

  Opacity multiplier in `[0, 1]`.

- lty:

  Line type: a name (`"solid"`, `"dashed"`, `"dotted"`, `"dotdash"`,
  `"longdash"`, `"twodash"`), an integer code `0:6`, a hex dash string
  (e.g. `"44"`), or a numeric vector of on/off dash lengths. Dash
  lengths scale with `lwd`.

- lineend:

  Line cap: `"round"` (default), `"butt"`, or `"square"`.

- linejoin:

  Line join: `"round"` (default), `"mitre"`, or `"bevel"`.

- linemitre:

  Mitre limit (\>= 1) for mitre joins; default 10.

- fontfamily:

  Font family (text grobs).

- fontface:

  One of `"plain"`, `"bold"`, `"italic"`, `"bold.italic"`.

- fontsize:

  Font size in points.

- lineheight:

  Line-height multiple.

## Value

A `gpar` object.

## Examples

``` r
gpar(col = "steelblue", lwd = 2, lty = "dashed", lineend = "round")
#> <vellum::gpar>
#>  @ col       : chr "steelblue"
#>  @ fill      : NULL
#>  @ lwd       : num 2
#>  @ alpha     : NULL
#>  @ lty       : chr "dashed"
#>  @ lineend   : chr "round"
#>  @ linejoin  : NULL
#>  @ linemitre : NULL
#>  @ fontfamily: NULL
#>  @ fontface  : NULL
#>  @ fontsize  : NULL
#>  @ lineheight: NULL
```
