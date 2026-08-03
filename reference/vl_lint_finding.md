# Build a lint finding

The return shape
[`vl_lint_rule()`](https://r-vellum.github.io/vellum/reference/vl_lint_rule.md)
functions must produce. Vectorised over `nodes`, so a rule matches rows
and describes them in one call.

## Usage

``` r
vl_lint_finding(rule, severity = c("warning", "note"), nodes, message)
```

## Arguments

- rule:

  Rule id.

- severity:

  `"warning"` (likely a real defect) or `"note"`.

- nodes:

  The matching rows of the node table.

- message:

  One message, or one per row.

## Value

A data frame of findings, one row per node, with the node's device-px
box carried through in `x0`/`y0`/`x1`/`y1` so a caller can point at the
finding on the image. The box is `NA` when `nodes` has no geometry.
