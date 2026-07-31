# Hull of a point set

`vl_hull()` returns the convex hull, or a concave one that follows the
point set more closely — useful for outlining a cluster, or for building
an exclusion zone that annotations should avoid.

## Usage

``` r
vl_hull(x, y, concavity = Inf)
```

## Arguments

- x, y:

  Point coordinates (plain numerics, in whatever space you are working
  in — the hull is scale-free).

- concavity:

  Threshold as above; larger is more convex, and `Inf` (the default) is
  the convex hull.

## Value

A data frame of the hull ring's `x`/`y`, in order, ready for
[`polygon_grob()`](https://r-vellum.github.io/vellum/reference/grob.md).
The ring is not closed (the last point does not repeat the first).

## Details

The concave hull digs into the convex hull, replacing an edge with two
edges through the nearest unused point whenever the edge is long
relative to the detour. `concavity` is that threshold, and **larger
means more convex**:

- `Inf` (the default) is exactly the convex hull.

- `8` follows the points loosely.

- `4` is a good tight outline for a scattered cluster.

- Below about `3` the boundary starts to self-intersect.

Self-intersection is inherent to the method, not a defect to be fixed
here — a boundary that threads between interior points has to cross
itself eventually. Inspect the result if you push it hard.

## Examples

``` r
set.seed(1)
pts <- data.frame(x = runif(40), y = runif(40))
h <- vl_hull(pts$x, pts$y)
vl_scene(3, 3, dpi = 96, bg = "white") |>
  draw(polygon_grob(h$x, h$y, gp = vl_gpar(fill = "#DCE7F5", col = "steelblue"))) |>
  draw(points_grob(pts$x, pts$y, gp = vl_gpar(fill = "grey25", col = NA)))
```
