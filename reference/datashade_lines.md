# Aggregate-then-shade dense lines and segments (datashader-style)

The line/segment analogue of
[`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md).
Past a few hundred thousand line vertices — a dense stack of timeseries,
or the edges of a large graph — drawing each line as a vector primitive
overplots into a solid mass and balloons the output. `datashade_lines()`
and `datashade_segments()` instead **rasterise** the lines into a
canvas-sized grid in one pass: each cell accumulates the (anti-aliased)
coverage of the lines crossing it, so overlapping lines *add* and the
grid records true line density. The grid is shaded exactly like
[`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)
(`colors`/`how`/`span`/`clip`) and returned as a single
[`raster_grob()`](https://r-vellum.github.io/vellum/reference/grob.md).

## Usage

``` r
datashade_lines(
  x,
  y,
  group = NULL,
  weight = NULL,
  width = 600L,
  height = 400L,
  xlim = NULL,
  ylim = NULL,
  colors = c("#deebf7", "#08306b"),
  how = c("eq_hist", "log", "cbrt", "linear"),
  span = NULL,
  clip = NULL,
  spread = NULL,
  interpolate = FALSE,
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
)

datashade_segments(
  x0,
  y0,
  x1,
  y1,
  weight = NULL,
  width = 600L,
  height = 400L,
  xlim = NULL,
  ylim = NULL,
  colors = c("#deebf7", "#08306b"),
  how = c("eq_hist", "log", "cbrt", "linear"),
  span = NULL,
  clip = NULL,
  spread = NULL,
  interpolate = FALSE,
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
)
```

## Arguments

- x, y:

  For `datashade_lines()`, the polyline vertices (data space); a segment
  joins each consecutive pair.

- group:

  For `datashade_lines()`, an optional per-vertex series id (factor or
  vector) the same length as `x`. The line breaks between vertices whose
  group differs, so multiple series pack into one call. `NULL` treats
  all vertices as one series (still broken by `NA` coordinates).

- weight:

  Optional per-line weight (per start-vertex for `datashade_lines()`,
  per segment for `datashade_segments()`): cells accumulate summed
  weight instead of plain coverage. `NULL` weighs each line 1; a scalar
  is recycled; otherwise it must match the line/segment count.

- width, height:

  Aggregation grid size in cells (= output raster pixels).

- xlim, ylim:

  Data range to bin over; default the finite range of `x`/`y`.

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

- spread:

  Optional post-aggregation spreading, applied to the shaded raster to
  keep sparse output visible (see
  [`spread()`](https://r-vellum.github.io/vellum/reference/spread.md) /
  [`dynspread()`](https://r-vellum.github.io/vellum/reference/dynspread.md)):
  `NULL` (default) none; a positive integer applies
  [`spread()`](https://r-vellum.github.io/vellum/reference/spread.md)
  with that pixel radius; `"auto"` applies
  [`dynspread()`](https://r-vellum.github.io/vellum/reference/dynspread.md)
  (radius chosen from the image density).

- interpolate:

  Passed to
  [`raster_grob()`](https://r-vellum.github.io/vellum/reference/grob.md);
  `FALSE` keeps hard bin edges.

- name, vp, id, role:

  Passed to
  [`raster_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  (see [grob](https://r-vellum.github.io/vellum/reference/grob.md)).

- x0, y0, x1, y1:

  For `datashade_segments()`, the segment endpoints (data space), one
  per segment; all four the same length.

## Value

A [grob](https://r-vellum.github.io/vellum/reference/grob.md) (a
raster), drawable with
[`draw()`](https://r-vellum.github.io/vellum/reference/vl_scene.md).

## Details

- `datashade_lines()` takes a **connected polyline**: a segment is drawn
  between each consecutive `(x, y)`. Pass `group` to pack several series
  into one call — the line breaks wherever the group changes; an `NA` in
  `x`/`y` also breaks it. This is the dense-timeseries path.

- `datashade_segments()` takes **independent segments**
  `(x0, y0) -> (x1, y1)`, one per element. This is the network-edge /
  `mark_segment` path.

Line coverage is anti-aliased (a Wu accumulator) and summed, so a line
deposits roughly `weight` per cell it spans and dense bundles brighten
honestly rather than saturating. As with
[`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md),
align the raster to data axes by drawing it in a
[`vl_viewport()`](https://r-vellum.github.io/vellum/reference/vl_viewport.md)
whose `xscale`/`yscale` match `xlim`/`ylim`.

## See also

[`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)
for points;
[`dynspread()`](https://r-vellum.github.io/vellum/reference/dynspread.md)/[`spread()`](https://r-vellum.github.io/vellum/reference/spread.md)
for keeping thin lines visible.

## Examples

``` r
set.seed(1)
# Dense timeseries: 400 random walks of 500 steps, packed into one raster.
k <- 400; m <- 500
walks <- apply(matrix(rnorm(k * m), m, k), 2, cumsum)
t <- rep(seq_len(m), k)
g <- datashade_lines(t, as.vector(walks), group = rep(seq_len(k), each = m),
                     width = 400, height = 300)

# Network edges: random segments shaded by edge density.
n <- 5000
e <- datashade_segments(rnorm(n), rnorm(n), rnorm(n), rnorm(n))
```
