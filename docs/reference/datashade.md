# Aggregate-then-shade a large point cloud (datashader-style)

For data beyond the point where drawing one marker each is practical
(overplotted, millions of points), the fast and *overplotting-honest*
approach is not to draw markers faster but to **not draw markers at
all**: bin the points into a canvas-sized grid in one pass, then colour
each cell by its density. This is what makes
[datashader](https://datashader.org) fast — aggregation decouples cost
from both point count and overplotting. `datashade()` returns a single
[`raster_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
you draw like any other grob.

## Usage

``` r
datashade(
  x,
  y,
  weight = NULL,
  width = 600L,
  height = 400L,
  xlim = NULL,
  ylim = NULL,
  colors = c("#deebf7", "#08306b"),
  how = c("eq_hist", "log", "cbrt", "linear"),
  interpolate = FALSE,
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
)
```

## Arguments

- x, y:

  Point coordinates (plain numerics, in data space).

- weight:

  Optional per-point weight; cells accumulate the summed weight instead
  of a plain count. `NULL` counts. A scalar is recycled to every point;
  otherwise `weight` must be the same length as `x`.

- width, height:

  Aggregation grid size in cells (= output raster pixels).

- xlim, ylim:

  Data range to bin over; default the finite range of `x`/`y`.

- colors:

  Two or more colours forming the low-to-high density ramp.

- how:

  Density-to-colour mapping: `"eq_hist"` (histogram equalisation —
  datashader's default, reveals structure across orders of magnitude),
  `"log"`, `"cbrt"` (cube root), or `"linear"`.

- interpolate:

  Passed to
  [`raster_grob()`](https://schochastics.github.io/vellum/reference/grob.md);
  `FALSE` keeps hard bin edges.

- name, vp, id, role:

  Passed to
  [`raster_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  (see [grob](https://schochastics.github.io/vellum/reference/grob.md)).

## Value

A [grob](https://schochastics.github.io/vellum/reference/grob.md) (a
raster), drawable with
[`draw()`](https://schochastics.github.io/vellum/reference/vl_scene.md).

## Details

The points are binned over `xlim` x `ylim` into a `width` x `height`
grid, so to line the image up with data axes draw it inside a
[`viewport()`](https://schochastics.github.io/vellum/reference/viewport.md)
whose `xscale` / `yscale` match `xlim` / `ylim` (it fills the viewport,
npc `0..1`). For crisp bins make `width`/`height` match the viewport's
pixel size and keep `interpolate = FALSE`.

## Examples

``` r
set.seed(1)
n <- 1e6
x <- rnorm(n); y <- x * 0.5 + rnorm(n)
g <- datashade(x, y, width = 400, height = 300)
s <- vl_scene(6, 4.5) |>
  push(viewport(xscale = range(x), yscale = range(y))) |>
  draw(g)
```
