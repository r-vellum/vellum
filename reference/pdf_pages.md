# Write several scenes as the pages of one PDF

[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
writes one page. This writes a document: a report's worth of figures,
one facet per page, an animation as a contact sheet.

## Usage

``` r
pdf_pages(scenes, path = NULL)
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

## Value

`path` invisibly, or a raw vector when `path` is `NULL`.

## Details

Pages may differ in size — each carries its own page box — so a
landscape figure can sit between two portrait ones.

Tagging follows each page's own metadata, exactly as it does for a
single-page render (see
[`vignette("accessible-output")`](https://r-vellum.github.io/vellum/articles/accessible-output.md)):
the pages are drawn by the same code, so a document cannot drift from a
single-page file.

## See also

[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
for a single page.

## Examples

``` r
pages <- lapply(c("tomato", "steelblue", "seagreen"), function(col) {
  vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(circle_grob(r = 0.3, gp = vl_gpar(fill = col)))
})
f <- tempfile(fileext = ".pdf")
pdf_pages(pages, f)
file.size(f) > 0
#> [1] TRUE
```
