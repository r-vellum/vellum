# Changelog

## vellum (development version)

- **Faster, leaner keyed SVG emission.** Emitting a scene to SVG with
  per-element `data-key`s (the interactivity attributes) now writes each
  element straight into the output buffer instead of building and
  copying an intermediate string per element, memoises the `fill`
  attribute across a batch’s shared paint, holds the current element key
  as an `Rc<str>`, and skips escaping work for keys/ids/labels that
  contain no XML metacharacters (the common case). Output is
  byte-identical; a 150k-point keyed scatter’s
  [`scene_svg()`](https://r-vellum.github.io/vellum/reference/scene_svg.md)
  is ~12% faster with substantially fewer per-element allocations.

- **[`vl_strwidth()`](https://r-vellum.github.io/vellum/reference/vl_strwidth.md)
  /
  [`vl_strheight()`](https://r-vellum.github.io/vellum/reference/vl_strwidth.md)
  measure [`md()`](https://r-vellum.github.io/vellum/reference/md.md)
  labels.** Both now accept a rich label from
  [`md()`](https://r-vellum.github.io/vellum/reference/md.md) (or a list
  of them) in addition to character strings, measuring it through the
  same run composition the renderer draws — so super/subscripts and bold
  runs reserve the space they actually occupy.
  `family`/`fontface`/`fontsize` supply the base style the label’s runs
  are relative to. Previously a caller had to reduce a rich label to
  plain text (and
  [`as.character()`](https://rdrr.io/r/base/character.html) on an
  [`md()`](https://r-vellum.github.io/vellum/reference/md.md) object
  errors), so downstream layout code that measured a rich title got zero
  width and clipped it.

- **Line & segment datashading.**
  [`datashade_lines()`](https://r-vellum.github.io/vellum/reference/datashade_lines.md)
  and
  [`datashade_segments()`](https://r-vellum.github.io/vellum/reference/datashade_lines.md)
  extend the aggregate-then-shade engine from point clouds to dense
  lines. A new anti-aliased Rust line rasteriser accumulates coverage
  per grid cell (overlapping lines *add*), so a bundle of hundreds of
  timeseries or a graph of tens of thousands of edges renders at cost
  decoupled from the vertex count, as one
  [`raster_grob()`](https://r-vellum.github.io/vellum/reference/grob.md).
  [`datashade_lines()`](https://r-vellum.github.io/vellum/reference/datashade_lines.md)
  takes a connected polyline with an optional `group` id (packing many
  series into one call; `NA` also breaks the line);
  [`datashade_segments()`](https://r-vellum.github.io/vellum/reference/datashade_lines.md)
  takes independent `(x0,y0)->(x1,y1)` segments (the network-edge case).
  Both share
  [`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)’s
  `colors`/`how`/`span`/`clip` shading and per-line `weight`. See the
  *Datashading* article and `inst/examples/lines.R`.

- **Pixel spreading
  ([`spread()`](https://r-vellum.github.io/vellum/reference/spread.md) /
  [`dynspread()`](https://r-vellum.github.io/vellum/reference/dynspread.md)).**
  Dilate the non-empty pixels of any raster grob so thin marks stay
  visible — datashader’s `spread` (fixed radius) and `dynspread` (radius
  chosen from image density). Available standalone, or via a `spread =`
  argument on the `datashade*` functions (`spread = 2` for a fixed
  radius, `spread = "auto"` for dynspread).

- **Focal / two-circle radial gradients.**
  [`radial_gradient()`](https://r-vellum.github.io/vellum/reference/gradients.md)
  gained `fx`, `fy`, `fr` — the *focal* (start) circle at stop offset 0,
  distinct from the *outer* (end) circle `cx`/`cy`/`r` at offset 1.
  Offsetting `fx`/`fy` moves the highlight off-centre (a sphere lit from
  one side); a non-zero `fr` gives an annular ramp between the two
  circles. This matches grid’s two-circle
  [`radialGradient()`](https://rdrr.io/r/grid/patterns.html) (the
  previous concentric-only form could only place the highlight
  dead-centre). The defaults (`fx = cx`, `fy = cy`, `fr = 0`) are the
  old concentric behaviour and are byte-for-byte unchanged on every
  backend. Rendered identically on raster (tiny-skia two-point conical),
  SVG (`<radialGradient fx fy fr>`), and PDF (krilla). See
  `inst/examples/gradients.R`.

- **Hue-preserving (OKLCH) gradient interpolation.**
  [`linear_gradient()`](https://r-vellum.github.io/vellum/reference/gradients.md)
  and
  [`radial_gradient()`](https://r-vellum.github.io/vellum/reference/gradients.md)
  now also accept `interpolation = "oklch"`, the polar form of Oklab
  (lightness, chroma, hue). Hue and chroma move independently, so a ramp
  between two saturated colours keeps its chroma through the middle
  instead of desaturating toward grey the way a straight line in Oklab
  can — the hue sweeps along the shorter arc (blue→yellow passes through
  green). An achromatic endpoint (grey/black/white) borrows the other
  end’s hue, so ramps to/from white don’t flash an arbitrary colour.
  Like `"oklab"` it is pre-sampled into dense sRGB stops in the Rust
  core, so it renders identically on the raster, SVG, and PDF backends
  with no new dependency. See `inst/examples/gradient-interpolation.R`
  for a side-by-side of all three spaces.

- **Perceptual (Oklab) gradient interpolation.**
  [`linear_gradient()`](https://r-vellum.github.io/vellum/reference/gradients.md)
  and
  [`radial_gradient()`](https://r-vellum.github.io/vellum/reference/gradients.md)
  gained `interpolation = "oklab"`, which blends the stops in the
  perceptually-uniform Oklab space instead of sRGB — removing the muddy,
  over-dark midtones and hue drift of sRGB blending (a blue→yellow ramp
  no longer passes through a grey dead-zone). It works identically on
  the raster, SVG, and PDF backends: the stops are pre-sampled in Oklab
  into dense sRGB stops, so no backend colour-space support is needed.
  The default is `"srgb"` and is byte-for-byte unchanged. (Implemented
  directly, with no new crate dependency.)

- **Two new marker shapes: `"triangle_down"` and `"star"`.**
  `points_grob(shape=)` now accepts a downward-pointing triangle and a
  five-pointed star in addition to
  `circle`/`square`/`triangle`/`diamond`/`plus`/`cross`. Like the other
  filled shapes they paint `gp$fill` and outline with `gp$col` (so an
  *open* marker is `fill = NA` with a `col`), and they take the same
  solid-fill fast path. The grid-device shim now maps `pch` 6/25 to
  `triangle_down` (previously collapsed onto the up-triangle) and `pch`
  8 to `star`.

- **Slimmer Rust dependency tree.** Bumped the direct `tiny-skia` (0.11
  → 0.12) and `skrifa` (0.31 → 0.42) crates to the versions the `krilla`
  PDF backend already pulls in. This collapses six duplicated transitive
  crates (`skrifa`, `read-fonts`, `font-types`, `tiny-skia-path`, `png`,
  and `bitflags` were each compiled twice), taking the vendored tree
  from 75 to 69 crates for a smaller source tarball and a faster build.
  Rendered output is unchanged — the raster snapshots are
  pixel-for-pixel identical — and the minimum Rust version is still
  1.92.

## vellum 0.3.0

- **Categorical datashading (`datashade(category=)`).**
  [`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)
  gained a `count_cat` mode: pass `category` (a factor or vector, one
  value per point) and each category is aggregated into its own count
  grid in the same single pass, then every cell is coloured by the
  **count-weighted average** of the category hues it holds, with opacity
  from the cell’s total density. This shows which category dominates
  where — and where categories mix — without overplotting bias, in one
  call instead of a hand-stacked layer per category. When `category` is
  set, `colors` is a per-category hue vector (named by level, or one per
  level in level order) rather than a low-to-high ramp. Backed by a new
  `rs_aggregate_2d_cat()` Rust aggregator (one O(N) pass, category-major
  grid). A
  [`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)
  call with no `category` renders byte-for-byte as before.

- **Percentile / span colour clamping for
  [`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md).**
  New `span` (absolute `c(lo, hi)` density limits) and `clip` (a
  percentile pair like `c(0.01, 0.99)`, derived from the non-empty cell
  quantiles) clamp the density range before the `how` transform, so a
  few extreme cells no longer flatten the rest. Both default `NULL`
  (unchanged output). The shade step is now a reusable internal colormap
  utility shared by the density and categorical paths.

## vellum 0.2.0

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
