# Reusable style classes

A `style` bundles
[`vl_gpar()`](https://r-vellum.github.io/vellum/reference/vl_gpar.md)
graphical parameters under an optional name so the same look can be
reused across many viewports or grobs. A `style` **is** a `gpar` — it
carries every graphical-parameter field and obeys the same inheritance
rules — with an added `name` for identification. It can therefore be
passed anywhere a `gp` is accepted.

## Usage

``` r
style(
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
  lineheight = NULL,
  name = NULL
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

- lineheight:

  Line-height multiple.

- name:

  Optional style-class name, for identification only; it is ignored by
  rendering.

## Value

A `style` object (a subclass of `gpar`).

## Details

Attaching a `style` to a viewport cascades its defaults to the whole
subtree via the ordinary gpar inheritance (more-specific overrides
less-specific), so a child grob's own `gp` still wins. This is the
reusable "style class" layer that sits below a grammar's themes: a theme
can compile *into* named styles rather than setting gpar fields ad hoc
on every element.

## Examples

``` r
accent <- style(col = "firebrick", lwd = 2, name = "accent")
# Reuse it on a viewport; children inherit unless they override.
vl_viewport(gp = accent)
#> <vellum::class_viewport>
#>  @ x      : unit [1:1] 0.5npc
#>  @ y      : unit [1:1] 0.5npc
#>  @ width  : unit [1:1] 1npc
#>  @ height : unit [1:1] 1npc
#>  @ xscale : num [1:2] 0 1
#>  @ yscale : num [1:2] 0 1
#>  @ angle  : num 0
#>  @ clip   : logi FALSE
#>  @ gp     : <vellum::vellum_style>
#>  .. @ col       : chr "firebrick"
#>  .. @ fill      : NULL
#>  .. @ lwd       : num 2
#>  .. @ alpha     : NULL
#>  .. @ lty       : NULL
#>  .. @ lineend   : NULL
#>  .. @ linejoin  : NULL
#>  .. @ linemitre : NULL
#>  .. @ fontfamily: NULL
#>  .. @ fontface  : NULL
#>  .. @ fontsize  : NULL
#>  .. @ lineheight: NULL
#>  .. @ name      : chr "accent"
#>  @ layout : NULL
#>  @ row    : NULL
#>  @ col    : NULL
#>  @ rowspan: int 1
#>  @ colspan: int 1
#>  @ mask   : NULL
#>  @ alpha  : NULL
#>  @ blend  : NULL
#>  @ name   : NULL
#>  @ cache  : logi FALSE
```
