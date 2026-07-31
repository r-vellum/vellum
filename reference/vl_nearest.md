# Find the marks nearest a point, by true geometry

Ranks a scene's keyed elements by their distance to a point — measuring
to the **actual geometry**, not to a bounding box.

## Usage

``` r
vl_nearest(scene, x, y, units = c("npc", "px"), n = 1L, max_dist = Inf)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  (or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method).

- x, y:

  The probe point.

- units:

  `"npc"` (default, y up) or `"px"` (device pixels, y down) — the same
  convention as
  [`hit_test()`](https://r-vellum.github.io/vellum/reference/hit_test.md).

- n:

  How many nearest elements to return.

- max_dist:

  Ignore anything further than this many device pixels.

## Value

A data frame of `key`, `kind` and `dist` (device px), nearest first.
Zero rows if nothing is in range. Only *keyed* elements are considered —
an unkeyed mark is not addressable, so reporting it would be no use.

## Why not the bounding box

For a round or upright mark the two agree. For anything diagonal or thin
they do not, and the difference is not subtle: a line from the
bottom-left of a panel to the top-right has a bounding box covering the
*entire panel*, so a box-based "what is nearest" reports it from
anywhere in the plot. That is why a host holding only boxes has to
exclude such marks from hover rather than rank them wrongly.

Distances are: to the disc for round marks (zero inside), to the
rectangle for rects (zero inside), perpendicular to the segment for
segments, to the nearest edge for open polylines, and **zero anywhere
inside** a closed polygon or path — so clicking the middle of a
choropleth region hits that region.

Marks vellum cannot describe more precisely than a box — labels, rounded
rects — fall back to their box, which for a label is a fair description
of the target anyway.

## For a client-side host

A browser cannot call back into R on every mouse move. Use
[`element_geometry()`](https://r-vellum.github.io/vellum/reference/element_geometry.md)
instead: it returns the same true geometry once, and the client computes
distances locally. `vl_nearest()` is for hosts that *can* ask — a Shiny
app, a test, a script.

## See also

[`element_geometry()`](https://r-vellum.github.io/vellum/reference/element_geometry.md)
for the geometry itself,
[`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
for bounding boxes,
[`hit_test()`](https://r-vellum.github.io/vellum/reference/hit_test.md)
for "which grob is under this pixel".

## Examples

``` r
s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
  draw(segments_grob(0.1, 0.1, 0.9, 0.9, key = "diagonal")) |>
  draw(points_grob(0.8, 0.2, key = "corner"))

# Near the corner the diagonal's *bounding box* also contains this point,
# but its geometry is far away.
vl_nearest(s, 0.8, 0.2)
#>      key  kind dist
#> 2 corner point    0
```
