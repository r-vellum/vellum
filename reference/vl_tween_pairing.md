# Check how adjacent keyframes will tween

[`vl_render_animation()`](https://r-vellum.github.io/vellum/reference/vl_render_animation.md)
matches marks across keyframes by their data keys (see *Matching marks
by identity* there). `vl_tween_pairing()` reports, before anything is
rendered, how each adjacent pair will tween – what still switches at the
midpoint and how many marks enter or leave – so a grammar layer can warn
its user.

## Usage

``` r
vl_tween_pairing(keyframes)
```

## Arguments

- keyframes:

  A list of at least two scenes, as for
  [`vl_render_animation()`](https://r-vellum.github.io/vellum/reference/vl_render_animation.md).

## Value

A data frame with one row per adjacent pair: `from`, `to` (keyframe
indices), `paired` (`FALSE` when the two keyframes do not share a
viewport tree, so the frames cut at the midpoint), `nodes_from`,
`nodes_to` (the node counts), `snapped` (the nodes that switch whole at
the midpoint: a matched line or path whose vertex count changes and
cannot be morphed, a matched pair of different kinds, or an unkeyed node
with no counterpart), and `exited`, `entered` (keyed elements with no
partner, which fade out or in). The last three are `NA` for a pair that
does not pair.

## See also

[`vl_render_animation()`](https://r-vellum.github.io/vellum/reference/vl_render_animation.md)

## Examples

``` r
a <- vl_scene(2, 2) |> draw(circle_grob(r = 0.2))
b <- a |> draw(rect_grob(width = 0.2, height = 0.2))
vl_tween_pairing(list(a, a, b))
#>   from to paired nodes_from nodes_to snapped exited entered
#> 1    1  2   TRUE          1        1       0      0       0
#> 2    2  3   TRUE          1        2       1      0       0
```
