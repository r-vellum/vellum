# SVG path data as scene geometry

`vl_svg_path()` parses the `d` attribute of an SVG `<path>` into rings;
`svg_grob()` wraps that up as a drawable
[`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md).

## Usage

``` r
vl_svg_path(d)

svg_grob(
  d,
  x = 0.5,
  y = 0.5,
  size = vl_unit(10, "mm"),
  flip_y = TRUE,
  viewbox = NULL,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
)
```

## Arguments

- d:

  A character string of SVG path data, or (for `svg_grob()`) a whole
  `<svg>` element to read `<path>` geometry and the `viewBox` from.

- x, y:

  Centre of the drawn icon.

- size:

  Size of the reference box's longer side, as a
  [`vl_unit()`](https://r-vellum.github.io/vellum/reference/vl_unit.md)
  — the viewBox when one is given, otherwise the path's own bounding
  box.

- flip_y:

  Flip the y axis to convert from SVG's convention. Leave `TRUE` unless
  your `d` is already in a y-up space.

- viewbox:

  The icon's SVG `viewBox` as `c(xmin, ymin, width, height)` or the
  attribute string `"xmin ymin width height"`, so `size` scales the box
  rather than the glyph's ink. `NULL` (default) uses a whole-`<svg>`
  document's own viewBox if present, else the path's ink bounds.

- gp, name, vp, id, role:

  Passed to the returned
  [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md).

## Value

`vl_svg_path()`: a data frame of `x`, `y`, `id`, `closed`. `svg_grob()`:
a [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md).

## Details

This is what makes vector icons usable as marks. Icon sets — Font
Awesome, Bootstrap Icons, Lucide, Material — ship one `<path d="...">`
per glyph, so `d` is the unit of exchange, and the result here is real
geometry: crisp at any size, fillable with a gradient, strokable, and
exported as `<path>` data rather than an embedded bitmap.

## Coordinate system

SVG's y axis points **down** and vellum's points up, so `svg_grob()`
flips it by default (`flip_y = TRUE`) — otherwise every icon arrives
upside-down. The geometry is then scaled so the longer side of its
reference box maps to `size`, preserving aspect, and centred on `x`/`y`.
`vl_svg_path()` returns the raw parsed coordinates without any of that,
for callers doing their own placement.

## Sizing across an icon set — the viewBox

Icon sets draw every glyph inside one shared `viewBox` (commonly
`"0 0 24 24"`) and pad each glyph within it, so a glyph's own ink fills
only part of the box. Sizing to the *ink* would blow each glyph up to
`size` individually — a sparse glyph would render far larger than a
dense one from the same set, and a lone icon larger than its nominal
box. Pass the set's `viewbox` (the four numbers
`c(xmin, ymin, width, height)`, or the raw attribute string
`"0 0 24 24"`) and `size` maps the *box* instead, so every glyph keeps
its intended relative and absolute size. If you hand `svg_grob()` a
whole `<svg>…</svg>` element (see below) its `viewBox` is used
automatically. With no viewBox at all, sizing falls back to the path's
own ink bounds.

## What is supported

The whole `d` grammar: `M`/`L`/`H`/`V`/`C`/`S`/`Q`/`T`/`A`/`Z` in
absolute and relative forms, implicit repeated commands, the
smooth-curve reflection rules, and elliptical arcs. Curves are flattened
to polylines.

`svg_grob()` also accepts a whole `<svg>` element as `d`: it reads the
`<path>` geometry and the document `viewBox` (needs the xml2 package).
Only `<path>` elements are read — other drawable shapes (`<circle>`,
`<rect>`, `<line>`, …) are not path data and are reported with a
warning, not silently dropped. The rest of SVG is still out of scope: no
stylesheets, gradients, `<use>`, clip paths, or element transforms —
this reads geometry, not documents.

Malformed data yields whatever parsed before the problem rather than an
error: a truncated icon is easier to diagnose than a stack trace.

## Examples

``` r
# A five-pointed star, as an icon set would ship it.
star <- "M12 2 L15 9 L22 9.3 L16.5 13.8 L18.5 21 L12 17 L5.5 21 L7.5 13.8 L2 9.3 L9 9 Z"
vl_scene(3, 2, dpi = 96, bg = "white") |>
  draw(svg_grob(star, x = 0.5, y = 0.5, size = vl_unit(15, "mm"),
                gp = vl_gpar(fill = "#F1C40F", col = "grey30")))


# As per-point markers, which is what raster icons cannot do crisply.
set.seed(1)
s <- vl_scene(4, 2, dpi = 96, bg = "white")
for (i in 1:6) {
  s <- draw(s, svg_grob(star, x = i / 7, y = runif(1) * 0.6 + 0.2,
                        size = vl_unit(6, "mm"),
                        gp = vl_gpar(fill = "#2C6FA6", col = NA)))
}
s
```
