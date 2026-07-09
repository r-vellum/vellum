# A serializable, per-element model of a scene

`scene_model()` walks a rendered scene and returns one row per drawn
element of the *keyable* marks (points, circles, rects, hexagons,
sectors, segments), pairing each element's grammar-supplied identity —
its data `key`, free-form `meta`, grob `id`/`name`, and enclosing
`panel` — with its resolved device-pixel bounding box. It is the
host-agnostic bridge underlying interactivity: a host renders the SVG
(each element tagged with `data-key`, see
[`scene_svg()`](https://schochastics.github.io/vellum/reference/scene_svg.md))
and uses this table to map an event back to the originating datum.

## Usage

``` r
scene_model(scene)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
  (or anything coercible via
  [`as_vellum_scene()`](https://schochastics.github.io/vellum/reference/as_vellum_scene.md)).

## Value

A list with two data frames:

- `elements` — one row per element: `key`, `mark`, `id`, `name`,
  `panel`, the device-px bbox `x0,y0,x1,y1`, its centre/size `x,y,w,h`,
  and a `meta` list-column.

- `panels` — one row per named panel: `name` and its elements' bounding
  box `x0,y0,x1,y1`.

## Details

Elements are returned in paint order. `key`/`meta` are `NA`/`NULL` for
marks drawn without them, so a plain scene still yields a geometry
table.

## See also

[`scene_svg()`](https://schochastics.github.io/vellum/reference/scene_svg.md)
