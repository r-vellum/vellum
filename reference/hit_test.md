# Hit-test a scene

Find the topmost node drawn under a point. The geometry is recorded by
the same walk that renders the scene, so offsets, caps and rotation are
where they are drawn; grobs are tested in reverse paint order against
that geometry and their viewport's clip, so the result is clip- and
overlap-exact. A filled shape is matched by its fill rule, a marker by
its disc, text by its (rotated) box, and lines and segments by a band of
half their stroke width (at least 2 px). grid ships no equivalent:
`grid.locator()` waits for one interactive click and returns coordinates
rather than a node.

## Usage

``` r
hit_test(scene, x, y, units = c("npc", "px"))
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  (or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method).

- x, y:

  Query point, in `units`: `"npc"` (default; the page, `0..1` with y up)
  or `"px"` (device pixels, top-left origin, y down).

- units:

  `"npc"` or `"px"`.

## Value

The hit node's `name` (character); `NA_character_` if the topmost grob
there is unnamed; or `NULL` if nothing is drawn at the point.
