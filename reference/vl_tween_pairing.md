# Check how adjacent keyframes will tween

[`vl_render_animation()`](https://r-vellum.github.io/vellum/reference/vl_render_animation.md)
tweens two keyframes node by node only when they draw the same number of
nodes over the same viewports (see *Keyframes that do not pair* there).
`vl_tween_pairing()` reports, before anything is rendered, which
adjacent pairs will tween and which will cut at the midpoint, so a
grammar layer can warn its user.

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
indices), `paired` (`TRUE` when the pair tweens node by node),
`nodes_from`, `nodes_to` (the node counts), and `snapped` – for a paired
segment, the number of nodes that still switch whole at the midpoint
because their variant, vertex count or (unkeyed) element count differs;
`NA` when the pair does not pair at all.

## See also

[`vl_render_animation()`](https://r-vellum.github.io/vellum/reference/vl_render_animation.md)

## Examples

``` r
a <- vl_scene(2, 2) |> draw(circle_grob(r = 0.2))
b <- a |> draw(rect_grob(width = 0.2, height = 0.2))
vl_tween_pairing(list(a, a, b))
#>   from to paired nodes_from nodes_to snapped
#> 1    1  2   TRUE          1        1       0
#> 2    2  3  FALSE          1        2      NA
```
