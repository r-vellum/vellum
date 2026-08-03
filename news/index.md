# Changelog

## vellum 0.6.7.9000

- **Fix: knitting a scene with a `dpi` chunk option errored.** A YAML
  `dpi: 150` parses as an `<integer>`, and the display path passed it
  straight to the scene’s `@dpi` property, which is declared
  `<double>` - S7 rejected it with
  `@dpi must be <double>, not <integer>`. The chunk dpi is now coerced.

## vellum 0.6.7

- **Fix: an animated SVG showed one frame and then near-nothing.** Every
  frame is rendered separately, so each restarted its `<defs>` id
  counters and the whole document ended up with N copies of `id="c0"`.
  All N `clip-path="url(#c0)"` references therefore resolved to the
  *first* frame’s clip — which lives inside a `visibility:hidden` group,
  and a hidden `<clipPath>` child contributes no geometry, so the clip
  was empty for the 47/48 of the cycle when frame 0 was hidden.
  Everything inside the panel was clipped away, leaving only the axis
  labels and legend drawn outside it, and the plot appeared to blink
  once and then vanish. Generated `<defs>` ids now carry a per-frame
  prefix.

- **Fix: animated SVG frames played in reverse.** The per-frame negative
  `animation-delay` was offset by `i` rather than `n - i`, so after
  frame 0 the cycle ran backwards (0, n-1, n-2, …).

- **Fix: a gradient (or pattern) `col` collapsed to its first stop on
  circle outlines.** Circles take a batched fast path that draws a unit
  circle placed by an affine transform; a gradient stroke is resolved in
  viewport pixels, so on the unit circle it sampled a single point of
  the ramp and rendered one flat colour. The same gradient stroked rects
  and polylines correctly. A gradient/ pattern stroke now drops circles
  to the per-element, real-coordinate build (as rects already did), so
  the ramp runs along the outline. Solid strokes keep the fast path and
  render byte-identically.

- **[`svg_grob()`](https://r-vellum.github.io/vellum/reference/vl_svg_path.md)
  can size an icon to its `viewBox`, and read a whole `<svg>`.** Icon
  sets share one `viewBox` per family and pad each glyph inside it, so
  sizing to the glyph’s own *ink* blew every icon up to `size`
  individually — a sparse glyph rendered far larger than a dense one
  from the same set, and a lone icon larger than its nominal box (the
  reported ~2.5× oversize).
  [`svg_grob()`](https://r-vellum.github.io/vellum/reference/vl_svg_path.md)
  now takes a `viewbox` argument (`c(xmin, ymin, width, height)`, or the
  raw `"0 0 24 24"` attribute string) and maps the *box* to `size`, so
  glyphs keep their intended relative and absolute size. Passing a whole
  `<svg>…</svg>` element as `d` reads its `<path>` geometry and
  `viewBox` automatically (needs ; non-`<path>` shapes are reported, not
  silently dropped). With no viewBox the previous ink-bounds sizing is
  unchanged.

## vellum 0.6.6

- **Fix:
  [`element_geometry()`](https://r-vellum.github.io/vellum/reference/element_geometry.md)
  and
  [`vl_nearest()`](https://r-vellum.github.io/vellum/reference/vl_nearest.md)
  reported viewport-local coordinates, not device pixels.** The pick
  table resolved every vertex through `vp.x_pos()`/`y_pos()` — which
  answer in the viewport’s own frame — and never applied the viewport’s
  transform. So for any viewport not at the page origin, which is every
  panel of every real plot:

  - [`element_geometry()`](https://r-vellum.github.io/vellum/reference/element_geometry.md)
    was off by the viewport’s offset, and *internally inconsistent*:
    `text` and `roundrect` rows went through `node_bbox()` and came back
    in device px, while `segment` / `line` / `polygon` / `path` /
    `point` / `rect` rows stayed local. One table, two coordinate
    systems.
  - [`vl_nearest()`](https://r-vellum.github.io/vellum/reference/vl_nearest.md)
    compared a **device-px** probe point against those local
    coordinates, so its answers in an offset panel were not merely
    imprecise but wrong — it would report a mark at distance 0 with the
    cursor nowhere near it, and rank the mark actually under the cursor
    far down the list.

  Both now report device pixels with y down, matching
  [`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)’s
  boxes and the rendered SVG, as documented. A round mark’s radius takes
  the transform’s scale as well as its translation.

  This is the same bug `lint_table()` had before 0.6.1, and it survived
  for the same reason: every test in `test-pick.R` drew into the default
  full-page viewport, where the transform is the identity and local *is*
  device. The regression tests added here use an off-origin viewport.

  Nothing rendered changes — the pick table feeds no drawing path.

- **Docs fix: the leader-line example placed labels and drew leaders
  from two different solves.**
  [`vignette("placement")`](https://r-vellum.github.io/vellum/articles/placement.md)
  and `inst/examples/labels.R` both computed `vl_place(scene)`, drew
  leaders from that answer, and *then* called
  [`vl_repel()`](https://r-vellum.github.io/vellum/reference/vl_place.md)
  on the scene with the leaders already in it. The leaders are obstacles
  to that second solve — and since each one lies exactly along the path
  its label wanted to take, and
  [`vl_place()`](https://r-vellum.github.io/vellum/reference/vl_place.md)
  works on bounding boxes (so a diagonal segment blocks the whole
  rectangle spanning it), the labels were pushed back the way they came.
  The median leader ended up **146°** from the label’s real
  displacement, with half of them pointing essentially backwards.

  Both now place first and annotate afterwards, which makes the leaders
  exact, and both say why. No engine change —
  [`vl_repel()`](https://r-vellum.github.io/vellum/reference/vl_place.md)
  was applying the solve it reported all along. The general rule, now
  stated in the article: **anything you add to a scene becomes an
  obstacle to a later solve.**

## vellum 0.6.5

- **[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)’s
  contrast rule no longer cries wolf on ordinary axis text.** It sampled
  the backdrop at four points just outside a label’s box and took the
  *worst*, so any label a single 2 px probe happened to graze against a
  nearby tick, gridline or axis rule read as ~1:1 — flagging dark axis
  text on white on essentially every plot. It now takes the
  **second-worst** of the four sides: incidental adjacent ink on one
  side is ignored, while a label genuinely on a low-contrast field (all
  sides) or straddling a dark region (two sides) is still flagged.

- **Gridlines (`role = "grid"`) are treated as decorative in tagged
  PDF.** A node with `role = "grid"` — the role a downstream sets so an
  interactive SVG host can find and hide the gridlines — is now a PDF
  *artifact* (skipped by a screen reader) alongside
  `"presentation"`/`"none"`/`"decorative"`, rather than a bogus `Figure`
  in the structure tree. The SVG role is unchanged, so the host selector
  still works. Found while wiring `vellumplot`’s accessibility pass.

## vellum 0.6.4

- **Fixed:
  [`grobwidth()`](https://r-vellum.github.io/vellum/reference/grobwidth.md)/[`grobheight()`](https://r-vellum.github.io/vellum/reference/grobwidth.md)
  of a width-constrained
  [`text_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  ignored the wrapping.** The renderer wraps a `text_grob(width=)` to
  its box and auto-fits when `fit=` is set, but the measurement path
  (`.grob_extent()`, what a `grobheight`/`grobwidth` unit resolves to)
  measured the *unwrapped* line. So a layout track sized by
  [`grobheight()`](https://r-vellum.github.io/vellum/reference/grobwidth.md)
  reserved a single line for a label that drew as several, and the
  wrapped text overran whatever sat above it. Extent now wraps the label
  to `width` (in mm), stacks the resulting lines, and applies the same
  auto-fit shrink as drawing — so a reserved region matches the glyphs
  that land in it. Plain labels only; rich
  [`md()`](https://r-vellum.github.io/vellum/reference/md.md) labels are
  unchanged (the renderer does not width-wrap them either). Found while
  wiring wrapped plot titles/subtitles/captions in `vellumplot`.

## vellum 0.6.3

- **Fixed: a keyed multi-box
  [`roundrect_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  aborted
  [`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md),
  and a keyed one silently dropped every key past the first.**
  [`roundrect_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  is a batch — one rounded box per `(x, y, width, height, r)` element —
  but it recycled `key`/`meta` to length 1, so
  `roundrect_grob(key = c("a", "b"))` kept only `"a"`. And
  [`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
  classed roundrect as a single shape (one row per grob), so a grob
  drawing N keyed boxes reported one element against the backend’s N and
  aborted on the count check. Roundrect is now a keyed batch, like
  [`text_grob()`](https://r-vellum.github.io/vellum/reference/grob.md):
  each keyed box is one
  [`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
  row carrying its own key/meta, and an unkeyed roundrect stays out of
  the model. Rendering is unaffected
  ([`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
  is interactivity metadata only). Found while wiring keyed data-label
  backgrounds in `vellumplot`.

## vellum 0.6.2

- **Fixed (breaking):
  [`vl_contour()`](https://r-vellum.github.io/vellum/reference/vl_contour.md)
  transposed its input matrix.** It assumed rows indexed y and
  columns x. Base R is the opposite —
  [`image()`](https://rdrr.io/r/graphics/image.html),
  [`contour()`](https://rdrr.io/r/graphics/contour.html),
  [`persp()`](https://rdrr.io/r/graphics/persp.html) and
  [`contourLines()`](https://rdrr.io/r/grDevices/contourLines.html) all
  take `dim(z) == c(length(x), length(y))`, i.e. **rows index x** — and
  that is also the shape `outer(xs, ys, f)` produces, which is how a
  grid is normally built.

  So every contour came back reflected across the diagonal. On a
  symmetric surface that is invisible; over a density with a reference
  layer under it, it is obvious. The documentation compounded it by
  citing [`image()`](https://rdrr.io/r/graphics/image.html) as the
  authority for the opposite of what
  [`image()`](https://rdrr.io/r/graphics/image.html) does.

  [`vl_contour()`](https://r-vellum.github.io/vellum/reference/vl_contour.md)
  now matches base R. **If you were transposing your matrix to work
  around this, stop.** Code that passed `outer(xs, ys, f)` directly was
  getting transposed output and is now correct with no change.

  The test suite missed it because every contour test used a grid
  symmetric in its two arguments. The new tests use an asymmetric
  surface and check against
  [`grDevices::contourLines()`](https://rdrr.io/r/grDevices/contourLines.html)
  rather than against our own expectation.

## vellum 0.6.1

- **Fixed: node bounding boxes were viewport-local, not device
  coordinates.** `lint_table()` resolved a node’s box through its
  viewport’s *scales* but never applied the viewport’s own *placement*,
  so for any viewport not at the page origin it disagreed with
  `element_table()` by the viewport’s offset — which is every real plot
  with a panel.

  Everything built on it inherited the error.
  [`vl_repel()`](https://r-vellum.github.io/vellum/reference/vl_place.md)
  solved labels against obstacles it believed were elsewhere, so on a
  panelled scatter it left labels sitting on top of the very markers it
  was asked to avoid (22 of 22 in the regression case, now 0).
  [`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)’s
  `offscreen` and `low_contrast` rules looked at the wrong part of the
  page, and
  [`vl_nearest()`](https://r-vellum.github.io/vellum/reference/vl_nearest.md)
  misplaced text and rounded rects.

  It was invisible in the test suite because tests draw into the default
  full-page viewport, where the transform is the identity and local *is*
  device.
  [`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
  was never affected — it takes geometry from `element_table()`, which
  was correct — so `vellumwidget` is unaffected.

## vellum 0.6.0

Six phases of engine work: a typography layer, label placement, geometry
operations, accessible output, new output destinations, and addressable
marks. Every mark family can now carry a data key, text can be wrapped
or set along a curve, labels can be repelled, paths can be combined,
PDFs are tagged, and scenes render to animated SVG, multi-page PDF or a
parallel batch.

Verified byte-identical across 11 scenes and 4 output paths throughout,
except where a fix deliberately changed output (noted below).

- **Fixed:
  [`vl_repel()`](https://r-vellum.github.io/vellum/reference/vl_place.md)
  was defeated by a panel background.** The default obstacle set is
  “everything that is not a label”, which on a real plot includes the
  panel background rectangle — and a label inside it collides with it
  wherever it goes, so it could never be placed. On a two-panel scene,
  29 of 32 labels were unresolvable; now 2.

  An obstacle that wholly contains a label is no longer treated as an
  obstacle for that label. That is also right for a bar or region a
  label deliberately annotates from the inside, where pushing the label
  out would be exactly wrong.

- **Fixed:
  [`vl_repel()`](https://r-vellum.github.io/vellum/reference/vl_place.md)
  could push labels off the page.** Resolving a collision by shoving a
  label off the canvas is strictly worse than the collision — an
  overlapping label is hard to read, an off-canvas one is gone. Solved
  positions are now bounded by the label’s clip region intersected with
  the page, widened to include its own anchor so a label deliberately
  placed off-page stays put.

- **Fixed: a halo ate the neighbouring glyphs on
  [`text_path_grob()`](https://r-vellum.github.io/vellum/reference/text_path_grob.md).**
  Placing each glyph as its own draw broke the rule that every glyph is
  stroked before any is filled, so each halo painted over the previous
  glyph’s fill. Haloed text on a curve is now stroked in one pass and
  filled in another, as straight text already was.

- **Fixed:
  [`render_all()`](https://r-vellum.github.io/vellum/reference/render_all.md)
  ignored `_R_CHECK_LIMIT_CORES_`.** `R CMD check` sets it and
  [`parallel::mclapply()`](https://rdrr.io/r/parallel/mclapply.html)
  errors above two processes under it, so any package depending on
  vellum would have failed its own check.

- **Every mark family can now carry an element `key`.**
  [`lines_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
  [`polygon_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
  [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
  [`roundrect_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  and
  [`text_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  gain `key`/`meta`, joining the batched marks that already had them;
  [`bezier_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
  [`spline_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
  [`svg_grob()`](https://r-vellum.github.io/vellum/reference/vl_svg_path.md)
  and
  [`contour_grob()`](https://r-vellum.github.io/vellum/reference/vl_contour.md)
  inherit it.

  A key is what makes a mark addressable — it becomes `data-key` in the
  SVG and a row in
  [`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md).
  Until now a line, an area, a choropleth region or a data label could
  not carry one, so they could never be hovered, tooltipped, brushed or
  cross-filtered by an interactive host. Now a whole series can be one
  addressable thing.

  Keyed text reports one element per label. Note the deliberate
  asymmetry with the batched marks: lines, polygons, paths and text
  appear in
  [`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
  **only when keyed**, because a plot is full of unkeyed gridlines and
  axis labels that would otherwise bury the marks that mean something.

- **[`vl_nearest()`](https://r-vellum.github.io/vellum/reference/vl_nearest.md)
  and
  [`element_geometry()`](https://r-vellum.github.io/vellum/reference/element_geometry.md)
  — hit-testing that respects the shape.** A bounding box is the right
  answer for a rectangular brush and the wrong one for anything diagonal
  or thin: a line across a panel has a bounding box covering the whole
  panel, so a box-based “what is nearest” matches it from anywhere in
  the plot.

  [`vl_nearest()`](https://r-vellum.github.io/vellum/reference/vl_nearest.md)
  measures to the real geometry — perpendicular to a segment, to the
  disc for round marks, and **zero anywhere inside** a closed polygon,
  so clicking the middle of a choropleth region hits the region.

  [`element_geometry()`](https://r-vellum.github.io/vellum/reference/element_geometry.md)
  returns that geometry instead of the answer, for hosts that cannot
  call R on every mouse move: a browser takes the vertices once and
  computes distances locally.

- **Animated SVG.** `vl_render_animation(format = "svg")` emits the same
  keyframe schedule as vector markup, shown in turn by a CSS step
  animation — resolution-independent, and honouring
  `prefers-reduced-motion`.

  Choose it by scene complexity, not by preference. Every frame is
  emitted in full, so size grows with complexity times frame count where
  a raster format’s does not. Measured on a 30-frame scatter, gzipped:
  20 marks → 20 KB vs GIF’s 61 KB; 2000 marks → 720 KB vs GIF’s 124 KB.
  Line art wins clearly; dense marks do not. Above 5 MB vellum warns
  rather than letting you find out later.

- **[`pdf_pages()`](https://r-vellum.github.io/vellum/reference/pdf_pages.md)
  — several scenes as the pages of one PDF.** A report’s figures, one
  facet per page, an animation as a contact sheet. Pages may differ in
  size, and each page’s tagging survives into the document’s structure
  tree.

- **[`render_all()`](https://r-vellum.github.io/vellum/reference/render_all.md)
  — render many scenes across cores.** Embarrassingly parallel, one
  whole scene per worker. About 3× on four report figures, and asserted
  byte-identical to rendering them one at a time. Named scenes plus a
  directory names the files.

- **Fixed: a tagged multi-page PDF orphaned its earlier pages’
  structure.** A document has exactly one tag tree; each page was
  setting its own, discarding the previous. Found by building
  [`pdf_pages()`](https://r-vellum.github.io/vellum/reference/pdf_pages.md),
  and only reachable there.

- **Tagged PDF output.** The per-mark `id`/`role`/`name` channel now
  builds a PDF structure tree: a `StructTreeRoot`, a `Figure` for the
  plot as a whole carrying the
  [`describe()`](https://r-vellum.github.io/vellum/reference/describe.md)
  text, and one structure element per marked-up mark, in draw order —
  which for a graphic is reading order.

  This needs no new annotation API: a scene already marked up for the
  web is already marked up for PDF. `role = "presentation"` marks a node
  a PDF *artifact*, so gridlines and panel backgrounds are skipped by
  assistive technology rather than read aloud.

  Structure is metadata — the rendered pixels are unchanged — and a
  scene with no marked-up nodes produces exactly the PDF it always did.

- **[`scene_fonts()`](https://r-vellum.github.io/vellum/reference/scene_fonts.md),
  [`font_pin()`](https://r-vellum.github.io/vellum/reference/font_pin.md)
  and
  [`font_check()`](https://r-vellum.github.io/vellum/reference/font_pin.md).**
  vellum claims identical pixels on every OS and in CI. Layout, shaping
  and rasterisation deliver that; font *resolution* does not and cannot,
  since `"sans"` is a different file on every platform.

  These make that gap visible rather than pretending it away:
  [`scene_fonts()`](https://r-vellum.github.io/vellum/reference/scene_fonts.md)
  reports the faces the text actually resolved to (read off the shaped
  glyphs), and a pin next to a reference image lets a failing comparison
  be attributed — your change, or the machine’s fonts.

  They deliberately do not bundle fonts. vellum resolves through so it
  agrees with the rest of R’s graphics stack; for a guarantee rather
  than a check, register the exact file with
  [`systemfonts::register_font()`](https://systemfonts.r-lib.org/reference/register_font.html).

- **[`vl_path_op()`](https://r-vellum.github.io/vellum/reference/vl_path_op.md)
  — boolean operations on paths.** Union, intersection, difference and
  exclusive-or over closed rings.

  The result is **geometry**, not a render-time mask, and that is the
  point: it is an ordinary path, so it can be measured, hit-tested,
  simplified, filled with its own gradient, stroked along the boundary
  the operation created, exported as `<path>` data, and used as the
  operand of another boolean. A clip can do none of those, rasterises,
  and degrades on some PDF paths.

  `rule` describes how to read the **inputs** — whether a ring inside
  another is a hole or an island — and operands must be in a single
  coordinate space, since a boolean has to be computed somewhere.

- **[`vl_contour()`](https://r-vellum.github.io/vellum/reference/vl_contour.md)
  and
  [`contour_grob()`](https://r-vellum.github.io/vellum/reference/vl_contour.md)
  — contours from a grid.** Marching squares over any matrix, with
  saddle cells resolved from the centre value rather than an arbitrary
  fixed choice, and cells with missing corners skipped so a contour
  breaks around a hole instead of being drawn through it.

  Segments are chained into continuous polylines. Under a solid stroke
  that is invisible; for everything else it is not — an unchained
  contour restarts its dash pattern in every grid cell and cannot be
  simplified, measured or closed. Closed contours come back marked
  `closed`, so a filled density contour is a
  [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  away.

- **[`svg_grob()`](https://r-vellum.github.io/vellum/reference/vl_svg_path.md)
  and
  [`vl_svg_path()`](https://r-vellum.github.io/vellum/reference/vl_svg_path.md)
  — SVG path data as scene geometry.** The full `d` grammar, including
  relative forms, implicit repeated commands, the smooth-curve
  reflection rules, and elliptical arcs with the packed flag form
  minified icon files use. Icon sets ship one `<path d="...">` per
  glyph, so this is what makes crisp vector markers possible.

  It reads path *data*, not SVG documents — no stylesheets, gradients,
  `<use>`, clip paths or element transforms. Use an XML parser to pull
  `d` strings out of a file.

- **Fixed:
  [`draw()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  accepted a list of grobs and then failed to compile it.** The list was
  appended as one child and the failure surfaced much later as
  `Can't find method for compile(<list>)`. A list now draws each
  element.

- **[`lines_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  now rejects a multi-value `id`.** Its `id` is the accessibility
  identifier, but
  [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)’s
  is a *grouping* variable — the same argument name with the opposite
  meaning. Passing a grouping vector by analogy silently drew one
  polyline through every group, joining them with straight lines across
  the plot.

- **[`vl_repel()`](https://r-vellum.github.io/vellum/reference/vl_place.md)
  /
  [`vl_place()`](https://r-vellum.github.io/vellum/reference/vl_place.md)
  — label placement as an engine service.**
  [`vl_place()`](https://r-vellum.github.io/vellum/reference/vl_place.md)
  solves label collisions over a scene’s resolved geometry and reports
  each label’s displacement;
  [`vl_repel()`](https://r-vellum.github.io/vellum/reference/vl_place.md)
  applies it and returns a new scene.

  The solve runs in device pixels and the answer is applied as an
  absolute millimetre offset on top of each label’s existing coordinate.
  That is what makes it coordinate-system-agnostic: a label anchored in
  `native` units inside a polar, faceted or warped panel moves by the
  same mechanism as one in `npc` on the page, and every panel is solved
  together rather than one at a time.

  It moves labels; it does not decide which to drop, shrink or
  abbreviate. Labels that cannot be placed are reported with
  `resolved = FALSE` rather than silently piled up or quietly deleted —
  that call needs to know what the labels mean, and belongs above the
  engine.

- **[`vl_empty_region()`](https://r-vellum.github.io/vellum/reference/vl_empty_region.md)
  — the largest empty rectangle in a scene.** Where a legend, annotation
  or watermark can go. Occupancy is rasterised onto a grid, so the
  answer is exact on that grid and conservative off it: boxes round
  outward, and it will never claim space that is in fact occupied. It
  reports millimetres on request, which is the absolute measure
  `text_grob(width = )` wants — so an annotation can be fitted to the
  gap that was just found.

- **[`vl_hull()`](https://r-vellum.github.io/vellum/reference/vl_hull.md)
  and
  [`vl_buffer()`](https://r-vellum.github.io/vellum/reference/vl_buffer.md).**
  Convex and concave hulls of a point set, and outward offsetting of a
  ring — for outlining a cluster and building the exclusion zone around
  it. Note that `concavity` runs the opposite way to what the name
  suggests: larger is *more* convex, `Inf` is the convex hull, and below
  about 3 the boundary starts to self-intersect.

- **`element_table()` gains `name`, `kind` and a node index**, and
  `lint_table()` gains the matching node index, so the per-element and
  per-node views of a scene can be joined. Without this a batched mark
  is a single node whose box is the union of every element, which makes
  a scatter read as one panel-sized obstacle.

- **Text that fits a box.** `text_grob(width = )` wraps a label to an
  absolute measure; `align` sets `"left"` / `"centre"` / `"right"` /
  `"justify"` within the box; `fit = TRUE` shrinks the font until the
  wrapped block fits `width` × `height`.

  Break decisions are made on the **shaped** width of each candidate
  line rather than a sum of word advances, so kerning and any active
  OpenType feature are accounted for and a line can never render wider
  than it measured. That is what makes auto-fit trustworthy rather than
  approximate.

  `width` must be an absolute unit (`mm`/`cm`/`in`/`pt`), and relative
  units are rejected with an explanation. Wrapping happens when the grob
  is *built*, and a viewport’s size in `npc`/`native` does not exist
  until render time — which is also the reason this cannot be built on
  grid at all, where a string has no width until a device is open.

- **[`text_path_grob()`](https://r-vellum.github.io/vellum/reference/text_path_grob.md)
  — text set along a curve.** Each glyph keeps the pen position shaping
  gave it and is placed that far along a polyline baseline, rotated to
  the local tangent. `offset` sets a perpendicular standoff.

  Halos, OpenType features, per-glyph colour and clipping all still
  apply, and all three backends handle it — SVG stays real `<text>`, PDF
  stays copyable. Glyphs follow the tangent as in SVG `textPath`, so a
  label on the underside of a closed curve reads upside-down; reverse
  the *path* to fix that, not the glyphs.

- **Fixed: multi-line text hung below its anchor.** A block of *n* lines
  was centred `(n-1)·lineheight/2` too low — at 12 pt a six-line block
  sat half an inch below where it should. Vertical justification is now
  correct at top, centre and bottom for any line count. **This changes
  the rendering of existing multi-line labels.**

- **Fixed: multi-line text collapsed to one line in SVG.** SVG `<text>`
  ignores newlines, and vellum emitted one element per label, so a
  multi-line label rendered as a single run of text with the breaks
  turned into spaces. Each line is now its own element. Single-line
  labels are untouched, and a label whose lines cannot be matched to its
  glyphs (a blank line, which produces none) falls back to glyph
  outlines rather than guessing.

- **Per-segment stroke style.** `segments_grob(col = , lwd = )` take one
  value per segment, mirroring the per-element `fill` that
  [`hexagon_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  and
  [`sector_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  already carry. Previously varying either meant building **one grob per
  segment**, and grob construction is the dominant expense on scenes
  made of many small marks.

  A single grob with per-element style renders byte-identically to N
  grobs each with its own `gp` (asserted in tests). No backend can
  stroke segments differently in one call, so each is still stroked on
  its own in the output — the saving is in R, not in the file size.
  Absent, the batch draws in one combined stroke exactly as before.

- **[`vl_hatch()`](https://r-vellum.github.io/vellum/reference/vl_hatch.md)
  — hatch fills as geometry.** Fills a shape with ruled lines at a given
  angle, spacing and width. Unlike
  [`vl_pattern()`](https://r-vellum.github.io/vellum/reference/vl_pattern.md),
  which rasterises a tile, a hatch is real geometry: crisp at any zoom,
  correct in print, and emitted as `<path>` data in SVG rather than an
  embedded image.

  The reason it matters is accessibility. A categorical encoding that
  fails for a red/green-blind reader — which `render(cvd = )` shows you
  and
  [`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)
  flags — is fixed by encoding with **texture as well as hue**. vellum
  could already diagnose that problem; now it can solve it.

  It is expanded in the scene walk into stroked spans, computed by
  scanline crossing against the shape, so no backend needs a hatch
  primitive and only the spans actually inside the shape are emitted.

- **Fixed: `gp$fill` never reached
  [`hexagon_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  or
  [`sector_grob()`](https://r-vellum.github.io/vellum/reference/grob.md).**
  Those marks take a per-element fill *colour*, and the shared gpar fill
  was not passed to them at all — so a gradient or pattern there
  silently drew nothing. Both now fall back to the shared paint when no
  per-element `fill` is given, which means gradients, patterns and
  hatches work on them for the first time. An explicit per-element
  `fill` still takes precedence.

- New example `inst/examples/hatching.R`;
  [`vignette("scene-and-paint")`](https://r-vellum.github.io/vellum/articles/scene-and-paint.md)
  gains a hatching section and
  [`vignette("render-quality")`](https://r-vellum.github.io/vellum/articles/render-quality.md)
  now points at it as the fix its CVD section was missing.

- **A scene is now a value you can save, fingerprint, compare and
  compose.**
  [`scene_write()`](https://r-vellum.github.io/vellum/reference/scene_write.md)
  /
  [`scene_read()`](https://r-vellum.github.io/vellum/reference/scene_write.md)
  persist a built scene (`.rds`, or `.json` with jsonlite) and rebuild
  it to byte-identical pixels;
  [`as_scene_spec()`](https://r-vellum.github.io/vellum/reference/as_scene_spec.md)
  /
  [`from_scene_spec()`](https://r-vellum.github.io/vellum/reference/as_scene_spec.md)
  are the plain-list form underneath. The conversion is generic over the
  S7 property model rather than written per grob type, so a grob added
  later serializes with no change to the serializer.

  This is one level below `vellumplot`’s *plot* spec and composes with
  it: a plot spec is portable and re-renderable at any size, a scene
  spec reproduces exactly this scene.

- **[`scene_hash()`](https://r-vellum.github.io/vellum/reference/scene_hash.md)**
  fingerprints content — two independently-built identical scenes agree,
  any change to what is drawn does not. Usable as a cache key or a test
  assertion.

- **[`scene_diff()`](https://r-vellum.github.io/vellum/reference/scene_diff.md)**
  reports *what* changed, in scene terms
  (`root$children[1]$gp$fill: steelblue -> tomato`) rather than as a
  pixel diff. That makes it a better basis for visual-regression testing
  than comparing images, because an image diff is sensitive to the font
  stack and a structural one is not.

- **[`scene_inset()`](https://r-vellum.github.io/vellum/reference/scene_inset.md)**
  places one scene inside a region of another. Because a scene has a
  known resolved size this is a graft, not a re-render, and the result
  is an ordinary scene: the inset is an addressable node that can be
  edited by name, inset again, or serialized. The *policy* questions
  (should panel edges align? should axes be shared?) stay above vellum,
  in a grammar; the engine supplies the ability to nest at all.

- New article
  [`vignette("scenes-as-values")`](https://r-vellum.github.io/vellum/articles/scenes-as-values.md)
  and example `inst/examples/serialize.R`.

- **Gradient strokes.** `vl_gpar(col = linear_gradient(...))` strokes
  *with* a gradient — the same paint model `fill` already had, applied
  to the region the line covers instead of the region a shape encloses.
  A trajectory can carry its colour along itself, and it is real paint
  on every backend (a tiny-skia shader, SVG `stroke="url(#…)"`, a krilla
  shading) rather than the usual workaround of emitting hundreds of
  one-segment lines in slightly different flat colours. It applies to
  any stroked path, outlines included, and inherits from a viewport like
  every other stroke property.

  Text and markers fall back to the gradient’s first stop, because a
  glyph run has no path to run a ramp along; a *pattern* in `col` falls
  back to the colour, because a pattern needs cell geometry a stroke
  does not have.

- **`vl_gpar(dash_phase = )`** sets how far into the dash pattern a line
  starts, in multiples of `lwd` so it scales with the line width exactly
  as the nibbles do. Aligns dashes across adjacent strokes, and
  animating it gives marching ants. Reaches SVG as `stroke-dashoffset`
  and PDF as krilla’s dash offset.

- New example `inst/examples/strokes-paint.R`;
  [`vignette("scene-and-paint")`](https://r-vellum.github.io/vellum/articles/scene-and-paint.md)
  gains sections on stroking with a gradient and on dash phase.

- **Dense paths are simplified at render resolution.** A coastline or a
  long time series carries far more vertices than the canvas has pixels
  to distinguish; vellum now drops the ones that could not have changed
  a pixel. Worth **1.7–2.5× on render time and 65–75% of the SVG size**
  at 50,000 vertices. It is automatic, and the dial is
  `options(vellum.simplify)` — a Douglas–Peucker tolerance in device
  pixels, default `0.1`, `0` to disable. Only the renderer knows the
  output resolution, which is why this belongs here rather than in a
  data-preparation step.

  Like the marker-sprite and glyph-bitmap fast paths this is a
  deliberate fidelity trade, so it engages only where the win is real:
  paths under 1000 points per sub-path are never touched and stay
  byte-identical.

- **[`stroke_to_path()`](https://r-vellum.github.io/vellum/reference/stroke_to_path.md)**
  converts the stroke of a line-like grob into a
  [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  describing the region it covers — so a line can be filled with a
  gradient or a pattern, or handed to a cutting plotter that needs a
  closed shape rather than a centreline. It uses the same stroker the
  rasterizer uses, so the outline is exactly what would have been inked.
  The result is absolute (mm): an outline is a shape baked at one size,
  not a stroke that rescales.

- New example `inst/examples/geometry.R` and benchmark
  `inst/benchmarks/simplify.R`;
  [`vignette("scene-and-paint")`](https://r-vellum.github.io/vellum/articles/scene-and-paint.md)
  gains sections on filling a line and on dense paths.

- **[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)
  — static analysis for graphics.** Resolves the scene and inspects the
  geometry the renderer would draw with, reporting the things people
  otherwise find by squinting at a PNG: a mark that landed off-canvas or
  outside its viewport’s clip, an element nothing will paint (no fill,
  no stroke, or zero alpha), text below a legibility floor, overlapping
  labels, and text whose contrast against its actual rendered backdrop
  falls below the WCAG threshold. This is possible because vellum
  resolves layout and text metrics *before* drawing — a layer above grid
  cannot ask how many pixels tall a label is, because the answer does
  not exist until a device is open.

  The rule set is a registry:
  [`vl_lint_rule()`](https://r-vellum.github.io/vellum/reference/vl_lint_rule.md)
  lets a package layered on vellum add its own, so a grammar’s semantic
  rules and vellum’s geometric ones come back from one call.

- **[`scene_stats()`](https://r-vellum.github.io/vellum/reference/scene_stats.md)**
  reports ink coverage, distinct colours, and an **overplotting index**
  — the honest signal for “should this be
  [`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)-ed?”.
  A mark count says nothing about overlap: 2000 scattered points score
  4.3, the same 2000 clustered score 91.

- **[`profile_render()`](https://r-vellum.github.io/vellum/reference/profile_render.md)**
  attributes render cost to the marks that caused it, and splits
  **build** / **compile** / **raster**. Read the phase split first:
  compile time is R-side, and on scenes with many small grobs it
  dominates, in which case tuning the backend cannot help. Timing is
  armed only for that call, so ordinary renders pay nothing.

- New example `inst/examples/linting.R`.

- **Colour-vision-deficiency simulation.** `render(scene, path, cvd =)`,
  `scene_png(cvd =)` and `scene_raster(cvd =)` re-render the finished
  raster as a viewer with `"protanopia"`, `"deuteranopia"`,
  `"tritanopia"` or `"achromatopsia"` would see it, using the Machado et
  al. (2009) matrices applied in **linear light** (doing it in sRGB is
  the common shortcut and it shifts lightness). An accessibility check
  becomes an argument rather than an export-and-upload round trip.
  Raster only – a vector format has no pixels to transform, and
  [`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  says so rather than silently writing an unsimulated file. The
  simulation is never written into the render cache.

- **Blur, drop shadow and glow as group effects.** `vl_viewport(blur =)`
  and `vl_viewport(shadow = vl_shadow(dx, dy, blur, col))` act on the
  composited layer, so overlapping shapes inside a viewport blur – or
  cast a single shadow – *together* rather than each shadowing the
  others. A glow is a shadow with no offset. Raster convolves (three box
  passes, the standard Gaussian approximation); SVG emits native
  `feGaussianBlur` / `feDropShadow` and stays vector; PDF has no filter
  model and reports it through the usual degradation warning instead of
  quietly rasterising your vector output.

- **`vl_gpar(crisp = TRUE)`** snaps axis-parallel strokes onto the pixel
  grid. A 1-px rule at a fractional coordinate straddles two rows and
  renders as two grey ones – the reason gridlines look muddy on screen.
  Diagonals are left alone. **`vl_gpar(antialias = FALSE)`** gives hard
  pixel edges, for pixel art, QR codes, and heatmap cells that must tile
  without a seam. Both inherit down the tree like any other graphical
  parameter.

- New examples `inst/examples/effects.R` and `inst/examples/cvd.R`.

- **Text halos (`shadowtext`).** `vl_gpar(halo_col =, halo_width =)`
  strokes the glyph outlines *under* the fill, so a label stays legible
  over a dense scatter or map imagery. Because vellum holds the
  outlines, this is one real stroke rather than the eight offset copies
  packages layered on grid have to draw – and it works on all three
  backends (raster and outline-SVG do two explicit passes, native SVG
  uses `paint-order` and stays selectable, PDF strokes then fills).
  `halo_width` is in points like `fontsize`, so a halo keeps its
  proportion at any dpi. Haloed text bypasses the glyph-sprite fast
  path, which bakes only the fill. Resolves
  [\#13](https://github.com/r-vellum/vellum/issues/13).

- **OpenType feature control.** `vl_gpar(features = c(tnum = 1))` passes
  four-character OpenType tags to the shaper: tabular figures so axis
  labels stop jittering between ticks, plus small caps (`smcp`),
  oldstyle figures (`onum`), and ligature (`liga`) and kerning (`kern`)
  control. Features reach **measurement** as well as drawing –
  [`vl_strwidth()`](https://r-vellum.github.io/vellum/reference/vl_strwidth.md),
  [`vl_strheight()`](https://r-vellum.github.io/vellum/reference/vl_strwidth.md),
  [`grobwidth()`](https://r-vellum.github.io/vellum/reference/grobwidth.md)
  and
  [`grobheight()`](https://r-vellum.github.io/vellum/reference/grobwidth.md)
  all take them, and the shape cache is keyed on them – so a
  `grobwidth`-sized track reserves space for the glyphs that actually
  get drawn. Nothing in R’s graphics stack has offered this.

- New article,
  [`vignette("typography")`](https://r-vellum.github.io/vellum/articles/typography.md),
  and `inst/examples/typography.R`.

- **Text renders ~3x faster on a cold plot with many distinct labels.**
  PERF-1 shaped every unique label in one
  [`textshaping::shape_text()`](https://rdrr.io/pkg/textshaping/man/shape_text.html)
  call; the multi-line-text change replaced that with a per-label loop,
  so each distinct label re-resolved its font and font resolution grew
  to 56% of a cold render. Shaping is batched across labels again –
  lines are pooled before shaping and re-stacked afterwards, so
  multi-line labels keep working. A cold 5000-label render goes from
  1.78 s to 0.55 s. Output is byte-identical.

- **Images are ~4x cheaper to convert, and can be read from a file.**
  [`raster_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  now takes a **path to a PNG**, decoded in the Rust backend, so no R
  image package is needed to put a picture in a plot. A numeric RGB/RGBA
  array – what
  [`png::readPNG()`](https://rdrr.io/pkg/png/man/readPNG.html) returns –
  takes a fast path that skips the per-pixel colour-string round-trip
  [`as.raster()`](https://rdrr.io/r/grDevices/as.raster.html) performs:
  0.21 s to 0.055 s at 1 megapixel, which turns an image draw from
  slower than grid (0.69x) into faster (1.38x). The pixels are identical
  either way.

- **`vl_gpar(cex =)`.** A multiplier on `fontsize`, as in grid, so a
  theme can ask for “20% larger” without knowing the base size. It folds
  into text drawing, `char`/`line` units, and grob measurement, so
  `cex = 2` is exactly equivalent to doubling `fontsize` everywhere.

- **[`vl_convert()`](https://r-vellum.github.io/vellum/reference/vl_convert.md)**
  resolves a unit to a plain number in another unit – grid’s
  [`convertWidth()`](https://rdrr.io/r/grid/grid.convert.html)/[`convertX()`](https://rdrr.io/r/grid/grid.convert.html)
  and friends. Absolute units need no context; `npc`/`native` resolve
  against the page or a named viewport. `axis` picks the extent and
  `what` distinguishes a length from a position (they differ for
  `native` when the scale does not start at zero).

- **[`scene_png()`](https://r-vellum.github.io/vellum/reference/scene_png.md)
  and
  [`scene_pdf()`](https://r-vellum.github.io/vellum/reference/scene_png.md)**
  return the encoded document as a raw vector instead of writing a file,
  alongside the existing
  [`scene_svg()`](https://r-vellum.github.io/vellum/reference/scene_svg.md)
  (a string) and
  [`scene_raster()`](https://r-vellum.github.io/vellum/reference/scene_raster.md)
  (pixels). Every output format can now be produced in memory – for a
  data URI, a web response, or a connection – with no temp-file
  round-trip. Backend degradation warnings are surfaced just as
  [`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  surfaces them.

- **`render(scale =)`** renders at a multiple of the device pixels while
  keeping the same physical size – the retina / `ggsave(scaling =)`
  idiom. It scales `dpi`, so the layout is untouched and text does not
  change relative size. Also available on
  [`scene_png()`](https://r-vellum.github.io/vellum/reference/scene_png.md).

- **[`print()`](https://rdrr.io/r/base/print.html) works again on
  gradients, patterns, masks, and
  [`why_size()`](https://r-vellum.github.io/vellum/reference/why_size.md)
  results.** All four have `print` methods declared in `NAMESPACE`, but
  none of them dispatched: the objects printed as raw lists.
  `S7::method(print, cls) <- fn` is a replacement call, so it also bound
  the symbol `print` inside the package namespace (holding
  [`base::print`](https://rdrr.io/r/base/print.html), unchanged) — and
  R’s [`registerS3methods()`](https://rdrr.io/r/base/ns-internal.html)
  treats a generic whose name is a local object as a *local* generic,
  filing every `S3method(print, <class>)` into vellum’s own
  `.__S3MethodsTable__.` rather than base’s, where dispatch looks.
  Dropping the accidental `print`/`plot` bindings restores normal
  registration; the S7 methods for `vellum_scene` register via
  [`S7::methods_register()`](https://rconsortium.github.io/S7/reference/methods_register.html)
  and were never affected. `test-print-methods.R` now guards both
  halves.

- **Cleaner GIF output from
  [`vl_render_animation()`](https://r-vellum.github.io/vellum/reference/vl_render_animation.md).**
  GIF frames are limited to 256 colours, so on a plot (smooth panels,
  antialiased marks) the old nearest-colour quantisation left bubble
  edges jagged and gradients banded. The encoder now defaults to the
  best-quality NeuQuant palette (sample factor `1`) and applies
  Floyd–Steinberg dithering, and a frame that already fits in 256
  colours is kept exact. New `gif_speed` (`1`–`30`) and `gif_dither`
  arguments expose the trade-off. GIF is still inherently lossy on a
  plot; `format = "apng"` remains the lossless option.

- **Converting between the build tree and the immutable tree is ~4-10x
  faster.** `.bnode_to_gtree()` (which runs the first time a built scene
  is rendered, edited, or queried) read the child dict with one
  [`get()`](https://rdrr.io/r/base/get.html) per child; it now uses a
  single [`mget()`](https://rdrr.io/r/base/get.html).
  `.gtree_to_bnode()` (which runs when a materialised scene is drawn on
  again, or when a branched scene forks) did an
  [`assign()`](https://rdrr.io/r/base/assign.html) per child and an
  `S7_inherits()` type test per child; it now builds the dict with one
  [`list2env()`](https://rdrr.io/r/base/list2env.html) and tests the
  type by attribute. Neither changes the resulting tree. On a scene of
  20,000 sibling grobs: materialising 34 ms -\> 9 ms, drawing onto an
  edited scene 106 ms -\> 11 ms, branching a scene 144 ms -\> 21 ms.

- **[`edit_node()`](https://r-vellum.github.io/vellum/reference/node_names.md)
  is ~40x faster on large scenes.** An edit rebuilt the nodes on the
  path with `node@children[[i]] <- ...` and then wrote the new tree back
  with `S7::set_props(scene, root =)`. Both write into an *existing* S7
  object, which makes R duplicate it first, and duplicating it
  deep-copies the whole children list hanging off its attributes — so a
  single edit copied every sibling grob, making it O(scene) instead of
  O(depth). Both now construct a fresh node/scene around the new
  children list, which just stores the pointer. `.find_path()` also
  reads `name`/`children` as attributes rather than through
  `S7_inherits()` + `prop_names()` + `@`, cutting the search itself by
  ~10x. On a scene of 20,000 named sibling grobs: 597 ms -\> 14 ms per
  edit (grid’s [`editGrob()`](https://rdrr.io/r/grid/grid.edit.html) is
  430 ms on the equivalent `gTree`). Scenes built from batched marks
  (one grob carrying many elements, which is what `vellumplot` emits)
  were already ~0.3 ms and are unchanged. No behaviour change: the
  derived tree, its `nid` re-stamping, the repaint-boundary cache hits,
  and the rendered bytes are all identical.

- **[`vl_render_animation()`](https://r-vellum.github.io/vellum/reference/vl_render_animation.md)
  — non-reactive keyframe animation.** Interpolate between a set of
  compiled keyframe scenes and encode the in-between frames to a looping
  GIF, an animated PNG (APNG), or a directory of PNG frames. The tween,
  render, and encode run in one parallel, streaming pass in the Rust
  backend (`rayon` over frames): matching primitives interpolate their
  geometry, their colours (perceptually, in Oklab), and their bounded
  graphical parameters, while discrete attributes snap. The caller
  supplies the keyframes and a per-frame schedule (which keyframe pair
  and the eased fraction), so easing stays in R. See
  `inst/examples/animation.R`.

## vellum 0.5.1

- **[`sector_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  and
  [`loop_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  no longer render vertically mirrored.** Sector arcs were built
  directly in the y-down device frame (`cy + r·sin θ`) while every other
  primitive maps coordinates through the y-up native frame, so a sector
  drawn at angle `θ` landed where the others would place `-θ` — the
  documented “0 at 3 o’clock, counter-clockwise” contract was mirrored
  across the horizontal axis. A centroid label/point overlaid on a pie /
  donut / rose / sunburst therefore sat on the mirror image of its
  wedge. Sector fills, strokes, arrowheads, and hand-drawn (`sketch=`)
  wedges — and
  [`loop_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)’s
  teardrop `angle`, which shared the same convention — now all honour
  the y-up angle contract
  ([\#14](https://github.com/r-vellum/vellum/issues/14)).

## vellum 0.5.0

- **`vl_viewport(pannable = TRUE)`: clip-stable pannable panels.** A
  named panel so marked is emitted to SVG as an outer
  `<g data-vellum-panel>` carrying the panel’s clip (hoisted once,
  untransformed) around an inner `<g data-vellum-pan>` holding the
  content. A host can set a `transform` on the inner group to pan/zoom
  the marks while the clip and the surrounding axes stay fixed — the
  basis for host-side axis-aware zoom. SVG-only and inert for static
  rendering; non-pannable panels and the raster/PDF backends are
  byte-for-byte unchanged. See
  [`vignette("scene-contract")`](https://r-vellum.github.io/vellum/articles/scene-contract.md).

- **[`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
  no longer forces a second scene compile.** Its viewport id↔︎name
  capture must compile (a cache *hit* would skip the capture), but it
  now writes that compiled backend to the render cache, so a
  [`scene_svg()`](https://r-vellum.github.io/vellum/reference/scene_svg.md)
  /
  [`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  that follows in the same build reuses it instead of recompiling.
  Restores the single-compile behaviour the earlier
  [`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
  change had lost.

- **Scene contract: `scene_model()$panels` now carries per-panel
  geometry and metadata.** Each panel row gains its panel viewport’s
  resolved device-px rectangle (`px0,py0,px1,py1` — the true data region
  from the layout solve, not the element-extent bbox), its native
  coordinate ranges (`xscale_lo/hi`, `yscale_lo/hi`), and a `meta`
  list-column. Together the pixel rect and native range give the affine
  a host needs to map device pixels back to native (and thence data)
  coordinates. The existing element-extent `x0..y1` columns are
  unchanged, so this is additive.

- **`vl_viewport(meta=)`: a panel-level free-form metadata channel.** A
  named viewport can carry arbitrary `meta` (any R object), surfaced as
  the `meta` column of `scene_model()$panels`. Like grob `meta`, it
  never crosses to the rendering backend and vellum names no conventions
  for it — it is the panel-scoped counterpart of per-element `meta`, for
  host conventions such as axis/scale descriptors. See
  [`vignette("scene-contract")`](https://r-vellum.github.io/vellum/articles/scene-contract.md).

## vellum 0.4.0

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
