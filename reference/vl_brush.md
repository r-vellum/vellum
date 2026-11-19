# Select the marks in a rectangle or a lasso, by true geometry

`vl_brush()` returns the keyed elements of a scene that meet an
axis-aligned rectangle; `vl_lasso()` those that meet a free-form
polygon. Both test the elements' **actual geometry** – the same recorded
shapes
[`vl_nearest()`](https://r-vellum.github.io/vellum/reference/vl_nearest.md)
measures – so a diagonal segment is selected only if the line itself
enters the region, not because its bounding box does. They are meant for
server-side brushing and lasso selection (a Shiny app receiving a brush
or lasso from the client) and share one cached spatial index with
[`vl_nearest()`](https://r-vellum.github.io/vellum/reference/vl_nearest.md).

## Usage

``` r
vl_brush(
  scene,
  xmin,
  xmax,
  ymin,
  ymax,
  units = c("npc", "px"),
  mode = c("intersect", "contain", "centre")
)

vl_lasso(
  scene,
  x,
  y,
  units = c("npc", "px"),
  mode = c("intersect", "contain", "centre")
)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  (or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method).

- xmin, xmax, ymin, ymax:

  The rectangle's edges, in `units`. Their order does not matter.

- units:

  `"npc"` (default, y up) or `"px"` (device pixels, y down) — the same
  convention as
  [`hit_test()`](https://r-vellum.github.io/vellum/reference/hit_test.md).

- mode:

  `"intersect"` (default), `"contain"` or `"centre"`; see below.

- x, y:

  For `vl_lasso()`, the polygon's vertices, in `units` (at least three;
  the last joins the first).

## Value

A data frame of `key` and `kind`, one row per selected element, in paint
order. A datum drawn as several elements (an error bar's segments)
contributes several rows; use `unique(res$key)` for the selected keys.
Only keyed elements are considered.

## Which elements are selected

`mode` decides how an element must meet the region:

- `"intersect"` (default): any part of the element touches the region –
  a point whose disc overlaps it, a line that passes through it, a
  polygon that overlaps it (including a region wholly inside the
  polygon). A polygon with a hole does not meet a region that lies
  entirely in the hole.

- `"contain"`: all of the element lies inside the region – the whole
  disc of a point, every vertex of a line or polygon (and, for a lasso,
  no edge leaving it).

- `"centre"`: the centre of the element's bounding box lies inside the
  region. This is the rule vellumwidget's client-side lasso uses, so a
  server can reproduce a client selection exactly.

Lines and segments are tested along their centre-line, as in
[`vl_nearest()`](https://r-vellum.github.io/vellum/reference/vl_nearest.md);
the stroke width is not added. Elements with nothing drawn (an `NA`
position) are never selected. The lasso polygon is closed implicitly and
filled with the even-odd rule, so a self-crossing lasso selects what a
client's ray-casting test would.

## Performance

The first query on a scene builds a uniform grid over its keyed
elements; every later
[`vl_nearest()`](https://r-vellum.github.io/vellum/reference/vl_nearest.md),
`vl_brush()` or `vl_lasso()` on the same scene visits only the cells the
query touches. The index lives with the compiled scene, so an edited
scene (a new object) gets a fresh one.

## See also

[`vl_nearest()`](https://r-vellum.github.io/vellum/reference/vl_nearest.md)
for the nearest marks to a point,
[`element_geometry()`](https://r-vellum.github.io/vellum/reference/element_geometry.md)
for the geometry itself.

## Examples

``` r
s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
  draw(segments_grob(0.1, 0.1, 0.9, 0.9, key = "diagonal")) |>
  draw(points_grob(c(0.2, 0.8), c(0.8, 0.2), key = c("tl", "br")))

# The diagonal's bounding box covers this corner, but the line does not.
vl_brush(s, 0.7, 0.9, 0.1, 0.3)
#>   key  kind
#> 1  br point
vl_brush(s, 0.4, 0.6, 0.4, 0.6)
#>        key    kind
#> 1 diagonal segment

# A triangle around the top-left point
vl_lasso(s, c(0.05, 0.4, 0.05), c(0.6, 0.95, 0.95))
#>   key  kind
#> 1  tl point
```
