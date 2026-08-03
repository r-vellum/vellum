# Draw lint findings onto the scene

Puts a box around every finding that has geometry, and labels it with
the rules that fired. For a graphics linter this is usually the fastest
way to understand a report: a message says a mark is clipped, an outline
shows you which one.

## Usage

``` r
vl_lint_overlay(scene, findings = NULL, labels = TRUE)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method.

- findings:

  The result of
  [`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md).
  `NULL` (default) lints `scene`.

- labels:

  Whether to write the rule name beside each box.

## Value

A new scene: `scene` with the overlay drawn on top, at page level.

## Details

Findings with no geometry (a `rule_error`, or a rule reporting something
scene-wide) have nothing to point at and are skipped.

## See also

[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md),
[`vl_lint_assert()`](https://r-vellum.github.io/vellum/reference/vl_lint_assert.md)

## Examples

``` r
s <- vl_scene(3, 2) |>
  draw(text_grob("off the edge", x = 1.6, y = 0.5)) |>
  draw(text_grob("tiny", x = 0.5, y = 0.2, gp = vl_gpar(fontsize = 2)))
# display(vl_lint_overlay(s))
nrow(vl_lint(s)) > 0
#> [1] TRUE
```
