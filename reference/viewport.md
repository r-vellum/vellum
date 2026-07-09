# Viewports and layouts

A `viewport` is a rectangular region that establishes its own coordinate
systems (its `xscale`/`yscale` for `"native"` units), optionally
rotated, clipped, and carrying inheritable graphical parameters. Push
one onto a scene with
[`push()`](https://r-vellum.github.io/vellum/reference/vl_scene.md). A
viewport may define a row/column `grid_layout()`; child viewports are
then placed into cells via `row`/`col`.

## Usage

``` r
viewport(
  x = 0.5,
  y = 0.5,
  width = 1,
  height = 1,
  xscale = c(0, 1),
  yscale = c(0, 1),
  angle = 0,
  clip = FALSE,
  gp = gpar(),
  layout = NULL,
  row = NULL,
  col = NULL,
  rowspan = 1,
  colspan = 1,
  mask = NULL,
  alpha = NULL,
  blend = NULL,
  name = NULL,
  cache = FALSE
)

grid_layout(
  widths = unit(1, "null"),
  heights = unit(1, "null"),
  respect = FALSE
)
```

## Arguments

- x, y:

  Centre of the viewport
  ([`unit()`](https://r-vellum.github.io/vellum/reference/unit.md) or
  numeric, in the parent).

- width, height:

  Size ([`unit()`](https://r-vellum.github.io/vellum/reference/unit.md)
  or numeric, in the parent).

- xscale, yscale:

  Length-2 native coordinate ranges.

- angle:

  Rotation in degrees, counter-clockwise about the centre.

- clip:

  Clip drawing to this viewport: `TRUE`/`FALSE` for the viewport
  rectangle, or a
  [`polygon_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)/[`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  (in this viewport's coordinates) to clip to an arbitrary path.

- gp:

  Inheritable graphical parameters, from
  [`gpar()`](https://r-vellum.github.io/vellum/reference/gpar.md).

- layout:

  An optional `grid_layout()`.

- row, col:

  Cell (1-based) of the parent's layout to place into.

- rowspan, colspan:

  Number of cells to span.

- mask:

  An optional mask: a grob (or list of grobs), or an
  [`as_mask()`](https://r-vellum.github.io/vellum/reference/as_mask.md)
  result. The viewport's contents are rendered as an isolated layer and
  the mask modulates their visibility.

- alpha:

  Optional group opacity in `[0, 1]`. The viewport's contents are
  composited as a single isolated layer at this opacity, so overlapping
  elements do not accumulate (unlike per-element `gpar(alpha=)`). `NULL`
  (default) means fully opaque.

- blend:

  Optional blend mode for compositing the viewport's contents (as an
  isolated layer) onto the backdrop below it. One of `"normal"`
  (default), `"multiply"`, `"screen"`, `"overlay"`, `"darken"`,
  `"lighten"`, `"color-dodge"`, `"color-burn"`, `"hard-light"`,
  `"soft-light"`, `"difference"`, `"exclusion"`, `"hue"`,
  `"saturation"`, `"color"`, or `"luminosity"` (the CSS `mix-blend-mode`
  set). `NULL`/`"normal"` is ordinary over-compositing.

- name:

  Optional name (for
  [`edit_node()`](https://r-vellum.github.io/vellum/reference/node_names.md)).

- cache:

  Repaint boundary (`TRUE`/`FALSE`, default `FALSE`). Flag this
  viewport's subtree as a cached sub-raster: on render it is rasterised
  once to its own layer and, on later renders where the subtree is
  **unchanged**, the cached pixels are composited instead of re-drawing
  the subtree. This makes partial redraw cheap — highlight/hover
  ([`edit_node()`](https://r-vellum.github.io/vellum/reference/node_names.md)
  one element and re-render) or animation (one subtree changes, others
  static) re-rasterise only what changed.
  Raster/[`display()`](https://r-vellum.github.io/vellum/reference/display.md)
  only; SVG/PDF ignore it and render the subtree as vector (no fidelity
  loss). Ignored when the viewport also sets a non-normal `blend` (a
  blend needs the live backdrop). See
  [`vl_clear_render_cache()`](https://r-vellum.github.io/vellum/reference/vl_clear_render_cache.md).

- widths, heights:

  Track sizes as a
  [`unit()`](https://r-vellum.github.io/vellum/reference/unit.md)
  vector. Use `"null"` units for flexible tracks that share leftover
  space in proportion to their value.

- respect:

  Logical; if `TRUE`, lock the layout's aspect grid-style: one unit of
  `"null"` width is forced to the same physical (device) size as one
  unit of `"null"` height. The axis whose `null` unit would be larger
  shrinks to match and the whole grid is centered in its parent (so
  absolute gutter tracks stay attached to the flexible cells). Encode a
  desired cell aspect in the `null` track weights — a cell of `null`
  width-weight `w` by height-weight `h` then renders with device aspect
  `w:h`. Default `FALSE` (tracks just fill the parent). This is how a
  fixed-aspect panel (e.g.
  [`coord_fixed()`](https://ggplot2.tidyverse.org/reference/coord_fixed.html),
  maps) is built on top of vellum.

## Value

A `viewport` object.

`grid_layout()`: a layout object.

## Examples

``` r
viewport(xscale = c(0, 10), yscale = c(0, 100))
#> <vellum::class_viewport>
#>  @ x      : unit [1:1] 0.5npc
#>  @ y      : unit [1:1] 0.5npc
#>  @ width  : unit [1:1] 1npc
#>  @ height : unit [1:1] 1npc
#>  @ xscale : num [1:2] 0 10
#>  @ yscale : num [1:2] 0 100
#>  @ angle  : num 0
#>  @ clip   : logi FALSE
#>  @ gp     : <vellum::gpar>
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
