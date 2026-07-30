# Expand a stroked polyline into the outline of the stroke, as a fillable path.

Input and output are device pixels. `nper` gives the point count of each
sub-path in `x`/`y`. Returns
`c(n_subpaths, len1, len2, ..., x..., y...)`: the sub-path lengths
followed by the flattened coordinates.

## Usage

``` r
rs_stroke_to_path(x, y, nper, closed, width, cap, join, miter)
```

## Details

tiny-skia already ships the stroker the rasterizer uses, so this is the
exact same expansion that drawing performs – not a reimplementation that
could drift from it.
