# Aggregate-then-shade a large point cloud (datashader-style)

For data beyond the point where drawing one marker each is practical
(overplotted, millions of points), the fast and *overplotting-honest*
approach is not to draw markers faster but to **not draw markers at
all**: bin the points into a canvas-sized grid in one pass, then colour
each cell by its density. This is what makes
[datashader](https://datashader.org) fast — aggregation decouples cost
from both point count and overplotting. `datashade()` returns a single
[`raster_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
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
  category = NULL,
  colors = c("#deebf7", "#08306b"),
  how = c("eq_hist", "log", "cbrt", "linear"),
  span = NULL,
  clip = NULL,
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

- category:

  Optional per-point category (factor or vector) selecting categorical
  (`count_cat`) shading; see Details. `NULL` (default) shades by plain
  density.

- colors:

  For density shading, two or more colours forming the low-to-high ramp.
  For categorical shading (`category` set), a per-category hue vector —
  named by category level, or one colour per level in level order.

- how:

  Density-to-colour mapping: `"eq_hist"` (histogram equalisation —
  datashader's default, reveals structure across orders of magnitude),
  `"log"`, `"cbrt"` (cube root), or `"linear"`. Also drives the per-cell
  opacity under categorical shading.

- span:

  Optional `c(lo, hi)` density values mapped to the ends of the colour
  ramp / opacity range; densities outside are clamped. `NULL` (default)
  uses the full observed range.

- clip:

  Optional percentile pair in `[0, 1]` (e.g. `c(0.01, 0.99)`) deriving
  `span` from the quantiles of the non-empty cell densities — a robust
  way to keep a few extreme cells from flattening the rest. Overrides
  `span`.

- interpolate:

  Passed to
  [`raster_grob()`](https://r-vellum.github.io/vellum/reference/grob.md);
  `FALSE` keeps hard bin edges.

- name, vp, id, role:

  Passed to
  [`raster_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  (see [grob](https://r-vellum.github.io/vellum/reference/grob.md)).

## Value

A [grob](https://r-vellum.github.io/vellum/reference/grob.md) (a
raster), drawable with
[`draw()`](https://r-vellum.github.io/vellum/reference/vl_scene.md).

## Details

The points are binned over `xlim` x `ylim` into a `width` x `height`
grid, so to line the image up with data axes draw it inside a
[`vl_viewport()`](https://r-vellum.github.io/vellum/reference/vl_viewport.md)
whose `xscale` / `yscale` match `xlim` / `ylim` (it fills the viewport,
npc `0..1`). For crisp bins make `width`/`height` match the viewport's
pixel size and keep `interpolate = FALSE`.

## Categorical shading (`count_cat`)

Pass `category` (a factor or vector, one value per point) to shade by
*category* rather than plain density: each category is aggregated into
its own count grid in the same single pass, and each cell is coloured by
the **count-weighted average** of the category hues it contains, with
opacity driven by the cell's total density (via `how`). This reveals
which category dominates where *and* where categories mix, without
overplotting bias. When `category` is set, `colors` is a per-category
hue vector (named by level, or one colour per level in level order)
instead of a low-to-high ramp.

## Examples

``` r
set.seed(1)
n <- 1e6
x <- rnorm(n); y <- x * 0.5 + rnorm(n)
g <- datashade(x, y, width = 400, height = 300)
s <- vl_scene(6, 4.5) |>
  push(vl_viewport(xscale = range(x), yscale = range(y))) |>
  draw(g)

# Categorical: colour each cell by which group dominates it
grp <- sample(c("a", "b"), n, replace = TRUE)
gc <- datashade(x, y, category = grp, colors = c(a = "#e41a1c", b = "#377eb8"))
```
