# Contour lines from a grid

Marching squares over a matrix, chained into polylines. Use it for
density isolines over a
[`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)
surface, level curves of a fitted model, or any other gridded field.

## Usage

``` r
vl_contour(z, levels = NULL, xlim = c(0, 1), ylim = c(0, 1))

contour_grob(
  contours,
  close = TRUE,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  role = NULL
)
```

## Arguments

- z:

  A numeric matrix. Rows are y, columns are x — the
  [`image()`](https://rdrr.io/r/graphics/image.html) convention.

- levels:

  Contour levels. Defaults to 5 levels spanning the finite range of `z`,
  excluding the extremes (a contour at the minimum or maximum is either
  empty or the whole boundary).

- xlim, ylim:

  The coordinate range the grid spans. Cell *centres* are placed at the
  ends of these ranges, matching
  [`image()`](https://rdrr.io/r/graphics/image.html).

- contours:

  The data frame returned by `vl_contour()`.

- close:

  Draw closed contours as closed rings. `TRUE` (the default) joins the
  last point back to the first for contours `vl_contour()` marked
  `closed`; open contours are never closed.

- gp, name, vp, role:

  Passed to each
  [`lines_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  the contours become.

## Value

A data frame with one row per point: `level`, `id` (a distinct contour
line), `x`, `y`, and `closed`. Draw it with `lines_grob(x, y, id = id)`.

## Details

Segments are chained into continuous lines rather than returned loose.
That matters beyond tidiness: an unchained contour restarts its dash
pattern in every grid cell, cannot be simplified or measured, and cannot
be filled. Closed rings come back closed.

Cells with a non-finite corner are skipped, so a contour **breaks**
around missing data rather than being drawn through it.

## Examples

``` r
# A ring contour around a Gaussian bump.
g <- outer(seq(-3, 3, length.out = 60), seq(-3, 3, length.out = 60),
           function(a, b) exp(-(a^2 + b^2) / 2))
head(vl_contour(g, levels = c(0.2, 0.5, 0.8)))
#>   level id         x         y closed
#> 1   0.2  1 0.4745763 0.2019822   TRUE
#> 2   0.2  1 0.4628971 0.2033898   TRUE
#> 3   0.2  1 0.4576271 0.2039628   TRUE
#> 4   0.2  1 0.4406780 0.2067596   TRUE
#> 5   0.2  1 0.4237288 0.2106261   TRUE
#> 6   0.2  1 0.4067797 0.2156898   TRUE
# Draw them: one grob per contour, because each is its own polyline.
g <- outer(seq(-3, 3, length.out = 60), seq(-3, 3, length.out = 60),
           function(a, b) exp(-(a^2 + b^2) / 2))
vl_scene(3, 3, dpi = 96, bg = "white") |>
  push(vl_viewport(xscale = c(-3, 3), yscale = c(-3, 3))) |>
  draw(contour_grob(vl_contour(g, levels = c(0.2, 0.5, 0.8)),
                    gp = vl_gpar(col = "steelblue"))) |>
  pop() |>
  (\(s) s)()
```
