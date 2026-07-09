# Changelog

## vellum (development version)

- **Breaking: renamed the grid-colliding exports to a `vl_` prefix** so
  attaching vellum no longer masks grid:
  [`gpar()`](https://rdrr.io/r/grid/gpar.html) →
  [`vl_gpar()`](https://r-vellum.github.io/vellum/reference/vl_gpar.md),
  [`unit()`](https://rdrr.io/r/grid/unit.html) →
  [`vl_unit()`](https://r-vellum.github.io/vellum/reference/vl_unit.md),
  [`viewport()`](https://rdrr.io/r/grid/viewport.html) →
  [`vl_viewport()`](https://r-vellum.github.io/vellum/reference/vl_viewport.md),
  [`arrow()`](https://rdrr.io/r/grid/arrow.html) →
  [`vl_arrow()`](https://r-vellum.github.io/vellum/reference/vl_arrow.md),
  and [`pattern()`](https://rdrr.io/r/grid/patterns.html) →
  [`vl_pattern()`](https://r-vellum.github.io/vellum/reference/vl_pattern.md).
  The old names are removed (no aliases).

- **Multi-line and per-datum rich text.**
  [`text_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  labels may now contain embedded newlines (`\n`), stacked
  baseline-to-baseline;
  [`md()`](https://r-vellum.github.io/vellum/reference/md.md) gained the
  same and is now **vectorised** — `md(x)` returns a single label for a
  length-1 `x` or a list of labels for a vector, so a label grob can
  carry one distinct rich label per position. Single-line, single-label
  output is byte-for-byte unchanged. (Rust is untouched — shaping stays
  R-side.)

- **Accessibility (a11y).** `vl_scene(title=, desc=)` and the new
  [`describe()`](https://r-vellum.github.io/vellum/reference/describe.md)
  setter attach an accessible name and long description (alt text) to a
  scene. When set:

  - the **SVG** backend marks the root
    `<svg role="img" aria-labelledby=…>` and emits `<title>`/`<desc>`
    (WCAG 1.1.1);
  - the **PDF** backend produces a **tagged PDF** — the chart is a
    `Figure` in the structure tree carrying the description as `Alt`
    text. Purely additive: a scene with no title/desc renders
    byte-for-byte as before. (Strict PDF/UA-1 validation is a planned
    follow-up; the tag tree + Alt ship now.)

- `datashade(weight=)` now recycles a scalar and errors on a
  wrong-length vector, instead of silently discarding a mismatched
  weight and reverting to a plain count.

## vellum 0.1.1

- **Compound `native + mm` / `npc + mm` units.** A position unit
  combined with an absolute unit now forms a compound unit — a
  data/panel anchor plus an exact absolute offset — instead of erroring.
  `unit(1, "native") + unit(2, "mm")` resolves to the native position
  shifted by exactly 2 mm at render, at any scale or aspect (the offset
  is applied device-side after the base resolves). This is the deferred
  “B1” route; it unlocks device-exact label nudges, halos, and
  drop-shadow offsets in the grammar layer. Mixing two *different*
  position bases (e.g. `npc` and `native`) still errors. Unit arithmetic
  scales the base and the offset together. Additive change: a scene
  using no compound units renders byte-for-byte as before.

## vellum 0.1.0

First release. vellum is a low-level graphics framework for R in the
spirit of `grid`, with a Rust backend: you describe a scene through a
small declarative R API, and the scene graph, unit/layout engine, and
rendering all run in Rust.

### Scenes and rendering

- Build a scene functionally with
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  and a pipeline of
  [`push()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  [`draw()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  and [`pop()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  over an immutable tree.
- [`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  draws the same scene to **PNG, SVG, or PDF**, picking the backend from
  the file extension — raster via
  [tiny-skia](https://github.com/linebender/tiny-skia), PDF via
  [krilla](https://github.com/LaurenzV/krilla), SVG hand-rolled. Output
  is byte-stable and snapshot-testable.
- [`display()`](https://r-vellum.github.io/vellum/reference/display.md)
  draws a scene into the active graphics device;
  [`scene_raster()`](https://r-vellum.github.io/vellum/reference/scene_raster.md)
  /
  [`scene_svg()`](https://r-vellum.github.io/vellum/reference/scene_svg.md)
  return the rendered scene in memory.

### Grobs, units, and layout

- Vectorised drawing primitives (rect, circle, points, segments, lines,
  path, polygon, text, raster, …) that batch internally.
- A unit system ([`unit()`](https://rdrr.io/r/grid/unit.html),
  `grobwidth`, …) and nested
  [`viewport()`](https://rdrr.io/r/grid/viewport.html)s with their own
  scales, rotation, and arbitrary-path clipping, plus a row/column
  layout solver with `"null"` (flexible) tracks.

### Paint model

- A modern paint model shared across all backends: linear and radial
  **gradients**, tiling **patterns**, alpha/luminance **masks**, group
  opacity (`viewport(alpha =)`), reusable
  [`style()`](https://r-vellum.github.io/vellum/reference/style.md)s,
  and hand-drawn
  [`sketch()`](https://r-vellum.github.io/vellum/reference/sketch.md)
  rendering.

### Text

- Device-independent shaping and measurement through
  [textshaping](https://github.com/r-lib/textshaping) /
  [systemfonts](https://github.com/r-lib/systemfonts) — the same stack
  as ragg/svglite — with per-glyph fallback, justification, and
  rotation, plus Markdown-style rich labels via
  [`md()`](https://r-vellum.github.io/vellum/reference/md.md).

### Big data

- [`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)
  aggregates millions of points into a density raster in a single pass —
  cost scales with output pixels, not point count — with no overplotting
  and small output files.

### Retained scene graph

- Because the scene is retained rather than drawn-and-forgotten, it can
  be queried and edited:
  [`node_names()`](https://r-vellum.github.io/vellum/reference/node_names.md)
  /
  [`get_node()`](https://r-vellum.github.io/vellum/reference/node_names.md)
  /
  [`edit_node()`](https://r-vellum.github.io/vellum/reference/node_names.md),
  [`hit_test()`](https://r-vellum.github.io/vellum/reference/hit_test.md)
  to pick the topmost grob under a point, and
  [`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
  to serialize a per-element model (data keys, bounding boxes) — the
  foundation the `vellumplot` grammar and the `vellumwidget` widget
  layer build on.

### Interop

- [`as_vellum()`](https://r-vellum.github.io/vellum/reference/as_vellum.md)
  /
  [`render_grid()`](https://r-vellum.github.io/vellum/reference/as_vellum.md)
  render an existing `grid` grob tree — including **ggplot2** and
  **lattice** — through the vellum backend.

### Under the hood

- The R package wires to a Rust crate via
  [extendr](https://extendr.github.io/); crates are vendored for
  offline/CRAN builds.
