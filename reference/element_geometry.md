# The true geometry of a scene's addressable elements

Returns the resolved device-pixel geometry of every **keyed** element:
the two endpoints of a segment, the vertices of a line or polygon, the
centre of a round mark, the opposite corners of a rect.

## Usage

``` r
element_geometry(scene)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  (or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method).

## Value

A data frame of `key`, `kind`, `vertex` (1-based within the element),
`ring` (1-based within the element), `x` and `y`. Zero rows if the scene
has no keyed elements.

## Details

This is what a host needs to hit-test *exactly* without asking the
engine per event.
[`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
gives bounding boxes, which are right for a brush and misleading for
diagonal or thin marks; this gives the shape the box was standing in
for, once, so a browser can compute point-to-geometry distances locally
at whatever rate it likes.

## Reading the result

One row per vertex, grouped by `key`. What the vertices mean depends on
`kind`:

|  |  |  |
|----|----|----|
| `kind` | rows | meaning |
| `segment` | 2 | the endpoints |
| `line`, `polygon` | *k* | the vertices, in order; `polygon` is closed |
| `path` | *k* | all rings' vertices concatenated; `ring` separates them |
| `point` | 1 | the centre |
| `rect` | 2 | opposite corners |
| `text`, `roundrect` | 2 | the bounding box's corners |

Coordinates are device pixels with y growing **down**, matching
[`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)'s
boxes and the rendered SVG's coordinate system.

`ring` groups the vertices of a multi-ring `path` – a polygon with a
hole, or a multipart feature – so a host can hit-test it the way the
engine does. Without it the concatenated vertices are lossy: treating
them as one closed ring invents a phantom edge from each ring's last
vertex to the next ring's first. Split on `ring` and test the rings
separately. Every other kind is a single ring, so `ring` is `1`
throughout.

## See also

[`vl_nearest()`](https://r-vellum.github.io/vellum/reference/vl_nearest.md),
[`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)

## Examples

``` r
s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
  draw(segments_grob(0.1, 0.1, 0.9, 0.9, key = "diagonal"))
element_geometry(s)
#>        key    kind vertex ring     x     y
#> 1 diagonal segment      1    1  38.4 259.2
#> 2 diagonal segment      2    1 345.6  28.8
```
