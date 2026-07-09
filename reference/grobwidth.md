# Size a unit by a grob's extent

`grobwidth(grob)` and `grobheight(grob)` return a
[`unit()`](https://r-vellum.github.io/vellum/reference/unit.md) equal to
the drawn width/height of `grob` — handy for sizing a
[`viewport()`](https://r-vellum.github.io/vellum/reference/viewport.md)
or
[`grid_layout()`](https://r-vellum.github.io/vellum/reference/viewport.md)
track to its contents (e.g. a margin to an axis label). The extent is
measured **eagerly** to absolute millimetres at construction, so it is
exact for text and absolute-unit (`mm`/`in`/`pt`) grobs. A grob sized in
`npc`/`native` has no viewport-independent extent and is measured
against a fixed reference, so for those prefer `npc`/`native` directly.

## Usage

``` r
grobwidth(grob, mult = 1)

grobheight(grob, mult = 1)
```

## Arguments

- grob:

  A grob (or composite subtree) to measure.

- mult:

  A multiplier on the measured extent (default 1).

## Value

A `unit` (in millimetres).

## Examples

``` r
grobwidth(text_grob("A wide axis label", gp = gpar(fontsize = 14)))
#> <vellum_unit[1]>
#> [1] 41.51753mm
grobheight(rect_grob(height = unit(8, "mm")))
#> <vellum_unit[1]>
#> [1] 8.466667mm
```
