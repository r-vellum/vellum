# vellum 0.13.0.9000 (development version)

## New features

* `vl_render_animation()` gains per-frame text (`text_variants`,
  `text_frame`; VP-82): a keyed text node can show a different string on every
  frame, not only at keyframes -- the string and glyph layout come from a small
  pre-shaped variant scene, the position and colour from the tween. vellumplot
  uses it for frame variables such as `{frame_time}` in titles.

* `vl_tween_pairing()` reports, before rendering, which adjacent keyframes
  tween node by node and which will cut at the midpoint (VR-26), so a grammar
  layer can warn about them.

## Performance

* An animated SVG writes each distinct definition (gradient, pattern, clip
  path, mask, filter) once, in one document-level `<defs>`, instead of in
  every frame (VR-36). A continuous colour bar's 256-stop gradient and the
  panel clip paths were repeated per frame: a 120-frame, five-bar animation
  with a colour bar shrinks from 2.9 MB to 0.9 MB (35 KB to 15 KB gzipped).

* GIF encoding runs in parallel (VL-17): each frame's palette quantisation and
  Floyd-Steinberg dither now run on the worker threads that rasterise it, and
  only the LZW write stays sequential. `vl_render_animation()`'s `gif_speed`
  default moves from 1 to 10, which is visually indistinguishable on a plot
  with dithering on. A 1200 x 800, 150-frame gapminder GIF drops from 49.9 s
  to 3.3 s (13.2 s with `gif_speed = 1`; APNG 2.2 s).

## Bug fixes

* An animated SVG's frame windows are rounded up rather than to nearest, so
  adjacent frames no longer leave a sub-nanosecond gap with nothing visible
  that a seek to a round time could land in (a blank flash; found by VW-55).

* `vl_render_animation()` matches marks across keyframes by their data keys,
  not by node and row position (VR-32). A keyed element tweens into the
  element with the same key wherever that is drawn -- another node, another
  index, another colour group's batch (a point that changes group slides and
  recolours) -- so reordered rows, a dropped row or a sorted bar race no longer
  blend unrelated marks. Keyed points, circles, rects, lines, polygons, paths
  and labels with no partner fade in or out; unkeyed nodes pair in order within
  their viewport/kind/role class and switch at the midpoint when that class
  changes size. Only keyframes on different viewport trees still cut whole.
  The matching is computed once per keyframe pair with hash maps.
  `vl_tween_pairing()` gains `exited` and `entered` counts.

* `vl_render_animation()`: when two keyframes draw a different number of nodes
  (a colour group present in one state and absent from the next), the frames
  now switch to the later keyframe at the positional midpoint instead of
  showing the earlier one for the whole segment, which meant the later
  keyframe never appeared (VR-26).
* A line, polygon or path whose vertex count changes between keyframes (or an
  unkeyed batch whose element count changes) now switches whole to the later
  shape at the midpoint; the last frame used to draw a truncated shape (VR-27).
  Resampling both shapes to a common vertex count, for a true morph, is left
  for later.
* A text label's string, glyph layout, font and halo now come from the nearer
  keyframe while its position tweens, so a changed label switches at the
  midpoint and the final keyframe's text is shown (VR-28). Per-segment colours
  and widths of a segments batch follow the same rule.
* The animated SVG's CSS class and `@keyframes` names now carry the document's
  id prefix, so two animated SVGs (or two widgets) on one HTML page no longer
  drive each other's timing and blank out (VR-29).
* Under `prefers-reduced-motion`, the animated SVG now holds its last frame
  when the schedule ends on the final keyframe (a reveal, a time series, a
  non-looping sequence) and its first frame otherwise; a reveal used to show
  an empty plot (VR-30).
* Easing overshoot (`back`, `elastic`) no longer drives sizes, radii, line
  widths or an enter/exit fade below 0, or opacity above 1 (VR-31).
* `fps` is no longer rounded to a whole number: the frame delay is passed as
  an exact fraction, so 12.5 fps is 2/25 s and 0.5 fps a two-second frame
  (VL-15). A GIF above 50 fps warns that browsers will play it slower.
* Per-node metadata and pick ids stay aligned with the drawn nodes when a
  keyed batch splits into entering, exiting and matched parts mid-tween.

## Documentation

* The `vl_render_animation()` example and `inst/examples/animation.R` no
  longer repeat each boundary keyframe (a one-frame stutter) and now really
  hold on the last keyframe as their comments say (VL-16).

# vellum 0.13.0

## New features

* `scene_display_list()` gains `precision` (VR-18) for compact coordinates.
  `"u16"` or `"u24"` quantise each geometry column (point centres and
  radii, rects, path vertices) to 16 or 24 bits within its own range,
  shipped as `lo`, `step` and the integers; a number is the largest
  rounding error allowed in device px, and picks the fewest of 8, 16 or 24
  bits per column that meets it. At `0.005` (the precision of
  `scene_svg()`'s coordinates) a 200k-point scatter's list shrinks from
  2.14 to 1.07 MB. The default, `"f32"`, is unchanged.

## Bug fixes

* A `vl_viewport(cache = TRUE)` holding a blend-mode viewport that composites
  against the page (not inside an opacity, mask, blend or blur/shadow group
  of its own) is no longer cached in PNG (VR-24). The cached sub-raster is an
  isolated layer, so the blend mixed with transparency there (a multiply
  group drew its colours unmultiplied), while SVG and PDF blended against
  the page. Such a viewport is now drawn inline, as one with its own blend
  already was.

* PDF output composites a blend-mode group as a unit, as PNG and SVG do
  (VR-23). The blend mode used to apply to each object in the group, so
  overlapping marks in one `blend = "multiply"` viewport multiplied each
  other, and a blend nested in another blend group composited against the
  page. A blend group is now drawn as an isolated transparency group and the
  mode applies to the result.

* The raster backend no longer isolates a group that has no mask, opacity,
  blend mode or effect (VR-21). SVG and PDF never did, and SVG/CSS
  compositing doesn't isolate such a group either, so a blend inside one now
  blends with what is beneath it in PNG output too, instead of with the
  group's own transparent layer. `scene_display_list()` reports such a blend
  root's `run_blend` mode instead of `""`. `compile()` never opens such a
  group, so PNG output of scenes built with vellum's R API is unchanged; it
  changes only for a blend group wrapped in a plain group by direct backend
  calls (`Scene$group_start()` with no mask, opacity 1, normal blend and no
  effect).

# vellum 0.12.0

## New features

* A grob's `meta` can be columnar: a data frame with one row per element and
  one column per field, in place of a list of records. `scene_model()` gains
  `meta = c("records", "columns")`: `"records"` (the default) returns the
  `meta` list-column as before, whatever form the grobs carried, and
  `"columns"` returns it as a data-frame column, one column per field, without
  building a record per element (VR-19).

* `scene_display_list()` (internal, for vellumwidget) gains `keys`: a
  character vector of keys the caller already has, such as vellumwidget's
  element table. `record$key` then indexes it, and the list's own `keys` holds
  only the keys it lacks, with `keys_given` saying how many come first
  (VR-22). vellumwidget used to ship every key twice; for a 200,000-point
  keyed scatter this saves about 1 MB of widget payload.

## Minor improvements and fixes

* Large clouds of equal-size, fill-only circles (10,000 or more in one grob,
  e.g. points with `col = NA`) are drawn in PNG from the same sub-pixel sprite
  as outlined ones (VR-20). Each mark used to snap to a whole pixel; now it
  lands within 1/32 px of its exact position, so the image is closer to the
  exact render (mean difference 0.04/255 instead of 0.39/255 for opaque marks)
  and about 3x faster to draw. Pixels change slightly. With antialiasing off,
  these clouds are now drawn per element, aliased as asked, instead of from an
  antialiased sprite.

# vellum 0.11.1

## New features

* `scene_display_list(version = 2)` (internal, for vellumwidget) splits the
  flagged runs where a blend mode starts or ends and reports how each run
  composites in `run_blend`: `"normal"`, or the CSS `mix-blend-mode` of the
  one blended group the run holds (VW-32). Rendered on its own
  (`scene_png(layer = "keyed_flagged", run = k)`), such a run is its marks
  unblended, so a client can composite it with that blend mode instead of
  falling back to the full mark image.

## Bug fixes

* `scene_svg()` wraps a compositing group's content in the group again when
  the group sits inside a named panel. A blend mode, group opacity, mask or
  blur/shadow effect inside a panel (every layer `blend`, `clip_layer()` or
  layer effect in a vellumplot plot) used to be written as an empty `<g>`
  after its marks, so the SVG showed the marks unblended, opaque and
  unmasked. The raster and PDF output were right.

# vellum 0.11.0

## New features

* `scene_display_list()` (internal, for vellumwidget) gains `version = 2`
  (VW-23). Version 2 lists three cases exactly that version 1 flags: linear
  and radial gradient fills with `pad` extension (a gradient table the paints
  refer to), clips by a path or a rotated rectangle (clip paths in device px),
  and groups whose only effect is an opacity below 1 (a group table each
  record refers to). vellumwidget can then draw these marks on its canvas,
  restyle them and show them as SVG nodes on deep zoom. The default stays
  `version = 1`, unchanged, so older vellumwidget releases are unaffected.
  Masks, blend modes, effects, hatches, patterns, repeating gradients and
  gradient strokes stay flagged.

* `scene_png()` and `scene_svg()` gain `layer = "keyed_flagged"` and a `run`
  argument (VW-30). The layer draws only the keyed marks that
  `scene_display_list(version = 2)` flags (masks, blend modes, effects,
  hatches, patterns, repeating gradients, gradient strokes, text), grouped
  into runs in paint order. A version-2 display list numbers them in a new
  `record$run` column and counts them in `runs`. vellumwidget can then draw the
  exact marks itself and composite each run's image where it falls in paint
  order, instead of keeping every mark on the PNG when one mark is flagged.
  A mark under a blend mode now also carries display-list flag `32`: it
  mixes with what is beneath it, which a separate raster cannot reproduce.

# vellum 0.10.1

## Bug fixes

* `vl_strwidth()`, `vl_strheight()` and text shaping now error when the text
  size (`fontsize * cex`) is missing or not finite, instead of passing it to
  textshaping. textshaping converts such a size to a fixed-point integer, which
  depends on the platform: on x86_64 Linux a string measured -33554432 pt
  (about -1.2e7 mm), while macOS (arm64) measured 0. A `NULL` `fontsize` was the
  usual way in (VR-15).

# vellum 0.10.0

## Bug fixes

* In a pannable clipped panel, the SVG backend hoists the panel clip onto the
  outer `data-vellum-panel` group so it stays put while a host transforms the
  inner `data-vellum-pan` group. When the first clipped element sat inside a
  per-node `<g>` (a layer with an `id`, or a split-render layer such as
  `"keyed"` or `"unkeyed_above"` whose panel background was filtered out), the
  clip landed on the pan group instead and moved with the data. It now always
  goes on the panel group.

## New features

* `scene_display_list()` now lists keyed marks that paint nothing (invisible
  hover targets: `fill = NA, col = NA` rects, circles, markers, polygons) with
  their geometry and a new pick-only flag (`16`), so vellumwidget can hit-test
  them in raster mode (VR-17). The change is additive: drawn marks keep their
  records and flags, and an older client treats the new flag like any other
  (falls back to the element's bounding box).

* `scene_svg()` and `scene_png()` accept `layer = "unkeyed_below"` and
  `layer = "unkeyed_above"` (VW-21), which split the unkeyed layer by paint
  order relative to the marks: an unkeyed element is above when a mark was
  painted before it in its innermost named panel. Stacking below, keyed and
  above reproduces an annotation or reference line drawn over the points,
  which the two-layer split put underneath them. `"unkeyed"` is unchanged and
  is exactly the union of the two; `"unkeyed_above"` has a transparent page.
  Feature-detect with `"unkeyed_above" %in% eval(formals(vellum::scene_png)$layer)`.

* `scene_svg()` and `scene_png()` gain `layer = c("all", "unkeyed", "keyed")`
  for a split render (VR-13). `"keyed"` draws only the marks that carry an
  interactivity key, on a transparent page; `"unkeyed"` draws everything else
  (background, gridlines, axes, legends). Both use the full page and the same
  transforms, and a mark keeps its clip, mask and group opacity, so the keyed
  PNG laid over the unkeyed SVG or PNG reproduces the full render. `panels`
  restricts the mark layer to keyed marks inside the named panels, which keeps
  a legend's keyed swatches with the furniture. vellumwidget uses this in
  raster mode to keep axes and legends as SVG and rasterise only the marks.

* `scene_display_list()` (internal, for vellumwidget) resolves every keyed
  mark to device-pixel geometry, a paint and its key, packed as columnar
  base64 typed arrays (VR-14, F-5 stage 1). Points carry centre, radius and
  marker shape, rects their box, and lines and polygons flattened vertex runs.
  Paints, clip rects and panels are small lookup tables. Marks the format
  cannot yet draw exactly (text, gradients, path clips, translucent groups)
  are flagged. For a 20,000-point scatter it comes to 268 KB, against 1.5 MB
  for the key-and-bbox index vellumwidget ships today, and it builds in 5 ms.
  The format is private to vellumwidget and may change without notice.

## Performance

* Large clouds of filled-and-stroked points (10,000 or more equal-radius
  circles with a solid, undashed outline, which is vellumplot's default point)
  now rasterise from a sprite instead of filling and stroking every circle
  (VR-16). The sprite is drawn once per 1/16 px sub-pixel phase and blitted
  with a plain source-over loop, so each mark lands within 1/32 px of its exact
  position. A 200k-point keyed scatter's PNG at 2x drops from about 3.5 s to
  0.2 s. Smaller batches, dashed or gradient strokes and SVG/PDF output are
  unchanged.

* A keyed batch of circles now reaches the backend as one batch with its keys
  (VR-14), instead of being split into one draw per circle whenever the
  backend writes keys. SVG, PNG and PDF output are byte-identical.

# vellum 0.9.0

## New features

* `vl_brush()` and `vl_lasso()` return the keyed elements that meet a
  rectangle or a free-form polygon, measured against their true geometry
  (F-6). A diagonal line is selected only where the line itself enters the
  region, not because its bounding box does, and a region inside a polygon's
  hole does not select the polygon. `mode = "intersect"` (the default)
  selects anything the region touches, `"contain"` only what lies wholly
  inside it, and `"centre"` whatever has its box centre inside, the rule
  vellumwidget's lasso uses in the browser. They are for server-side
  brushing and lasso selection in Shiny, and return `key` and `kind` in paint
  order.

## Performance

* `vl_nearest()` answers from a spatial index cached on the scene instead of
  measuring every keyed element on each call (F-6). The first query on a
  scene builds a uniform grid over its elements; later `vl_nearest()`,
  `vl_brush()` and `vl_lasso()` calls visit only the cells near the query.
  On a 20,000-point scatter a warm `vl_nearest()` call drops from about 6 ms
  to 0.25 ms, fast enough for hover-rate use. The results, ties included,
  are the same as before. Editing a scene gives it a new index.

* A filled, outlined shape is one SVG element instead of two (VW-12). When
  the fill is a solid colour and the outline a solid, undashed stroke, the
  shape is written once with both `fill` and `stroke`, not as a fill element
  followed by a `fill="none"` stroke twin. SVG paints the fill and then the
  stroke on one element, so what renders is unchanged. A `<circle>` also
  drops `stroke-linecap`, `stroke-linejoin` and `stroke-miterlimit`, which
  cannot change a shape with no ends or corners. A 5,000-point keyed scatter
  goes from 224 to 107 bytes per point (1.1 MB to 0.54 MB) and from 10,000
  to 5,000 `<circle>` nodes. Every element still carries its datum's
  `data-key`. Gradient or pattern paint, dashed outlines and non-uniform
  scales keep the two-element form. vellumwidget's selection, hover and
  focus rings need vellumwidget 0.11.0.9000 or later to show in full on the
  single element; older widgets still work but draw half the ring.

# vellum 0.8.1

## Bug fixes

* The same scene now renders to byte-identical SVG every time, so SVG output
  can be diffed and snapshot-tested (VP-24). The `<title>`/`<desc>` ids used
  to take a prefix from a session counter, stamped when the scene was built,
  so two builds of one scene differed (`vl2-d` against `vl208-d`). Every id in
  the document (title, desc, and each clip path, gradient, pattern, mask and
  filter) now starts with one prefix, `vl` plus a hash of the document's own
  content, followed by a counter that restarts at 0 in every render
  (`vl3f9a01c2-c0`). Different scenes embedded in one HTML page therefore
  still get distinct ids. Clip-path and gradient ids used to have no prefix at
  all, so two SVGs on one page could resolve each other's `url(#c0)`. A
  scene's `a11y_prefix`, when set, is used as the prefix instead.

## Performance

* SVG output is about 4.5x smaller per mark and renders about 4x faster
  (VW-8). A circular point is now a `<circle>` rather than an eight-segment
  path; a solid fill or stroke has its transform baked into device
  coordinates instead of carrying a per-element `matrix()`; path coordinates
  are rounded to 0.01 px (more digits under a scaling transform); and
  `fill-opacity`/`stroke-opacity` of 1 and the miter limit of a round join are
  left out. A 5,000-point keyed scatter drops from 5.0 MB to 1.1 MB. What
  renders is unchanged, and so is the structure vellumwidget relies on: every
  keyed element keeps its `data-key`, and a filled, stroked point is still a
  fill element followed by its `fill="none"` stroke twin. Gradient and pattern
  paint keep local geometry and the element's `transform`.

# vellum 0.8.0

## Breaking changes

* **Bare numbers now mean npc in every constructor**;
  `lines_grob()`/`polygon_grob()`/`segments_grob()`/`path_grob()`/
  `bezier_grob()`/`spline_grob()` and `hexagon_grob()`/`sector_grob()` sizes
  used native. Pass `default_units = "native"` or `vl_unit(x, "native")` for
  the old behaviour.

  vellum mixed two defaults: a bare number was `"npc"` in `rect_grob()`,
  `circle_grob()`, `text_grob()` and most other constructors, but `"native"`
  in the line and polygon family, in the `width`/`height` of a hexagon and in
  the `r0`/`r1` of a sector. Now every constructor reads it as grid does.

  Where it shows: in a viewport whose `xscale`/`yscale` is the default
  `c(0, 1)`, npc and native positions coincide, so lines, polygons, segments,
  paths and hexagon sizes drawn there do not move. Bare data values passed to
  them inside a *scaled* viewport must now say `"native"`. A bare sector radius
  changes even on the default scale: a native radius was a fraction of the
  viewport's width, an npc radius is a fraction of its shorter side (so a pie
  in a wide viewport draws smaller).

## New features

* **Every constructor takes a `default_units` argument**, as grid's
  `default.units`: the unit a bare number is read in for the position and size
  arguments. It defaults to `"npc"` everywhere, including `vl_viewport()` and
  `svg_grob()`. Arguments with a physical default of their own are unaffected:
  a bare point, hexagon or loop `size`, and `foot`, `start_cap`, `end_cap` and
  `offset`, stay millimetres; an arrow `length` stays inches. `?grob` now
  documents how a relative length resolves: a `width` or `height` per axis, a
  radius against the viewport's shorter side.

* `vl_path_op()` returns its result in the operands' unit (bare operands give
  `"npc"`), instead of tagging the numbers `"native"` whatever went in.

* Constructors refuse a non-numeric coordinate (`rect_grob(x = "left")`) with
  a clear error instead of an obscure cast failure.

## Hit testing

* **`hit_test()` is ~1000x faster when called repeatedly on one scene.** Each
  call compiled the scene into a fresh backend, so 1000 hit tests on a
  ~270-grob scene took 111 s. The compiled pick backend is now memoised like
  the render cache, keyed on the scene's content and device size, so the same
  1000 calls take 0.12 s. An edit, a resize or `vl_clear_render_cache()` starts
  afresh, and `options(vellum.cache = FALSE)` turns the memo off.

* `hit_test()`, `node_names()`, `get_node()` and `edit_node()` now coerce their
  `scene` through `as_vellum_scene()`, like `render()` and the other scene
  functions, so they accept any object with an `as_vellum_scene()` method.

## Rendering fixes

* **Fix: inputs that crashed or hung the renderer now draw or fail with a clear
  error.**
  - A sketched `sector_grob()` with a gradient, pattern or hatch fill panicked
    with "index out of bounds"; it now draws with that paint.
  - Tweening a size-driven `hexagon_grob()` into a `width`/`height` one in
    `vl_render_animation()` panicked; it now animates.
  - A layout cell out of range (`vl_viewport(row = 5)` in a 2-row layout) is
    rejected when the scene compiles. Before, the check ran at render time,
    where for an animation it raised an R error from a worker thread and could
    crash the session.
  - `vl_render_animation()` refuses keyframes of different pixel sizes. Before,
    a GIF panicked on frames of the wrong length.
  - A sector sweeping more than a full turn is drawn, boxed and picked as the
    full disc. Before, a sweep of thousands of turns became a star polygon.
  - Raster renders over 2^28 pixels (16384 x 16384) error instead of
    attempting multi-gigabyte allocations, which abort R when they fail. SVG
    and PDF output is not limited.
  - `datashade()` grids over 2^27 cells, `vl_empty_region()` grids over 2^24
    cells, and PNG images over 2^27 pixels are refused for the same reason.
  - A hachure, zigzag or dots sketch fill on a huge shape no longer hangs, and
    a huge or infinite `blur` radius no longer hangs or overflows.

* **Fix: PNG files read by `raster_grob()` keep their colours when they use a
  palette or fewer than 8 bits per sample.** They came back as grey palette
  indices or packed bytes.

* **Fix: no faint bead where the PNG stroke runs of a long line meet.** The
  raster fast path strokes a line in runs of up to 256 segments, and both runs
  drew a round cap on the shared vertex, darkening its antialiased rim by up
  to 25% at low resolution. Each joint is now redrawn once from a single
  stroke, so a line of any length matches the combined stroke. Lines of up to
  256 segments are unchanged.

* The PDF warning for a pattern that cannot be rendered now says whether it
  was a fill or a stroke. A pattern stroke used to be reported as a "fill" that
  "was left unfilled".

## Input validation

* **Bad inputs fail where they are passed, with an error that names the
  argument and the function.** Before, many reached the Rust backend and came
  back as bare extendr messages ("Must not be NA.", "Expected Scalar, got
  Integers", "Expected Strings got Doubles") at render time.
  - `hit_test()` and `vl_nearest()` check `x`, `y`, `units`, `n` and
    `max_dist`.
  - `vl_scene()` checks the page size (a single positive absolute length),
    `dpi`, `bg`, `xscale`/`yscale`, `clip`, `title` and `desc`; `describe()`
    checks `title`/`desc`.
  - `vl_viewport()` checks `angle`, `xscale`/`yscale` (finite, length 2),
    `row`/`col`/`rowspan`/`colspan` (whole numbers >= 1), `blur`, `clip`,
    `pannable` and `blend` (no longer partially matched).
  - `vl_arrow()` checks `angle` (strictly between 0 and 180), `ends` and
    `type`, and rejects an `npc`/`native`, negative or vector `length` when it
    is built rather than when the scene renders.
  - `vl_gpar()` rejects a negative `lwd` (`0` is still fine), a `fontsize` that
    is not positive, an unknown `fontface` such as `"heavy"`, and an empty or
    invalid colour vector, which was silently drawn as transparent. A numeric
    `fontface` (grid's `1:4`) is now accepted and converted to its name.
  - `sector_grob()` rejects `r0 > r1` (where both radii share a unit) and
    negative radii; `loop_grob()` rejects a negative `width`.
  - `draw()` accepts only a grob (a gtree is one) or a list of grobs.
    `draw(scene, 1)` used to succeed and then fail at render with "Can't find
    method for compile(<double>)".

* **Fix: `text_grob(width =)` and `height =` take one length.** A vector such
  as `vl_unit(c(10, 50), "mm")` silently used its first element; it is now an
  error. The internal page-size reader behind it validates the same way.

* **Fix: `sector_grob()` and `hexagon_grob()` take a per-element `gp$fill`
  vector**, as documented, instead of failing at render. Like `fill =`, it must
  have length 1 or the element count.

* **Fix: unary minus negates a compound unit's offset.**
  `-(vl_unit(1, "native") + vl_unit(2, "mm"))` is now `-1native-2mm`; it was
  `-1native+2mm`.

* **Fix: `strwidth`/`strheight` units take a vector label.**
  `vl_unit(1:2, "strwidth", data = list(label = c("a", "bb")))` measures each
  label; it failed with "values must be length 1". The label must have length
  1 or the length of `values`.

## Documentation

* `vignette("scene-contract")` matches the code again. The `mark` vocabulary
  has eleven values, including `roundrect` and `text` (rows only for keyed
  elements). `lines_grob()`, `polygon_grob()` and `path_grob()` take `key`.
  `key`/`meta` must have length 1 or the element count. Bare numbers are npc
  in every constructor. A `circle_grob()` element reports as `point` in
  `element_geometry()`. `hit_test()` follows the fill rule as `vl_nearest()`
  does. A panel row appears only for a named viewport that encloses an
  element. `test-contract.R` pins each of these, and the `scene_model()`
  help page no longer lists only the batched marks.

# vellum 0.7.2

## Strokes

* **Fix: an odd-length dash pattern draws the same on every backend.**
  `vl_gpar(lty = c(4, 2, 1))` (or a one-digit hex string like `"4"`) drew a
  solid line in PNG, because the raster backend rejects an odd dash array, while
  SVG and PDF repeated the list and drew dashes.

  The engine now normalises the dash array once for all three backends: an
  odd-length list is doubled (the SVG and PDF rule), and a list that sums to
  zero draws solid. Negative or infinite dash lengths are rejected with an
  error.

* **Fix: thin, densely sampled lines no longer look stippled in PNG.** For the
  default line style (opaque, solid, round caps and joins) the raster backend
  stroked every segment of a line on its own. The antialiased pixels around
  each vertex were then blended twice, so contours, curves and other lines with
  many short segments got a dark bead at every vertex. At 72-100 dpi that read
  as a dotted line, and a contour plot carried about 20% more ink than in SVG
  or PDF.

  The fast path now strokes a line in runs of up to 256 consecutive segments.
  Within a run the result is identical to a single stroke, and a long
  self-intersecting polyline renders as fast as before.

## Paint

* **Fix: pattern strokes and reflected patterns draw the same on every
  backend.** A `vl_pattern()` given to `col` stroked with the pattern in SVG
  but fell back to plain black in PNG and PDF. All three backends now stroke
  with the pattern, and a faded pattern stroke keeps its opacity in SVG.

  `vl_pattern(extend = "reflect")` mirrored every other cell in PNG but repeated
  the tile in SVG and PDF. A reflected pattern is now drawn from a 2x2 mirrored
  tile, which every backend tiles identically. `extend = "pad"` is now an error
  for patterns, because SVG and PDF tiling patterns cannot clamp a tile's edges
  outwards (it already drew as `"repeat"` there).

  A `vl_hatch()` in `col` is now an error. It drew nothing in SVG and a black
  line in PNG; a hatch fills a shape and has no meaning as a stroke.

## Scenes

* **Fix: a written scene keeps the names on its vectors.** `scene_write()`
  stored doubles and strings without their names (or any other attribute), so a
  scene drawn with `vl_gpar(features = c(tnum = 1))` read back from `.rds` or
  `.json` failed to render with "`features` must be a named vector". Named
  per-element `meta` silently lost its names, a JSON round-trip turned a named
  logical into an integer, and a systemfonts `font_feature()` object lost its
  class.

  Atomic vectors now carry their names, and atomic vectors and lists carry their
  other attributes, through the scene spec, and a read restores them. Specs
  written by earlier versions have no such fields and read as before, and the
  spec of a scene without named or classed values is unchanged, so its
  `scene_hash()` does not move.

## Hit-testing

* **Fix: keyed batched marks with a scalar `x` and a vector `y` no longer break
  `scene_model()`.** `scene_model()` counted a batch by the length of `x`, so
  `rect_grob(x = 0.5, y = c(0.2, 0.5, 0.8), key = c("a", "b", "c"))` gave one
  element from the grob walk against three from the backend, and aborted with
  an element-count mismatch. `roundrect_grob()` had the same problem.

  Every batched grob (rect, roundrect, circle, points, hexagon, sector,
  segments, loop and text) now has one definition of its element count: the
  common length of all its per-element vectors (`x`, `y`, `width`, `height`,
  `r`, `size`, `shape`, angles, caps, ...). The constructor recycles `key` and
  `meta` to it, `compile()` draws that many elements, and `scene_model()`
  expects that many rows. Incompatible lengths fail in the constructor, with an
  error that names the arguments. `key` and `meta` must now have length 1 or n.
  Before, `rep_len()` silently truncated or wrapped them, so elements could be
  paired with the wrong data.

* **Fix: every geometry query now reports what is drawn.** `element_geometry()`,
  `vl_nearest()`, `hit_test()`, the `scene_model()` boxes and the linter's node
  boxes each had their own copy of every mark's geometry, and the copies had
  drifted from the renderer. A segment drawn with `offset =` or
  `start_cap =`/`end_cap =` was reported (and picked) where it would have been
  without them, so `vl_nearest()` could return distance 0 at a point 38 px from
  the ink. Keyed hexagons and sectors were in `scene_model()` but absent from
  `vl_nearest()` and `element_geometry()`. Rotated text kept an unrotated box,
  and the linter ignored a non-regular hexagon's `width`/`height`.

  The render walk now records each element's geometry as it resolves it (after
  offsets, caps and trims; text rotated about its anchor), and all five queries
  read that one recording. Results change where the old copies were wrong:
  offset/capped segments and lines, rotated text (whose `element_geometry()` is
  now its four corners), non-regular hexagons, and sectors, whose box is now the
  wedge rather than the whole circle. Hexagons and sectors join `vl_nearest()`
  and `element_geometry()` as kinds `"hexagon"` and `"sector"` (their outline as
  one ring). `hit_test()` no longer rasterises the scene on every call: it tests
  the recorded shapes topmost-first against the viewport clip, picks a stroke
  by half its width (at least 2 px) and a marker by its disc.

* **Behaviour change: a point in a polygon's hole no longer counts as a hit.**
  `vl_nearest()` measured a multi-ring path as the minimum over its rings, each
  treated as filled, so a point inside any ring, including a hole, was at
  distance 0. Containment is now decided once across all of an element's rings
  under the rule the shape is painted with: even-odd parity, or nonzero
  winding. A point in an `"evenodd"` path's hole (or in a `"winding"` path's
  reversed inner ring) is outside, and its distance is to the nearest edge,
  which is the hole's own boundary. A plain polygon picks as before.

  `element_geometry()` gains a `rule` column (`"nonzero"`, `"evenodd"`, or `NA`
  for segments, lines and points), one value per element, so a client-side
  host can decide containment the same way. The column is appended, so no
  existing column moves. The scene-contract article now documents
  `element_geometry()` and its containment rule.

## Other changes

* **Backend parity is now tested on rendered pixels.** A new test suite renders
  the same scenes to PNG, SVG and PDF, rasterises the SVG and PDF back to
  pixels, and checks that the ink lands in the same places and colours (at a
  1-px antialiasing tolerance). The fixtures cover lines and polygons, outlined
  text, even and odd dash patterns, gradients, pattern fills and strokes, and
  clipping. The suite uses the rsvg and pdftools packages (now in Suggests),
  falling back to magick and poppler's `pdftoppm`, and skips when no
  rasteriser is available.

# vellum 0.7.1

## Text

* **Fix: `vl_gpar(features = c(liga = 0))` no longer errors on every backend.**
  The feature vector was handed to `systemfonts::font_feature()` through
  `do.call()`, and R partial-matched the tag `liga` onto that function's
  `ligatures` argument, so systemfonts read `0` as a ligature name and stopped
  with "No ligature setting called '0'". Any tag that prefixes `letters` or
  `numbers` (`lett`, `numb`, ...) hit the same trap. `c(liga = 0)` is the example
  in the `vl_gpar()` docs.

  systemfonts' own arguments are now passed explicitly as `NULL`, so every tag
  reaches it verbatim, and `c(liga = 0)` really does switch the fi ligature off.

* **Fix: a multi-label `text_grob()` with keys no longer breaks
  `scene_model()`.** `key` and `meta` were recycled to the length of `x`, not to
  the number of labels, so `text_grob(c("a", "b", "c"), key = c("k1", "k2", "k3"))`
  -- scalar `x`, three labels -- kept one key. `scene_model()` then saw one element
  from the grob walk and three from the backend, and aborted with an element-count
  mismatch.

  The element count is now the common length of `label`, `x` and `y`, the same n
  the backend draws, and `key`/`meta` recycle to it. Incompatible lengths fail up
  front with an error that names `label`, `x` and `y`, instead of a vctrs
  recycling message from deep inside the render.

# vellum 0.7.0

## Geometry

* **Fix: a mitre or bevel join on a strongly tapered stroke left a pinhole at the
  apex.** With a peaked width profile -- a wide corner between narrow neighbours --
  a small unfilled island survived the ribbon's self-union right at the join,
  reading as a speck of dust on the corner of a thick tapered line (about 4 px in
  a 62 px stroke). Round joins and constant widths were never affected.

  Each segment's sweep ends on a tangent *chord* of the vertex's disc, and when
  the width varies that chord is tilted -- displaced from the vertex along the
  centreline in proportion to the width gradient. Between the two chords lies a
  lens containing the vertex that neither sweep covers. The convex side was
  already stitched; the concave side relied on the two inner edges crossing, which
  they only do when the width is near constant. That lens is now filled
  explicitly, and the wedge's reach-back takes the chord tilt as a floor rather
  than scaling off the vertex half-width alone.

  Affects both entry points, since they share the generator: `stroke_to_path()`'s
  outlines and the new `lines_grob(lwd_profile =)`. A constant-width stroke is
  byte-for-byte unchanged -- the new fill is skipped when the chords are not
  tilted -- so the only output that moves is a tapered mitre/bevel join, which is
  the bug.

* **`lines_grob()` takes a `lwd_profile`: a stroke whose width varies along the
  line, resolved at render.** `stroke_to_path(lwd_profile =)` in 0.6.9 solved the
  geometry of a variable-width stroke but bakes it at a page size you supply and
  hands back absolute mm. That is right for a shape, and no use to anything whose
  rect is measured later -- a mark heading into a panel laid out after axes,
  strips and legends. This carries the profile into the scene instead and builds
  the ribbon inside the grob's viewport at render.

  ```r
  lines_grob(x, y, gp = vl_gpar(col = "steelblue", lwd = 12),
             lwd_profile = c(1, 1.6, 0.8, 0))
  ```

  One multiplier per vertex, scaling the `lwd` that is **resolved** at render --
  so an `lwd` inherited from an enclosing viewport is what the profile multiplies,
  which is why the vector crosses into the engine as multipliers rather than as
  finished widths. Because nothing is baked, the same grob tapers correctly at any
  figure size: doubling the page doubles the ribbon's length and leaves its
  physical width alone, and doubling the dpi scales both.

  The geometry is the one that shipped with `stroke_to_path()` -- external common
  tangents, so a taper reaches its point instead of waisting, and one non-zero
  self-union to resolve tight bends and the inner side of each join. Nothing in
  `ribbon.rs` changed; this is the plumbing that was missing.

  A varying-width stroke is generated as an outline and **filled**, since no
  backend can stroke one path at several widths -- so PNG, SVG and PDF all get
  identical geometry and it degrades nowhere, unlike the group effects. Two
  consequences worth knowing: the stroke colour paints the ribbon (a gradient
  `col` ramps along it) while `lty` and dashing do not apply, and every ribbon is
  unique geometry, so it opts out of the batching fast paths -- sized for the low
  element counts this is for, not for a million points.

  `sketch` and `lwd_profile` together are an error rather than a guess: jittering
  a ribbon's outline gives a wobbly silhouette, not a wobbly pen, and those are
  different pictures. Arc-length spreading (`along = "arclength"`) stays with
  `stroke_to_path()`, which has the resolved device px that measuring it needs.

  A scene with no profile is byte-for-byte unchanged.

## Hit-testing

* **`element_geometry()` gains a `ring` column, so a multi-ring path's
  boundaries survive the trip to R.** A `path` element reports all its rings'
  vertices concatenated, which on its own is lossy: a host had no way to tell
  where one ring ended, and joining the whole run invents a phantom edge from
  each ring's last vertex to the next ring's first. For a single-ring path (a
  plain polygon, the common case) that was exact; for a polygon with a hole or a
  multipart feature it was an approximation.

  `ring` is 1-based within the element, so `split()` on it recovers exactly the
  rings the engine measured against -- `pick_table()` had `nper` in hand and was
  throwing it away at the point of emitting. Every other kind is a single ring,
  so `ring` is `1` throughout and nothing else changes.

  Worth knowing when reproducing the engine's own answer: a path's distance is
  the minimum over its rings, each measured as filled, so **inside any ring
  counts as a hit** and the path's fill `rule` does not enter into it -- a point
  in a hole is at distance zero. That is the behaviour to match locally, and the
  `ring` column is what makes matching it possible.

# vellum 0.6.9

## Geometry

* **`stroke_to_path()` can vary the stroke width along the line.** The new
  `lwd_profile` argument takes a numeric vector of multipliers of `lwd` and
  returns an outline whose width follows it: `c(1, 0.2)` is a ribbon tapering to
  a fifth of its width, `c(0, 1, 0)` a leaf, `c(1, 0, 1)` a stroke pinched to
  nothing in the middle. A zero is a legal width — tapering to a point is the
  main thing people want this for — and only an all-zero profile is an error.

  `along` chooses how the values are positioned. The default `"arclength"`
  spreads them evenly along the drawn length of the stroke and interpolates, so
  the profile is independent of how densely the polyline happens to be sampled
  and any profile length works. `along = "vertex"` reads one value per vertex
  instead, which is what you want when the widths come from data attached to the
  vertices — a per-observation weight, a pressure trace from a tablet. The two
  parameterisations coincide only when the vertices are evenly spaced, which is
  why they are separate options rather than one argument that guesses from
  length. On a closed `polygon_grob()` or `path_grob()` the profile is cyclic: a
  ring has no first vertex a reader can see, so wrapping is the only reading
  that does not put a width step wherever the input happened to start.

  `segments_grob(lwd = )` has varied width per *element* for some time, but it
  strokes each segment separately, so the width steps and the joins show.
  Variable-width `stroke_to_path()` is the higher-fidelity alternative: one
  continuous filled outline with nothing to give away where the width changed.
  The tradeoff is the one that has always applied here — an outline is baked at
  one page size and comes back in absolute millimetres.

  Two honest notes. The first is a correction to what the documentation used to
  promise unconditionally: a plain expansion still uses tiny-skia's own stroker,
  the one the rasterizer uses, so the outline is exactly the region that would
  have been inked. A varying width has no such reference, because no rasterizer
  can stroke a line at a changing width; vellum offsets the polyline itself in
  that case, building the region a round nib of varying radius sweeps. The
  second is that width varies linearly *between vertices*, so a taper is only as
  smooth as the polyline under it — raise `n` on `bezier_grob()`/`spline_grob()`,
  whose flattening happens before `stroke_to_path()` ever sees the curve.

  With `lwd_profile = NULL` — every call written before this release — the
  function takes exactly the code path it always took, and the outline is
  byte-identical to 0.6.8, which a test and a PNG baseline both assert. A
  *constant* profile such as `lwd_profile = 1` deliberately does not make that
  promise: it goes through the new offsetter, so it matches the old expansion as
  a picture but not to the last bit.

## Animation

* **The tween carries one eased fraction per property class, not one for the
  whole scene.** `vl_render_animation()` gains `frac_col`, `frac_size` and
  `frac_alpha` alongside `frac`, each an optional per-frame schedule for one
  class of drawn property. This is what lets a grammar layer offer per-aesthetic
  easing — position arriving on a cubic curve while colour crossfades linearly.

  `frac` drives coordinate geometry and every discrete attribute's halfway snap;
  `frac_col` drives paints and per-element colour vectors; `frac_size` drives
  `lwd`, marker size, radii and `linemitre`; `frac_alpha` drives opacity **and
  the enter/exit fade of keyed elements**.

  All three default to `frac`, and passing four identical schedules is
  byte-identical to the previous single-fraction tween, so existing animations
  are unchanged.

## Accessibility

* **Fix: an all-decorative described scene lost its tagged Figure.** When every
  drawn node was decorative (`role = "presentation"`, `"grid"`, …) but still
  carried metadata such as a provenance `id`, the per-mark tagging path fired on
  that metadata alone — suppressing the single whole-content span — and then, since
  decorative nodes are artifacts rather than structure entries, the tagged PDF was
  left with no `Figure` and no `Alt` at all. Decorative metadata no longer counts
  as per-mark metadata: such a scene keeps its single `Figure` carrying the
  `describe()` text, with the marks as its artifact content. This is what lets a
  charting frontend tag its marks `role = "presentation"` to get one clean figure
  description instead of a screen reader announcing every mark's internal id.

# vellum 0.6.8

## Linting

* **Fix: `invisible_fill` and `bleed` fired on every plot a grammar layer
  produces.** Found by running the new rules against vellumplot's output, where
  each of five ordinary plots collected one of each with no true positives among
  them.

  `invisible_fill` now exempts a mark that spans its whole viewport. Something
  filling its entire container is a substrate rather than a mark — a theme's page
  background, a panel backdrop — and painting the page in the page's own colour
  is how you guarantee an opaque export, not an oversight. A mark that merely
  sits inside the viewport is still reported.

  `bleed` now exempts text, which is most of what the rule was reporting. A label
  is routinely placed in a strip sized from an approximate metric and overhangs
  it by a few pixels; measured across that corpus, every escape was an axis or
  plot title clearing its strip by 4–8 px and none was a mark. A non-text mark
  escaping an unclipped viewport is still reported.

The linter grew from 7 rules to 20, and from something you read to something you
can gate a build on. `vignette("inspecting-scenes")` covers all of it.

* **Thirteen new rules.** The one worth having first is `truncated`: `offscreen`
  and `clipped_away` both require a mark to be *entirely* gone, so the defect
  that actually ships — the axis label with its last characters cut off, the
  title chopped by the page edge — had no rule at all. It reports how much was
  lost, as a warning for text and a note otherwise.

  Then, in rough order of how hard they are to catch by eye:

  * `cvd_collision` — two colours a reader is meant to tell apart that a
    colour-blind reader cannot. Nobody catches this by looking, because the
    person looking can see the difference.
  * `font_fallback` — a character no font on *this* machine can draw, which
    renders as a tofu box. Deliberately machine-dependent, which makes it the
    rule most worth running on CI rather than on the author's laptop.
  * `invisible_fill` — a mark filled in the page's own background colour with no
    outline. Painted, correctly sized, correctly placed, and invisible.
  * `occluded` — an opaque mark completely hidden behind a later one: ink that
    never reaches the page, usually a layer ordering mistake.
  * `label_on_mark` — a label swallowing the mark it annotates, which is exactly
    what `vl_repel()` exists to fix.
  * `overplotted` — a batched mark dense enough to hide its own distribution,
    measured per layer so it names the one to fix, and suggesting `datashade()`.
  * `hairline` — a stroke under half a pixel, which the raster backends render as
    a dpi-dependent smudge and the vector backends as a crisp line.
  * `subpixel` — an area mark less than a pixel across.
  * `bleed` — a mark drawn outside a viewport that does not clip.
  * `duplicate_name` — two nodes sharing a name, which silently makes all but the
    first unaddressable by `get_node()`, `edit_node()` and `vl_repel()`.
  * `double_draw` — the same mark drawn twice in the same place.
  * `blank_label` — a text mark with no visible characters.

  Every rule was checked against realistic figures as well as planted defects,
  and several were deliberately narrowed as a result: a bar chart with value
  labels, a panel with axis text, a scatter grazing its clip and a viewport-filling
  background rect all lint clean, and there are tests to keep it that way. The
  same applies to `cvd_collision`'s threshold, which is calibrated to report
  ggplot2's default red/green pair while staying quiet on the CVD-safe Okabe-Ito
  and viridis palettes.

* **`tiny_text` gained a point floor and fires on either.** `font_px` scales with
  `dpi`, so the pixel floor alone stopped seeing illegible text on a
  print-resolution render: 4 pt at `dpi = 300` is 16.7 device px and cleared the
  7 px default comfortably. `min_text_pt` (default `6`) asks the other question —
  can a human read this. Text between 6 pt and the pixel floor may now be
  flagged where it was not before; pass both arguments to move both floors.

* **`vl_lint_assert()` turns a lint into a gate** for a test suite or a CI job,
  without vellum taking a testthat dependency. `severity = "note"` fails on
  anything at all; `on = "warn"` reports without stopping.

* **`vl_lint_overlay()` draws the findings onto the scene** — a box round each
  one, labelled with the rules that fired, red for warnings and orange for
  notes. For a graphics linter this is usually the faster way to read a report: a
  message says a mark is clipped, an outline shows you which.

* **`vl_lint(exclude = )` suppresses findings for named nodes.** Suppression is
  by node, since `rules` already selects rules, and the usual case is one
  deliberate oddity in an otherwise clean figure — without it a project with a
  single intentional off-canvas mark could never reach a clean lint to assert on.
  An entry matching nothing warns, because a stale exclude list looks exactly
  like a working one. `vl_lint(severity = )` likewise overrides a rule's own
  severity for a project that cares about it more, or less, than vellum does.

* **Findings carry the node's device-px box**, so a caller can point at a defect
  rather than only describe it — which is what the overlay is built on. A rule
  reporting something with no geometry gets `NA`.

* **A failing rule is reported instead of aborting the lint.** The registry is
  open to downstream packages, and one broken rule used to lose every other
  rule's findings behind an opaque
  `Error in get(id, envir = .lint_rules)$fn(...)`. Failures come back as a
  `rule_error` finding naming the rule, as does a rule returning a data frame
  without the required columns.

* **Rules can see more, and describe themselves.** `ctx` gained `elements()` —
  the per-element table, the only honest view of a batched mark, since a scatter
  is one node whose box is the union over every point — and
  `region(x0, y0, x1, y1)` for a whole block of composited pixels rather than
  probing point by point. Both are lazy, like `pixel()`. The node table gained
  the resolved `fill` and `fill_kind`, `lwd_px`, the viewport id and extent, and
  a `notdef` count. `vl_lint_rule()` takes `kinds`, `needs_pixels` and `tags`: a
  rule naming the kinds it reads is skipped on a scene with none of them, and
  `vl_lint_rules()` reports all three.

* **Fix: the lint node table reported light colours wrongly.** `col` was packed
  as `0xRRGGBBAA` into a signed 32-bit integer, which overflows as soon as red
  reaches 128 — `#EEEEEE` came back as `-286331137` and unpacked to a red channel
  of `-18`. `low_contrast` therefore mis-measured the luminance of every light or
  reddish text colour, landing on the right side of its threshold by luck rather
  than by arithmetic. Colours are now packed as doubles, which hold all 32 bits
  exactly. Reported contrast ratios change accordingly: the README's `#F2F2F2`
  watermark on white is 1.1:1, not the 1.4:1 previously claimed.

* **`invisible` also catches a fill that is present but fully transparent.**
  `fill = "#FF000000"` sets a colour and then asks for none of it; `has_fill`
  cannot see that, and the fill's alpha channel can.

* **`label_overlap` no longer compares every pair of labels in interpreted R.**
  The collision search moved to a sort-and-sweep in Rust, which drops a
  quadratic term: the detection itself goes from 3.02 s to 0.007 s on 2400
  labels, and a full `vl_lint()` of that scene from 7.78 s to 2.14 s. At a few
  hundred labels the win is smaller, because compiling the scene dominates
  either way. Results are unchanged, and tests assert the sweep agrees with the
  all-pairs check it replaced. `occluded`, `label_on_mark` and `double_draw` were
  measured and left alone — their inner loops are already vectorised, and they
  cost milliseconds on 400 marks.

## Other changes

* **Fix: knitting a scene with a `dpi` chunk option errored.** A YAML `dpi: 150`
  parses as an `<integer>`, and the display path passed it straight to the
  scene's `@dpi` property, which is declared `<double>` - S7 rejected it with
  `@dpi must be <double>, not <integer>`. The chunk dpi is now coerced.

* **Internal: the sources are clean under the `jarl` linter.** Dropped a dead
  `.diff_body()` helper, hoisted assignments out of `for()` heads and out of
  `on.exit()` (via a new `.set_debug_reg()` setter), added the leading zero to
  fractional literals in the vignettes, and removed the redundant `vellum:::`
  prefix from the test suite, which already evaluates inside the package
  namespace. The `:::` calls that reach Rust kernels from the vignettes and
  `inst/` scripts are genuinely required and carry a `# jarl-ignore` with a
  reason. No user-visible behaviour changes.

# vellum 0.6.7

* **Fix: an animated SVG showed one frame and then near-nothing.** Every frame is
  rendered separately, so each restarted its `<defs>` id counters and the whole
  document ended up with N copies of `id="c0"`. All N `clip-path="url(#c0)"`
  references therefore resolved to the *first* frame's clip — which lives inside
  a `visibility:hidden` group, and a hidden `<clipPath>` child contributes no
  geometry, so the clip was empty for the 47/48 of the cycle when frame 0 was
  hidden. Everything inside the panel was clipped away, leaving only the axis
  labels and legend drawn outside it, and the plot appeared to blink once and
  then vanish. Generated `<defs>` ids now carry a per-frame prefix.

* **Fix: animated SVG frames played in reverse.** The per-frame negative
  `animation-delay` was offset by `i` rather than `n - i`, so after frame 0 the
  cycle ran backwards (0, n-1, n-2, …).

* **Fix: a gradient (or pattern) `col` collapsed to its first stop on circle
  outlines.** Circles take a batched fast path that draws a unit circle placed
  by an affine transform; a gradient stroke is resolved in viewport pixels, so
  on the unit circle it sampled a single point of the ramp and rendered one flat
  colour. The same gradient stroked rects and polylines correctly. A gradient/
  pattern stroke now drops circles to the per-element, real-coordinate build (as
  rects already did), so the ramp runs along the outline. Solid strokes keep the
  fast path and render byte-identically.

* **`svg_grob()` can size an icon to its `viewBox`, and read a whole `<svg>`.**
  Icon sets share one `viewBox` per family and pad each glyph inside it, so
  sizing to the glyph's own *ink* blew every icon up to `size` individually — a
  sparse glyph rendered far larger than a dense one from the same set, and a lone
  icon larger than its nominal box (the reported ~2.5× oversize). `svg_grob()`
  now takes a `viewbox` argument (`c(xmin, ymin, width, height)`, or the raw
  `"0 0 24 24"` attribute string) and maps the *box* to `size`, so glyphs keep
  their intended relative and absolute size. Passing a whole `<svg>…</svg>`
  element as `d` reads its `<path>` geometry and `viewBox` automatically (needs
  \pkg{xml2}; non-`<path>` shapes are reported, not silently dropped). With no
  viewBox the previous ink-bounds sizing is unchanged.

# vellum 0.6.6

* **Fix: `element_geometry()` and `vl_nearest()` reported viewport-local
  coordinates, not device pixels.** The pick table resolved every vertex through
  `vp.x_pos()`/`y_pos()` — which answer in the viewport's own frame — and never
  applied the viewport's transform. So for any viewport not at the page origin,
  which is every panel of every real plot:

  - `element_geometry()` was off by the viewport's offset, and *internally
    inconsistent*: `text` and `roundrect` rows went through `node_bbox()` and
    came back in device px, while `segment` / `line` / `polygon` / `path` /
    `point` / `rect` rows stayed local. One table, two coordinate systems.
  - `vl_nearest()` compared a **device-px** probe point against those local
    coordinates, so its answers in an offset panel were not merely imprecise but
    wrong — it would report a mark at distance 0 with the cursor nowhere near it,
    and rank the mark actually under the cursor far down the list.

  Both now report device pixels with y down, matching `scene_model()`'s boxes and
  the rendered SVG, as documented. A round mark's radius takes the transform's
  scale as well as its translation.

  This is the same bug `lint_table()` had before 0.6.1, and it survived for the
  same reason: every test in `test-pick.R` drew into the default full-page
  viewport, where the transform is the identity and local *is* device. The
  regression tests added here use an off-origin viewport.

  Nothing rendered changes — the pick table feeds no drawing path.

* **Docs fix: the leader-line example placed labels and drew leaders from two
  different solves.** `vignette("placement")` and `inst/examples/labels.R` both
  computed `vl_place(scene)`, drew leaders from that answer, and *then* called
  `vl_repel()` on the scene with the leaders already in it. The leaders are
  obstacles to that second solve — and since each one lies exactly along the path
  its label wanted to take, and `vl_place()` works on bounding boxes (so a
  diagonal segment blocks the whole rectangle spanning it), the labels were
  pushed back the way they came. The median leader ended up **146°** from the
  label's real displacement, with half of them pointing essentially backwards.

  Both now place first and annotate afterwards, which makes the leaders exact,
  and both say why. No engine change — `vl_repel()` was applying the solve it
  reported all along. The general rule, now stated in the article: **anything you
  add to a scene becomes an obstacle to a later solve.**

# vellum 0.6.5

* **`vl_lint()`'s contrast rule no longer cries wolf on ordinary axis text.**
  It sampled the backdrop at four points just outside a label's box and took the
  *worst*, so any label a single 2 px probe happened to graze against a nearby
  tick, gridline or axis rule read as ~1:1 — flagging dark axis text on white on
  essentially every plot. It now takes the **second-worst** of the four sides:
  incidental adjacent ink on one side is ignored, while a label genuinely on a
  low-contrast field (all sides) or straddling a dark region (two sides) is still
  flagged.

* **Gridlines (`role = "grid"`) are treated as decorative in tagged PDF.** A node
  with `role = "grid"` — the role a downstream sets so an interactive SVG host can
  find and hide the gridlines — is now a PDF *artifact* (skipped by a screen
  reader) alongside `"presentation"`/`"none"`/`"decorative"`, rather than a bogus
  `Figure` in the structure tree. The SVG role is unchanged, so the host selector
  still works. Found while wiring `vellumplot`'s accessibility pass.

# vellum 0.6.4

* **Fixed: `grobwidth()`/`grobheight()` of a width-constrained `text_grob()`
  ignored the wrapping.** The renderer wraps a `text_grob(width=)` to its box and
  auto-fits when `fit=` is set, but the measurement path (`.grob_extent()`, what a
  `grobheight`/`grobwidth` unit resolves to) measured the *unwrapped* line. So a
  layout track sized by `grobheight()` reserved a single line for a label that
  drew as several, and the wrapped text overran whatever sat above it. Extent now
  wraps the label to `width` (in mm), stacks the resulting lines, and applies the
  same auto-fit shrink as drawing — so a reserved region matches the glyphs that
  land in it. Plain labels only; rich `md()` labels are unchanged (the renderer
  does not width-wrap them either). Found while wiring wrapped plot
  titles/subtitles/captions in `vellumplot`.

# vellum 0.6.3

* **Fixed: a keyed multi-box `roundrect_grob()` aborted `scene_model()`, and a
  keyed one silently dropped every key past the first.** `roundrect_grob()` is a
  batch — one rounded box per `(x, y, width, height, r)` element — but it
  recycled `key`/`meta` to length 1, so `roundrect_grob(key = c("a", "b"))` kept
  only `"a"`. And `scene_model()` classed roundrect as a single shape (one row
  per grob), so a grob drawing N keyed boxes reported one element against the
  backend's N and aborted on the count check. Roundrect is now a keyed batch,
  like `text_grob()`: each keyed box is one `scene_model()` row carrying its own
  key/meta, and an unkeyed roundrect stays out of the model. Rendering is
  unaffected (`scene_model()` is interactivity metadata only). Found while wiring
  keyed data-label backgrounds in `vellumplot`.

# vellum 0.6.2

* **Fixed (breaking): `vl_contour()` transposed its input matrix.** It assumed
  rows indexed y and columns x. Base R is the opposite — `image()`, `contour()`,
  `persp()` and `contourLines()` all take `dim(z) == c(length(x), length(y))`,
  i.e. **rows index x** — and that is also the shape `outer(xs, ys, f)` produces,
  which is how a grid is normally built.

  So every contour came back reflected across the diagonal. On a symmetric
  surface that is invisible; over a density with a reference layer under it,
  it is obvious. The documentation compounded it by citing `image()` as the
  authority for the opposite of what `image()` does.

  `vl_contour()` now matches base R. **If you were transposing your matrix to
  work around this, stop.** Code that passed `outer(xs, ys, f)` directly was
  getting transposed output and is now correct with no change.

  The test suite missed it because every contour test used a grid symmetric in
  its two arguments. The new tests use an asymmetric surface and check against
  `grDevices::contourLines()` rather than against our own expectation.

# vellum 0.6.1

* **Fixed: node bounding boxes were viewport-local, not device coordinates.**
  `lint_table()` resolved a node's box through its viewport's *scales* but never
  applied the viewport's own *placement*, so for any viewport not at the page
  origin it disagreed with `element_table()` by the viewport's offset — which is
  every real plot with a panel.

  Everything built on it inherited the error. `vl_repel()` solved labels against
  obstacles it believed were elsewhere, so on a panelled scatter it left labels
  sitting on top of the very markers it was asked to avoid (22 of 22 in the
  regression case, now 0). `vl_lint()`'s `offscreen` and `low_contrast` rules
  looked at the wrong part of the page, and `vl_nearest()` misplaced text and
  rounded rects.

  It was invisible in the test suite because tests draw into the default
  full-page viewport, where the transform is the identity and local *is*
  device. `scene_model()` was never affected — it takes geometry from
  `element_table()`, which was correct — so `vellumwidget` is unaffected.

# vellum 0.6.0

Six phases of engine work: a typography layer, label placement, geometry
operations, accessible output, new output destinations, and addressable marks.
Every mark family can now carry a data key, text can be wrapped or set along a
curve, labels can be repelled, paths can be combined, PDFs are tagged, and
scenes render to animated SVG, multi-page PDF or a parallel batch.

Verified byte-identical across 11 scenes and 4 output paths throughout, except
where a fix deliberately changed output (noted below).

* **Fixed: `vl_repel()` was defeated by a panel background.** The default
  obstacle set is "everything that is not a label", which on a real plot
  includes the panel background rectangle — and a label inside it collides with
  it wherever it goes, so it could never be placed. On a two-panel scene, 29 of
  32 labels were unresolvable; now 2.

  An obstacle that wholly contains a label is no longer treated as an obstacle
  for that label. That is also right for a bar or region a label deliberately
  annotates from the inside, where pushing the label out would be exactly wrong.

* **Fixed: `vl_repel()` could push labels off the page.** Resolving a collision
  by shoving a label off the canvas is strictly worse than the collision — an
  overlapping label is hard to read, an off-canvas one is gone. Solved positions
  are now bounded by the label's clip region intersected with the page, widened
  to include its own anchor so a label deliberately placed off-page stays put.

* **Fixed: a halo ate the neighbouring glyphs on `text_path_grob()`.** Placing
  each glyph as its own draw broke the rule that every glyph is stroked before
  any is filled, so each halo painted over the previous glyph's fill. Haloed
  text on a curve is now stroked in one pass and filled in another, as straight
  text already was.

* **Fixed: `render_all()` ignored `_R_CHECK_LIMIT_CORES_`.** `R CMD check` sets
  it and `parallel::mclapply()` errors above two processes under it, so any
  package depending on vellum would have failed its own check.

* **Every mark family can now carry an element `key`.** `lines_grob()`,
  `polygon_grob()`, `path_grob()`, `roundrect_grob()` and `text_grob()` gain
  `key`/`meta`, joining the batched marks that already had them;
  `bezier_grob()`, `spline_grob()`, `svg_grob()` and `contour_grob()` inherit it.

  A key is what makes a mark addressable — it becomes `data-key` in the SVG and a
  row in `scene_model()`. Until now a line, an area, a choropleth region or a
  data label could not carry one, so they could never be hovered, tooltipped,
  brushed or cross-filtered by an interactive host. Now a whole series can be one
  addressable thing.

  Keyed text reports one element per label. Note the deliberate asymmetry with
  the batched marks: lines, polygons, paths and text appear in `scene_model()`
  **only when keyed**, because a plot is full of unkeyed gridlines and axis
  labels that would otherwise bury the marks that mean something.

* **`vl_nearest()` and `element_geometry()` — hit-testing that respects the
  shape.** A bounding box is the right answer for a rectangular brush and the
  wrong one for anything diagonal or thin: a line across a panel has a bounding
  box covering the whole panel, so a box-based "what is nearest" matches it from
  anywhere in the plot.

  `vl_nearest()` measures to the real geometry — perpendicular to a segment, to
  the disc for round marks, and **zero anywhere inside** a closed polygon, so
  clicking the middle of a choropleth region hits the region.

  `element_geometry()` returns that geometry instead of the answer, for hosts
  that cannot call R on every mouse move: a browser takes the vertices once and
  computes distances locally.

* **Animated SVG.** `vl_render_animation(format = "svg")` emits the same
  keyframe schedule as vector markup, shown in turn by a CSS step animation —
  resolution-independent, and honouring `prefers-reduced-motion`.

  Choose it by scene complexity, not by preference. Every frame is emitted in
  full, so size grows with complexity times frame count where a raster format's
  does not. Measured on a 30-frame scatter, gzipped: 20 marks → 20 KB vs GIF's
  61 KB; 2000 marks → 720 KB vs GIF's 124 KB. Line art wins clearly; dense marks
  do not. Above 5 MB vellum warns rather than letting you find out later.

* **`pdf_pages()` — several scenes as the pages of one PDF.** A report's
  figures, one facet per page, an animation as a contact sheet. Pages may differ
  in size, and each page's tagging survives into the document's structure tree.

* **`render_all()` — render many scenes across cores.** Embarrassingly parallel,
  one whole scene per worker. About 3× on four report figures, and asserted
  byte-identical to rendering them one at a time. Named scenes plus a directory
  names the files.

* **Fixed: a tagged multi-page PDF orphaned its earlier pages' structure.** A
  document has exactly one tag tree; each page was setting its own, discarding
  the previous. Found by building `pdf_pages()`, and only reachable there.

* **Tagged PDF output.** The per-mark `id`/`role`/`name` channel now builds a PDF
  structure tree: a `StructTreeRoot`, a `Figure` for the plot as a whole carrying
  the `describe()` text, and one structure element per marked-up mark, in draw
  order — which for a graphic is reading order.

  This needs no new annotation API: a scene already marked up for the web is
  already marked up for PDF. `role = "presentation"` marks a node a PDF
  *artifact*, so gridlines and panel backgrounds are skipped by assistive
  technology rather than read aloud.

  Structure is metadata — the rendered pixels are unchanged — and a scene with no
  marked-up nodes produces exactly the PDF it always did.

* **`scene_fonts()`, `font_pin()` and `font_check()`.** vellum claims identical
  pixels on every OS and in CI. Layout, shaping and rasterisation deliver that;
  font *resolution* does not and cannot, since `"sans"` is a different file on
  every platform.

  These make that gap visible rather than pretending it away: `scene_fonts()`
  reports the faces the text actually resolved to (read off the shaped glyphs),
  and a pin next to a reference image lets a failing comparison be attributed —
  your change, or the machine's fonts.

  They deliberately do not bundle fonts. vellum resolves through
  \pkg{systemfonts} so it agrees with the rest of R's graphics stack; for a
  guarantee rather than a check, register the exact file with
  `systemfonts::register_font()`.

* **`vl_path_op()` — boolean operations on paths.** Union, intersection,
  difference and exclusive-or over closed rings.

  The result is **geometry**, not a render-time mask, and that is the point: it
  is an ordinary path, so it can be measured, hit-tested, simplified, filled
  with its own gradient, stroked along the boundary the operation created,
  exported as `<path>` data, and used as the operand of another boolean. A clip
  can do none of those, rasterises, and degrades on some PDF paths.

  `rule` describes how to read the **inputs** — whether a ring inside another is
  a hole or an island — and operands must be in a single coordinate space, since
  a boolean has to be computed somewhere.

* **`vl_contour()` and `contour_grob()` — contours from a grid.** Marching
  squares over any matrix, with saddle cells resolved from the centre value
  rather than an arbitrary fixed choice, and cells with missing corners skipped
  so a contour breaks around a hole instead of being drawn through it.

  Segments are chained into continuous polylines. Under a solid stroke that is
  invisible; for everything else it is not — an unchained contour restarts its
  dash pattern in every grid cell and cannot be simplified, measured or closed.
  Closed contours come back marked `closed`, so a filled density contour is a
  `path_grob()` away.

* **`svg_grob()` and `vl_svg_path()` — SVG path data as scene geometry.** The
  full `d` grammar, including relative forms, implicit repeated commands, the
  smooth-curve reflection rules, and elliptical arcs with the packed flag form
  minified icon files use. Icon sets ship one `<path d="...">` per glyph, so
  this is what makes crisp vector markers possible.

  It reads path *data*, not SVG documents — no stylesheets, gradients, `<use>`,
  clip paths or element transforms. Use an XML parser to pull `d` strings out of
  a file.

* **Fixed: `draw()` accepted a list of grobs and then failed to compile it.**
  The list was appended as one child and the failure surfaced much later as
  `Can't find method for compile(<list>)`. A list now draws each element.

* **`lines_grob()` now rejects a multi-value `id`.** Its `id` is the
  accessibility identifier, but `path_grob()`'s is a *grouping* variable — the
  same argument name with the opposite meaning. Passing a grouping vector by
  analogy silently drew one polyline through every group, joining them with
  straight lines across the plot.

* **`vl_repel()` / `vl_place()` — label placement as an engine service.**
  `vl_place()` solves label collisions over a scene's resolved geometry and
  reports each label's displacement; `vl_repel()` applies it and returns a new
  scene.

  The solve runs in device pixels and the answer is applied as an absolute
  millimetre offset on top of each label's existing coordinate. That is what
  makes it coordinate-system-agnostic: a label anchored in `native` units inside
  a polar, faceted or warped panel moves by the same mechanism as one in `npc`
  on the page, and every panel is solved together rather than one at a time.

  It moves labels; it does not decide which to drop, shrink or abbreviate.
  Labels that cannot be placed are reported with `resolved = FALSE` rather than
  silently piled up or quietly deleted — that call needs to know what the labels
  mean, and belongs above the engine.

* **`vl_empty_region()` — the largest empty rectangle in a scene.** Where a
  legend, annotation or watermark can go. Occupancy is rasterised onto a grid,
  so the answer is exact on that grid and conservative off it: boxes round
  outward, and it will never claim space that is in fact occupied. It reports
  millimetres on request, which is the absolute measure `text_grob(width = )`
  wants — so an annotation can be fitted to the gap that was just found.

* **`vl_hull()` and `vl_buffer()`.** Convex and concave hulls of a point set,
  and outward offsetting of a ring — for outlining a cluster and building the
  exclusion zone around it. Note that `concavity` runs the opposite way to what
  the name suggests: larger is *more* convex, `Inf` is the convex hull, and
  below about 3 the boundary starts to self-intersect.

* **`element_table()` gains `name`, `kind` and a node index**, and
  `lint_table()` gains the matching node index, so the per-element and per-node
  views of a scene can be joined. Without this a batched mark is a single node
  whose box is the union of every element, which makes a scatter read as one
  panel-sized obstacle.

* **Text that fits a box.** `text_grob(width = )` wraps a label to an absolute
  measure; `align` sets `"left"` / `"centre"` / `"right"` / `"justify"` within
  the box; `fit = TRUE` shrinks the font until the wrapped block fits
  `width` × `height`.

  Break decisions are made on the **shaped** width of each candidate line rather
  than a sum of word advances, so kerning and any active OpenType feature are
  accounted for and a line can never render wider than it measured. That is what
  makes auto-fit trustworthy rather than approximate.

  `width` must be an absolute unit (`mm`/`cm`/`in`/`pt`), and relative units are
  rejected with an explanation. Wrapping happens when the grob is *built*, and a
  viewport's size in `npc`/`native` does not exist until render time — which is
  also the reason this cannot be built on grid at all, where a string has no
  width until a device is open.

* **`text_path_grob()` — text set along a curve.** Each glyph keeps the pen
  position shaping gave it and is placed that far along a polyline baseline,
  rotated to the local tangent. `offset` sets a perpendicular standoff.

  Halos, OpenType features, per-glyph colour and clipping all still apply, and
  all three backends handle it — SVG stays real `<text>`, PDF stays copyable.
  Glyphs follow the tangent as in SVG `textPath`, so a label on the underside of
  a closed curve reads upside-down; reverse the *path* to fix that, not the
  glyphs.

* **Fixed: multi-line text hung below its anchor.** A block of *n* lines was
  centred `(n-1)·lineheight/2` too low — at 12 pt a six-line block sat half an
  inch below where it should. Vertical justification is now correct at top,
  centre and bottom for any line count. **This changes the rendering of existing
  multi-line labels.**

* **Fixed: multi-line text collapsed to one line in SVG.** SVG `<text>` ignores
  newlines, and vellum emitted one element per label, so a multi-line label
  rendered as a single run of text with the breaks turned into spaces. Each line
  is now its own element. Single-line labels are untouched, and a label whose
  lines cannot be matched to its glyphs (a blank line, which produces none)
  falls back to glyph outlines rather than guessing.

* **Per-segment stroke style.** `segments_grob(col = , lwd = )` take one value
  per segment, mirroring the per-element `fill` that `hexagon_grob()` and
  `sector_grob()` already carry. Previously varying either meant building **one
  grob per segment**, and grob construction is the dominant expense on scenes
  made of many small marks.

  A single grob with per-element style renders byte-identically to N grobs each
  with its own `gp` (asserted in tests). No backend can stroke segments
  differently in one call, so each is still stroked on its own in the output —
  the saving is in R, not in the file size. Absent, the batch draws in one
  combined stroke exactly as before.

* **`vl_hatch()` — hatch fills as geometry.** Fills a shape with ruled lines at
  a given angle, spacing and width. Unlike `vl_pattern()`, which rasterises a
  tile, a hatch is real geometry: crisp at any zoom, correct in print, and
  emitted as `<path>` data in SVG rather than an embedded image.

  The reason it matters is accessibility. A categorical encoding that fails for
  a red/green-blind reader — which `render(cvd = )` shows you and `vl_lint()`
  flags — is fixed by encoding with **texture as well as hue**. vellum could
  already diagnose that problem; now it can solve it.

  It is expanded in the scene walk into stroked spans, computed by scanline
  crossing against the shape, so no backend needs a hatch primitive and only the
  spans actually inside the shape are emitted.

* **Fixed: `gp$fill` never reached `hexagon_grob()` or `sector_grob()`.** Those
  marks take a per-element fill *colour*, and the shared gpar fill was not passed
  to them at all — so a gradient or pattern there silently drew nothing. Both now
  fall back to the shared paint when no per-element `fill` is given, which means
  gradients, patterns and hatches work on them for the first time. An explicit
  per-element `fill` still takes precedence.

* New example `inst/examples/hatching.R`; `vignette("scene-and-paint")` gains a
  hatching section and `vignette("render-quality")` now points at it as the fix
  its CVD section was missing.

* **A scene is now a value you can save, fingerprint, compare and compose.**
  `scene_write()` / `scene_read()` persist a built scene (`.rds`, or `.json`
  with jsonlite) and rebuild it to byte-identical pixels; `as_scene_spec()` /
  `from_scene_spec()` are the plain-list form underneath. The conversion is
  generic over the S7 property model rather than written per grob type, so a
  grob added later serializes with no change to the serializer.

  This is one level below `vellumplot`'s *plot* spec and composes with it: a plot
  spec is portable and re-renderable at any size, a scene spec reproduces exactly
  this scene.

* **`scene_hash()`** fingerprints content — two independently-built identical
  scenes agree, any change to what is drawn does not. Usable as a cache key or a
  test assertion.

* **`scene_diff()`** reports *what* changed, in scene terms
  (`root$children[1]$gp$fill: steelblue -> tomato`) rather than as a pixel diff.
  That makes it a better basis for visual-regression testing than comparing
  images, because an image diff is sensitive to the font stack and a structural
  one is not.

* **`scene_inset()`** places one scene inside a region of another. Because a
  scene has a known resolved size this is a graft, not a re-render, and the
  result is an ordinary scene: the inset is an addressable node that can be
  edited by name, inset again, or serialized. The *policy* questions
  (should panel edges align? should axes be shared?) stay above vellum, in a
  grammar; the engine supplies the ability to nest at all.

* New article `vignette("scenes-as-values")` and example
  `inst/examples/serialize.R`.

* **Gradient strokes.** `vl_gpar(col = linear_gradient(...))` strokes *with* a
  gradient — the same paint model `fill` already had, applied to the region the
  line covers instead of the region a shape encloses. A trajectory can carry its
  colour along itself, and it is real paint on every backend (a tiny-skia
  shader, SVG `stroke="url(#…)"`, a krilla shading) rather than the usual
  workaround of emitting hundreds of one-segment lines in slightly different
  flat colours. It applies to any stroked path, outlines included, and inherits
  from a viewport like every other stroke property.

  Text and markers fall back to the gradient's first stop, because a glyph run
  has no path to run a ramp along; a *pattern* in `col` falls back to the colour,
  because a pattern needs cell geometry a stroke does not have.

* **`vl_gpar(dash_phase = )`** sets how far into the dash pattern a line starts,
  in multiples of `lwd` so it scales with the line width exactly as the nibbles
  do. Aligns dashes across adjacent strokes, and animating it gives marching
  ants. Reaches SVG as `stroke-dashoffset` and PDF as krilla's dash offset.

* New example `inst/examples/strokes-paint.R`; `vignette("scene-and-paint")`
  gains sections on stroking with a gradient and on dash phase.

* **Dense paths are simplified at render resolution.** A coastline or a long
  time series carries far more vertices than the canvas has pixels to
  distinguish; vellum now drops the ones that could not have changed a pixel.
  Worth **1.7–2.5× on render time and 65–75% of the SVG size** at 50,000
  vertices. It is automatic, and the dial is `options(vellum.simplify)` — a
  Douglas–Peucker tolerance in device pixels, default `0.1`, `0` to disable.
  Only the renderer knows the output resolution, which is why this belongs here
  rather than in a data-preparation step.

  Like the marker-sprite and glyph-bitmap fast paths this is a deliberate
  fidelity trade, so it engages only where the win is real: paths under 1000
  points per sub-path are never touched and stay byte-identical.

* **`stroke_to_path()`** converts the stroke of a line-like grob into a
  `path_grob()` describing the region it covers — so a line can be filled with a
  gradient or a pattern, or handed to a cutting plotter that needs a closed
  shape rather than a centreline. It uses the same stroker the rasterizer uses,
  so the outline is exactly what would have been inked. The result is absolute
  (mm): an outline is a shape baked at one size, not a stroke that rescales.

* New example `inst/examples/geometry.R` and benchmark
  `inst/benchmarks/simplify.R`; `vignette("scene-and-paint")` gains sections on
  filling a line and on dense paths.

* **`vl_lint()` — static analysis for graphics.** Resolves the scene and
  inspects the geometry the renderer would draw with, reporting the things
  people otherwise find by squinting at a PNG: a mark that landed off-canvas or
  outside its viewport's clip, an element nothing will paint (no fill, no
  stroke, or zero alpha), text below a legibility floor, overlapping labels, and
  text whose contrast against its actual rendered backdrop falls below the WCAG
  threshold. This is possible because vellum resolves layout and text metrics
  *before* drawing — a layer above grid cannot ask how many pixels tall a label
  is, because the answer does not exist until a device is open.

  The rule set is a registry: `vl_lint_rule()` lets a package layered on vellum
  add its own, so a grammar's semantic rules and vellum's geometric ones come
  back from one call.

* **`scene_stats()`** reports ink coverage, distinct colours, and an
  **overplotting index** — the honest signal for "should this be
  `datashade()`-ed?". A mark count says nothing about overlap: 2000 scattered
  points score 4.3, the same 2000 clustered score 91.

* **`profile_render()`** attributes render cost to the marks that caused it, and
  splits **build** / **compile** / **raster**. Read the phase split first:
  compile time is R-side, and on scenes with many small grobs it dominates, in
  which case tuning the backend cannot help. Timing is armed only for that call,
  so ordinary renders pay nothing.

* New example `inst/examples/linting.R`.

* **Colour-vision-deficiency simulation.** `render(scene, path, cvd =)`,
  `scene_png(cvd =)` and `scene_raster(cvd =)` re-render the finished raster as
  a viewer with `"protanopia"`, `"deuteranopia"`, `"tritanopia"` or
  `"achromatopsia"` would see it, using the Machado et al. (2009) matrices
  applied in **linear light** (doing it in sRGB is the common shortcut and it
  shifts lightness). An accessibility check becomes an argument rather than an
  export-and-upload round trip. Raster only -- a vector format has no pixels to
  transform, and `render()` says so rather than silently writing an unsimulated
  file. The simulation is never written into the render cache.

* **Blur, drop shadow and glow as group effects.** `vl_viewport(blur =)` and
  `vl_viewport(shadow = vl_shadow(dx, dy, blur, col))` act on the composited
  layer, so overlapping shapes inside a viewport blur -- or cast a single
  shadow -- *together* rather than each shadowing the others. A glow is a shadow
  with no offset. Raster convolves (three box passes, the standard Gaussian
  approximation); SVG emits native `feGaussianBlur` / `feDropShadow` and stays
  vector; PDF has no filter model and reports it through the usual degradation
  warning instead of quietly rasterising your vector output.

* **`vl_gpar(crisp = TRUE)`** snaps axis-parallel strokes onto the pixel grid. A
  1-px rule at a fractional coordinate straddles two rows and renders as two
  grey ones -- the reason gridlines look muddy on screen. Diagonals are left
  alone. **`vl_gpar(antialias = FALSE)`** gives hard pixel edges, for pixel art,
  QR codes, and heatmap cells that must tile without a seam. Both inherit down
  the tree like any other graphical parameter.

* New examples `inst/examples/effects.R` and `inst/examples/cvd.R`.

* **Text halos (`shadowtext`).** `vl_gpar(halo_col =, halo_width =)` strokes the
  glyph outlines *under* the fill, so a label stays legible over a dense scatter
  or map imagery. Because vellum holds the outlines, this is one real stroke
  rather than the eight offset copies packages layered on grid have to draw --
  and it works on all three backends (raster and outline-SVG do two explicit
  passes, native SVG uses `paint-order` and stays selectable, PDF strokes then
  fills). `halo_width` is in points like `fontsize`, so a halo keeps its
  proportion at any dpi. Haloed text bypasses the glyph-sprite fast path, which
  bakes only the fill. Resolves
  [#13](https://github.com/r-vellum/vellum/issues/13).

* **OpenType feature control.** `vl_gpar(features = c(tnum = 1))` passes
  four-character OpenType tags to the shaper: tabular figures so axis labels
  stop jittering between ticks, plus small caps (`smcp`), oldstyle figures
  (`onum`), and ligature (`liga`) and kerning (`kern`) control. Features reach
  **measurement** as well as drawing -- `vl_strwidth()`, `vl_strheight()`,
  `grobwidth()` and `grobheight()` all take them, and the shape cache is keyed
  on them -- so a `grobwidth`-sized track reserves space for the glyphs that
  actually get drawn. Nothing in R's graphics stack has offered this.

* New article, `vignette("typography")`, and `inst/examples/typography.R`.

* **Text renders ~3x faster on a cold plot with many distinct labels.** PERF-1
  shaped every unique label in one `textshaping::shape_text()` call; the
  multi-line-text change replaced that with a per-label loop, so each distinct
  label re-resolved its font and font resolution grew to 56% of a cold render.
  Shaping is batched across labels again -- lines are pooled before shaping and
  re-stacked afterwards, so multi-line labels keep working. A cold 5000-label
  render goes from 1.78 s to 0.55 s. Output is byte-identical.

* **Images are ~4x cheaper to convert, and can be read from a file.**
  `raster_grob()` now takes a **path to a PNG**, decoded in the Rust backend, so
  no R image package is needed to put a picture in a plot. A numeric RGB/RGBA
  array -- what `png::readPNG()` returns -- takes a fast path that skips the
  per-pixel colour-string round-trip `as.raster()` performs: 0.21 s to 0.055 s
  at 1 megapixel, which turns an image draw from slower than grid (0.69x) into
  faster (1.38x). The pixels are identical either way.

* **`vl_gpar(cex =)`.** A multiplier on `fontsize`, as in grid, so a theme can
  ask for "20% larger" without knowing the base size. It folds into text
  drawing, `char`/`line` units, and grob measurement, so `cex = 2` is exactly
  equivalent to doubling `fontsize` everywhere.

* **`vl_convert()`** resolves a unit to a plain number in another unit --
  grid's `convertWidth()`/`convertX()` and friends. Absolute units need no
  context; `npc`/`native` resolve against the page or a named viewport.
  `axis` picks the extent and `what` distinguishes a length from a position
  (they differ for `native` when the scale does not start at zero).

* **`scene_png()` and `scene_pdf()`** return the encoded document as a raw
  vector instead of writing a file, alongside the existing `scene_svg()`
  (a string) and `scene_raster()` (pixels). Every output format can now be
  produced in memory -- for a data URI, a web response, or a connection --
  with no temp-file round-trip. Backend degradation warnings are surfaced just
  as `render()` surfaces them.

* **`render(scale =)`** renders at a multiple of the device pixels while
  keeping the same physical size -- the retina / `ggsave(scaling =)` idiom.
  It scales `dpi`, so the layout is untouched and text does not change relative
  size. Also available on `scene_png()`.

* **`print()` works again on gradients, patterns, masks, and `why_size()`
  results.** All four have `print` methods declared in `NAMESPACE`, but none of
  them dispatched: the objects printed as raw lists. `S7::method(print, cls) <-
  fn` is a replacement call, so it also bound the symbol `print` inside the
  package namespace (holding `base::print`, unchanged) — and R's
  `registerS3methods()` treats a generic whose name is a local object as a
  *local* generic, filing every `S3method(print, <class>)` into vellum's own
  `.__S3MethodsTable__.` rather than base's, where dispatch looks. Dropping the
  accidental `print`/`plot` bindings restores normal registration; the S7 methods
  for `vellum_scene` register via `S7::methods_register()` and were never
  affected. `test-print-methods.R` now guards both halves.

* **Cleaner GIF output from `vl_render_animation()`.** GIF frames are limited to
  256 colours, so on a plot (smooth panels, antialiased marks) the old
  nearest-colour quantisation left bubble edges jagged and gradients banded. The
  encoder now defaults to the best-quality NeuQuant palette (sample factor `1`) and
  applies Floyd–Steinberg dithering, and a frame that already fits in 256 colours
  is kept exact. New `gif_speed` (`1`–`30`) and `gif_dither` arguments expose the
  trade-off. GIF is still inherently lossy on a plot; `format = "apng"` remains the
  lossless option.

* **Converting between the build tree and the immutable tree is ~4-10x faster.**
  `.bnode_to_gtree()` (which runs the first time a built scene is rendered,
  edited, or queried) read the child dict with one `get()` per child; it now uses
  a single `mget()`. `.gtree_to_bnode()` (which runs when a materialised scene is
  drawn on again, or when a branched scene forks) did an `assign()` per child and
  an `S7_inherits()` type test per child; it now builds the dict with one
  `list2env()` and tests the type by attribute. Neither changes the resulting
  tree. On a scene of 20,000 sibling grobs: materialising 34 ms -> 9 ms, drawing
  onto an edited scene 106 ms -> 11 ms, branching a scene 144 ms -> 21 ms.

* **`edit_node()` is ~40x faster on large scenes.** An edit rebuilt the nodes on
  the path with `node@children[[i]] <- ...` and then wrote the new tree back with
  `S7::set_props(scene, root =)`. Both write into an *existing* S7 object, which
  makes R duplicate it first, and duplicating it deep-copies the whole children
  list hanging off its attributes — so a single edit copied every sibling grob,
  making it O(scene) instead of O(depth). Both now construct a fresh node/scene
  around the new children list, which just stores the pointer. `.find_path()` also
  reads `name`/`children` as attributes rather than through `S7_inherits()` +
  `prop_names()` + `@`, cutting the search itself by ~10x. On a scene of 20,000
  named sibling grobs: 597 ms -> 14 ms per edit (grid's `editGrob()` is 430 ms on
  the equivalent `gTree`). Scenes built from batched marks (one grob carrying many
  elements, which is what `vellumplot` emits) were already ~0.3 ms and are
  unchanged. No behaviour change: the derived tree, its `nid` re-stamping, the
  repaint-boundary cache hits, and the rendered bytes are all identical.

* **`vl_render_animation()` — non-reactive keyframe animation.** Interpolate
  between a set of compiled keyframe scenes and encode the in-between frames to a
  looping GIF, an animated PNG (APNG), or a directory of PNG frames. The tween,
  render, and encode run in one parallel, streaming pass in the Rust backend
  (`rayon` over frames): matching primitives interpolate their geometry, their
  colours (perceptually, in Oklab), and their bounded graphical parameters, while
  discrete attributes snap. The caller supplies the keyframes and a per-frame
  schedule (which keyframe pair and the eased fraction), so easing stays in R. See
  `inst/examples/animation.R`.

# vellum 0.5.1

* **`sector_grob()` and `loop_grob()` no longer render vertically mirrored.**
  Sector arcs were built directly in the y-down device frame (`cy + r·sin θ`)
  while every other primitive maps coordinates through the y-up native frame, so a
  sector drawn at angle `θ` landed where the others would place `-θ` — the
  documented "0 at 3 o'clock, counter-clockwise" contract was mirrored across the
  horizontal axis. A centroid label/point overlaid on a pie / donut / rose /
  sunburst therefore sat on the mirror image of its wedge. Sector fills, strokes,
  arrowheads, and hand-drawn (`sketch=`) wedges — and `loop_grob()`'s teardrop
  `angle`, which shared the same convention — now all honour the y-up angle
  contract (#14).

# vellum 0.5.0

* **`vl_viewport(pannable = TRUE)`: clip-stable pannable panels.** A named panel so
  marked is emitted to SVG as an outer `<g data-vellum-panel>` carrying the panel's
  clip (hoisted once, untransformed) around an inner `<g data-vellum-pan>` holding
  the content. A host can set a `transform` on the inner group to pan/zoom the
  marks while the clip and the surrounding axes stay fixed — the basis for
  host-side axis-aware zoom. SVG-only and inert for static rendering; non-pannable
  panels and the raster/PDF backends are byte-for-byte unchanged. See
  `vignette("scene-contract")`.

* **`scene_model()` no longer forces a second scene compile.** Its viewport
  id↔name capture must compile (a cache *hit* would skip the capture), but it now
  writes that compiled backend to the render cache, so a `scene_svg()` / `render()`
  that follows in the same build reuses it instead of recompiling. Restores the
  single-compile behaviour the earlier `scene_model()` change had lost.

* **Scene contract: `scene_model()$panels` now carries per-panel geometry and
  metadata.** Each panel row gains its panel viewport's resolved device-px
  rectangle (`px0,py0,px1,py1` — the true data region from the layout solve, not
  the element-extent bbox), its native coordinate ranges
  (`xscale_lo/hi`, `yscale_lo/hi`), and a `meta` list-column. Together the pixel
  rect and native range give the affine a host needs to map device pixels back to
  native (and thence data) coordinates. The existing element-extent `x0..y1`
  columns are unchanged, so this is additive.

* **`vl_viewport(meta=)`: a panel-level free-form metadata channel.** A named
  viewport can carry arbitrary `meta` (any R object), surfaced as the `meta` column
  of `scene_model()$panels`. Like grob `meta`, it never crosses to the rendering
  backend and vellum names no conventions for it — it is the panel-scoped
  counterpart of per-element `meta`, for host conventions such as axis/scale
  descriptors. See `vignette("scene-contract")`.

# vellum 0.4.0

* **Faster, leaner keyed SVG emission.** Emitting a scene to SVG with per-element
  `data-key`s (the interactivity attributes) now writes each element straight into
  the output buffer instead of building and copying an intermediate string per
  element, memoises the `fill` attribute across a batch's shared paint, holds the
  current element key as an `Rc<str>`, and skips escaping work for keys/ids/labels
  that contain no XML metacharacters (the common case). Output is byte-identical;
  a 150k-point keyed scatter's `scene_svg()` is ~12% faster with substantially
  fewer per-element allocations.

* **`vl_strwidth()` / `vl_strheight()` measure `md()` labels.** Both now accept a
  rich label from `md()` (or a list of them) in addition to character strings,
  measuring it through the same run composition the renderer draws — so
  super/subscripts and bold runs reserve the space they actually occupy.
  `family`/`fontface`/`fontsize` supply the base style the label's runs are
  relative to. Previously a caller had to reduce a rich label to plain text (and
  `as.character()` on an `md()` object errors), so downstream layout code that
  measured a rich title got zero width and clipped it.

* **Line & segment datashading.** `datashade_lines()` and `datashade_segments()`
  extend the aggregate-then-shade engine from point clouds to dense lines. A new
  anti-aliased Rust line rasteriser accumulates coverage per grid cell (overlapping
  lines *add*), so a bundle of hundreds of timeseries or a graph of tens of
  thousands of edges renders at cost decoupled from the vertex count, as one
  `raster_grob()`. `datashade_lines()` takes a connected polyline with an optional
  `group` id (packing many series into one call; `NA` also breaks the line);
  `datashade_segments()` takes independent `(x0,y0)->(x1,y1)` segments (the
  network-edge case). Both share `datashade()`'s `colors`/`how`/`span`/`clip`
  shading and per-line `weight`. See the *Datashading* article and
  `inst/examples/lines.R`.

* **Pixel spreading (`spread()` / `dynspread()`).** Dilate the non-empty pixels of
  any raster grob so thin marks stay visible — datashader's `spread` (fixed radius)
  and `dynspread` (radius chosen from image density). Available standalone, or via
  a `spread =` argument on the `datashade*` functions (`spread = 2` for a fixed
  radius, `spread = "auto"` for dynspread).

* **Focal / two-circle radial gradients.** `radial_gradient()` gained `fx`, `fy`,
  `fr` — the *focal* (start) circle at stop offset 0, distinct from the *outer*
  (end) circle `cx`/`cy`/`r` at offset 1. Offsetting `fx`/`fy` moves the highlight
  off-centre (a sphere lit from one side); a non-zero `fr` gives an annular ramp
  between the two circles. This matches grid's two-circle `radialGradient()` (the
  previous concentric-only form could only place the highlight dead-centre). The
  defaults (`fx = cx`, `fy = cy`, `fr = 0`) are the old concentric behaviour and
  are byte-for-byte unchanged on every backend. Rendered identically on raster
  (tiny-skia two-point conical), SVG (`<radialGradient fx fy fr>`), and PDF
  (krilla). See `inst/examples/gradients.R`.

* **Hue-preserving (OKLCH) gradient interpolation.** `linear_gradient()` and
  `radial_gradient()` now also accept `interpolation = "oklch"`, the polar form
  of Oklab (lightness, chroma, hue). Hue and chroma move independently, so a ramp
  between two saturated colours keeps its chroma through the middle instead of
  desaturating toward grey the way a straight line in Oklab can — the hue sweeps
  along the shorter arc (blue→yellow passes through green). An achromatic endpoint
  (grey/black/white) borrows the other end's hue, so ramps to/from white don't
  flash an arbitrary colour. Like `"oklab"` it is pre-sampled into dense sRGB
  stops in the Rust core, so it renders identically on the raster, SVG, and PDF
  backends with no new dependency. See `inst/examples/gradient-interpolation.R`
  for a side-by-side of all three spaces.

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

* **Slimmer Rust dependency tree.** Bumped the direct `tiny-skia` (0.11 → 0.12)
  and `skrifa` (0.31 → 0.42) crates to the versions the `krilla` PDF backend
  already pulls in. This collapses six duplicated transitive crates (`skrifa`,
  `read-fonts`, `font-types`, `tiny-skia-path`, `png`, and `bitflags` were each
  compiled twice), taking the vendored tree from 75 to 69 crates for a smaller
  source tarball and a faster build. Rendered output is unchanged — the raster
  snapshots are pixel-for-pixel identical — and the minimum Rust version is still
  1.92.

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
