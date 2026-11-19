#' @include grob-class.R
NULL

# --- friendly constructors --------------------------------------------------

#' @rdname grob
#' @param x,y Coordinates ([vl_unit()] or numeric).
#' @param width,height Grob size ([vl_unit()] or numeric), recycled like `x`/`y`.
#'   For most grobs the drawn rectangle size. For [hexagon_grob()], the optional
#'   per-hexagon **full** corner-to-corner extent along x/y: when both are given
#'   they override `size` (resolved per-axis, so a hexagon can be *non-regular*
#'   and tile a non-square lattice — e.g. `"native"` units tile in data space
#'   regardless of device aspect); a *regular* flat hexagon is
#'   `height == width * sqrt(3) / 2`; leave both `NULL` to use circumradius
#'   `size`; must be given together. For [loop_grob()], `width` is instead a
#'   dimensionless lateral petal scale in `(0, 1]` (recycled per loop): `1`
#'   (default) is the full teardrop, smaller narrows the petal's **waist**
#'   without shortening it (the igraph "narrowing" factor).
#'
#'   For [text_grob()] these mean something different: `width` is an
#'   **absolute** wrapping measure (`mm`/`cm`/`in`/`pt`), and giving it breaks
#'   the label into lines that fit, making the drawn block a box of exactly that
#'   width — so `just` anchors the box rather than the longest line. `height` is
#'   used only by `fit`. Relative units are rejected there on purpose: wrapping
#'   happens when the grob is built, and a viewport has no size in
#'   `npc`/`native` until render time.
#' @param gp Graphical parameters, from [vl_gpar()].
#' @param name Optional name (for [edit_node()]).
#' @param vp Optional [vl_viewport()] to draw this grob inside.
#' @param role Optional ARIA role, emitted by the SVG backend as `role=` for
#'   accessibility (ignored by the raster and PDF backends).
#' @export
rect_grob <- function(
  x = 0.5,
  y = 0.5,
  width = 1,
  height = 1,
  sketch = NULL,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
) {
  w <- as_unit(width)
  h <- as_unit(height)
  .check_extent(w, "width")
  .check_extent(h, "height")
  n <- .elem_n(list(x = x, y = y, width = w, height = h))
  grob_rect(
    x = as_unit(x),
    y = as_unit(y),
    width = w,
    height = h,
    sketch = sketch,
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role,
    keys = .recycle_keys(key, n),
    meta = .recycle_meta(meta, n)
  )
}

#' @rdname grob
#' @param r Corner radius ([vl_unit()] or numeric). An `"npc"`/numeric radius is
#'   isotropic (a fraction of the shorter side, like grid's `"snpc"`), so corners
#'   stay circular on non-square rectangles; clamped to half the shorter side.
#' @export
roundrect_grob <- function(
  x = 0.5,
  y = 0.5,
  width = 1,
  height = 1,
  r = 0.1,
  sketch = NULL,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
) {
  w <- as_unit(width)
  h <- as_unit(height)
  rr <- as_unit(r)
  .check_extent(w, "width")
  .check_extent(h, "height")
  .check_extent(rr, "r")
  # A roundrect grob is a *batch*: one box per (x, y, w, h, r) element, like
  # `rect_grob()`. Recycle keys/meta to that element count (not to 1, which
  # silently dropped every key past the first on a multi-box grob).
  n <- .elem_n(list(x = x, y = y, width = w, height = h, r = rr))
  grob_roundrect(
    x = as_unit(x),
    y = as_unit(y),
    width = w,
    height = h,
    r = rr,
    sketch = sketch,
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role,
    keys = .recycle_keys(key, n),
    meta = .recycle_meta(meta, n)
  )
}

# An extent (width/height/radius/size) must be non-negative. Checks the resolved
# numeric value of a unit vector (absolute/derived kinds are already in mm; npc/
# native lengths are likewise non-negative when sensible).
.check_extent <- function(u, arg) {
  v <- vctrs::field(u, "value")
  if (length(v) && any(v < 0, na.rm = TRUE)) {
    cli::cli_abort("{.arg {arg}} must be non-negative.")
  }
  invisible(u)
}

# A numeric angle/parameter vector must be finite (no NA/NaN/Inf). Non-finite
# angles otherwise reach the backend and, for arc/sector spans, blow up the
# segment count (see the render-time clamp in `sector_path`). Named cli error.
.check_finite_num <- function(v, arg) {
  v <- as.numeric(v)
  if (length(v) && !all(is.finite(v))) {
    cli::cli_abort(
      "{.arg {arg}} must be finite (no {.val NA}/{.val NaN}/{.val Inf})."
    )
  }
  invisible(v)
}

#' @rdname grob
#' @param arrow An [vl_arrow()] spec to draw heads on the line/segment ends, or
#'   `NULL` for none.
#' @param start_cap,end_cap Optional **absolute-length** [vl_unit()]s (`mm`/`cm`/
#'   `in`/`pt`; a bare numeric is taken as `mm`) that shorten the drawn line
#'   inward from its start/end by that physical amount, resolved **at render** in
#'   device space — so the gap is exact at any size, dpi, and aspect ratio, with
#'   no reliance on the native scale. For [segments_grob()] the caps are
#'   per-element (scalar or length-n, recycled like the coordinates); for
#'   [lines_grob()] a single (scalar) cap trims each end of the whole polyline.
#'   `NULL` (default) leaves the endpoint untouched. When an [vl_arrow()] is also
#'   present its head is placed at the *capped* end, so the tip lands on the
#'   boundary (e.g. a node marker) rather than under it. This is what lets a
#'   directed edge stop at a node's radius. See the acceptance notes in the
#'   package for the degenerate cases (a cap `>=` the segment length draws
#'   nothing; a zero-length segment is skipped).
#' @param offset Optional **absolute-length** [vl_unit()] (`mm`/`cm`/`in`/`pt`; a bare
#'   numeric is `mm`) that shifts the line **perpendicular** to its own direction by
#'   that physical amount, resolved **at render** in device space. The sign picks
#'   the side (`+` left of the direction of travel, `−` right). For
#'   [segments_grob()] it is per-element (scalar or length-n) — passing a vector
#'   spreads parallel/reciprocal edges by a fixed physical spacing that tracks mm
#'   node sizes at any figure size; for [lines_grob()] a single (scalar) offset
#'   rigidly translates the whole polyline along the perpendicular of its overall
#'   direction. Applied **before** `start_cap`/`end_cap` and the arrowhead (offset,
#'   then cap, then head). `NULL`/`0` (default) leaves the geometry untouched.
#' @param sketch Optional [sketch()] spec for a hand-drawn look; `NULL` = crisp.
#' @param lwd_profile For [lines_grob()], an optional numeric vector of **one
#'   width multiplier per vertex**, turning the polyline into a variable-width
#'   stroke that tapers smoothly between vertices. Each value scales the resolved
#'   `lwd`, so `c(1, 2, 0)` runs from the nominal width, through double, to a
#'   point. Resolved **at render**, inside the grob's viewport, so the taper is
#'   correct at any figure size and moves with a panel that is laid out later --
#'   which is the difference from [stroke_to_path()], whose outline is baked at a
#'   page size you supply. `NULL` (default) draws an ordinary uniform stroke, and
#'   is byte-for-byte the output you got before this argument existed.
#'
#'   A varying-width stroke is generated as an outline and **filled** (no backend
#'   can stroke one path at several widths), so PNG, SVG and PDF all get the same
#'   geometry -- it degrades nowhere. Two consequences: the stroke colour paints
#'   the ribbon while `lty` and dashing do not apply, and each ribbon is unique
#'   geometry, so it opts out of the batching fast paths -- fine for the low
#'   element counts this is meant for, not for a million points. Cannot be
#'   combined with `sketch`. For a profile spread by **arc length** rather than
#'   per vertex, see [stroke_to_path()]'s `along` argument.
#' @export
lines_grob <- function(
  x,
  y,
  arrow = NULL,
  start_cap = NULL,
  end_cap = NULL,
  offset = NULL,
  sketch = NULL,
  lwd_profile = NULL,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
) {
  n <- .coord_n(x, y)
  # `id` here is the accessibility identifier, NOT a grouping variable — unlike
  # `path_grob(id=)`, which splits points into rings. Passing a grouping vector
  # by analogy used to draw one polyline through every group, joining them with
  # straight lines; catch it rather than silently drawing that.
  if (length(id) > 1L) {
    cli::cli_abort(c(
      "{.arg id} is an accessibility identifier and must be a single value.",
      i = "{.fn lines_grob} draws ONE polyline. Unlike {.fn path_grob}, it has no grouping argument.",
      i = "To draw several polylines, pass a list of grobs; see {.fn contour_grob} for an example."
    ))
  }
  start_cap <- .check_cap(start_cap, "start_cap", scalar = TRUE)
  end_cap <- .check_cap(end_cap, "end_cap", scalar = TRUE)
  offset <- .check_cap(offset, "offset", scalar = TRUE, nonneg = FALSE)
  lwd_profile <- .check_vertex_profile(lwd_profile, n, sketch)
  grob_lines(
    x = vctrs::vec_recycle(as_unit(x, "native"), n),
    y = vctrs::vec_recycle(as_unit(y, "native"), n),
    arrow = arrow,
    start_cap = start_cap,
    end_cap = end_cap,
    offset = offset,
    sketch = sketch,
    lwd_profile = lwd_profile,
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role,
    keys = .recycle_keys(key, 1L),
    meta = .recycle_meta(meta, 1L)
  )
}

# Validate a render-time per-vertex `lwd_profile` for `lines_grob()`. The value
# checks (numeric, finite, non-negative, not all zero) are the SHARED ones from
# `.check_lwd_profile()`, so the two entry points cannot drift; only the two
# render-time-specific rules live here.
#
# `sketch` is refused alongside a profile. A sketched variable-width stroke is
# two different pictures -- a wobbly pen versus a wobbly silhouette -- and
# neither is obviously the one meant, so this asks rather than guesses.
.check_vertex_profile <- function(profile, n, sketch) {
  if (is.null(profile)) {
    return(NULL)
  }
  if (!is.null(sketch)) {
    cli::cli_abort(c(
      "{.arg sketch} and {.arg lwd_profile} cannot be combined.",
      i = "A sketched ribbon would jitter the stroke's outline, not the pen that drew it -- a wobbly silhouette rather than a hand-drawn line.",
      i = "Draw the sketch and the tapered stroke as separate grobs if you want both."
    ))
  }
  .check_lwd_profile(profile)
  # No arc-length option here: spreading a profile along the drawn length needs
  # resolved device px, which a grob does not have when it is constructed. That
  # mode stays with `stroke_to_path()`, which resolves at a page size you give it.
  if (length(profile) != 1L && length(profile) != n) {
    cli::cli_abort(c(
      "{.arg lwd_profile} must have one value per vertex.",
      x = "Got {length(profile)} value{?s} for {n} vertex/vertices.",
      i = 'For a profile spread evenly ALONG the line, use {.fn stroke_to_path} with {.code along = "arclength"}.'
    ))
  }
  rep_len(as.numeric(profile), n)
}

# Validate a cap/offset argument: NULL passes through; otherwise it must resolve
# to an absolute unit (mm/cm/in/pt — derived kinds already resolve to mm).
# `scalar = TRUE` (lines: whole-path amount) requires a single value; segments
# allow a length-n vector (recycled by the caller). `nonneg = TRUE` (caps, radii)
# rejects negatives; `nonneg = FALSE` (a signed perpendicular `offset`) allows
# them — the sign picks the side.
.check_cap <- function(cap, arg, scalar = FALSE, nonneg = TRUE) {
  if (is.null(cap)) {
    return(NULL)
  }
  cap <- as_unit(cap, "mm")
  if (nonneg) {
    .check_extent(cap, arg)
  }
  abs_codes <- unname(.unit_codes[c("mm", "in", "pt")])
  if (!all(vctrs::field(cap, "unit") %in% abs_codes)) {
    cli::cli_abort(c(
      "{.arg {arg}} must be an absolute-length {.cls unit} ({.val mm}/{.val cm}/{.val in}/{.val pt}).",
      i = "Caps are resolved in device space at render, so a {.val native}/{.val npc} length is not allowed."
    ))
  }
  if (scalar && .vsize(cap) > 1L) {
    cli::cli_abort(
      "{.arg {arg}} on a {.fn lines_grob} must be a single value (it trims the whole-path ends)."
    )
  }
  cap
}

#' Arrowheads
#'
#' Describe arrowheads to draw on the ends of a [lines_grob()] or
#' [segments_grob()] (pass as their `arrow =` argument).
#'
#' @param angle Half-angle of the head at the tip, in degrees (default 30).
#' @param length Head length as an absolute [vl_unit()] (default `vl_unit(0.25, "in")`).
#' @param ends Which ends get a head: `"last"` (default), `"first"`, or `"both"`.
#' @param type `"open"` (a two-barb V) or `"closed"` (a filled triangle).
#' @return A `vellum_arrow` object.
#' @examples
#' lines_grob(c(0.1, 0.9), c(0.1, 0.9), arrow = vl_arrow(type = "closed"))
#' @export
vl_arrow <- function(
  angle = 30,
  length = vl_unit(0.25, "in"),
  ends = c("last", "first", "both"),
  type = c("open", "closed")
) {
  ends <- match.arg(ends)
  type <- match.arg(type)
  len <- as_unit(length, "in")
  structure(
    list(angle = as.numeric(angle)[1], length = len, ends = ends, type = type),
    class = "vellum_arrow"
  )
}

# Encode an arrow (or NULL) into the scalars the backend takes.
.encode_arrow <- function(a) {
  if (is.null(a)) {
    return(list(angle = 0, len = 0, ends = 0L, closed = FALSE))
  }
  list(
    angle = a$angle,
    len = .to_inches(a$length),
    ends = switch(a$ends, first = 1L, last = 2L, both = 3L),
    closed = identical(a$type, "closed")
  )
}

# Fill-style names -> the integer codes `sketch.rs` decodes (FillStyle::from_code).
.sketch_fill_codes <- c(
  solid = 0L,
  hachure = 1L,
  crosshatch = 2L,
  zigzag = 3L,
  dots = 4L
)

#' Hand-drawn ("sketch") rendering
#'
#' Attach to a grob's `sketch` argument to render it in a hand-drawn, sketchy
#' style (the [Rough.js](https://roughjs.com) look): wobbly outlines and hachure
#' fills. Supported by [rect_grob()], [polygon_grob()], [lines_grob()], and
#' [circle_grob()]. Output is deterministic given `seed`.
#'
#' Sketch is a deliberate exception to vellum's crisp, fidelity-first defaults —
#' see `vignette` / `_docs/DESIGN-ROUGHR.md`. Text is never sketched.
#'
#' @param roughness Wobble amount (`>= 0`; `0` is nearly crisp, `1` the default
#'   hand-drawn look, higher is wilder).
#' @param bowing How much straight edges bow (0 disables bowing).
#' @param fill_style One of `"hachure"` (default), `"solid"`, `"crosshatch"`,
#'   `"zigzag"`, `"dots"`. Non-solid styles paint the fill colour as line work.
#' @param fill_weight Stroke width of fill/hachure lines, in `lwd` units
#'   (1 == 1/96 inch); `NULL` derives it from the grob's `lwd`.
#' @param hachure_angle Hachure line angle in degrees.
#' @param hachure_gap Gap between hachure lines, in `lwd` units; `NULL` = auto.
#' @param curve_tightness Curve fit tightness for round shapes (circles, arcs).
#' @param disable_multi_stroke If `TRUE`, draw single (not doubled) outline
#'   strokes — a cleaner, less sketchy line.
#' @param preserve_vertices If `TRUE`, keep shape vertices exact (only edges wobble).
#' @param seed Integer seed for the wobble (same seed => identical output).
#' @return A `vellum_sketch` object for a grob's `sketch` argument.
#' @examples
#' rect_grob(gp = vl_gpar(fill = "steelblue", col = "black"), sketch = sketch())
#' @export
sketch <- function(
  roughness = 1,
  bowing = 1,
  fill_style = c("hachure", "solid", "crosshatch", "zigzag", "dots"),
  fill_weight = NULL,
  hachure_angle = -41,
  hachure_gap = NULL,
  curve_tightness = 0,
  disable_multi_stroke = FALSE,
  preserve_vertices = FALSE,
  seed = 1L
) {
  fill_style <- match.arg(fill_style)
  if (
    !is.numeric(roughness) ||
      length(roughness) != 1L ||
      is.na(roughness) ||
      roughness < 0
  ) {
    cli::cli_abort("{.arg roughness} must be a single number >= 0.")
  }
  structure(
    list(
      roughness = as.numeric(roughness)[1],
      bowing = as.numeric(bowing)[1],
      fill_style = fill_style,
      fill_weight = if (is.null(fill_weight)) {
        -1
      } else {
        as.numeric(fill_weight)[1]
      },
      hachure_angle = as.numeric(hachure_angle)[1],
      hachure_gap = if (is.null(hachure_gap)) {
        -1
      } else {
        as.numeric(hachure_gap)[1]
      },
      curve_tightness = as.numeric(curve_tightness)[1],
      disable_multi_stroke = isTRUE(disable_multi_stroke),
      preserve_vertices = isTRUE(preserve_vertices),
      seed = as.numeric(seed)[1]
    ),
    class = "vellum_sketch"
  )
}

# Encode a sketch (or NULL) into the scalars the backend takes. `roughness = -1`
# is the "no sketch" sentinel (sketch_from returns None), so a scene without any
# sketch is byte-for-byte unchanged.
.encode_sketch <- function(s) {
  if (is.null(s)) {
    return(list(
      roughness = -1,
      bowing = 0,
      fill_style = 0L,
      fill_weight = -1,
      hachure_angle = 0,
      hachure_gap = -1,
      curve_tightness = 0,
      disable_multi = FALSE,
      preserve = FALSE,
      seed = 1
    ))
  }
  if (!inherits(s, "vellum_sketch")) {
    cli::cli_abort(
      "{.arg sketch} must be a {.fn sketch} object or {.code NULL}."
    )
  }
  list(
    roughness = s$roughness,
    bowing = s$bowing,
    fill_style = unname(.sketch_fill_codes[[s$fill_style]]),
    fill_weight = s$fill_weight,
    hachure_angle = s$hachure_angle,
    hachure_gap = s$hachure_gap,
    curve_tightness = s$curve_tightness,
    disable_multi = s$disable_multi_stroke,
    preserve = s$preserve_vertices,
    seed = s$seed
  )
}

# Encode a cap unit (or NULL) into the parallel (value, code) streams the backend
# resolves. `NULL` -> empty streams, the backend's "no cap" signal (so a scene
# without caps is byte-for-byte unchanged). Caps are validated absolute upstream,
# so the backend resolves them to a device length exactly like `size`/`r`.
.encode_cap <- function(cap) {
  if (is.null(cap)) {
    return(list(value = numeric(0), code = integer(0)))
  }
  list(
    value = vctrs::field(cap, "value"),
    code = as.integer(vctrs::field(cap, "unit"))
  )
}

#' @rdname grob
#' @export
polygon_grob <- function(
  x,
  y,
  sketch = NULL,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
) {
  n <- .coord_n(x, y)
  grob_polygon(
    x = vctrs::vec_recycle(as_unit(x, "native"), n),
    y = vctrs::vec_recycle(as_unit(y, "native"), n),
    sketch = sketch,
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role,
    keys = .recycle_keys(key, 1L),
    meta = .recycle_meta(meta, 1L)
  )
}

#' @rdname grob
#' @param n Number of points to sample the curve at (flattened to a polyline).
#' @export
bezier_grob <- function(
  x,
  y,
  n = 60,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
) {
  ax <- .axis_unit(x)
  ay <- .axis_unit(y)
  if (length(ax$value) != length(ay$value)) {
    cli::cli_abort("{.arg x} and {.arg y} must have the same length.")
  }
  if (length(ax$value) < 2L) {
    cli::cli_abort("A Bezier needs at least 2 control points.")
  }
  t <- seq(0, 1, length.out = max(2L, n))
  lines_grob(
    vl_unit(.bezier_eval(ax$value, t), ax$unit),
    vl_unit(.bezier_eval(ay$value, t), ay$unit),
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role
  )
}

#' @rdname grob
#' @param shape Spline smoothness in `[0, 1]`: `1` (default) a smooth
#'   Catmull-Rom curve through the points, `0` straight segments.
#' @param open If `FALSE`, the spline is closed (wraps end to start).
#' @export
spline_grob <- function(
  x,
  y,
  shape = 1,
  n = 20,
  open = TRUE,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
) {
  ax <- .axis_unit(x)
  ay <- .axis_unit(y)
  if (length(ax$value) != length(ay$value)) {
    cli::cli_abort("{.arg x} and {.arg y} must have the same length.")
  }
  tension <- 1 - max(0, min(1, shape))
  fx <- .cardinal(ax$value, tension, max(1L, n), !open)
  fy <- .cardinal(ay$value, tension, max(1L, n), !open)
  lines_grob(
    vl_unit(fx, ax$unit),
    vl_unit(fy, ay$unit),
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role
  )
}

#' @rdname grob
#' @param r Radius ([vl_unit()] or numeric).
#' @export
circle_grob <- function(
  x = 0.5,
  y = 0.5,
  r = 0.25,
  sketch = NULL,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
) {
  n <- .elem_n(list(x = x, y = y, r = r))
  ru <- as_unit(r)
  .check_extent(ru, "r")
  grob_circle(
    x = vctrs::vec_recycle(as_unit(x), n),
    y = vctrs::vec_recycle(as_unit(y), n),
    r = vctrs::vec_recycle(ru, n),
    sketch = sketch,
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role,
    keys = .recycle_keys(key, n),
    meta = .recycle_meta(meta, n)
  )
}

#' @rdname grob
#' @param size Point size ([vl_unit()] or numeric).
#' @param shape Marker shape(s): `"circle"` (default), `"square"`, `"triangle"`,
#'   `"diamond"`, `"plus"`, `"cross"`, `"triangle_down"`, or `"star"`, recycled per
#'   point. Filled shapes (all but `"plus"`/`"cross"`) paint `gp$fill` and outline
#'   with `gp$col`, so an *open* marker is `fill = NA` with a `col`, a *filled* one
#'   sets `fill`; `"plus"`/`"cross"` are stroke-only line glyphs.
#' @export
points_grob <- function(
  x,
  y,
  size = vl_unit(2, "mm"),
  shape = "circle",
  sketch = NULL,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
) {
  sz <- as_unit(size, "mm")
  .check_extent(sz, "size")
  shape <- as.character(shape)
  n <- .elem_n(list(x = x, y = y, size = sz, shape = shape))
  bad <- setdiff(unique(shape), names(.marker_codes))
  if (length(bad)) {
    cli::cli_abort(
      "Unknown point {.arg shape}: {.val {bad}}. Use {.or {names(.marker_codes)}}."
    )
  }
  grob_points(
    x = vctrs::vec_recycle(as_unit(x), n),
    y = vctrs::vec_recycle(as_unit(y), n),
    size = vctrs::vec_recycle(sz, n),
    shape = vctrs::vec_recycle(shape, n),
    sketch = sketch,
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role,
    keys = .recycle_keys(key, n),
    meta = .recycle_meta(meta, n)
  )
}

#' @rdname grob
#' @param fill Per-hexagon fill colour(s), recycled to the number of hexagons. The
#'   binned-count colour mesh: each hexagon is filled with its own colour in a
#'   single batched draw. `NULL` (default) falls back to `gp$fill`. The uniform
#'   stroke comes from `gp` (`col`/`lwd`).
#' @param orientation Hexagon orientation: `"flat"` (default, flat top/bottom edge)
#'   or `"pointy"` (vertex at top). `size` is the circumradius (centre to vertex).
#' @export
hexagon_grob <- function(
  x = 0.5,
  y = 0.5,
  size = vl_unit(2, "mm"),
  width = NULL,
  height = NULL,
  fill = NULL,
  orientation = c("flat", "pointy"),
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
) {
  orientation <- match.arg(orientation)
  sz <- as_unit(size, "mm")
  .check_extent(sz, "size")
  if (is.null(width) != is.null(height)) {
    cli::cli_abort("{.arg width} and {.arg height} must be supplied together.")
  }
  n <- .elem_n(list(
    x = x,
    y = y,
    size = sz,
    width = width,
    height = height
  ))
  if (!is.null(width)) {
    width <- as_unit(width, "native")
    height <- as_unit(height, "native")
    .check_extent(width, "width")
    .check_extent(height, "height")
    width <- vctrs::vec_recycle(width, n)
    height <- vctrs::vec_recycle(height, n)
  }
  if (!is.null(fill) && !.is_paint(fill)) {
    fill <- rep_len(fill, n)
  }
  grob_hexagon(
    x = vctrs::vec_recycle(as_unit(x), n),
    y = vctrs::vec_recycle(as_unit(y), n),
    size = vctrs::vec_recycle(sz, n),
    width = width,
    height = height,
    fill = fill,
    orientation = orientation,
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role,
    keys = .recycle_keys(key, n),
    meta = .recycle_meta(meta, n)
  )
}

#' @rdname grob
#' @param r0,r1 Inner and outer radius of each sector ([vl_unit()] or numeric;
#'   numeric is treated as `"native"`). `r0 = 0` gives a pie slice; `r0 == r1`
#'   gives an arc outline (stroke only, no fill).
#' @param theta0,theta1 Start and end angle of each sector, in **radians**, with 0
#'   at 3 o'clock and increasing counter-clockwise.
#' @param fill Per-element fill colour(s), recycled to the number of sectors. `NULL`
#'   falls back to `gp$fill`.
#' @details
#' `sector_grob()` draws a batch of annular sectors (pie / donut / rose wedges) in a
#' single call. `gp$fill` recycles per sector; `gp$col`/`lwd` give a uniform stroke.
#'
#' Passing `r0 == r1` gives an **open arc** (stroke only). Combined with an
#' absolute (`mm`) radius at a `"native"` centre and an [vl_arrow()], the radius is
#' resolved to a device length at render (like a marker `size`), so the arc tracks
#' an mm size at any page size or dpi; the arrowhead sits tangent to the outer arc's
#' end. (For node-link **self-loops**, prefer [loop_grob()] — a teardrop, not a
#' ring.)
#' @export
sector_grob <- function(
  x = 0.5,
  y = 0.5,
  r0 = 0,
  r1 = 0.5,
  theta0 = 0,
  theta1 = 2 * pi,
  fill = NULL,
  arrow = NULL,
  sketch = NULL,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
) {
  n <- .elem_n(list(
    x = x,
    y = y,
    r0 = r0,
    r1 = r1,
    theta0 = theta0,
    theta1 = theta1
  ))
  .check_finite_num(theta0, "theta0")
  .check_finite_num(theta1, "theta1")
  if (!is.null(fill) && !.is_paint(fill)) {
    fill <- rep_len(fill, n)
  }
  grob_sector(
    x = vctrs::vec_recycle(as_unit(x), n),
    y = vctrs::vec_recycle(as_unit(y), n),
    r0 = vctrs::vec_recycle(as_unit(r0, "native"), n),
    r1 = vctrs::vec_recycle(as_unit(r1, "native"), n),
    theta0 = vctrs::vec_recycle(as.numeric(theta0), n),
    theta1 = vctrs::vec_recycle(as.numeric(theta1), n),
    fill = fill,
    arrow = arrow,
    sketch = sketch,
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role,
    keys = .recycle_keys(key, n),
    meta = .recycle_meta(meta, n)
  )
}

#' @rdname grob
#' @param size Loop extent: an **absolute** [vl_unit()] (`mm`/`cm`/`in`/`pt`; a bare
#'   numeric is `mm`), resolved to a device length **at render** so the loop tracks
#'   a node's mm size at any page size/dpi. Nested loops on one vertex pass growing
#'   `size` (same `x`/`y`/`angle`) for concentric teardrops. Recycled per loop.
#' @param foot Node radius the loop's two **feet** attach at (an **absolute**
#'   [vl_unit()]; `0` = both feet at the vertex, like igraph). A positive `foot` puts
#'   the feet on the node's boundary so the loop visibly leaves and re-enters the
#'   node edge, and a directed loop's head lands on the boundary rather than under
#'   the marker. Recycled per loop.
#' @param angle Outward direction of the loop in **radians** (which way the teardrop
#'   bulges away from the vertex, e.g. away from the layout centroid).
#' @details
#' `loop_grob()` draws **self-loops** for node-link diagrams as an igraph-style cubic
#' **Bézier teardrop**: it leaves the vertex `(x, y)` (a `"native"` anchor), bulges
#' out to `size` along `angle`, and returns, with an optional [vl_arrow()] head tangent
#' to the curve at the returning foot. `size` and `foot` are absolute and resolved to
#' device px **at render**, so the loop is a fixed physical size that scales with the
#' mm node markers — no native-per-mm estimation, exact at any figure size/dpi.
#' @export
loop_grob <- function(
  x = 0.5,
  y = 0.5,
  size = vl_unit(4, "mm"),
  foot = vl_unit(0, "mm"),
  angle = 0,
  width = 1,
  arrow = NULL,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
) {
  n <- .elem_n(list(
    x = x,
    y = y,
    size = size,
    foot = foot,
    angle = angle,
    width = width
  ))
  .check_finite_num(angle, "angle")
  sz <- .check_cap(as_unit(size, "mm"), "size")
  ft <- .check_cap(as_unit(foot, "mm"), "foot")
  grob_loop(
    x = vctrs::vec_recycle(as_unit(x), n),
    y = vctrs::vec_recycle(as_unit(y), n),
    size = vctrs::vec_recycle(sz, n),
    foot = vctrs::vec_recycle(ft, n),
    angle = vctrs::vec_recycle(as.numeric(angle), n),
    width = vctrs::vec_recycle(as.numeric(width), n),
    arrow = arrow,
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role
  )
}

#' @rdname grob
#' @param x0,y0,x1,y1 Segment start/end coordinates ([vl_unit()] or numeric).
#' @export
segments_grob <- function(
  x0,
  y0,
  x1,
  y1,
  arrow = NULL,
  start_cap = NULL,
  end_cap = NULL,
  offset = NULL,
  sketch = NULL,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  key = NULL,
  meta = NULL,
  col = NULL,
  lwd = NULL
) {
  n <- .elem_n(list(
    x0 = x0,
    y0 = y0,
    x1 = x1,
    y1 = y1,
    start_cap = start_cap,
    end_cap = end_cap,
    offset = offset
  ))
  start_cap <- .check_cap(start_cap, "start_cap")
  end_cap <- .check_cap(end_cap, "end_cap")
  offset <- .check_cap(offset, "offset", nonneg = FALSE)
  if (!is.null(start_cap)) {
    start_cap <- vctrs::vec_recycle(start_cap, n)
  }
  if (!is.null(end_cap)) {
    end_cap <- vctrs::vec_recycle(end_cap, n)
  }
  if (!is.null(offset)) {
    offset <- vctrs::vec_recycle(offset, n)
  }
  grob_segments(
    x0 = vctrs::vec_recycle(as_unit(x0, "native"), n),
    y0 = vctrs::vec_recycle(as_unit(y0, "native"), n),
    x1 = vctrs::vec_recycle(as_unit(x1, "native"), n),
    y1 = vctrs::vec_recycle(as_unit(y1, "native"), n),
    arrow = arrow,
    start_cap = start_cap,
    end_cap = end_cap,
    offset = offset,
    sketch = sketch,
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role,
    keys = .recycle_keys(key, n),
    meta = .recycle_meta(meta, n),
    ecol = if (is.null(col)) NULL else rep_len(col, n),
    elwd = if (is.null(lwd)) NULL else rep_len(as.numeric(lwd), n)
  )
}

#' @rdname grob
#' @param id For most grobs, an optional semantic identifier emitted by the SVG
#'   backend as `data-vellum-id` (for interactivity, accessibility, and testing;
#'   ignored by raster/PDF). **For `path_grob` only**, `id` instead groups points
#'   (one value per point) into closed sub-paths: all points sharing an `id` form
#'   one sub-path (so a hole is a separate `id`), in first-appearance order (à la
#'   grid); `NULL` makes a single sub-path.
#' @param rule Fill rule: `"winding"` (non-zero, default) or `"evenodd"`.
#' @param col,lwd **`segments_grob()` only** — per-segment stroke colour and
#'   width, recycled to the segment count, mirroring the per-element `fill` that
#'   `hexagon_grob()` and `sector_grob()` carry. `NULL` (default) uses the shared
#'   `gp`, and the batch is drawn in one combined stroke exactly as before.
#'
#'   Reach for these instead of building one grob per segment: varying width or
#'   colour that way costs an R-side grob each, which is the dominant expense on
#'   scenes made of many small marks. Note that no backend can stroke segments
#'   differently in a single call, so each segment is stroked on its own here —
#'   the saving is in R, not in the output size.
#'
#'   These vary width *per element*, so the width steps between segments and the
#'   joins show. For width varying smoothly *along* one line, with no joins to
#'   give it away, see `lwd_profile` in [stroke_to_path()].
#' @param key Optional per-element data key(s) for the batched marks
#'   (`points_grob`, `circle_grob`, `rect_grob`, `segments_grob`, `hexagon_grob`,
#'   `sector_grob`), recycled to the element count like `fill`. Emitted by the SVG
#'   backend as `data-key` on each element and surfaced by [scene_model()] — the
#'   join key a host uses to map an interaction back to a datum. `NULL` (default)
#'   emits nothing (a static render is unchanged). Ignored by raster/PDF.
#' @param meta Optional free-form per-element metadata for the batched marks: a
#'   list with one entry (record) per element (recycled), e.g. tooltip text or
#'   field values. It never reaches the backend (nothing drawn changes); it rides
#'   on the scene and is returned by [scene_model()]. `NULL` (default) = none.
#' @export
path_grob <- function(
  x,
  y,
  id = NULL,
  rule = c("winding", "evenodd"),
  sketch = NULL,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  role = NULL,
  key = NULL,
  meta = NULL
) {
  rule <- match.arg(rule)
  n <- .coord_n(x, y)
  xu <- vctrs::vec_recycle(as_unit(x, "native"), n)
  yu <- vctrs::vec_recycle(as_unit(y, "native"), n)
  if (is.null(id)) {
    nper <- n
  } else {
    if (length(id) != n) {
      cli::cli_abort("{.arg id} must have one value per point ({n}).")
    }
    grp <- match(id, unique(id)) # group index in first-appearance order
    ord <- order(grp, seq_along(grp)) # stable: gather each id's points together
    xu <- xu[ord]
    yu <- yu[ord]
    nper <- tabulate(grp)
  }
  grob_path(
    x = xu,
    y = yu,
    nper = as.integer(nper),
    rule = rule,
    sketch = sketch,
    gp = gp,
    name = name,
    vp = vp,
    role = role,
    keys = .recycle_keys(key, 1L),
    meta = .recycle_meta(meta, 1L)
  )
}

#' @rdname grob
#' @param image A raster image. Either a [grDevices::as.raster()]-compatible
#'   object — a matrix/array of colours or greyscale values, or a `raster` — or a
#'   **path to a PNG file**, decoded in the Rust backend so no R image package is
#'   needed. A numeric RGB/RGBA array in `[0, 1]` (what `png::readPNG()` returns)
#'   takes a fast path that skips the per-pixel colour-string round-trip
#'   `as.raster()` would otherwise do; the pixels are identical either way.
#' @param interpolate Smoothly interpolate when scaling (default `TRUE`)? `FALSE`
#'   keeps hard pixel edges.
#' @export
raster_grob <- function(
  image,
  x = 0.5,
  y = 0.5,
  width = 1,
  height = 1,
  interpolate = TRUE,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
) {
  px <- .image_to_rgba(image)
  grob_raster(
    rgba = px$rgba,
    iw = px$iw,
    ih = px$ih,
    x = as_unit(x),
    y = as_unit(y),
    width = as_unit(width),
    height = as_unit(height),
    interpolate = isTRUE(interpolate),
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role
  )
}

#' @rdname grob
#' @param label Character string(s) to draw.
#' @param just Justification: `c(hjust, vjust)` as names (`"left"`, `"centre"`,
#'   `"right"`, `"bottom"`, `"top"`) or numbers in `[0, 1]`.
#' @param rot Rotation in degrees, counter-clockwise.
#' @param align Alignment of lines within the box: `"left"` (default),
#'   `"centre"`/`"center"`, `"right"`, or `"justify"` (flush both edges, last
#'   line of each paragraph left as-is).
#' @param fit Auto-fit sizing. `FALSE` (default) keeps `gp$fontsize`. `TRUE`
#'   shrinks the font — never grows it — until the wrapped block fits
#'   `width` × `height`, down to a floor of 4 pt; a number sets that floor
#'   instead. Requires `width`.
#' @export
text_grob <- function(
  label,
  x = 0.5,
  y = 0.5,
  just = "centre",
  rot = 0,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL,
  width = NULL,
  height = NULL,
  align = "left",
  fit = FALSE,
  key = NULL,
  meta = NULL
) {
  # Rich labels pass through untouched; everything else coerces to character.
  if (!S7::S7_inherits(label, vellum_label)) {
    label <- as.character(label)
  }
  align <- match.arg(align, c("left", "centre", "center", "right", "justify"))
  if (!isFALSE(fit) && is.null(width)) {
    cli::cli_abort("{.arg fit} needs a {.arg width} to fit into.")
  }
  x <- as_unit(x)
  y <- as_unit(y)
  n <- .text_n(label, x, y)
  grob_text(
    label = label,
    x = x,
    y = y,
    just = as.character(just),
    rot = as.numeric(rot),
    width = .abs_mm(width, "width"),
    height = .abs_mm(height, "height"),
    align = align,
    fit = if (isFALSE(fit)) {
      NA_real_
    } else if (isTRUE(fit)) {
      4
    } else {
      as.numeric(fit)
    },
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role,
    keys = .recycle_keys(key, n),
    meta = .recycle_meta(meta, n)
  )
}

#' Text set along a path
#'
#' `text_path_grob()` places a label along a polyline baseline instead of at a
#' point: each glyph keeps the pen position shaping gave it and is drawn at that
#' distance along the path, rotated to the local tangent. Use it for labels that
#' follow an arc, a contour, a river or a curved axis.
#'
#' The path is a sequence of points, exactly like [lines_grob()] — pass the
#' output of [bezier_grob()]-style control points already flattened, or any
#' polyline. Arc length is measured on the *rendered* path, so the result adapts
#' to the viewport the grob is drawn in.
#'
#' `just` does double duty: the horizontal component slides the run along the
#' baseline (`"left"` starts at the first point, `"centre"` centres it,
#' `"right"` ends at the last), and the vertical component positions the glyphs
#' against the baseline as it would for ordinary text. For finer control of the
#' standoff — a label riding just above a curve rather than sitting on it — use
#' `offset`.
#'
#' Glyphs follow the tangent, as in SVG `textPath`: a label on the underside
#' of a closed curve reads upside-down. That is the honest result of the
#' geometry, and the fix is to reverse the path rather than the glyphs — set the
#' lower arc as a second `text_path_grob()` whose points run the other way.
#'
#' Glyphs are placed one per character. For Latin text that is exact; scripts
#' where shaping produces a different number of glyphs than characters (Arabic,
#' Devanagari, and ligature-heavy fonts) will still draw, but the per-glyph
#' text recovered by PDF copy-paste and by SVG native text degrades to the whole
#' label on the first glyph.
#'
#' @inheritParams grob
#' @param label A single character string.
#' @param x,y The baseline path, as unit vectors of equal length.
#' @param offset Perpendicular standoff from the baseline in points; positive is
#'   to the left of the direction of travel.
#' @return A grob.
#' @examples
#' th <- seq(pi, 0, length.out = 60)
#' vl_scene(4, 2.2, dpi = 96, bg = "white") |>
#'   draw(text_path_grob(
#'     "text that follows a curve",
#'     x = 0.5 + 0.42 * cos(th), y = 0.15 + 0.7 * sin(th),
#'     offset = 3, gp = vl_gpar(fontsize = 13)
#'   ))
#' @export
text_path_grob <- function(
  label,
  x,
  y,
  just = "centre",
  offset = 0,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
) {
  label <- as.character(label)
  if (length(label) != 1L) {
    cli::cli_abort("{.arg label} must be a single string; got {length(label)}.")
  }
  grob_textpath(
    label = label,
    x = as_unit(x),
    y = as_unit(y),
    just = as.character(just),
    offset = as.numeric(offset),
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role
  )
}

# Resolve a text-box dimension to millimetres, insisting it be absolute. NULL
# stays NA (unset).
.abs_mm <- function(u, arg) {
  if (is.null(u)) {
    return(NA_real_)
  }
  u <- as_unit(u)
  mm <- try(.to_inches(u) * 25.4, silent = TRUE)
  if (inherits(mm, "try-error") || !is.finite(mm)) {
    cli::cli_abort(c(
      "{.arg {arg}} must be an absolute unit ({.val mm}/{.val cm}/{.val in}/{.val pt}).",
      i = "Text is wrapped when the grob is built, and {.val npc}/{.val native} have no size until render time."
    ))
  }
  mm
}
