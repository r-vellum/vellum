# Buffer a polygon outward

Grows a ring by `width` in every direction — the exclusion zone around a
region, the halo around a cluster outline, the standoff a leader line
should keep.

## Usage

``` r
vl_buffer(x, y, width, arc = 6)
```

## Arguments

- x, y:

  The ring's coordinates, in order and not closed.

- width:

  Distance to grow by, in the same units as `x`/`y`.

- arc:

  Points per quarter-turn on rounded corners. More is smoother.

## Value

A data frame of the buffered ring's `x`/`y`.

## Details

Corners are rounded, which is what a standoff usually wants and what
keeps the result well-defined at sharp angles (a mitred corner runs away
to infinity as the angle closes).

**On concave rings:** the offset boundary of a concave polygon can cross
itself where the buffer is wider than a local feature. This function
offsets the ring and does not repair that, because repairing it is a
boolean union — a Phase 12 operation. Buffering a convex ring, or
buffering by less than the narrowest feature, is always well-behaved.
Passing the result through
[`vl_hull()`](https://r-vellum.github.io/vellum/reference/vl_hull.md) is
a crude but effective fix when it is not.

## Examples

``` r
tri <- data.frame(x = c(0.3, 0.7, 0.5), y = c(0.3, 0.35, 0.7))
buf <- vl_buffer(tri$x, tri$y, 0.08)
vl_scene(3, 3, dpi = 96, bg = "white") |>
  draw(polygon_grob(buf$x, buf$y, gp = vl_gpar(fill = "#F3E0DA", col = NA))) |>
  draw(polygon_grob(tri$x, tri$y, gp = vl_gpar(fill = "tomato", col = NA)))
```
