# Hit-test a scene

Find the topmost node drawn under a point. The scene is compiled into a
colour pick-buffer (each grob drawn in a colour encoding its id,
respecting clipping and paint order) using the same code path that
renders it, so the result is geometry-, clip- and overlap-exact by
construction. Markers and text are matched by their bounding box; lines
and segments by a small pick band. grid ships no equivalent:
`grid.locator()` waits for one interactive click and returns coordinates
rather than a node.

## Usage

``` r
hit_test(scene, x, y, units = c("npc", "px"))
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md).

- x, y:

  Query point, in `units`: `"npc"` (default; the page, `0..1` with y up)
  or `"px"` (device pixels, top-left origin, y down).

- units:

  `"npc"` or `"px"`.

## Value

The hit node's `name` (character); `NA_character_` if the topmost grob
there is unnamed; or `NULL` if nothing is drawn at the point.
