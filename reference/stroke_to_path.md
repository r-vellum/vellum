# Freeze a stroke into a fillable outline

Converts the *stroke* of a line-like grob into a `path_grob` describing
the region the stroke covers — the shape you would get by tracing round
the drawn line. What was a one-pixel-wide path with a colour becomes an
area with an interior, which is what you need in order to fill it with a
gradient or a pattern, to send it to a cutting plotter or CNC tool, or
to do geometry with it.

## Usage

``` r
stroke_to_path(grob, width = 6, height = 4, dpi = 96, gp = NULL)
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

## Value

A [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
in `mm` units, with `rule = "winding"`, whose fill is the stroked
region. Its `gp` starts from the source grob's stroke colour as a fill,
so drawing it looks like the original line.

## Details

The expansion uses the same stroker the rasterizer uses, so the outline
is exactly the region that would have been inked, not a reimplementation
that could drift from it.

**The result is baked at one size.** A stroke width is a device
quantity, so its outline only exists once a page size and resolution are
chosen. Those are arguments here, and the returned coordinates are
absolute (mm) — the outline will *not* rescale with the page the way the
original stroke would. That is inherent: an outline is a shape, not a
stroke.

## See also

[`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
[grob](https://r-vellum.github.io/vellum/reference/grob.md)

## Examples

``` r
zig <- lines_grob(c(0.1, 0.35, 0.6, 0.9), c(0.2, 0.8, 0.2, 0.8),
                  gp = vl_gpar(col = "steelblue", lwd = 12))
outline <- stroke_to_path(zig, width = 3, height = 2)
# Now fillable: a gradient across the ribbon the line traced.
vl_scene(3, 2) |>
  draw(S7::set_props(outline, gp = vl_gpar(
    fill = linear_gradient(c("tomato", "gold")), col = "grey20", lwd = 0.5
  )))
```
