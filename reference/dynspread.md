# Dynamically spread a raster grob to a target density

[datashader's](https://datashader.org) `dynspread`: pick the smallest
spread radius (up to `max_px`) at which the shaded pixels become
"connected enough" — the fraction of non-empty pixels with a non-empty
neighbour reaches `threshold` — then
[`spread()`](https://r-vellum.github.io/vellum/reference/spread.md) by
it. Denser images spread less, sparse ones more, so a mix of dense and
sparse regions all stay legible.

## Usage

``` r
dynspread(
  grob,
  max_px = 3L,
  threshold = 0.5,
  shape = c("circle", "square"),
  how = c("over", "add")
)
```

## Arguments

- grob:

  A raster [grob](https://r-vellum.github.io/vellum/reference/grob.md)
  (e.g. from
  [`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)).
  Other grob kinds are returned unchanged.

- max_px:

  Largest spread radius to consider (non-negative integer).

- threshold:

  Target fraction in `(0, 1]` of non-empty pixels that should have a
  non-empty neighbour; growth stops once it is reached.

- shape:

  Neighbourhood shape: `"circle"` (default, Euclidean radius) or
  `"square"` (Chebyshev radius).

- how:

  How overlapping spread pixels combine: `"over"` (default) keeps the
  colour of the most-opaque contributor; `"add"` accumulates opacity
  (clamped) so overlaps darken.

## Value

A raster [grob](https://r-vellum.github.io/vellum/reference/grob.md)
with the chosen spread applied.

## See also

[`spread()`](https://r-vellum.github.io/vellum/reference/spread.md),
[`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md),
[`datashade_lines()`](https://r-vellum.github.io/vellum/reference/datashade_lines.md).

## Examples

``` r
set.seed(1)
g <- datashade_segments(rnorm(2000), rnorm(2000), rnorm(2000), rnorm(2000))
g2 <- dynspread(g)
```
