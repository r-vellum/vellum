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
- [`stroke_to_path()`](https://r-vellum.github.io/vellum/reference/stroke_to_path.md)
  : Freeze a stroke into a fillable outline

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
- [`vl_lint_assert()`](https://r-vellum.github.io/vellum/reference/vl_lint_assert.md)
  : Fail on lint findings
- [`vl_lint_overlay()`](https://r-vellum.github.io/vellum/reference/vl_lint_overlay.md)
  : Draw lint findings onto the scene
- [`vl_lint_rule()`](https://r-vellum.github.io/vellum/reference/vl_lint_rule.md)
  [`vl_lint_rules()`](https://r-vellum.github.io/vellum/reference/vl_lint_rule.md)
  : Register a lint rule
- [`vl_lint_finding()`](https://r-vellum.github.io/vellum/reference/vl_lint_finding.md)
  : Build a lint finding
- [`scene_stats()`](https://r-vellum.github.io/vellum/reference/scene_stats.md)
  : Ink and overplotting statistics for a scene
- [`profile_render()`](https://r-vellum.github.io/vellum/reference/profile_render.md)
  : Where a scene spends its render time
- [`as_scene_spec()`](https://r-vellum.github.io/vellum/reference/as_scene_spec.md)
  [`from_scene_spec()`](https://r-vellum.github.io/vellum/reference/as_scene_spec.md)
  : Convert a scene to and from a plain list
- [`scene_write()`](https://r-vellum.github.io/vellum/reference/scene_write.md)
  [`scene_read()`](https://r-vellum.github.io/vellum/reference/scene_write.md)
  : Write and read a scene
- [`scene_hash()`](https://r-vellum.github.io/vellum/reference/scene_hash.md)
  : A content fingerprint for a scene
- [`scene_diff()`](https://r-vellum.github.io/vellum/reference/scene_diff.md)
  : What changed between two scenes
- [`scene_inset()`](https://r-vellum.github.io/vellum/reference/scene_inset.md)
  : Inset one scene inside another

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
- [`vl_hatch()`](https://r-vellum.github.io/vellum/reference/vl_hatch.md)
  : Hatch fill
- [`as_mask()`](https://r-vellum.github.io/vellum/reference/as_mask.md)
  : Masks
- [`vl_shadow()`](https://r-vellum.github.io/vellum/reference/vl_shadow.md)
  : Drop shadow for a viewport group
- [`sketch()`](https://r-vellum.github.io/vellum/reference/sketch.md) :
  Hand-drawn ("sketch") rendering

## Text

Device-independent shaping and measurement, Markdown-style rich labels,
and layout: text wrapped to a box or set along a curve.

- [`vl_strwidth()`](https://r-vellum.github.io/vellum/reference/vl_strwidth.md)
  [`vl_strheight()`](https://r-vellum.github.io/vellum/reference/vl_strwidth.md)
  : Measure text
- [`md()`](https://r-vellum.github.io/vellum/reference/md.md) :
  Rich-text labels (markdown subset)
- [`text_path_grob()`](https://r-vellum.github.io/vellum/reference/text_path_grob.md)
  : Text set along a path

## Placement

Geometry services over a scene’s resolved boxes: move labels apart, find
the emptiest region, outline and buffer a group.

- [`vl_place()`](https://r-vellum.github.io/vellum/reference/vl_place.md)
  [`vl_repel()`](https://r-vellum.github.io/vellum/reference/vl_place.md)
  : Move labels so they stop overlapping
- [`vl_empty_region()`](https://r-vellum.github.io/vellum/reference/vl_empty_region.md)
  : Find the largest empty rectangle in a scene
- [`vl_hull()`](https://r-vellum.github.io/vellum/reference/vl_hull.md)
  : Hull of a point set
- [`vl_buffer()`](https://r-vellum.github.io/vellum/reference/vl_buffer.md)
  : Buffer a polygon outward

## Geometry operations

Producing paths: boolean combinations, contours from a grid, and SVG
path data imported as real vector geometry.

- [`vl_path_op()`](https://r-vellum.github.io/vellum/reference/vl_path_op.md)
  : Boolean operations on paths
- [`vl_contour()`](https://r-vellum.github.io/vellum/reference/vl_contour.md)
  [`contour_grob()`](https://r-vellum.github.io/vellum/reference/vl_contour.md)
  : Contour lines from a grid
- [`vl_svg_path()`](https://r-vellum.github.io/vellum/reference/vl_svg_path.md)
  [`svg_grob()`](https://r-vellum.github.io/vellum/reference/vl_svg_path.md)
  : SVG path data as scene geometry

## Output reach

Destinations for a finished scene beyond a single file: a multi-page
document, and a batch rendered across cores.

- [`pdf_pages()`](https://r-vellum.github.io/vellum/reference/pdf_pages.md)
  : Write several scenes as the pages of one PDF
- [`render_all()`](https://r-vellum.github.io/vellum/reference/render_all.md)
  : Render many scenes in parallel

## Accessibility & fonts

Tagged PDF output from the per-mark metadata channel, and a check on the
one part of the determinism claim vellum does not control.

- [`scene_fonts()`](https://r-vellum.github.io/vellum/reference/scene_fonts.md)
  : Which fonts a scene actually used
- [`font_pin()`](https://r-vellum.github.io/vellum/reference/font_pin.md)
  [`font_check()`](https://r-vellum.github.io/vellum/reference/font_pin.md)
  : Pin a scene's fonts, and check them later

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
- [`vl_nearest()`](https://r-vellum.github.io/vellum/reference/vl_nearest.md)
  : Find the marks nearest a point, by true geometry
- [`element_geometry()`](https://r-vellum.github.io/vellum/reference/element_geometry.md)
  : The true geometry of a scene's addressable elements

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
