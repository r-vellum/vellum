# Flatten a quadratic segment into line segments at roughly pixel accuracy. Expand a stroke whose width varies along it into a fillable outline.

Input and output are device pixels, and the return uses the same flat
encoding as
[`rs_stroke_to_path`](https://r-vellum.github.io/vellum/reference/rs_stroke_to_path.md):
`c(n_subpaths, len1, len2, ..., x..., y...)`.

## Usage

``` r
rs_stroke_to_path_var(x, y, nper, closed, hw, cap, join, miter, arc)
```

## Details

`hw` is the **half**-width at each vertex, parallel to `x`/`y`, so the
caller owns every question about how a width profile is positioned along
the line. `arc <= 0` means "auto" (about one point per pixel of arc).

This is a separate entry point rather than a flag on `rs_stroke_to_path`
because the two are genuinely different generators – tiny-skia's stroker
versus our own offsetter (see `ribbon.rs`). Keeping them apart means a
scene with no width profile takes byte-for-byte the path it always took.
