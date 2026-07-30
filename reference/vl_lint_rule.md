# Register a lint rule

Adds a rule to the registry
[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)
runs. A package layered on vellum can register rules of its own — vellum
supplies the geometric ones (a mark drawn off-canvas, text too small to
read), a grammar layer can add semantic ones (a scale with a single
level, a legend with forty entries) — and both come back from one
[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)
call.

## Usage

``` r
vl_lint_rule(name, fn, description = "")

vl_lint_rules()
```

## Arguments

- name:

  Short rule id, e.g. `"tiny_text"`. Re-registering replaces.

- fn:

  A function of `(scene, nodes, ctx)` returning a data frame with
  columns `rule`, `severity` (`"warning"`/`"note"`), `node`, `message` —
  or `NULL` for "nothing found". `nodes` is the resolved per-node table
  (device-px `x0`/`y0`/`x1`/`y1`, clip box, `kind`, `name`, `n`,
  `alpha`, `has_fill`, `has_col`, `font_px`, `col`, `label`); `ctx`
  carries the page size (`w`, `h`), `dpi`, and a `pixel(x, y)` sampler
  over the rendered image.

- description:

  One line, shown by `vl_lint_rules()`.

## Value

Invisibly, `name`.

`vl_lint_rules()`: a data frame of registered rules.

## See also

[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md),
`vl_lint_rules()`

## Examples

``` r
vl_lint_rule("no_hexagons", function(scene, nodes, ctx) {
  hits <- nodes[nodes$kind == "hexagon", , drop = FALSE]
  if (!nrow(hits)) return(NULL)
  vl_lint_finding("no_hexagons", "note", hits, "hexagons are banned here")
}, "example rule")
```
