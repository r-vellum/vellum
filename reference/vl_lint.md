# Check a scene for likely mistakes

Static analysis for graphics. `vl_lint()` resolves the scene and
inspects the geometry the renderer would draw with, reporting the things
people normally find by squinting at the output: a mark that landed
off-canvas, a label too small to read, text that will not contrast with
what is behind it, an element that is invisible because nothing was ever
going to paint it.

## Usage

``` r
vl_lint(
  scene,
  rules = NULL,
  exclude = NULL,
  severity = NULL,
  min_text_px = 7,
  min_text_pt = 6,
  min_contrast = 3,
  max_overplot = 8,
  cvd = "deuteranopia",
  min_cvd_delta = 0.06
)
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

- exclude:

  Node names (or ids, or kinds) whose findings to drop — the deliberate
  oddity you have already looked at and accepted. Suppression is by node
  because `rules` already selects rules, and without it a figure with
  one intentional off-canvas mark could never reach a clean lint to
  assert on. An entry matching nothing in the scene warns, since a stale
  exclude list looks exactly like a working one.

- severity:

  Named character vector overriding a rule's own severity, e.g.
  `c(tiny_text = "note")`. Useful when a project cares about a rule
  more, or less, than vellum does.

- min_text_px:

  Text shorter than this many device pixels is flagged as illegible.
  Default `7`.

- min_text_pt:

  Text smaller than this many points is flagged as illegible. Default
  `6`.

  The two floors answer different questions and `tiny_text` fires on
  either. Device pixels decide whether the glyphs survive rasterisation,
  and points decide whether a human can read them — which is why a pixel
  floor alone is not enough: `font_px` scales with `dpi`, so a 4 pt
  label rendered at `dpi = 300` clears a 7 px floor comfortably while
  remaining illegible on paper.

- min_contrast:

  Minimum text-to-backdrop contrast ratio before `low_contrast` fires.
  Default `3` (WCAG AA for large text); WCAG AA for body text is `4.5`.

- max_overplot:

  How many times an average pixel inside a batched mark's own extent may
  be painted before `overplotted` fires. Default `8`; a well-spread
  scatter sits below `1`, a few thousand points around `4`, and a dense
  cluster in the hundreds.

- cvd:

  Colour-vision deficiencies `cvd_collision` should check:
  `"deuteranopia"` (the default, and the most common form),
  `"protanopia"`, `"tritanopia"`, `"achromatopsia"` — which doubles as
  "will this survive a greyscale printer" — or `"none"` to switch the
  rule off. Simulated with the same matrices `render(cvd = )` draws
  with.

- min_cvd_delta:

  How close two colours may come, as an Oklab distance after simulation,
  before `cvd_collision` calls them the same colour. Default `0.06`. Two
  references for that number: ggplot2's default three-colour palette
  puts red and green `0.325` apart in normal vision and `0.048` apart
  under deuteranopia, while the closest pair in the CVD-safe Okabe-Ito
  palette stays at `0.075`.

## Value

A data frame of findings, empty if the scene is clean: `rule`,
`severity`, `node`, `message`, and the finding's device-px box (`x0`,
`y0`, `x1`, `y1`, `NA` where a rule reported something with no
geometry). Printing shows a grouped summary.

A rule that fails does not abort the lint: it is reported as a
`rule_error` finding naming the rule, and the other rules still run.

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
