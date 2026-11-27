# Editable PowerPoint output via officer

Put a scene on a PowerPoint slide as **editable shapes**: every mark is
a DrawingML freeform (or a preset rectangle or ellipse), every label a
real text box whose words can be retyped, and each panel a named group
that can be ungrouped, recoloured or moved in PowerPoint.

## Usage

``` r
as_dml(x, text = c("native", "outline"), resize = TRUE)
```

## Arguments

- x:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method.

- text:

  `"native"` (default) for editable text runs, `"outline"` for glyph
  outlines.

- resize:

  Re-solve the layout at the location's size (default `TRUE`).

## Value

`as_dml()`: a `vellum_dml` object, for
[`officer::ph_with()`](https://davidgohel.github.io/officer/reference/ph_with.html).

## Details

With the officer package installed, a scene goes straight into
[`officer::ph_with()`](https://davidgohel.github.io/officer/reference/ph_with.html);
`as_dml()` wraps anything else
[`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
can compile (a vellumplot plot, say) so it can go there too:

    doc <- officer::read_pptx()
    doc <- officer::add_slide(doc, layout = "Title and Content")
    doc <- officer::ph_with(doc, scene, location = officer::ph_location_type("body"))
    doc <- officer::ph_with(doc, as_dml(plot), location = officer::ph_location_fullsize())
    print(doc, target = "deck.pptx")

To write a deck without officer, give
[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md) a
`.pptx` path (one slide) or use
[`pptx_pages()`](https://r-vellum.github.io/vellum/reference/pptx_pages.md)
(several).

## Size

By default the scene is laid out again at the size of the location
(`resize = TRUE`), exactly as
[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
would at that size, so text keeps its point size and nothing is
stretched. `resize = FALSE` keeps the scene's own size, anchored at the
location's top-left corner.

## Text and fonts

Each label names the font vellum measured it with. PowerPoint uses that
font when the machine opening the deck has it and substitutes another
when it does not; the box is anchored so a wider substitute grows away
from the label's anchor (right-aligned tick labels stay right-aligned)
rather than drifting. Vertically, the text sits on the box's bottom edge
whatever its justification. LibreOffice assumes a fixed line, 1.0 em
above the baseline and 0.2 em below, whatever the font: on the bottom
edge a label sits where vellum draws it when the font's descent is about
0.2 em, and lower by the excess for a deeper one (Avenir Next, Hoefler
Text). Keynote follows the font's own metrics. PowerPoint itself has not
been checked. Fonts are not embedded. `text = "outline"` writes glyph
outlines instead: identical everywhere, but no longer editable as text.
An [`md()`](https://r-vellum.github.io/vellum/reference/md.md) label is
one text run per styled span (bold, italic, colour; a superscript or
subscript as a raised or lowered run).
[`tex()`](https://r-vellum.github.io/vellum/reference/tex.md) labels,
[`md()`](https://r-vellum.github.io/vellum/reference/md.md) labels with
inline math, halos and text set on a path are always outlines, as in
SVG.

## What cannot be expressed

DrawingML has no clipping, blend modes, masks or group opacity.

- Clipped geometry is cut in advance: fills to the visible area, strokes
  along their centreline (a round or square cap at a cut end reaches
  half a line width past the edge), pictures cropped. Native text cannot
  be cut: a label crossing a clip edge is drawn whole, with a warning
  (outlined text is cut exactly).

- Group opacity over shapes that do not overlap is folded into their
  colours, which is exactly what the group composites to.

- Blend modes, masks, blur and shadow effects, and group opacity over
  overlapping shapes are drawn as a picture of the region they cover,
  with a warning: the slide looks right, but that part is not editable.

- Linear and radial gradients are native gradient fills, patterns a
  tiled picture fill. A radial gradient's focal point moves to its
  centre (with a warning). Rasters become pictures.

LibreOffice is not a reliable preview for these: it drops gradients with
translucent stops and the transparency of tiled pattern pictures, and
places an off-centre radial gradient differently.

For charts whose *data* stays editable in PowerPoint, see the mschart
package; this writes the drawing, not the data.

## See also

[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
and
[`pptx_pages()`](https://r-vellum.github.io/vellum/reference/pptx_pages.md)
to write a `.pptx` without officer.

## Examples

``` r
sc <- vl_scene(6, 4, dpi = 96, bg = "white") |>
  draw(rect_grob(width = 0.5, height = 0.5, gp = vl_gpar(fill = "tomato"))) |>
  draw(text_grob("editable", gp = vl_gpar(fontsize = 24)))
doc <- officer::read_pptx()
doc <- officer::add_slide(doc, layout = "Blank", master = "Office Theme")
doc <- officer::ph_with(doc, as_dml(sc),
  location = officer::ph_location(left = 1, top = 1, width = 6, height = 4)
)
f <- tempfile(fileext = ".pptx")
print(doc, target = f)
```
