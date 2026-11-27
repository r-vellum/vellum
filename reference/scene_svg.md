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
  layer = c("all", "unkeyed", "keyed", "unkeyed_below", "unkeyed_above", "keyed_flagged"),
  panels = NULL,
  run = NULL
)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md).

- text:

  For SVG and PowerPoint output, how text is written: `"native"`
  (default) emits selectable, editable text referencing system fonts,
  `"outline"` emits glyph outlines (pixel-faithful, identical to the
  raster/PDF backends, but not selectable). Ignored for PNG/PDF.

- layer:

  Which part of the scene to draw: `"all"` (the default), only the
  `"keyed"` marks, everything `"unkeyed"`, the unkeyed elements painted
  before (`"unkeyed_below"`) or after (`"unkeyed_above"`) the marks, or
  only the keyed marks the display list flags (`"keyed_flagged"`). See
  the *Split render* section.

- panels:

  `NULL` (the default: every keyed mark is in the mark layer), or a
  character vector of panel names restricting the mark layer to keyed
  marks inside those panels. Ignored when `layer = "all"`.

- run:

  For `layer = "keyed_flagged"`: `NULL` (the default) for every flagged
  mark, or a positive integer, the one run of flagged marks to draw (see
  the *Split render* section). Ignored for the other layers.

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

`"unkeyed_below"` and `"unkeyed_above"` split `"unkeyed"` by paint
order, so stacking `"unkeyed_below"`, `"keyed"`, `"unkeyed_above"`
(bottom to top) also gets an annotation or reference line drawn after
the marks right. An unkeyed element is *above* when a mark (an element
of the `"keyed"` layer, so `panels` applies) was painted before it
inside its innermost named panel; a mark in a nested panel counts for
every panel around it, and an element outside every named panel is above
when any mark precedes it. Unkeyed elements interleaved between two
keyed batches are therefore above, and a later facet's gridlines stay
below that facet's own marks. With no marks at all, everything is below.
`"unkeyed_above"`, like `"keyed"`, has a transparent page. The two
halves together are exactly `"unkeyed"`.

`"keyed_flagged"` draws only the marks of the `"keyed"` layer that
[`scene_display_list()`](https://r-vellum.github.io/vellum/reference/scene_display_list.md)
(`version = 2`, same `panels`) flags as not drawable from the list:
marks under a mask, a blend mode or an effect, patterned or
repeating-gradient fills, gradient strokes and text. A hatched fill, on
a point marker too, is listed as exact geometry, so it is not drawn here
unless something else flags it (see
[`scene_display_list()`](https://r-vellum.github.io/vellum/reference/scene_display_list.md)).
Whole nodes are drawn (every record of a node with one flagged record),
and an opacity group holding a flagged mark goes in whole. The flagged
marks fall into *runs*: maximal stretches in paint order not interrupted
by a mark the list draws exactly, numbered from 1 in the list's
`record$run` (its `runs` field counts them). `run = k` draws only run
`k`; `NULL` draws every run. A host that draws the exact marks itself
can composite run `k` at its place in paint order and keep the overlap
order right. The page is transparent. A mark under a blend mode
(display-list flag `32`) is drawn too, but blends against transparency
here rather than against the marks beneath it.

## See also

[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
[`scene_png()`](https://r-vellum.github.io/vellum/reference/scene_png.md),
[`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
