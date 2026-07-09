# Units of measurement

A `unit` is a vectorised `(value, unit)` pair used for coordinates and
sizes. Each element carries its own unit, so a single `unit` vector can
mix coordinate systems and a primitive can use different units on the x
and y axes (e.g. `x` in `"native"`, `y` in `"npc"`).

## Usage

``` r
unit(values, units = "npc", data = NULL)

is_unit(x)
```

## Arguments

- values:

  Numeric vector of magnitudes.

- units:

  Character vector of unit names, recycled against `values`.

- data:

  Optional list supplying context for derived units: `label`,
  `fontfamily`, `fontface`, `fontsize`, `lineheight`.

- x:

  An object.

## Value

A `unit` vector.

## Details

Supported units:

- `"npc"` — normalised parent coordinates (0 = bottom/left, 1 =
  top/right)

- `"native"` — the enclosing viewport's `xscale`/`yscale`

- `"mm"`, `"cm"`, `"in"`, `"pt"` — absolute lengths

- `"char"`, `"line"` — font-relative (need `fontsize`/`lineheight` via
  `data`)

- `"strwidth"`, `"strheight"` — size of a string (need `label` via
  `data`)

Font- and string-relative units are resolved to absolute millimetres at
construction (text metrics are available device-independently), so a
stored `unit` only ever holds one of the core backend units.

Arithmetic: `+` and `-` combine two units of the *same* code, or two
*absolute* units (`"mm"`/`"cm"`/`"in"`/`"pt"`), which resolve to `"mm"`
immediately (e.g. `unit(10, "mm") + unit(1, "in")` is `35.4mm`). A
position unit (`"npc"`/`"native"`) plus an absolute unit forms a
**compound** unit — a data/panel anchor plus an exact absolute offset —
e.g. `unit(1, "native") + unit(2, "mm")` is `1native+2mm`: it resolves
to the native position shifted right by exactly 2 mm at render, at any
scale or aspect. Mixing two *different* position bases (e.g. `"npc"` and
`"native"`) still errors, as it cannot be reduced to one unit.
`unit * scalar` scales the base value and the offset together.

## Examples

``` r
unit(1:3, "native")
#> <vellum_unit[3]>
#> [1] 1native 2native 3native
unit(c(0.5, 1), c("npc", "in"))
#> <vellum_unit[2]>
#> [1] 0.5npc 1.0in 
```
