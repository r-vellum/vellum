# A serializable, per-element model of a scene

`scene_model()` walks a rendered scene and returns one row per drawn
element of the *keyable* marks, pairing each element's grammar-supplied
identity — its data `key`, free-form `meta`, grob `id`/`name`, and
enclosing `panel` — with its resolved device-pixel bounding box. It is
the host-agnostic bridge underlying interactivity: a host renders the
SVG (each element tagged with `data-key`, see
[`scene_svg()`](https://r-vellum.github.io/vellum/reference/scene_svg.md))
and uses this table to map an event back to the originating datum.

## Usage

``` r
scene_model(scene, meta = c("records", "columns"))
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  (or anything coercible via
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)).

- meta:

  The form of the elements' `meta` column. `"records"` (the default) is
  a list-column with one record per element. `"columns"` is a data-frame
  column instead, with one row per element and one column per field. In
  it a field is a plain vector when every element that carries it holds
  one atomic value of one type (`NA` for the elements without it), and a
  list-column (`NULL` where absent) otherwise. The columnar form skips
  the per-element records, so a host reading many elements should ask
  for it.

## Value

A list with two data frames:

- `elements` — one row per element: `key`, `mark`, `id`, `name`,
  `panel`, the device-px bbox `x0,y0,x1,y1`, its centre/size `x,y,w,h`,
  and a `meta` column (see the `meta` argument).

- `panels` — one row per named panel that encloses at least one element,
  plus any named viewport carrying `meta` (a declared data panel, whose
  element bbox is `NA` when it holds no element): `name`, its elements'
  bounding box `x0,y0,x1,y1`, the panel viewport's device-px rectangle
  `px0,py0,px1,py1`, its native ranges
  `xscale_lo,xscale_hi,yscale_lo,yscale_hi`, and a `meta` list-column.

## Details

Elements are returned in paint order. Batched marks (points, circles,
rects, hexagons, sectors, segments) always emit one row per element,
with `key`/`meta` `NA`/`NULL` when drawn without them, so a plain scene
still yields a geometry table. Round rects and text emit a row only for
keyed elements, and paths, lines and polygons one row per grob only when
keyed.
[`vignette("scene-contract")`](https://r-vellum.github.io/vellum/articles/scene-contract.md)
is the full contract.

## See also

[`scene_svg()`](https://r-vellum.github.io/vellum/reference/scene_svg.md)
