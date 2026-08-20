# Freeze a stroke into a fillable outline

Converts the *stroke* of a line-like grob into a `path_grob` describing
the region the stroke covers — the shape you would get by tracing round
the drawn line. What was a one-pixel-wide path with a colour becomes an
area with an interior, which is what you need in order to fill it with a
gradient or a pattern, to send it to a cutting plotter or CNC tool, or
to do geometry with it.

## Usage

``` r
stroke_to_path(
  grob,
  width = 6,
  height = 4,
  dpi = 96,
  gp = NULL,
  lwd_profile = NULL,
  along = c("arclength", "vertex")
)
```

## Arguments

- grob:

  A
  [`lines_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
  [`polygon_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
  or
  [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md).
  Its coordinates must be resolvable without a viewport: `npc`, an
  absolute unit, or `native` (read against the root's default `0..1`
  scale, which is what a bare numeric means).

- width, height:

  Page size in inches to resolve the geometry against.

- dpi:

  Resolution to resolve the stroke width against.

- gp:

  Optional
  [`vl_gpar()`](https://r-vellum.github.io/vellum/reference/vl_gpar.md)
  overriding the grob's own for the stroke parameters (`lwd`, `lineend`,
  `linejoin`, `linemitre`).

- lwd_profile:

  Optional numeric vector of multipliers of `lwd`, describing how the
  width varies along the line: `c(1, 0.2)` tapers a ribbon to a fifth of
  its width, `c(0, 1, 0)` is a leaf, `c(1, 0, 1)` is pinched to nothing
  in the middle. Values must be finite and `>= 0`, and at least one must
  be positive; a zero is a legal width, not an error. A single value
  simply scales the width. `NULL` (default) is a constant width, and
  takes exactly the expansion this function has always performed.

- along:

  How `lwd_profile` is positioned. `"arclength"` (default) spreads its
  values evenly along the *drawn length* of the stroke and interpolates
  between them, so the profile is independent of how the polyline
  happens to be sampled and any profile length works. `"vertex"` reads
  one value per vertex, in point order, which is what you want when the
  widths come from data attached to the vertices — a per-observation
  weight, a pressure trace. The two coincide only when the vertices are
  evenly spaced.

## Value

A [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
in `mm` units, with `rule = "winding"`, whose fill is the stroked
region. Its `gp` starts from the source grob's stroke colour as a fill,
so drawing it looks like the original line.

## Details

At constant width the expansion uses the same stroker the rasterizer
uses, so the outline is exactly the region that would have been inked,
not a reimplementation that could drift from it. A *varying* width has
no such reference — no rasterizer can stroke a line at a changing width
— so `lwd_profile` is served by vellum's own offsetter instead. See
`Variable width` below.

**The result is baked at one size.** A stroke width is a device
quantity, so its outline only exists once a page size and resolution are
chosen. Those are arguments here, and the returned coordinates are
absolute (mm) — the outline will *not* rescale with the page the way the
original stroke would. That is inherent: an outline is a shape, not a
stroke.

## Variable width

The region swept by a round nib of varying radius is the union of the
convex hulls of successive pairs of end discs, so `lwd_profile` builds
that union rather than offsetting each vertex along its normal. The
distinction matters at a taper: an offset boundary would cut *into* the
end disc and the tip would come out waisted rather than pointed.

Three consequences worth knowing:

- Width varies linearly **between vertices**, so a profile is only as
  smooth as the polyline under it.
  [`bezier_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  and
  [`spline_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  flatten to a polyline before this function sees them, so a profile
  rides the flattened points — prefer `along = "arclength"` there, and
  raise their `n` if a taper looks faceted.

- On a closed
  [`polygon_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  or
  [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  the profile is **cyclic**: a ring has no first vertex a reader can
  see, so the values wrap. `c(1, 0)` on a ring is therefore two tapers,
  not one.

- `lwd_profile = NULL` is byte-identical to previous versions. A
  *constant* profile such as `lwd_profile = 1` is not — it goes through
  the offsetter, so it agrees with tiny-skia's stroker as a picture but
  not to the last bit. `lineend` and `linejoin` are honoured, but only
  on the outer silhouette; the inner side of a join is the natural
  overlap either way.

## See also

[`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
[grob](https://r-vellum.github.io/vellum/reference/grob.md),
[`segments_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
for per-*element* widths

## Examples

``` r
zig <- lines_grob(c(0.1, 0.35, 0.6, 0.9), c(0.2, 0.8, 0.2, 0.8),
                  gp = vl_gpar(col = "steelblue", lwd = 12))
outline <- stroke_to_path(zig, width = 3, height = 2)
# A width that varies along the line: thick in the middle, tapered at both ends.
leaf <- stroke_to_path(zig, width = 3, height = 2, lwd_profile = c(0.15, 1, 0.15))
# Now fillable: a gradient across the ribbon the line traced.
vl_scene(3, 2) |>
  draw(S7::set_props(outline, gp = vl_gpar(
    fill = linear_gradient(c("tomato", "gold")), col = "grey20", lwd = 0.5
  )))
```
