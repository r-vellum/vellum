# Render a scene to an SVG string

Like
[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
with an `.svg` path, but returns the SVG document as a character string
instead of writing a file. This is the in-memory entry point for hosting
a scene interactively (an htmlwidget embeds the markup directly) and for
tests that assert on emitted attributes such as `data-key`.

## Usage

``` r
scene_svg(
  scene,
  text = c("native", "outline"),
  layer = c("all", "unkeyed", "keyed"),
  panels = NULL
)
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

- layer:

  Which part of the scene to draw: `"all"` (the default), only the
  `"keyed"` marks, or everything `"unkeyed"`. See the *Split render*
  section.

- panels:

  `NULL` (the default: every keyed mark is in the mark layer), or a
  character vector of panel names restricting the mark layer to keyed
  marks inside those panels. Ignored when `layer = "all"`.

## Value

A length-1 character vector: the SVG document.

## Split render

`layer` renders part of the scene on the same page, with the same
transforms and clips, so the parts overlay pixel-exactly. `"keyed"`
draws only the marks that carry an interactivity key (`data_id`/`key`:
the elements with a non-`NA` `key` in
[`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md))
on a transparent page; `"unkeyed"` draws everything else (background,
gridlines, axes, legends, unkeyed annotations). Groups, clips and masks
around a mark stay with it. A batch of elements counts as keyed when any
element carries a key.

`panels` narrows the mark layer to keyed marks whose innermost named
panel (the `panel` column of `scene_model()$elements`) is listed, so
keyed marks elsewhere (e.g. a vellumplot legend's interactive swatches,
in panel `"legend"`) stay with the furniture. The two layers remain
exact complements.

Compositing the `"keyed"` layer over the `"unkeyed"` one reproduces the
full render, except where an unkeyed node is painted *above* a keyed
mark (it ends up underneath), or where a keyed mark's blend mode would
mix with the unkeyed backdrop (it blends against transparency instead).
This is the raster mode of vellumwidget: SVG furniture plus a PNG of the
heavy mark layer.

## See also

[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
[`scene_png()`](https://r-vellum.github.io/vellum/reference/scene_png.md),
[`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
