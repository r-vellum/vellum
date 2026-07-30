# Render a scene to PNG or PDF bytes

Like
[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
with a `.png` / `.pdf` path, but returns the encoded document as a raw
vector instead of writing a file. These are the in-memory entry points
for a host that needs the bytes rather than a path — embedding a base64
data URI in an HTML widget, serving a plot from a web API, or writing to
a connection — without a temp-file round-trip.

## Usage

``` r
scene_png(scene, scale = 1)

scene_pdf(scene)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method.

- scale:

  Resolution multiplier (default `1`). `scale = 2` renders at twice the
  device pixels while keeping the **same physical size** — the retina /
  `ggsave(scaling=)` idiom. It multiplies `dpi`, so absolute units
  (`mm`, `pt`, `in`) cover proportionally more pixels and nothing about
  the layout changes; text does not get relatively bigger or smaller.
  Only raster output gains anything: a PDF's page size in points and an
  SVG's physical size are unchanged by construction.

## Value

A raw vector: the encoded PNG or PDF document.

## Details

Together with
[`scene_svg()`](https://r-vellum.github.io/vellum/reference/scene_svg.md)
(a string) and
[`scene_raster()`](https://r-vellum.github.io/vellum/reference/scene_raster.md)
(pixels), every output format vellum supports can now be produced
without touching disk.

Backend degradation warnings (see
[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md))
are surfaced here too, so a PDF that could not honour a pattern or mask
reports it exactly as writing a file would.

## See also

[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
[`scene_svg()`](https://r-vellum.github.io/vellum/reference/scene_svg.md),
[`scene_raster()`](https://r-vellum.github.io/vellum/reference/scene_raster.md)

## Examples

``` r
s <- vl_scene(2, 2) |> draw(circle_grob(gp = vl_gpar(fill = "steelblue")))
png_bytes <- scene_png(s)
length(png_bytes)
#> [1] 3349
rawToChar(png_bytes[2:4]) # "PNG"
#> [1] "PNG"
```
