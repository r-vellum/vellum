# Marching-squares contours at one level, chained into polylines.

Marching-squares contours at one level, chained into polylines.

## Usage

``` r
rs_contour_lines(z, nx, ny, level)
```

## Arguments

- z:

  Row-major grid values, `nx` wide by `ny` tall.

- nx, ny:

  Grid dimensions.

- level:

  Contour level.

## Value

List of `x`, `y`, `nper`, `closed` in grid coordinates.
