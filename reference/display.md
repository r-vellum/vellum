# Display a scene in the active graphics device

`display()` re-renders `scene` to fill the current graphics device and
draws it there. Interactively this is the RStudio / Positron **Plots**
pane; inside a knitr / Quarto chunk it becomes the chunk's figure (it
draws to the chunk's device). This is the seam any package built on
vellum can call to *show* output instead of writing a file: `scene` is
coerced via
[`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md),
so it also accepts e.g. a grammar's plot spec.

## Usage

``` r
display(scene, ...)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method.

- ...:

  Unused.

## Value

The (coerced) scene, invisibly.

## Details

To fill the window (no letterbox margins, like ggplot2) the scene is
re-rendered at the device's size and pixel density, so its relative
(`npc`/`native`/layout) content reflows to the window and absolute
(`mm`/`in`/`pt`) content keeps its physical size. It draws through a
grid grob that re-rasterizes on every draw, so **resizing the Plots pane
re-renders the scene crisply** at the new size (round markers stay
round) rather than stretching one bitmap. Use
[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md) to
write the scene at its *authored* width/height. Auto-printing a scene at
the console (or calling
[`plot()`](https://rdrr.io/r/graphics/plot.default.html) on it) displays
it.

Inside a knitr / Quarto chunk the chunk's `dpi` option wins, so
`knitr::opts_chunk$set(dpi = 200)` yields a genuine 200-dpi figure even
on knitr's default `dev = "png"` device (which misreports its pixel
density); outside knitting the scene's authored
[`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
`dpi` is honored unless the live device reports a trustworthy higher
density (e.g. a resized Plots pane).

## Examples

``` r
if (FALSE) { # \dontrun{
vl_scene(4, 3) |>
  draw(circle_grob(r = 0.3, gp = gpar(fill = "tomato", col = NA))) |>
  display()
} # }
```
