# Boolean operations on paths

Combine two shapes as **geometry**: union, intersection, difference or
exclusive-or over their closed rings.

## Usage

``` r
vl_path_op(
  a,
  b,
  op = c("union", "intersect", "difference", "xor"),
  rule = c("nonzero", "evenodd"),
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  role = NULL
)
```

## Arguments

- a, b:

  The operands: a
  [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
  a
  [`polygon_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
  or a list with `x`, `y` and optionally `nper` (points per ring).

- op:

  One of `"union"`, `"intersect"`, `"difference"` (`a` minus `b`), or
  `"xor"`.

- rule:

  Fill rule for interpreting the inputs: `"nonzero"` (default) or
  `"evenodd"`.

- gp, name, vp, role:

  Passed to the returned
  [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md).

## Value

A [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
with `rule = "winding"`. An empty result (a disjoint intersection, say)
gives a grob with no points, which draws nothing.

## Why geometry and not a mask

vellum can already clip one shape by another at render time, and for
simply *showing* an intersection that is often enough. A boolean result
is different in kind: it is an ordinary path, so it can be measured,
hit-tested, simplified, filled with a gradient, stroked, exported as
`<path>` data, and fed into another boolean. A mask can do none of
those, rasterises, and degrades on some PDF paths.

## Rings, holes and the fill rule

`rule` says how to interpret the **inputs** — whether a ring inside
another ring is a hole (`"evenodd"`) or a separate island (`"nonzero"`).
It must match the rule the operands were drawn with, or the answer will
be correct for a shape you did not mean.

The **result** always uses the non-zero rule: holes come back wound
opposite to their outer ring, which is how the returned
[`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md) is
set up.

Operands must be in a single coordinate space — one unit, no offsets —
since a boolean has to be computed somewhere, and mixed units have no
common space.

## Examples

``` r
sq <- function(x0, y0, s = 0.4) {
  list(x = c(x0, x0 + s, x0 + s, x0), y = c(y0, y0, y0 + s, y0 + s))
}
a <- sq(0.2, 0.3)
b <- sq(0.45, 0.4)
vl_scene(3, 2, dpi = 96, bg = "white") |>
  draw(vl_path_op(a, b, "union", gp = vl_gpar(fill = "#DCE7F5", col = "steelblue")))
```
