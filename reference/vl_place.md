# Move labels so they stop overlapping

`vl_place()` solves label collisions over a scene's **resolved**
geometry and reports the displacement each label needs. `vl_repel()`
applies that solution and returns a new scene.

## Usage

``` r
vl_place(
  scene,
  labels = NULL,
  avoid = NULL,
  padding = 1,
  max_shift = 10,
  max_iter = 200,
  pull = 0.1
)

vl_repel(
  scene,
  labels = NULL,
  avoid = NULL,
  padding = 1,
  max_shift = 10,
  max_iter = 200,
  pull = 0.1
)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  (or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method).

- labels:

  Names of the grobs to move. `NULL` (default) takes every text node in
  the scene.

- avoid:

  Names of the grobs to treat as obstacles. `NULL` (default) takes every
  node that is not a label.

- padding:

  Clear space to keep around each label, in millimetres.

- max_shift:

  The furthest a label may travel from its anchor, in millimetres.
  Labels needing more are left at their best position and reported as
  unresolved.

- max_iter:

  Iteration cap for the relaxation.

- pull:

  Strength of the spring back to the anchor, in `[0, 1]`. Higher keeps
  labels closer to what they label; lower resolves crowding more
  readily.

## Value

`vl_place()`: a data frame with one row per label — `name`, `index`
(which element of that grob), the original device box
`x0`/`y0`/`x1`/`y1`, the shift `dx`/`dy` in millimetres, and `resolved`
(did it end up clear). `vl_repel()`: a new scene.

## Why this is an engine service

Repulsion is a geometry problem over boxes: where things ended up, how
big they are, and what they must not touch. It carries no data
semantics, so every layer above vellum would otherwise reimplement it —
and reimplement it against numbers it can only get by rendering first.

Because the solve happens in **device pixels** and the answer is applied
as an absolute millimetre offset on top of each label's existing
coordinate, it does not care what produced the position. A label
anchored in `native` units inside a polar viewport, a facet panel, or a
warped coordinate system moves by the same mechanism as one in `npc` on
the page, and panels are all solved together rather than one at a time.

## What it does not do

It moves labels; it does not choose which to drop, shrink or abbreviate
— those are editorial decisions belonging to the layer that knows what
the labels mean. Labels that cannot be separated within `max_shift` are
reported with `resolved = FALSE` rather than silently piled up or
quietly deleted.

## See also

[`vl_empty_region()`](https://r-vellum.github.io/vellum/reference/vl_empty_region.md)
for placing one thing in the gap rather than moving many things apart.

## Examples

``` r
set.seed(1)
n <- 12
s <- vl_scene(5, 3, dpi = 96, bg = "white") |>
  draw(points_grob(runif(n), runif(n), gp = vl_gpar(fill = "steelblue", col = NA),
                   name = "pts")) |>
  draw(text_grob(paste0("item ", seq_len(n)), x = runif(n), y = runif(n),
                 gp = vl_gpar(fontsize = 9), name = "lab"))
head(vl_place(s))
#>   name index        x0        y0        x1        y1       dx       dy resolved
#> 1  lab     1 108.99509  52.26934 147.53675  66.24850 1.485252 0.000000     TRUE
#> 2  lab     2 166.06393 249.92265 204.60560 263.90182 0.000000 0.000000     TRUE
#> 3  lab     3 -12.84347  72.58166  25.69819  86.56083 0.000000 0.000000     TRUE
#> 4  lab     4 164.27539 162.56338 202.81705 176.54255 0.000000 2.834301     TRUE
#> 5  lab     5 398.18077  44.57788 436.72244  58.55705 0.000000 0.000000     TRUE
#> 6  lab     6 144.09669  94.65708 182.63835 108.63625 0.000000 0.000000     TRUE
```
