# Package index

## Building & rendering scenes

Build a scene functionally with
[`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
and a pipeline of
[`push()`](https://r-vellum.github.io/vellum/reference/vl_scene.md) /
[`draw()`](https://r-vellum.github.io/vellum/reference/vl_scene.md) /
[`pop()`](https://r-vellum.github.io/vellum/reference/vl_scene.md), then
render it.
[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
picks the backend (PNG / SVG / PDF) from the file extension.

- [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  [`push()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  [`draw()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  [`pop()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  [`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  : Build and render a scene
- [`describe()`](https://r-vellum.github.io/vellum/reference/describe.md)
  : Set a scene's accessibility name and description
- [`display()`](https://r-vellum.github.io/vellum/reference/display.md)
  : Display a scene in the active graphics device
- [`scene_raster()`](https://r-vellum.github.io/vellum/reference/scene_raster.md)
  : Read a rendered scene back as pixels
- [`scene_svg()`](https://r-vellum.github.io/vellum/reference/scene_svg.md)
  : Render a scene to an SVG string
- [`scene_png()`](https://r-vellum.github.io/vellum/reference/scene_png.md)
  [`scene_pdf()`](https://r-vellum.github.io/vellum/reference/scene_png.md)
  : Render a scene to PNG or PDF bytes
- [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  : Coerce an object to a vellum scene
- [`vl_render_animation()`](https://r-vellum.github.io/vellum/reference/vl_render_animation.md)
  : Render a keyframe animation

## Graphical objects (grobs)

The drawable primitives. Most are vectorised and batch internally.

- [`rect_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`roundrect_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`lines_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`polygon_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`bezier_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`spline_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`circle_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`points_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`hexagon_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`sector_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`loop_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`segments_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`path_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`raster_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
  [`text_grob()`](https://r-vellum.github.io/vellum/reference/grob.md) :
  Graphical objects (grobs)
- [`vl_arrow()`](https://r-vellum.github.io/vellum/reference/vl_arrow.md)
  : Arrowheads

## Units, viewports & layout

Coordinate systems, nested viewports with scales, clipping and rotation,
and the row/column layout solver.

- [`vl_unit()`](https://r-vellum.github.io/vellum/reference/vl_unit.md)
  [`is_unit()`](https://r-vellum.github.io/vellum/reference/vl_unit.md)
  : Units of measurement
- [`vl_convert()`](https://r-vellum.github.io/vellum/reference/vl_convert.md)
  : Convert a unit to another unit, in a scene's context
- [`vl_viewport()`](https://r-vellum.github.io/vellum/reference/vl_viewport.md)
  [`grid_layout()`](https://r-vellum.github.io/vellum/reference/vl_viewport.md)
  : Viewports and layouts
- [`grobwidth()`](https://r-vellum.github.io/vellum/reference/grobwidth.md)
  [`grobheight()`](https://r-vellum.github.io/vellum/reference/grobwidth.md)
  : Size a unit by a grob's extent
- [`why_size()`](https://r-vellum.github.io/vellum/reference/why_size.md)
  : Explain why a node has its resolved size

## Inspecting a scene

Static analysis, coverage statistics, and render profiling — all reading
the resolved geometry the renderer draws with.

- [`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)
  : Check a scene for likely mistakes
- [`vl_lint_rule()`](https://r-vellum.github.io/vellum/reference/vl_lint_rule.md)
  [`vl_lint_rules()`](https://r-vellum.github.io/vellum/reference/vl_lint_rule.md)
  : Register a lint rule
- [`vl_lint_finding()`](https://r-vellum.github.io/vellum/reference/vl_lint_finding.md)
  : Build a lint finding
- [`scene_stats()`](https://r-vellum.github.io/vellum/reference/scene_stats.md)
  : Ink and overplotting statistics for a scene
- [`profile_render()`](https://r-vellum.github.io/vellum/reference/profile_render.md)
  : Where a scene spends its render time

## Paint & appearance

The paint model shared across all backends: gradients, tiling patterns,
masks, reusable styles, and hand-drawn rendering.

- [`vl_gpar()`](https://r-vellum.github.io/vellum/reference/vl_gpar.md)
  : Graphical parameters
- [`style()`](https://r-vellum.github.io/vellum/reference/style.md) :
  Reusable style classes
- [`linear_gradient()`](https://r-vellum.github.io/vellum/reference/gradients.md)
  [`radial_gradient()`](https://r-vellum.github.io/vellum/reference/gradients.md)
  : Gradient fills
- [`vl_pattern()`](https://r-vellum.github.io/vellum/reference/vl_pattern.md)
  : Tiling-pattern fills
- [`as_mask()`](https://r-vellum.github.io/vellum/reference/as_mask.md)
  : Masks
- [`vl_shadow()`](https://r-vellum.github.io/vellum/reference/vl_shadow.md)
  : Drop shadow for a viewport group
- [`sketch()`](https://r-vellum.github.io/vellum/reference/sketch.md) :
  Hand-drawn ("sketch") rendering

## Text

Device-independent shaping and measurement, plus Markdown-style rich
labels.

- [`vl_strwidth()`](https://r-vellum.github.io/vellum/reference/vl_strwidth.md)
  [`vl_strheight()`](https://r-vellum.github.io/vellum/reference/vl_strwidth.md)
  : Measure text
- [`md()`](https://r-vellum.github.io/vellum/reference/md.md) :
  Rich-text labels (markdown subset)

## Big data

Aggregate-then-shade rendering for large point clouds, dense timeseries,
and network edges.

- [`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md)
  : Aggregate-then-shade a large point cloud (datashader-style)
- [`datashade_lines()`](https://r-vellum.github.io/vellum/reference/datashade_lines.md)
  [`datashade_segments()`](https://r-vellum.github.io/vellum/reference/datashade_lines.md)
  : Aggregate-then-shade dense lines and segments (datashader-style)
- [`spread()`](https://r-vellum.github.io/vellum/reference/spread.md) :
  Spread (dilate) the pixels of a raster grob
- [`dynspread()`](https://r-vellum.github.io/vellum/reference/dynspread.md)
  : Dynamically spread a raster grob to a target density

## Querying & editing scenes

A solved scene reports its geometry: a per-element model with data keys
and device-pixel boxes, picking by point, and editing by node name.

- [`node_names()`](https://r-vellum.github.io/vellum/reference/node_names.md)
  [`get_node()`](https://r-vellum.github.io/vellum/reference/node_names.md)
  [`edit_node()`](https://r-vellum.github.io/vellum/reference/node_names.md)
  : Inspect and edit a scene by node name
- [`hit_test()`](https://r-vellum.github.io/vellum/reference/hit_test.md)
  : Hit-test a scene
- [`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
  : A serializable, per-element model of a scene

## Grid & ggplot2 interop

Render an existing grid grob tree — including ggplot2 and lattice —
through the vellum backend.

- [`as_vellum()`](https://r-vellum.github.io/vellum/reference/as_vellum.md)
  [`render_grid()`](https://r-vellum.github.io/vellum/reference/as_vellum.md)
  : Render grid graphics (ggplot2 / lattice / grid) through vellum

## Caches & diagnostics

- [`vl_clear_render_cache()`](https://r-vellum.github.io/vellum/reference/vl_clear_render_cache.md)
  : Clear the render cache

## Package

- [`vellum`](https://r-vellum.github.io/vellum/reference/vellum-package.md)
  [`vellum-package`](https://r-vellum.github.io/vellum/reference/vellum-package.md)
  : vellum: Low-Level Graphics with Device-Independent Layout and
  Queryable Scenes
