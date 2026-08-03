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
vl_lint_rule(
  name,
  fn,
  description = "",
  kinds = NULL,
  needs_pixels = FALSE,
  tags = character()
)

vl_lint_rules()
```

## Arguments

- name:

  Short rule id, e.g. `"tiny_text"`. Re-registering replaces.

- fn:

  A function of `(scene, nodes, ctx)` returning a data frame of findings
  — build it with
  [`vl_lint_finding()`](https://r-vellum.github.io/vellum/reference/vl_lint_finding.md)
  — or `NULL` for "nothing found". A rule that fails is reported as a
  `rule_error` finding rather than aborting the lint.

  `nodes` is the resolved per-node table, one row per drawn node in
  paint order:

  `kind`, `name`, `id`, `label`

  :   what the node is, and what it was called. `label` is the string,
      for text nodes.

  `node`

  :   the paint index — later means drawn on top.

  `x0`, `y0`, `x1`, `y1`

  :   the device-px box, y-down. For a batched mark this is the union
      over every element, so reach for `ctx$elements()` when that
      distinction matters.

  `clip_x0`…`clip_y1`

  :   the innermost clip box, which is the whole page when the node is
      unclipped.

  `vp`, `vp_x0`…`vp_y1`

  :   the node's viewport: an id that nodes sharing a viewport share,
      and that viewport's own device-px extent. Not the same as the clip
      box — an unclipped viewport still has an extent, and a mark can
      leave it.

  `n`

  :   how many elements the node draws.

  `alpha`, `has_fill`, `has_col`

  :   the group alpha, and whether a fill and a stroke are present at
      all.

  `col`, `fill`

  :   stroke and fill colour as `0xRRGGBBAA` packed into a double (not
      an integer — the value overflows a signed 32-bit int once red
      reaches 128). Group alpha is already folded in.

  `fill_kind`

  :   `"none"`, `"solid"`, `"linear"`, `"radial"`, `"pattern"` or
      `"hatch"`. A gradient has no single colour, so a rule reasoning
      about colour must check this before reading `fill`.

  `lwd_px`

  :   stroke width in device pixels.

  `font_px`

  :   text size in device pixels; `0` for everything else.

  `notdef`

  :   how many characters of a text node shaped to glyph 0 — no font on
      this machine has them, and they will render as tofu boxes.

  `ctx` carries:

  `w`, `h`, `dpi`

  :   the page in device pixels, and its resolution.

  `min_text_px`, `min_text_pt`, `min_contrast`, `max_overplot`, `cvd`, `min_cvd_delta`

  :   the thresholds
      [`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)
      was called with.

  `pixel(x, y)`

  :   one composited RGBA pixel, as a length-4 vector.

  `region(x0, y0, x1, y1)`

  :   every composited pixel in a box, as a 4-column RGBA matrix —
      cheaper and steadier than probing point by point, since a single
      probe can land on an incidental gridline.

  `elements()`

  :   the per-element table (`key`, `panel`, `name`, `kind`, `node`,
      box), which is what to use when a node is a batch: a scatter is
      one node whose box is the union over every point.

  `pixel()`, `region()` and `elements()` are all lazy. Rendering the
  scene to look at it is the expensive part of linting, and most rules
  never need to.

- description:

  One line, shown by `vl_lint_rules()`.

- kinds:

  Node kinds the rule looks at, e.g. `"text"`. The rule is skipped when
  the scene contains none of them. `NULL` (default) means "any".

- needs_pixels:

  Whether the rule renders the scene. Reported by `vl_lint_rules()` so a
  caller can select the cheap rules for a tight loop.

- tags:

  Free-form labels for grouping rules, e.g. `"accessibility"`.

## Value

Invisibly, `name`.

`vl_lint_rules()`: a data frame of registered rules, with the `kinds` a
rule looks at, whether it renders the scene, and its `tags`.

## See also

[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md),
`vl_lint_rules()`

## Examples

``` r
vl_lint_rule("no_hexagons", function(scene, nodes, ctx) {
  hits <- nodes[nodes$kind == "hexagon", , drop = FALSE]
  if (!nrow(hits)) return(NULL)
  vl_lint_finding("no_hexagons", "note", hits, "hexagons are banned here")
}, "example rule", kinds = "hexagon")
```
