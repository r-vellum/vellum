# Build and render a scene

`vl_scene()` creates an empty scene. `push()` adds a viewport (and
descends into it), `draw()` adds a grob, `pop()` ascends. The builder is
a linear pipe; a *rendered or edited* scene is an immutable value
([`edit_node()`](https://schochastics.github.io/vellum/reference/node_names.md)
copies on modify). `render()` compiles the scene and writes the output.

## Usage

``` r
vl_scene(
  width = 6,
  height = 4,
  dpi = 96,
  bg = "white",
  gp = gpar(),
  xscale = c(0, 1),
  yscale = c(0, 1),
  clip = FALSE,
  title = NULL,
  desc = NULL
)

push(scene, vp)

draw(scene, grob)

pop(scene, n = 1)

render(scene, path, text = c("native", "outline"), debug = FALSE)
```

## Arguments

- width, height:

  Page size
  ([`unit()`](https://schochastics.github.io/vellum/reference/unit.md)
  or numeric inches).

- dpi:

  Resolution in dots per inch.

- bg:

  Background colour (or `NA` for transparent).

- gp:

  Page-level graphical parameters
  ([`gpar()`](https://schochastics.github.io/vellum/reference/gpar.md))
  carried by the root viewport; inherited by everything drawn (e.g. a
  default `col`/`fontsize`).

- xscale, yscale:

  Native coordinate range of the root viewport, so `"native"` units work
  at the page level without an explicit `push()`.

- clip:

  Clip drawing to the page rectangle?

- title, desc:

  Accessibility: an accessible **name** (a short title) and a longer
  **description** (alt text) for the scene. When either is set, the SVG
  backend emits `role="img"` + `<title>`/`<desc>` (referenced by
  `aria-labelledby`) and the PDF backend tags the page as a Figure with
  the description as Alt text. `NULL` (default) emits no accessibility
  markup, so output is unchanged. See
  [`describe()`](https://schochastics.github.io/vellum/reference/describe.md)
  to set them on an existing scene.

- scene:

  A `vl_scene()`.

- vp:

  A
  [`viewport()`](https://schochastics.github.io/vellum/reference/viewport.md).

- grob:

  A grob (see
  [grob](https://schochastics.github.io/vellum/reference/grob.md)).

- n:

  Number of viewport levels to ascend.

- path:

  Output file path; the format is taken from the extension (`.png`,
  `.svg`, or `.pdf`).

- text:

  For SVG output, how text is written: `"native"` (default) emits
  selectable `<text>` referencing system fonts, `"outline"` emits glyph
  outlines (pixel-faithful, identical to the raster/PDF backends, but
  not selectable). Ignored for PNG/PDF.

- debug:

  If `TRUE`, overlay a layout-debug skeleton on the output: each
  viewport region (outlined and labelled by name), its layout track
  boundaries, and its clip region. Built from the resolved scene with
  [`why_size()`](https://schochastics.github.io/vellum/reference/why_size.md);
  useful for understanding why elements land where they do. Default
  `FALSE`.

## Value

`vl_scene()`, `push()`, `draw()`, `pop()`: a `vellum_scene`.

`render()`: `path`, invisibly.

## Examples

``` r
s <- vl_scene(width = 4, height = 3) |>
  push(viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
  draw(rect_grob(gp = gpar(fill = "grey95", col = "grey50"))) |>
  draw(lines_grob(x = unit(0:10, "native"), y = unit(0:10, "native"),
                  gp = gpar(col = "steelblue", lwd = 2)))
```
