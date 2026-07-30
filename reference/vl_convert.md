# Convert a unit to another unit, in a scene's context

The counterpart to grid's
`convertWidth()`/`convertHeight()`/`convertX()`/ `convertY()`: resolve a
[`vl_unit()`](https://r-vellum.github.io/vellum/reference/vl_unit.md)
vector to a plain number in some other unit.
[`why_size()`](https://r-vellum.github.io/vellum/reference/why_size.md)
explains a *named node's* resolved size and
[`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
reports resolved boxes for *keyed elements*; this answers the remaining
question — "how big is this particular unit, here?" — which a layer
built on vellum needs whenever it has to size something itself.

## Usage

``` r
vl_convert(
  u,
  to = "mm",
  scene = NULL,
  name = NULL,
  axis = c("x", "y"),
  what = c("length", "position")
)
```

## Arguments

- u:

  A
  [`vl_unit()`](https://r-vellum.github.io/vellum/reference/vl_unit.md)
  vector (or a bare numeric, read as `npc`).

- to:

  Target unit: `"mm"` (default), `"cm"`, `"in"`, `"pt"`, `"px"`,
  `"npc"`, or `"native"`.

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  (or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method) giving the context. Required unless every input *and* `to` is
  absolute.

- name:

  Name of the viewport to resolve against. `NULL` (default) uses the
  whole page.

- axis:

  Which extent relative units refer to: `"x"` (default) or `"y"`.

- what:

  `"length"` (default) for a size, `"position"` for a coordinate. Only
  affects `native`.

## Value

A numeric vector the same length as `u`, in `to` units.

## Details

Absolute units (`mm`, `cm`, `in`, `pt`) convert with no context, so
`scene` may be omitted. Relative units (`npc`, `native`) need to know
the region they are relative to, and therefore need a `scene` — and, for
anything other than the whole page, the `name` of a viewport in it.

Where grid uses four functions, this uses two arguments: `axis` picks
the x or y extent, and `what` distinguishes a **length** from a
**position**. They differ only for `native`, and only when the scale
does not start at zero: on `xscale = c(10, 20)`, `unit(12, "native")` is
*two tenths* of the width as a position, but *twelve tenths* as a
length.

## See also

[`why_size()`](https://r-vellum.github.io/vellum/reference/why_size.md),
[`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md),
[`vl_unit()`](https://r-vellum.github.io/vellum/reference/vl_unit.md)

## Examples

``` r
s <- vl_scene(4, 3, dpi = 100)
vl_convert(vl_unit(1, "in"), "mm") # absolute: no scene needed
#> [1] 25.4
vl_convert(vl_unit(0.5, "npc"), "mm", s) # half the page width
#> [1] 50.8
vl_convert(vl_unit(0.5, "npc"), "mm", s, axis = "y")
#> [1] 38.1

# A named viewport, and the length/position distinction on a shifted scale.
s2 <- s |> push(vl_viewport(width = 0.5, xscale = c(10, 20), name = "panel"))
vl_convert(vl_unit(12, "native"), "mm", s2, name = "panel")
#> [1] 60.96
vl_convert(vl_unit(12, "native"), "mm", s2, name = "panel", what = "position")
#> [1] 10.16
```
