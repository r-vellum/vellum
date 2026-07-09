# Hit-test a scene

Find the topmost node drawn under a point — the picking primitive the
retained scene graph enables (base grid offers only `grid.locator()`).
The scene is compiled into a colour pick-buffer (each grob drawn in a
colour encoding its id, respecting clipping and paint order), so the
result is geometry-, clip- and overlap-exact. Markers and text are
matched by their bounding box; lines and segments by a small pick band.

## Usage

``` r
hit_test(scene, x, y, units = c("npc", "px"))
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://schochastics.github.io/vellum/reference/vl_scene.md).

- x, y:

  Query point, in `units`: `"npc"` (default; the page, `0..1` with y up)
  or `"px"` (device pixels, top-left origin, y down).

- units:

  `"npc"` or `"px"`.

## Value

The hit node's `name` (character); `NA_character_` if the topmost grob
there is unnamed; or `NULL` if nothing is drawn at the point.
