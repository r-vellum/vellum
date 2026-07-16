# Spread (dilate) the pixels of a raster grob

Grow each non-empty pixel of a raster over a small neighbourhood so thin
marks stay visible. This is [datashader's](https://datashader.org)
`spread`: useful after
[`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md),
[`datashade_lines()`](https://r-vellum.github.io/vellum/reference/datashade_lines.md),
or
[`datashade_segments()`](https://r-vellum.github.io/vellum/reference/datashade_lines.md)
when the output is sparse (single-pixel lines, isolated points).
[`dynspread()`](https://r-vellum.github.io/vellum/reference/dynspread.md)
chooses the radius automatically from the image's density; `spread()`
uses a fixed one.

## Usage

``` r
spread(grob, px = 1L, shape = c("circle", "square"), how = c("over", "add"))
```

## Arguments

- grob:

  A raster [grob](https://r-vellum.github.io/vellum/reference/grob.md)
  (e.g. from
  [`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)).
  Other grob kinds are returned unchanged.

- px:

  Spread radius in pixels (non-negative integer). `0` returns `grob`
  unchanged.

- shape:

  Neighbourhood shape: `"circle"` (default, Euclidean radius) or
  `"square"` (Chebyshev radius).

- how:

  How overlapping spread pixels combine: `"over"` (default) keeps the
  colour of the most-opaque contributor; `"add"` accumulates opacity
  (clamped) so overlaps darken.

## Value

A raster [grob](https://r-vellum.github.io/vellum/reference/grob.md)
with the spread applied.

## See also

[`dynspread()`](https://r-vellum.github.io/vellum/reference/dynspread.md),
[`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md),
[`datashade_lines()`](https://r-vellum.github.io/vellum/reference/datashade_lines.md).

## Examples

``` r
set.seed(1)
g <- datashade_segments(rnorm(2000), rnorm(2000), rnorm(2000), rnorm(2000))
g2 <- spread(g, px = 2)
```
