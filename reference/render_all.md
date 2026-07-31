# Render many scenes in parallel

Renders a list of independent scenes across cores. This is
embarrassingly parallel — one whole scene per worker, nothing shared —
which is why it exists while *tiling a single raster* across threads
does not: that needs synchronised access to one pixmap and is declined
in `PERFORMANCE.md`.

## Usage

``` r
render_all(scenes, paths, workers = NULL, ...)
```

## Arguments

- scenes:

  A named or unnamed list of scenes.

- paths:

  Output paths, one per scene. The format of each comes from its
  extension, exactly as in
  [`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md).
  When `scenes` is named and `paths` is a single directory, files are
  named after the list.

- workers:

  Number of parallel workers. Defaults to one per available core, capped
  at the number of scenes.

- ...:

  Passed to
  [`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  for every scene.

## Value

The paths written, invisibly.

## Details

The saving is real when the scenes are substantial and there are several
of them. For a handful of small figures the process/thread overhead
dominates and a plain `lapply(scenes, render)` is as fast; this reports
enough to tell.

## See also

[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
[`pdf_pages()`](https://r-vellum.github.io/vellum/reference/pdf_pages.md)

## Examples

``` r
scenes <- list(
  a = vl_scene(3, 2, dpi = 96) |> draw(circle_grob(gp = vl_gpar(fill = "tomato"))),
  b = vl_scene(3, 2, dpi = 96) |> draw(rect_grob(gp = vl_gpar(fill = "steelblue")))
)
render_all(scenes, file.path(tempdir(), c("a.png", "b.png")))
```
