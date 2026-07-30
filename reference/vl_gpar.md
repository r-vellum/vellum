# Graphical parameters

Builds a set of graphical parameters attached to a grob or viewport. Any
field left `NULL` is inherited from the enclosing viewport; `alpha`
multiplies down the viewport tree. A colour value sets it; `NA` means
"no paint".

## Usage

``` r
vl_gpar(
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
  cex = NULL,
  lineheight = NULL,
  halo_col = NULL,
  halo_width = NULL,
  features = NULL,
  antialias = NULL,
  crisp = NULL
)
```

## Arguments

- col:

  Stroke/text colour.

- fill:

  Fill colour, or a gradient from
  [`linear_gradient()`](https://r-vellum.github.io/vellum/reference/gradients.md)
  /
  [`radial_gradient()`](https://r-vellum.github.io/vellum/reference/gradients.md).

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

- cex:

  Multiplier applied to `fontsize` (grid semantics), so a theme can ask
  for a relative size without knowing the base one. `cex = 2` is exactly
  equivalent to doubling `fontsize`: it scales drawn text, `char`/`line`
  units, and
  [`grobwidth()`](https://r-vellum.github.io/vellum/reference/grobwidth.md)/[`grobheight()`](https://r-vellum.github.io/vellum/reference/grobwidth.md)
  measurement alike. `NULL` (the default) means 1.

- lineheight:

  Line-height multiple.

- halo_col:

  Halo colour for text (a "shadowtext" outline drawn *under* the glyphs,
  so a label stays legible over dense marks or map imagery). `NULL`
  (default) means no halo. Needs `halo_width` to be visible.

- halo_width:

  Halo thickness in points – the visible width outside the glyph. `NULL`
  or `0` means no halo. A good starting point is roughly an eighth of
  `fontsize`.

- features:

  OpenType font features, as a named numeric vector of four-character
  feature tags – e.g. `c(tnum = 1)` for tabular (fixed-width) figures so
  axis labels stop jittering between ticks, `c(smcp = 1)` for small
  caps, `c(onum = 1)` for oldstyle figures, `c(liga = 0)` to switch
  ligatures off, or `c(kern = 0)` to disable kerning. `NULL` (default)
  uses the font's own defaults. A feature the font does not carry is
  silently ignored – that is HarfBuzz's behaviour, not something vellum
  can check for you.

- antialias:

  Anti-alias this element's edges? `NULL` (default) inherits; the root
  default is `TRUE`. `FALSE` gives hard pixel edges, which is what pixel
  art, QR codes, and heatmap cells that must tile without a seam want.

- crisp:

  Snap axis-parallel strokes onto the pixel grid? `NULL` (default)
  inherits; the root default is `FALSE`. A 1-px rule at a fractional
  coordinate straddles two pixel rows and renders as two grey ones
  rather than one solid — the reason gridlines look muddy on screen.
  `TRUE` snaps horizontal and vertical runs so they land on whole
  pixels. Diagonals are unaffected (there is no grid to snap them to),
  and it only applies to raster output — a vector format has no pixel
  grid.

## Value

A `gpar` object.

## Examples

``` r
vl_gpar(col = "steelblue", lwd = 2, lty = "dashed", lineend = "round")
#> <vellum::vl_gpar>
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
#>  @ cex       : NULL
#>  @ lineheight: NULL
#>  @ halo_col  : NULL
#>  @ halo_width: NULL
#>  @ features  : NULL
#>  @ antialias : NULL
#>  @ crisp     : NULL
```
