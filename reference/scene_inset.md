# Inset one scene inside another

Places a whole scene inside a region of another one. Because a scene is
a retained tree with a known resolved size, this is a graft rather than
a re-render: the guest's grobs are spliced under a viewport of the host,
and the result is an ordinary scene you can keep building on, edit by
name, or inset again.

## Usage

``` r
scene_inset(
  host,
  guest,
  x = 0.5,
  y = 0.5,
  width = 0.3,
  height = 0.3,
  name = NULL,
  ...
)
```

## Arguments

- host:

  The scene to place into.

- guest:

  The scene to place. Its page size, background and dpi are *not*
  carried over — it becomes a region of the host, which owns those.

- x, y, width, height:

  The region, in the host's current coordinates.

- name:

  Optional name for the region's viewport, so the inset can later be
  found with
  [`node_names()`](https://r-vellum.github.io/vellum/reference/node_names.md)
  and edited with
  [`edit_node()`](https://r-vellum.github.io/vellum/reference/node_names.md).

- ...:

  Further arguments to
  [`vl_viewport()`](https://r-vellum.github.io/vellum/reference/vl_viewport.md)
  (`clip`, `angle`, `gp`, `mask`, `blur`, `shadow`, ...).

## Value

A `vellum_scene`.

## Details

This is the mechanism a composition layer needs — inset maps, small
multiples assembled from independently-built plots, a legend built
separately and dropped into a corner. The *policy* (should panel edges
align across composed plots? should axes be shared?) belongs above
vellum, in a grammar; what the engine provides is the ability to nest
one scene in another at all.

The guest's `npc` coordinates become relative to the region it is placed
in, so a guest built on a square page and inset into a wide region will
stretch. Match the aspect ratio, or build the guest at the aspect you
want.

## See also

[`vl_viewport()`](https://r-vellum.github.io/vellum/reference/vl_viewport.md),
[`as_scene_spec()`](https://r-vellum.github.io/vellum/reference/as_scene_spec.md)

## Examples

``` r
main <- vl_scene(4, 3) |>
  draw(rect_grob(gp = vl_gpar(fill = "#eef2f6", col = NA)))
mini <- vl_scene(1, 1) |>
  draw(circle_grob(r = 0.4, gp = vl_gpar(fill = "tomato", col = NA)))
scene_inset(main, mini, x = 0.8, y = 0.75, width = 0.3, height = 0.35)
```
