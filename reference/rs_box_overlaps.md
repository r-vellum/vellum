# Every overlapping pair among `boxes`, as flat 1-based index pairs.

Every overlapping pair among `boxes`, as flat 1-based index pairs.

## Usage

``` r
rs_box_overlaps(boxes, pad)
```

## Arguments

- boxes:

  Flat numeric `c(x0, y0, x1, y1, ...)`.

- pad:

  Grow every box outward by this much before testing.

## Value

Flat `c(i1, j1, i2, j2, ...)`, 1-based, low index first.
