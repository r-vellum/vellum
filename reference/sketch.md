# Hand-drawn ("sketch") rendering

Attach to a grob's `sketch` argument to render it in a hand-drawn,
sketchy style (the [Rough.js](https://roughjs.com) look): wobbly
outlines and hachure fills. Supported by
[`rect_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
[`polygon_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
[`lines_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
and
[`circle_grob()`](https://r-vellum.github.io/vellum/reference/grob.md).
Output is deterministic given `seed`.

## Usage

``` r
sketch(
  roughness = 1,
  bowing = 1,
  fill_style = c("hachure", "solid", "crosshatch", "zigzag", "dots"),
  fill_weight = NULL,
  hachure_angle = -41,
  hachure_gap = NULL,
  curve_tightness = 0,
  disable_multi_stroke = FALSE,
  preserve_vertices = FALSE,
  seed = 1L
)
```

## Arguments

- roughness:

  Wobble amount (`>= 0`; `0` is nearly crisp, `1` the default hand-drawn
  look, higher is wilder).

- bowing:

  How much straight edges bow (0 disables bowing).

- fill_style:

  One of `"hachure"` (default), `"solid"`, `"crosshatch"`, `"zigzag"`,
  `"dots"`. Non-solid styles paint the fill colour as line work.

- fill_weight:

  Stroke width of fill/hachure lines, in `lwd` units (1 == 1/96 inch);
  `NULL` derives it from the grob's `lwd`.

- hachure_angle:

  Hachure line angle in degrees.

- hachure_gap:

  Gap between hachure lines, in `lwd` units; `NULL` = auto.

- curve_tightness:

  Curve fit tightness for round shapes (circles, arcs).

- disable_multi_stroke:

  If `TRUE`, draw single (not doubled) outline strokes — a cleaner, less
  sketchy line.

- preserve_vertices:

  If `TRUE`, keep shape vertices exact (only edges wobble).

- seed:

  Integer seed for the wobble (same seed =\> identical output).

## Value

A `vellum_sketch` object for a grob's `sketch` argument.

## Details

Sketch is a deliberate exception to vellum's crisp, fidelity-first
defaults — see `vignette` / `_docs/DESIGN-ROUGHR.md`. Text is never
sketched.

## Examples

``` r
rect_grob(gp = gpar(fill = "steelblue", col = "black"), sketch = sketch())
#> <vellum::grob_rect>
#>  @ name  : NULL
#>  @ gp    : <vellum::gpar>
#>  .. @ col       : chr "black"
#>  .. @ fill      : chr "steelblue"
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
#>  @ width : unit [1:1] 1npc
#>  @ height: unit [1:1] 1npc
#>  @ sketch:List of 10
#>  .. $ roughness           : num 1
#>  .. $ bowing              : num 1
#>  .. $ fill_style          : chr "hachure"
#>  .. $ fill_weight         : num -1
#>  .. $ hachure_angle       : num -41
#>  .. $ hachure_gap         : num -1
#>  .. $ curve_tightness     : num 0
#>  .. $ disable_multi_stroke: logi FALSE
#>  .. $ preserve_vertices   : logi FALSE
#>  .. $ seed                : num 1
#>  .. - attr(*, "class")= chr "vellum_sketch"
```
