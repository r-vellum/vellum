#' @include grob-class.R
NULL

# --- friendly constructors --------------------------------------------------

#' @rdname grob
#' @param x,y Coordinates ([vl_unit()] or numeric, read in `default_units`).
#' @param width,height Grob size ([vl_unit()] or numeric, read in
#'   `default_units`), recycled like `x`/`y`.
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
#' @param default_units Unit a **bare numeric** is read in, for the position
#'   and size arguments (`x`, `y`, `width`, `height`, `x0`..`y1`, `r`,
#'   `r0`/`r1`), as grid's `default.units`. Defaults to `"npc"` in every
#'   constructor; pass `"native"` to read bare numbers on the viewport's
#'   `xscale`/`yscale`, or an absolute unit such as `"mm"`. A [vl_unit()] keeps
#'   its own unit. Arguments with a physical default of their own ignore it: a
#'   bare `size` on [points_grob()], [hexagon_grob()] and [loop_grob()], and
#'   `foot`, `start_cap`, `end_cap` and `offset`, stay `"mm"`; an arrow
#'   `length` stays `"in"`. See **Units** below for how a relative length
#'   resolves.
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
  meta = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  v <- list(
    x = .as_unit_arg(x, "x", du),
    y = .as_unit_arg(y, "y", du),
    width = .check_extent(.as_unit_arg(width, "width", du), "width"),
    height = .check_extent(.as_unit_arg(height, "height", du), "height")
  )
  n <- .elem_n(v)
  grob_rect(
    x = v$x,
    y = v$y,
    width = v$width,
    height = v$height,
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
#' @param r Corner radius ([vl_unit()] or numeric, read in `default_units`).
#'   An `"npc"` radius is isotropic (a fraction of the shorter side, like grid's `"snpc"`), so corners
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
  meta = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  v <- list(
    x = .as_unit_arg(x, "x", du),
    y = .as_unit_arg(y, "y", du),
    width = .check_extent(.as_unit_arg(width, "width", du), "width"),
    height = .check_extent(.as_unit_arg(height, "height", du), "height"),
    r = .check_extent(.as_unit_arg(r, "r", du), "r")
  )
  # A roundrect grob is a *batch*: one box per (x, y, w, h, r) element, like
  # `rect_grob()`. Recycle keys/meta to that element count (not to 1, which
  # silently dropped every key past the first on a multi-box grob).
  n <- .elem_n(v)
  grob_roundrect(
    x = v$x,
    y = v$y,
    width = v$width,
    height = v$height,
    r = v$r,
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
  meta = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
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
  v <- .recycle_elems(
    list(x = .as_unit_arg(x, "x", du), y = .as_unit_arg(y, "y", du)),
    n
  )
  grob_lines(
    x = v$x,
    y = v$y,
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
#' @param angle Half-angle of the head at the tip, in degrees, strictly between
#'   0 and 180 (default 30).
#' @param length Head length as a single, non-negative absolute [vl_unit()]
#'   (`mm`/`cm`/`in`/`pt`; a bare number is inches). Default `vl_unit(0.25, "in")`.
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
  ends <- .check_choice(ends, c("last", "first", "both"), "ends")
  type <- .check_choice(type, c("open", "closed"), "type")
  .check_scalar(angle, "angle", "numeric")
  .check_range(angle, "angle", min = 0, max = 180, inclusive = c(FALSE, FALSE))
  # The head is sized in device space at render, so only an absolute length
  # works; check it here rather than failing when the scene is rendered.
  .abs_length_mm(
    length,
    "length",
    default_units = "in",
    why = "Arrowheads are sized in device space at render, so a {.val npc}/{.val native} length is not allowed."
  )
  len <- as_unit(length, "in")
  structure(
    list(angle = as.numeric(angle), length = len, ends = ends, type = type),
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
    len = .to_inches(a$length, "length"),
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
  meta = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  n <- .coord_n(x, y)
  v <- .recycle_elems(
    list(x = .as_unit_arg(x, "x", du), y = .as_unit_arg(y, "y", du)),
    n
  )
  grob_polygon(
    x = v$x,
    y = v$y,
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
  role = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  ax <- .axis_unit(x, du)
  ay <- .axis_unit(y, du)
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
  role = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  ax <- .axis_unit(x, du)
  ay <- .axis_unit(y, du)
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
#' @param r Radius ([vl_unit()] or numeric, read in `default_units`). An
#'   `"npc"` radius is a fraction of the viewport's shorter side, so the circle
#'   stays round.
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
  meta = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  v <- list(
    x = .as_unit_arg(x, "x", du),
    y = .as_unit_arg(y, "y", du),
    r = .check_extent(.as_unit_arg(r, "r", du), "r")
  )
  n <- .elem_n(v)
  v <- .recycle_elems(v, n)
  grob_circle(
    x = v$x,
    y = v$y,
    r = v$r,
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
#' @param size Point size ([vl_unit()] or numeric; a bare numeric is `"mm"`,
#'   whatever `default_units` says).
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
  meta = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  shape <- as.character(shape)
  v <- list(
    x = .as_unit_arg(x, "x", du),
    y = .as_unit_arg(y, "y", du),
    # `size` keeps its own physical default: a bare number is millimetres.
    size = .check_extent(.as_unit_arg(size, "size", "mm"), "size"),
    shape = shape
  )
  n <- .elem_n(v)
  bad <- setdiff(unique(shape), names(.marker_codes))
  if (length(bad)) {
    cli::cli_abort(
      "Unknown point {.arg shape}: {.val {bad}}. Use {.or {names(.marker_codes)}}."
    )
  }
  v <- .recycle_elems(v, n)
  grob_points(
    x = v$x,
    y = v$y,
    size = v$size,
    shape = v$shape,
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
  meta = NULL,
  default_units = "npc"
) {
  orientation <- .check_choice(orientation, c("flat", "pointy"), "orientation")
  du <- .check_default_units(default_units)
  if (is.null(width) != is.null(height)) {
    cli::cli_abort("{.arg width} and {.arg height} must be supplied together.")
  }
  v <- list(
    x = .as_unit_arg(x, "x", du),
    y = .as_unit_arg(y, "y", du),
    # `size` keeps its own physical default: a bare number is millimetres.
    size = .check_extent(.as_unit_arg(size, "size", "mm"), "size"),
    width = .check_extent(
      .as_unit_arg(width, "width", du, allow_null = TRUE),
      "width"
    ),
    height = .check_extent(
      .as_unit_arg(height, "height", du, allow_null = TRUE),
      "height"
    )
  )
  n <- .elem_n(v)
  v <- .recycle_elems(v, n)
  fill <- .elem_fill(fill, gp, n)
  grob_hexagon(
    x = v$x,
    y = v$y,
    size = v$size,
    width = v$width,
    height = v$height,
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

# Per-element fill for the batched marks (hexagon, sector): an explicit `fill`
# wins, else a colour *vector* in `gp$fill`, recycled per element. Either must
# have length 1 or `n`. A gradient/pattern stays on `gp` (the shared paint),
# and a scalar `gp$fill` is left there too, so the stored grob is unchanged for
# the common case.
.elem_fill <- function(fill, gp, n, call = parent.frame()) {
  if (!is.null(fill)) {
    if (.is_paint(fill)) {
      return(fill)
    }
    .check_colour(fill, "fill", call = call)
    .check_len1n(fill, n, "fill", call = call)
    return(rep_len(fill, n))
  }
  gf <- gp@fill
  if (!is.null(gf) && !.is_paint(gf) && length(gf) > 1L) {
    .check_len1n(gf, n, "gp$fill", call = call)
    return(rep_len(gf, n))
  }
  NULL
}

# An annular sector needs `r0 <= r1`. Only elements whose two radii share a
# unit (and offset) are comparable before render; mixed units resolve later.
.check_radii <- function(r0, r1, call = parent.frame()) {
  .check_extent(r0, "r0", call = call)
  .check_extent(r1, "r1", call = call)
  same <- vctrs::field(r0, "unit") == vctrs::field(r1, "unit") &
    vctrs::field(r0, "offset") == vctrs::field(r1, "offset")
  bad <- which(same & vctrs::field(r0, "value") > vctrs::field(r1, "value"))
  if (length(bad)) {
    cli::cli_abort(
      c(
        "{.arg r0} must not exceed {.arg r1} (the inner radius is inside the outer one).",
        x = "{cli::qty(length(bad))}Element{?s} {bad} ha{?s/ve} {.arg r0} > {.arg r1}."
      ),
      call = call
    )
  }
  invisible()
}

#' @rdname grob
#' @param r0,r1 Inner and outer radius of each sector ([vl_unit()] or numeric,
#'   read in `default_units`; an `"npc"` radius is a fraction of the viewport's
#'   shorter side). `r0 = 0` gives a pie slice; `r0 == r1`
#'   gives an arc outline (stroke only, no fill).
#' @param theta0,theta1 Start and end angle of each sector, in **radians**, with 0
#'   at 3 o'clock and increasing counter-clockwise.
#' @param fill Per-element fill colour(s), length 1 or the number of sectors.
#'   `NULL` falls back to `gp$fill`, which may likewise be a per-sector vector.
#' @details
#' `sector_grob()` draws a batch of annular sectors (pie / donut / rose wedges) in a
#' single call. `fill` (or a colour vector in `gp$fill`) recycles per sector;
#' `gp$col`/`lwd` give a uniform stroke. `r0` must not exceed `r1`.
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
  meta = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  v <- list(
    x = .as_unit_arg(x, "x", du),
    y = .as_unit_arg(y, "y", du),
    r0 = .as_unit_arg(r0, "r0", du),
    r1 = .as_unit_arg(r1, "r1", du),
    theta0 = .check_finite_num(theta0, "theta0"),
    theta1 = .check_finite_num(theta1, "theta1")
  )
  n <- .elem_n(v)
  v <- .recycle_elems(v, n)
  .check_radii(v$r0, v$r1)
  fill <- .elem_fill(fill, gp, n)
  grob_sector(
    x = v$x,
    y = v$y,
    r0 = v$r0,
    r1 = v$r1,
    theta0 = v$theta0,
    theta1 = v$theta1,
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
  role = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  v <- list(
    x = .as_unit_arg(x, "x", du),
    y = .as_unit_arg(y, "y", du),
    # `size`/`foot` are absolute (a bare number is mm), whatever `default_units`.
    size = .check_cap(size, "size"),
    foot = .check_cap(foot, "foot"),
    angle = .check_finite_num(angle, "angle"),
    width = .check_range(width, "width", min = 0)
  )
  n <- .elem_n(v)
  v <- .recycle_elems(v, n)
  grob_loop(
    x = v$x,
    y = v$y,
    size = v$size,
    foot = v$foot,
    angle = v$angle,
    width = v$width,
    arrow = arrow,
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role
  )
}

#' @rdname grob
#' @param x0,y0,x1,y1 Segment start/end coordinates ([vl_unit()] or numeric,
#'   read in `default_units`).
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
  lwd = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  v <- list(
    x0 = .as_unit_arg(x0, "x0", du),
    y0 = .as_unit_arg(y0, "y0", du),
    x1 = .as_unit_arg(x1, "x1", du),
    y1 = .as_unit_arg(y1, "y1", du),
    # Caps and offset are absolute (a bare number is mm), whatever
    # `default_units`.
    start_cap = .check_cap(start_cap, "start_cap"),
    end_cap = .check_cap(end_cap, "end_cap"),
    offset = .check_cap(offset, "offset", nonneg = FALSE)
  )
  n <- .elem_n(v)
  v <- .recycle_elems(v, n)
  grob_segments(
    x0 = v$x0,
    y0 = v$y0,
    x1 = v$x1,
    y1 = v$y1,
    arrow = arrow,
    start_cap = v$start_cap,
    end_cap = v$end_cap,
    offset = v$offset,
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
#'   field values, or a data frame with one row per element and one column per
#'   field (columnar, cheaper for many elements; row `i` stands for the record
#'   of its values, a `NULL` list-column entry leaving its field out). It never
#'   reaches the backend (nothing drawn changes); it rides on the scene and is
#'   returned by [scene_model()]. `NULL` (default) = none.
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
  meta = NULL,
  default_units = "npc"
) {
  rule <- .check_choice(rule, c("winding", "evenodd"), "rule")
  du <- .check_default_units(default_units)
  n <- .coord_n(x, y)
  v <- .recycle_elems(
    list(x = .as_unit_arg(x, "x", du), y = .as_unit_arg(y, "y", du)),
    n
  )
  xu <- v$x
  yu <- v$y
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
  role = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  px <- .image_to_rgba(image)
  grob_raster(
    rgba = px$rgba,
    iw = px$iw,
    ih = px$ih,
    x = .as_unit_arg(x, "x", du),
    y = .as_unit_arg(y, "y", du),
    width = .as_unit_arg(width, "width", du),
    height = .as_unit_arg(height, "height", du),
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
  meta = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  # Rich labels (one, or a list of them: one per datum) pass through
  # untouched; everything else coerces to character.
  if (!.is_rich_label(label)) {
    label <- as.character(label)
  }
  align <- match.arg(align, c("left", "centre", "center", "right", "justify"))
  if (!isFALSE(fit) && is.null(width)) {
    cli::cli_abort("{.arg fit} needs a {.arg width} to fit into.")
  }
  x <- .as_unit_arg(x, "x", du)
  y <- .as_unit_arg(y, "y", du)
  n <- .text_n(label, x, y)
  grob_text(
    label = label,
    x = x,
    y = y,
    just = as.character(just),
    rot = as.numeric(rot),
    width = .abs_mm(
      .as_unit_arg(width, "width", du, allow_null = TRUE),
      "width"
    ),
    height = .abs_mm(
      .as_unit_arg(height, "height", du, allow_null = TRUE),
      "height"
    ),
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
#' @param x,y The baseline path, as [vl_unit()] or numeric vectors (read in
#'   `default_units`) of equal length.
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
  role = NULL,
  default_units = "npc"
) {
  du <- .check_default_units(default_units)
  label <- as.character(label)
  if (length(label) != 1L) {
    cli::cli_abort("{.arg label} must be a single string; got {length(label)}.")
  }
  grob_textpath(
    label = label,
    x = .as_unit_arg(x, "x", du),
    y = .as_unit_arg(y, "y", du),
    just = as.character(just),
    offset = as.numeric(offset),
    gp = gp,
    name = name,
    vp = vp,
    id = id,
    role = role
  )
}

# Resolve a text-box dimension to millimetres, insisting it be a single
# absolute length. NULL stays NA (unset). The box is one per grob (wrapping is
# done per label against the same width), so a vector is an error rather than
# silently using its first element.
.abs_mm <- function(u, arg, call = parent.frame()) {
  if (is.null(u)) {
    return(NA_real_)
  }
  .abs_length_mm(
    u,
    arg,
    why = "Text is wrapped when the grob is built, and {.val npc}/{.val native} have no size until render time.",
    call = call
  )
}
