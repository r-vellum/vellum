# Write several scenes as the slides of one PowerPoint file

[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
with a `.pptx` path writes one slide; this writes a deck, one slide per
scene, without officer. The shapes are the same editable ones
[`as_dml()`](https://r-vellum.github.io/vellum/reference/as_dml.md) puts
on an officer slide.

## Usage

``` r
pptx_pages(scenes, path = NULL, text = c("native", "outline"), title = NULL)
```

## Arguments

- scenes:

  A list of scenes (each a
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method).

- path:

  Output file. `NULL` returns the bytes instead.

- text:

  `"native"` (default) for editable text, `"outline"` for glyph
  outlines.

- title:

  The presentation's title property. `NULL` (default) uses the first
  scene's `title`.

## Value

`path` invisibly, or a raw vector when `path` is `NULL`.

## Details

A presentation has a single slide size, so the deck takes the largest
scene's width and height (at least 1 inch, at most 56) and centres any
smaller scene on its slide. The file is byte-for-byte reproducible: it
carries no timestamps, user name or software version.

## See also

[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
for a single slide,
[`as_dml()`](https://r-vellum.github.io/vellum/reference/as_dml.md) for
officer decks.

## Examples

``` r
slides <- lapply(c("tomato", "steelblue"), function(col) {
  vl_scene(6, 4, dpi = 96, bg = "white") |>
    draw(rect_grob(width = 0.5, height = 0.5, gp = vl_gpar(fill = col))) |>
    draw(text_grob(col, gp = vl_gpar(fontsize = 24)))
})
f <- tempfile(fileext = ".pptx")
pptx_pages(slides, f)
file.size(f) > 0
#> [1] TRUE
```
