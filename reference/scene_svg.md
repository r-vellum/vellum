# Render a scene to an SVG string

Like
[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
with an `.svg` path, but returns the SVG document as a character string
instead of writing a file. This is the in-memory entry point for hosting
a scene interactively (an htmlwidget embeds the markup directly) and for
tests that assert on emitted attributes such as `data-key`.

## Usage

``` r
scene_svg(scene, text = c("native", "outline"))
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md).

- text:

  For SVG output, how text is written: `"native"` (default) emits
  selectable `<text>` referencing system fonts, `"outline"` emits glyph
  outlines (pixel-faithful, identical to the raster/PDF backends, but
  not selectable). Ignored for PNG/PDF.

## Value

A length-1 character vector: the SVG document.

## See also

[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
[`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
