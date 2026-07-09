# Graphical objects (grobs)

Grobs are immutable value objects describing something to draw. Build
them with the constructors below, add them to a scene with
[`draw()`](https://schochastics.github.io/vellum/reference/vl_scene.md),
and render with
[`render()`](https://schochastics.github.io/vellum/reference/vl_scene.md).
Coordinates accept a
[`unit()`](https://schochastics.github.io/vellum/reference/unit.md)
vector or a bare numeric (interpreted in the `default_units`, usually
`"npc"`).

## Usage

``` r
rect_grob(
  x = 0.5,
  y = 0.5,
  width = 1,
  height = 1,
  sketch = NULL,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
)

roundrect_grob(
  x = 0.5,
  y = 0.5,
  width = 1,
  height = 1,
  r = 0.1,
  sketch = NULL,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
)

lines_grob(
  x,
  y,
  arrow = NULL,
  start_cap = NULL,
  end_cap = NULL,
  offset = NULL,
  sketch = NULL,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
)

polygon_grob(
  x,
  y,
  sketch = NULL,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
)

bezier_grob(
  x,
  y,
  n = 60,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
)

spline_grob(
  x,
  y,
  shape = 1,
  n = 20,
  open = TRUE,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
)

circle_grob(
  x = 0.5,
  y = 0.5,
  r = 0.25,
  sketch = NULL,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
)

points_grob(
  x,
  y,
  size = unit(2, "mm"),
  shape = "circle",
  sketch = NULL,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
)

hexagon_grob(
  x = 0.5,
  y = 0.5,
  size = unit(2, "mm"),
  width = NULL,
  height = NULL,
  fill = NULL,
  orientation = c("flat", "pointy"),
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
)

sector_grob(
  x = 0.5,
  y = 0.5,
  r0 = 0,
  r1 = 0.5,
  theta0 = 0,
  theta1 = 2 * pi,
  fill = NULL,
  arrow = NULL,
  sketch = NULL,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
)

loop_grob(
  x = 0.5,
  y = 0.5,
  size = unit(4, "mm"),
  foot = unit(0, "mm"),
  angle = 0,
  width = 1,
  arrow = NULL,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
)

segments_grob(
  x0,
  y0,
  x1,
  y1,
  arrow = NULL,
  start_cap = NULL,
  end_cap = NULL,
  offset = NULL,
  sketch = NULL,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
)

path_grob(
  x,
  y,
  id = NULL,
  rule = c("winding", "evenodd"),
  sketch = NULL,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  role = NULL
)

raster_grob(
  image,
  x = 0.5,
  y = 0.5,
  width = 1,
  height = 1,
  interpolate = TRUE,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
)

text_grob(
  label,
  x = 0.5,
  y = 0.5,
  just = "centre",
  rot = 0,
  gp = gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
)
```

## Arguments

- x, y:

  Coordinates
  ([`unit()`](https://schochastics.github.io/vellum/reference/unit.md)
  or numeric).

- width, height:

  Grob size
  ([`unit()`](https://schochastics.github.io/vellum/reference/unit.md)
  or numeric), recycled like `x`/`y`. For most grobs the drawn rectangle
  size. For `hexagon_grob()`, the optional per-hexagon **full**
  corner-to-corner extent along x/y: when both are given they override
  `size` (resolved per-axis, so a hexagon can be *non-regular* and tile
  a non-square lattice — e.g. `"native"` units tile in data space
  regardless of device aspect); a *regular* flat hexagon is
  `height == width * sqrt(3) / 2`; leave both `NULL` to use circumradius
  `size`; must be given together. For `loop_grob()`, `width` is instead
  a dimensionless lateral petal scale in `(0, 1]` (recycled per loop):
  `1` (default) is the full teardrop, smaller narrows the petal's
  **waist** without shortening it (the igraph "narrowing" factor).

- sketch:

  Optional
  [`sketch()`](https://schochastics.github.io/vellum/reference/sketch.md)
  spec for a hand-drawn look; `NULL` = crisp.

- gp:

  Graphical parameters, from
  [`gpar()`](https://schochastics.github.io/vellum/reference/gpar.md).

- name:

  Optional name (for
  [`edit_node()`](https://schochastics.github.io/vellum/reference/node_names.md)).

- vp:

  Optional
  [`viewport()`](https://schochastics.github.io/vellum/reference/viewport.md)
  to draw this grob inside.

- id:

  For most grobs, an optional semantic identifier emitted by the SVG
  backend as `data-vellum-id` (for interactivity, accessibility, and
  testing; ignored by raster/PDF). **For `path_grob` only**, `id`
  instead groups points (one value per point) into closed sub-paths: all
  points sharing an `id` form one sub-path (so a hole is a separate
  `id`), in first-appearance order (à la grid); `NULL` makes a single
  sub-path.

- role:

  Optional ARIA role, emitted by the SVG backend as `role=` for
  accessibility (ignored by the raster and PDF backends).

- key:

  Optional per-element data key(s) for the batched marks (`points_grob`,
  `circle_grob`, `rect_grob`, `segments_grob`, `hexagon_grob`,
  `sector_grob`), recycled to the element count like `fill`. Emitted by
  the SVG backend as `data-key` on each element and surfaced by
  [`scene_model()`](https://schochastics.github.io/vellum/reference/scene_model.md)
  — the join key a host uses to map an interaction back to a datum.
  `NULL` (default) emits nothing (a static render is unchanged). Ignored
  by raster/PDF.

- meta:

  Optional free-form per-element metadata for the batched marks: a list
  with one entry (record) per element (recycled), e.g. tooltip text or
  field values. It never reaches the backend (nothing drawn changes); it
  rides on the scene and is returned by
  [`scene_model()`](https://schochastics.github.io/vellum/reference/scene_model.md).
  `NULL` (default) = none.

- r:

  Radius
  ([`unit()`](https://schochastics.github.io/vellum/reference/unit.md)
  or numeric).

- arrow:

  An
  [`arrow()`](https://schochastics.github.io/vellum/reference/arrow.md)
  spec to draw heads on the line/segment ends, or `NULL` for none.

- start_cap, end_cap:

  Optional **absolute-length**
  [`unit()`](https://schochastics.github.io/vellum/reference/unit.md)s
  (`mm`/`cm`/ `in`/`pt`; a bare numeric is taken as `mm`) that shorten
  the drawn line inward from its start/end by that physical amount,
  resolved **at render** in device space — so the gap is exact at any
  size, dpi, and aspect ratio, with no reliance on the native scale. For
  `segments_grob()` the caps are per-element (scalar or length-n,
  recycled like the coordinates); for `lines_grob()` a single (scalar)
  cap trims each end of the whole polyline. `NULL` (default) leaves the
  endpoint untouched. When an
  [`arrow()`](https://schochastics.github.io/vellum/reference/arrow.md)
  is also present its head is placed at the *capped* end, so the tip
  lands on the boundary (e.g. a node marker) rather than under it. This
  is what lets a directed edge stop at a node's radius. See the
  acceptance notes in the package for the degenerate cases (a cap `>=`
  the segment length draws nothing; a zero-length segment is skipped).

- offset:

  Optional **absolute-length**
  [`unit()`](https://schochastics.github.io/vellum/reference/unit.md)
  (`mm`/`cm`/`in`/`pt`; a bare numeric is `mm`) that shifts the line
  **perpendicular** to its own direction by that physical amount,
  resolved **at render** in device space. The sign picks the side (`+`
  left of the direction of travel, `−` right). For `segments_grob()` it
  is per-element (scalar or length-n) — passing a vector spreads
  parallel/reciprocal edges by a fixed physical spacing that tracks mm
  node sizes at any figure size; for `lines_grob()` a single (scalar)
  offset rigidly translates the whole polyline along the perpendicular
  of its overall direction. Applied **before** `start_cap`/`end_cap` and
  the arrowhead (offset, then cap, then head). `NULL`/`0` (default)
  leaves the geometry untouched.

- n:

  Number of points to sample the curve at (flattened to a polyline).

- shape:

  Marker shape(s): `"circle"` (default), `"square"`, `"triangle"`,
  `"diamond"`, `"plus"`, or `"cross"`, recycled per point. Filled shapes
  use `gp$fill` (and outline `gp$col`); `"plus"`/`"cross"` are
  stroke-only.

- open:

  If `FALSE`, the spline is closed (wraps end to start).

- size:

  Loop extent: an **absolute**
  [`unit()`](https://schochastics.github.io/vellum/reference/unit.md)
  (`mm`/`cm`/`in`/`pt`; a bare numeric is `mm`), resolved to a device
  length **at render** so the loop tracks a node's mm size at any page
  size/dpi. Nested loops on one vertex pass growing `size` (same
  `x`/`y`/`angle`) for concentric teardrops. Recycled per loop.

- fill:

  Per-element fill colour(s), recycled to the number of sectors. `NULL`
  falls back to `gp$fill`.

- orientation:

  Hexagon orientation: `"flat"` (default, flat top/bottom edge) or
  `"pointy"` (vertex at top). `size` is the circumradius (centre to
  vertex).

- r0, r1:

  Inner and outer radius of each sector
  ([`unit()`](https://schochastics.github.io/vellum/reference/unit.md)
  or numeric; numeric is treated as `"native"`). `r0 = 0` gives a pie
  slice; `r0 == r1` gives an arc outline (stroke only, no fill).

- theta0, theta1:

  Start and end angle of each sector, in **radians**, with 0 at 3
  o'clock and increasing counter-clockwise.

- foot:

  Node radius the loop's two **feet** attach at (an **absolute**
  [`unit()`](https://schochastics.github.io/vellum/reference/unit.md);
  `0` = both feet at the vertex, like igraph). A positive `foot` puts
  the feet on the node's boundary so the loop visibly leaves and
  re-enters the node edge, and a directed loop's head lands on the
  boundary rather than under the marker. Recycled per loop.

- angle:

  Outward direction of the loop in **radians** (which way the teardrop
  bulges away from the vertex, e.g. away from the layout centroid).

- x0, y0, x1, y1:

  Segment start/end coordinates
  ([`unit()`](https://schochastics.github.io/vellum/reference/unit.md)
  or numeric).

- rule:

  Fill rule: `"winding"` (non-zero, default) or `"evenodd"`.

- image:

  A raster image: a
  [`grDevices::as.raster()`](https://rdrr.io/r/grDevices/as.raster.html)-compatible
  object — a matrix/array of colours or greyscale values, or a `raster`
  object.

- interpolate:

  Smoothly interpolate when scaling (default `TRUE`)? `FALSE` keeps hard
  pixel edges.

- label:

  Character string(s) to draw.

- just:

  Justification: `c(hjust, vjust)` as names (`"left"`, `"centre"`,
  `"right"`, `"bottom"`, `"top"`) or numbers in `[0, 1]`.

- rot:

  Rotation in degrees, counter-clockwise.

## Value

A grob object.

## Details

`sector_grob()` draws a batch of annular sectors (pie / donut / rose
wedges) in a single call. `gp$fill` recycles per sector; `gp$col`/`lwd`
give a uniform stroke.

Passing `r0 == r1` gives an **open arc** (stroke only). Combined with an
absolute (`mm`) radius at a `"native"` centre and an
[`arrow()`](https://schochastics.github.io/vellum/reference/arrow.md),
the radius is resolved to a device length at render (like a marker
`size`), so the arc tracks an mm size at any page size or dpi; the
arrowhead sits tangent to the outer arc's end. (For node-link
**self-loops**, prefer `loop_grob()` — a teardrop, not a ring.)

`loop_grob()` draws **self-loops** for node-link diagrams as an
igraph-style cubic **Bézier teardrop**: it leaves the vertex `(x, y)` (a
`"native"` anchor), bulges out to `size` along `angle`, and returns,
with an optional
[`arrow()`](https://schochastics.github.io/vellum/reference/arrow.md)
head tangent to the curve at the returning foot. `size` and `foot` are
absolute and resolved to device px **at render**, so the loop is a fixed
physical size that scales with the mm node markers — no native-per-mm
estimation, exact at any figure size/dpi.
