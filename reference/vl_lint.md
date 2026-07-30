# Check a scene for likely mistakes

Static analysis for graphics. `vl_lint()` resolves the scene and
inspects the geometry the renderer would draw with, reporting the things
people normally find by squinting at the output: a mark that landed
off-canvas, a label too small to read, text that will not contrast with
what is behind it, an element that is invisible because nothing was ever
going to paint it.

## Usage

``` r
vl_lint(scene, rules = NULL, min_text_px = 7, min_contrast = 3)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method.

- rules:

  Rule ids to run; `NULL` (default) runs all registered rules.

- min_text_px:

  Text shorter than this many device pixels is flagged as illegible.
  Default `7`.

- min_contrast:

  Minimum text-to-backdrop contrast ratio before `low_contrast` fires.
  Default `3` (WCAG AA for large text); WCAG AA for body text is `4.5`.

## Value

A data frame of findings (`rule`, `severity`, `node`, `message`), empty
if the scene is clean. Printing shows a grouped summary.

## Details

This is possible because vellum resolves layout and text metrics
*before* drawing. A layer above grid cannot ask "how many pixels tall is
this label", because the answer does not exist until a device is open.

The rule set is extensible — see
[`vl_lint_rule()`](https://r-vellum.github.io/vellum/reference/vl_lint_rule.md).

## See also

[`vl_lint_rule()`](https://r-vellum.github.io/vellum/reference/vl_lint_rule.md),
[`scene_stats()`](https://r-vellum.github.io/vellum/reference/scene_stats.md),
[`why_size()`](https://r-vellum.github.io/vellum/reference/why_size.md)

## Examples

``` r
# A label pushed off the page, and one too small to read.
s <- vl_scene(3, 2) |>
  draw(text_grob("off the edge", x = 1.6, y = 0.5)) |>
  draw(text_grob("tiny", x = 0.5, y = 0.2, gp = vl_gpar(fontsize = 2)))
vl_lint(s)
#> 2 lint findings (2 warnings):
#> ✖ [offscreen] text: drawn entirely outside the page - check the coordinates or
#>   the scale
#> ✖ [tiny_text] text: 2.7 px tall - below the 7 px legibility floor
```
