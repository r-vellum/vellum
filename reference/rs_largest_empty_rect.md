# Largest axis-aligned empty rectangle in `region`, avoiding `boxes`.

Largest axis-aligned empty rectangle in `region`, avoiding `boxes`.

## Usage

``` r
rs_largest_empty_rect(boxes, region, nx, ny)
```

## Arguments

- boxes:

  Flat numeric `c(x0, y0, x1, y1, ...)` of obstacles.

- region:

  Numeric `c(x0, y0, x1, y1)` to search within.

- nx, ny:

  Grid resolution; the answer is exact on this grid.

## Value

Numeric `c(x0, y0, x1, y1)`, all zero if there is no room.
