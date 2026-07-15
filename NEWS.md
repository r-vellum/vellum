# vellum (development version)

* **Perceptual (Oklab) gradient interpolation.** `linear_gradient()` and
  `radial_gradient()` gained `interpolation = "oklab"`, which blends the stops in
  the perceptually-uniform Oklab space instead of sRGB — removing the muddy,
  over-dark midtones and hue drift of sRGB blending (a blue→yellow ramp no longer
  passes through a grey dead-zone). It works identically on the raster, SVG, and
  PDF backends: the stops are pre-sampled in Oklab into dense sRGB stops, so no
  backend colour-space support is needed. The default is `"srgb"` and is
  byte-for-byte unchanged. (Implemented directly, with no new crate dependency.)

* **Two new marker shapes: `"triangle_down"` and `"star"`.** `points_grob(shape=)`
  now accepts a downward-pointing triangle and a five-pointed star in addition to
  `circle`/`square`/`triangle`/`diamond`/`plus`/`cross`. Like the other filled
  shapes they paint `gp$fill` and outline with `gp$col` (so an *open* marker is
  `fill = NA` with a `col`), and they take the same solid-fill fast path. The
  grid-device shim now maps `pch` 6/25 to `triangle_down` (previously collapsed
  onto the up-triangle) and `pch` 8 to `star`.

# vellum 0.3.0

* **Categorical datashading (`datashade(category=)`).** `datashade()` gained a
  `count_cat` mode: pass `category` (a factor or vector, one value per point) and
  each category is aggregated into its own count grid in the same single pass, then
  every cell is coloured by the **count-weighted average** of the category hues it
  holds, with opacity from the cell's total density. This shows which category
  dominates where — and where categories mix — without overplotting bias, in one
  call instead of a hand-stacked layer per category. When `category` is set,
  `colors` is a per-category hue vector (named by level, or one per level in level
  order) rather than a low-to-high ramp. Backed by a new `rs_aggregate_2d_cat()`
  Rust aggregator (one O(N) pass, category-major grid). A `datashade()` call with no
  `category` renders byte-for-byte as before.

* **Percentile / span colour clamping for `datashade()`.** New `span` (absolute
  `c(lo, hi)` density limits) and `clip` (a percentile pair like `c(0.01, 0.99)`,
  derived from the non-empty cell quantiles) clamp the density range before the
  `how` transform, so a few extreme cells no longer flatten the rest. Both default
  `NULL` (unchanged output). The shade step is now a reusable internal colormap
  utility shared by the density and categorical paths.

# vellum 0.2.0

* **Breaking: renamed the grid-colliding exports to a `vl_` prefix** so
  attaching vellum no longer masks grid: `gpar()` → `vl_gpar()`, `unit()` →
  `vl_unit()`, `viewport()` → `vl_viewport()`, `arrow()` → `vl_arrow()`, and
  `pattern()` → `vl_pattern()`. The old names are removed (no aliases).

* **Multi-line and per-datum rich text.** `text_grob()` labels may now contain
  embedded newlines (`\n`), stacked baseline-to-baseline; `md()` gained the same
  and is now **vectorised** — `md(x)` returns a single label for a length-1 `x` or
  a list of labels for a vector, so a label grob can carry one distinct rich label
  per position. Single-line, single-label output is byte-for-byte unchanged. (Rust
  is untouched — shaping stays R-side.)

* **Accessibility (a11y).** `vl_scene(title=, desc=)` and the new `describe()` setter
  attach an accessible name and long description (alt text) to a scene. When set:
  * the **SVG** backend marks the root `<svg role="img" aria-labelledby=…>` and emits
    `<title>`/`<desc>` (WCAG 1.1.1);
  * the **PDF** backend produces a **tagged PDF** — the chart is a `Figure` in the
    structure tree carrying the description as `Alt` text.
  Purely additive: a scene with no title/desc renders byte-for-byte as before. (Strict
  PDF/UA-1 validation is a planned follow-up; the tag tree + Alt ship now.)

* `datashade(weight=)` now recycles a scalar and errors on a wrong-length vector,
  instead of silently discarding a mismatched weight and reverting to a plain count.

# vellum 0.1.1

* **Compound `native + mm` / `npc + mm` units.** A position unit combined with an
  absolute unit now forms a compound unit — a data/panel anchor plus an exact
  absolute offset — instead of erroring. `unit(1, "native") + unit(2, "mm")`
  resolves to the native position shifted by exactly 2 mm at render, at any scale
  or aspect (the offset is applied device-side after the base resolves). This is
  the deferred "B1" route; it unlocks device-exact label nudges, halos, and
  drop-shadow offsets in the grammar layer. Mixing two *different* position bases
  (e.g. `npc` and `native`) still errors. Unit arithmetic scales the base and the
  offset together. Additive change: a scene using no compound units renders
  byte-for-byte as before.

# vellum 0.1.0

First release. vellum is a low-level graphics framework for R in the spirit of
`grid`, with a Rust backend: you describe a scene through a small declarative R
API, and the scene graph, unit/layout engine, and rendering all run in Rust.

## Scenes and rendering

* Build a scene functionally with `vl_scene()` and a pipeline of `push()`,
  `draw()`, and `pop()` over an immutable tree.
* `render()` draws the same scene to **PNG, SVG, or PDF**, picking the backend
  from the file extension — raster via [tiny-skia](https://github.com/linebender/tiny-skia),
  PDF via [krilla](https://github.com/LaurenzV/krilla), SVG hand-rolled. Output
  is byte-stable and snapshot-testable.
* `display()` draws a scene into the active graphics device; `scene_raster()` /
  `scene_svg()` return the rendered scene in memory.

## Grobs, units, and layout

* Vectorised drawing primitives (rect, circle, points, segments, lines, path,
  polygon, text, raster, ...) that batch internally.
* A unit system (`unit()`, `grobwidth`, ...) and nested `viewport()`s with their
  own scales, rotation, and arbitrary-path clipping, plus a row/column layout
  solver with `"null"` (flexible) tracks.

## Paint model

* A modern paint model shared across all backends: linear and radial
  **gradients**, tiling **patterns**, alpha/luminance **masks**, group opacity
  (`viewport(alpha =)`), reusable `style()`s, and hand-drawn `sketch()`
  rendering.

## Text

* Device-independent shaping and measurement through
  [textshaping](https://github.com/r-lib/textshaping) /
  [systemfonts](https://github.com/r-lib/systemfonts) — the same stack as
  ragg/svglite — with per-glyph fallback, justification, and rotation, plus
  Markdown-style rich labels via `md()`.

## Big data

* `datashade()` aggregates millions of points into a density raster in a single
  pass — cost scales with output pixels, not point count — with no overplotting
  and small output files.

## Retained scene graph

* Because the scene is retained rather than drawn-and-forgotten, it can be
  queried and edited: `node_names()` / `get_node()` / `edit_node()`,
  `hit_test()` to pick the topmost grob under a point, and `scene_model()` to
  serialize a per-element model (data keys, bounding boxes) — the foundation the
  `vellumplot` grammar and the `vellumwidget` widget layer build on.

## Interop

* `as_vellum()` / `render_grid()` render an existing `grid` grob tree —
  including **ggplot2** and **lattice** — through the vellum backend.

## Under the hood

* The R package wires to a Rust crate via [extendr](https://extendr.github.io/);
  crates are vendored for offline/CRAN builds.
