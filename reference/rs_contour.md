# Marching-squares contour segments at one level.

Marching-squares contour segments at one level.

## Usage

``` r
rs_contour(z, nx, ny, level)
```

## Arguments

- z:

  Row-major grid values, `nx` wide by `ny` tall.

- nx, ny:

  Grid dimensions.

- level:

  Contour level.

## Value

Flat `c(x0, y0, x1, y1, ...)` in grid coordinates.
