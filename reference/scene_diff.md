# What changed between two scenes

Compares two scenes structurally and reports the differences in terms of
the scene — "the node `axis-x` moved", "3 marks changed fill" — rather
than as a pixel diff.

## Usage

``` r
scene_diff(a, b, max_depth = 40L)
```

## Arguments

- a, b:

  Two scenes
  ([`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method).

- max_depth:

  Stop descending after this many levels (guards a runaway report on
  deeply nested trees).

## Value

A data frame with columns `path` (where in the tree), `change`
(`"added"`, `"removed"`, or `"changed"`), and `detail`. Empty when the
two scenes are equivalent. Printing shows a readable summary.

## Details

This is a better basis for visual-regression testing than comparing
rendered images, for one specific reason: an image diff is sensitive to
the font stack, so the same code compared across two machines produces
differences that swamp the real change. A structural diff compares what
was *asked for*, and is unaffected.

## See also

[`scene_hash()`](https://r-vellum.github.io/vellum/reference/scene_hash.md)
for a yes/no answer,
[`as_scene_spec()`](https://r-vellum.github.io/vellum/reference/as_scene_spec.md).

## Examples

``` r
a <- vl_scene(3, 2) |> draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "red")))
b <- vl_scene(3, 2) |> draw(circle_grob(r = 0.4, gp = vl_gpar(fill = "blue")))
scene_diff(a, b)
#> 2 differences:
#> • ~ root$children[1]$gp$fill: red -> blue
#> • ~ root$children[1]$r: 0.3npc -> 0.4npc
```
