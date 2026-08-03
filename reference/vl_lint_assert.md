# Fail on lint findings

[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)
for a test suite or a CI job: run the rules and stop if anything turns
up. A figure that lints clean today stays that way, in the same spirit
as
[`font_pin()`](https://r-vellum.github.io/vellum/reference/font_pin.md)
and
[`scene_hash()`](https://r-vellum.github.io/vellum/reference/scene_hash.md)
— with the difference that this one catches defects rather than changes.

## Usage

``` r
vl_lint_assert(
  scene,
  ...,
  severity = c("warning", "note"),
  on = c("error", "warn")
)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method.

- ...:

  Passed to
  [`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)
  — `rules`, `exclude`, the thresholds.

- severity:

  `"warning"` (default) fails only on warnings; `"note"` fails on
  anything at all.

- on:

  `"error"` (default) or `"warn"`.

## Value

Invisibly, the findings that triggered the failure — a zero-row frame
when the scene is clean.

## See also

[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md),
[`vl_lint_overlay()`](https://r-vellum.github.io/vellum/reference/vl_lint_overlay.md)
to see what was reported.

## Examples

``` r
clean <- vl_scene(3, 2) |> draw(text_grob("fine", gp = vl_gpar(fontsize = 12)))
vl_lint_assert(clean)

# In a test:
# test_that("the figure has no lint findings", vl_lint_assert(my_plot()))
```
