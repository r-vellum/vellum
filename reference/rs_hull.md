# Convex or concave hull of a point set, as 1-based point indices in order.

Convex or concave hull of a point set, as 1-based point indices in
order.

## Usage

``` r
rs_hull(x, y, concavity)
```

## Arguments

- x, y:

  Point coordinates.

- concavity:

  Threshold; non-finite or non-positive gives the convex hull.

## Value

Integer vector of 1-based indices.
