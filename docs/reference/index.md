# Package index

## Building & rendering scenes

Build a scene functionally with
[`vl_scene()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
and a pipeline of
[`push()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
/
[`draw()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
/
[`pop()`](https://schochastics.github.io/vellum/reference/vl_scene.md),
then render it.
[`render()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
picks the backend (PNG / SVG / PDF) from the file extension.

- [`vl_scene()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
  [`push()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
  [`draw()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
  [`pop()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
  [`render()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
  : Build and render a scene
- [`describe()`](https://schochastics.github.io/vellum/reference/describe.md)
  : Set a scene's accessibility name and description
- [`display()`](https://schochastics.github.io/vellum/reference/display.md)
  : Display a scene in the active graphics device
- [`scene_raster()`](https://schochastics.github.io/vellum/reference/scene_raster.md)
  : Read a rendered scene back as pixels
- [`scene_svg()`](https://schochastics.github.io/vellum/reference/scene_svg.md)
  : Render a scene to an SVG string
- [`as_vellum_scene()`](https://schochastics.github.io/vellum/reference/as_vellum_scene.md)
  : Coerce an object to a vellum scene

## Graphical objects (grobs)

The drawable primitives. Most are vectorised and batch internally.

- [`rect_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`roundrect_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`lines_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`polygon_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`bezier_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`spline_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`circle_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`points_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`hexagon_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`sector_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`loop_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`segments_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`path_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`raster_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  [`text_grob()`](https://schochastics.github.io/vellum/reference/grob.md)
  : Graphical objects (grobs)
- [`arrow()`](https://schochastics.github.io/vellum/reference/arrow.md)
  : Arrowheads

## Units, viewports & layout

Coordinate systems, nested viewports with scales, clipping and rotation,
and the row/column layout solver.

- [`unit()`](https://schochastics.github.io/vellum/reference/unit.md)
  [`is_unit()`](https://schochastics.github.io/vellum/reference/unit.md)
  : Units of measurement
- [`viewport()`](https://schochastics.github.io/vellum/reference/viewport.md)
  [`grid_layout()`](https://schochastics.github.io/vellum/reference/viewport.md)
  : Viewports and layouts
- [`grobwidth()`](https://schochastics.github.io/vellum/reference/grobwidth.md)
  [`grobheight()`](https://schochastics.github.io/vellum/reference/grobwidth.md)
  : Size a unit by a grob's extent
- [`why_size()`](https://schochastics.github.io/vellum/reference/why_size.md)
  : Explain why a node has its resolved size

## Paint & appearance

The paint model shared across all backends: gradients, tiling patterns,
masks, reusable styles, and hand-drawn rendering.

- [`gpar()`](https://schochastics.github.io/vellum/reference/gpar.md) :
  Graphical parameters
- [`style()`](https://schochastics.github.io/vellum/reference/style.md)
  : Reusable style classes
- [`linear_gradient()`](https://schochastics.github.io/vellum/reference/gradients.md)
  [`radial_gradient()`](https://schochastics.github.io/vellum/reference/gradients.md)
  : Gradient fills
- [`pattern()`](https://schochastics.github.io/vellum/reference/pattern.md)
  : Tiling-pattern fills
- [`as_mask()`](https://schochastics.github.io/vellum/reference/as_mask.md)
  : Masks
- [`sketch()`](https://schochastics.github.io/vellum/reference/sketch.md)
  : Hand-drawn ("sketch") rendering

## Text

Device-independent shaping and measurement, plus Markdown-style rich
labels.

- [`vl_strwidth()`](https://schochastics.github.io/vellum/reference/vl_strwidth.md)
  [`vl_strheight()`](https://schochastics.github.io/vellum/reference/vl_strwidth.md)
  : Measure text
- [`md()`](https://schochastics.github.io/vellum/reference/md.md) :
  Rich-text labels (markdown subset)

## Big data

Aggregate-then-shade rendering for large point clouds.

- [`datashade()`](https://schochastics.github.io/vellum/reference/datashade.md)
  : Aggregate-then-shade a large point cloud (datashader-style)

## Inspecting & editing scenes

Because the scene graph is retained, it can be queried, edited by node
name, hit-tested, and serialized to a per-element model.

- [`node_names()`](https://schochastics.github.io/vellum/reference/node_names.md)
  [`get_node()`](https://schochastics.github.io/vellum/reference/node_names.md)
  [`edit_node()`](https://schochastics.github.io/vellum/reference/node_names.md)
  : Inspect and edit a scene by node name
- [`hit_test()`](https://schochastics.github.io/vellum/reference/hit_test.md)
  : Hit-test a scene
- [`scene_model()`](https://schochastics.github.io/vellum/reference/scene_model.md)
  : A serializable, per-element model of a scene

## Grid & ggplot2 interop

Render an existing grid grob tree — including ggplot2 and lattice —
through the vellum backend.

- [`as_vellum()`](https://schochastics.github.io/vellum/reference/as_vellum.md)
  [`render_grid()`](https://schochastics.github.io/vellum/reference/as_vellum.md)
  : Render grid graphics (ggplot2 / lattice / grid) through vellum

## Caches & diagnostics

- [`vl_clear_render_cache()`](https://schochastics.github.io/vellum/reference/vl_clear_render_cache.md)
  : Clear the render cache

## Package

- [`vellum`](https://schochastics.github.io/vellum/reference/vellum-package.md)
  [`vellum-package`](https://schochastics.github.io/vellum/reference/vellum-package.md)
  : vellum: A Low-Level Graphics Framework with a Rust Backend
