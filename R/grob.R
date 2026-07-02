#' Graphical objects (grobs)
#'
#' Grobs are immutable value objects describing something to draw. Build them
#' with the constructors below, add them to a scene with [draw()], and render
#' with [render()]. Coordinates accept a [unit()] vector or a bare numeric
#' (interpreted in the `default_units`, usually `"npc"`).
#'
#' @name grob
#' @return A grob object.
NULL

# Abstract base: every grob carries a name, gpar, and an optional viewport.
# `id`/`role` are optional semantic metadata: a stable identifier and an ARIA
# role, emitted by the SVG backend as `data-vellum-id` / `role` for interactivity,
# accessibility, and testing. They are ignored by the raster and PDF backends.
grob <- S7::new_class(
  "grob", package = "vellum", abstract = TRUE,
  properties = list(
    name = S7::new_property(S7::class_any, default = NULL),
    gp   = S7::new_property(gpar, default = quote(gpar())),
    vp   = S7::new_property(S7::class_any, default = NULL),
    id   = S7::new_property(S7::class_any, default = NULL),
    role = S7::new_property(S7::class_any, default = NULL)
  )
)

grob_rect <- S7::new_class("grob_rect", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    width = .unit_prop("unit(1, \"npc\")"), height = .unit_prop("unit(1, \"npc\")")
  )
)
grob_roundrect <- S7::new_class("grob_roundrect", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    width = .unit_prop("unit(1, \"npc\")"), height = .unit_prop("unit(1, \"npc\")"),
    r = .unit_prop("unit(0.1, \"npc\")")
  )
)
grob_lines <- S7::new_class("grob_lines", parent = grob, package = "vellum",
  properties = list(x = .unit_prop(), y = .unit_prop(),
                    arrow = S7::new_property(S7::class_any, default = NULL),
                    start_cap = S7::new_property(S7::class_any, default = NULL),
                    end_cap = S7::new_property(S7::class_any, default = NULL),
                    offset = S7::new_property(S7::class_any, default = NULL)))
grob_polygon <- S7::new_class("grob_polygon", parent = grob, package = "vellum",
  properties = list(x = .unit_prop(), y = .unit_prop()))
grob_circle <- S7::new_class("grob_circle", parent = grob, package = "vellum",
  properties = list(x = .unit_prop(), y = .unit_prop(), r = .unit_prop("unit(0.25, \"npc\")")))
grob_points <- S7::new_class("grob_points", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(), size = .unit_prop("unit(2, \"mm\")"),
    shape = S7::new_property(S7::class_character, default = "circle")
  ))

grob_hexagon <- S7::new_class("grob_hexagon", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(), size = .unit_prop("unit(2, \"mm\")"),
    width = S7::new_property(S7::class_any, default = NULL),
    height = S7::new_property(S7::class_any, default = NULL),
    fill = S7::new_property(S7::class_any, default = NULL),
    orientation = S7::new_property(S7::class_character, default = "flat")
  ))

grob_sector <- S7::new_class("grob_sector", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    r0 = .unit_prop("unit(0, \"native\")"), r1 = .unit_prop("unit(0.5, \"native\")"),
    theta0 = S7::new_property(S7::class_double, default = 0),
    theta1 = S7::new_property(S7::class_double, default = 0),
    fill = S7::new_property(S7::class_any, default = NULL),
    arrow = S7::new_property(S7::class_any, default = NULL)
  ))

# Marker shape names -> backend codes (must match the `markers` arm in scene.rs).
.marker_codes <- c(circle = 0L, square = 1L, triangle = 2L, diamond = 3L, plus = 4L, cross = 5L)
# Extension point for rich text labels (plotmath, markdown, ...). A concrete
# rich-label type subclasses this and adds a `.text_labels()` method that returns
# the strings to shape; until such a type exists only plain character labels are
# drawn. The seam keeps the grammar's text path from hard-coding `character`, so a
# future label kind plugs in here rather than in every geom (see DESIGN, the
# grammar-coupled items section).
vellum_label <- S7::new_class("vellum_label", package = "vellum", abstract = TRUE)

# A concrete rich label: a markdown-subset string parsed into styled runs (see
# `md()` and `.md_parse()` in text.R). `runs` is a list of run descriptors (text +
# per-run face/size/baseline/colour); `text` is the markup-stripped plain string,
# used by the `.text_labels()` seam and as a measurement fallback.
vellum_md_label <- S7::new_class("vellum_md_label", parent = vellum_label, package = "vellum",
  properties = list(
    runs = S7::new_property(S7::class_list, default = list()),
    text = S7::new_property(S7::class_character, default = "")
  ))

# The single place a label becomes the character vector the backend shapes.
.text_labels <- S7::new_generic("text_labels", "label")
S7::method(.text_labels, S7::class_character) <- function(label) label
S7::method(.text_labels, S7::class_any) <- function(label) as.character(label)
S7::method(.text_labels, vellum_md_label) <- function(label) label@text

grob_text <- S7::new_class("grob_text", parent = grob, package = "vellum",
  properties = list(
    label = S7::new_property(S7::new_union(S7::class_character, vellum_label)),
    x = .unit_prop(), y = .unit_prop(),
    just = S7::new_property(S7::class_character, default = c("centre", "centre")),
    rot  = S7::new_property(S7::class_double, default = 0)
  )
)
grob_segments <- S7::new_class("grob_segments", parent = grob, package = "vellum",
  properties = list(x0 = .unit_prop(), y0 = .unit_prop(), x1 = .unit_prop(), y1 = .unit_prop(),
                    arrow = S7::new_property(S7::class_any, default = NULL),
                    start_cap = S7::new_property(S7::class_any, default = NULL),
                    end_cap = S7::new_property(S7::class_any, default = NULL),
                    offset = S7::new_property(S7::class_any, default = NULL)))

grob_loop <- S7::new_class("grob_loop", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    size = .unit_prop("unit(4, \"mm\")"), foot = .unit_prop("unit(0, \"mm\")"),
    angle = S7::new_property(S7::class_double, default = 0),
    width = S7::new_property(S7::class_double, default = 1),
    arrow = S7::new_property(S7::class_any, default = NULL)
  ))
grob_path <- S7::new_class("grob_path", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    nper = S7::new_property(S7::class_integer, default = integer(0)),
    rule = S7::new_property(S7::class_character, default = "winding")
  )
)
grob_raster <- S7::new_class("grob_raster", parent = grob, package = "vellum",
  properties = list(
    rgba = S7::new_property(S7::class_integer, default = integer(0)),
    iw = S7::new_property(S7::class_integer, default = 0L),
    ih = S7::new_property(S7::class_integer, default = 0L),
    x = .unit_prop(), y = .unit_prop(),
    width = .unit_prop("unit(1, \"npc\")"), height = .unit_prop("unit(1, \"npc\")"),
    interpolate = S7::new_property(S7::class_logical, default = TRUE)
  )
)

# --- friendly constructors --------------------------------------------------

#' @rdname grob
#' @param x,y Coordinates ([unit()] or numeric).
#' @param width,height Sizes ([unit()] or numeric).
#' @param gp Graphical parameters, from [gpar()].
#' @param name Optional name (for [edit_node()]).
#' @param vp Optional [viewport()] to draw this grob inside.
#' @param role Optional ARIA role, emitted by the SVG backend as `role=` for
#'   accessibility (ignored by the raster and PDF backends).
#' @export
rect_grob <- function(x = 0.5, y = 0.5, width = 1, height = 1,
                      gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  w <- as_unit(width)
  h <- as_unit(height)
  .check_extent(w, "width")
  .check_extent(h, "height")
  grob_rect(x = as_unit(x), y = as_unit(y), width = w, height = h,
            gp = gp, name = name, vp = vp, id = id, role = role)
}

#' @rdname grob
#' @param r Corner radius ([unit()] or numeric). An `"npc"`/numeric radius is
#'   isotropic (a fraction of the shorter side, like grid's `"snpc"`), so corners
#'   stay circular on non-square rectangles; clamped to half the shorter side.
#' @export
roundrect_grob <- function(x = 0.5, y = 0.5, width = 1, height = 1, r = 0.1,
                           gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  w <- as_unit(width)
  h <- as_unit(height)
  rr <- as_unit(r)
  .check_extent(w, "width")
  .check_extent(h, "height")
  .check_extent(rr, "r")
  grob_roundrect(x = as_unit(x), y = as_unit(y), width = w, height = h, r = rr,
                 gp = gp, name = name, vp = vp, id = id, role = role)
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
  if (length(v) && any(!is.finite(v))) {
    cli::cli_abort("{.arg {arg}} must be finite (no {.val NA}/{.val NaN}/{.val Inf}).")
  }
  invisible(v)
}

#' @rdname grob
#' @param arrow An [arrow()] spec to draw heads on the line/segment ends, or
#'   `NULL` for none.
#' @param start_cap,end_cap Optional **absolute-length** [unit()]s (`mm`/`cm`/
#'   `in`/`pt`; a bare numeric is taken as `mm`) that shorten the drawn line
#'   inward from its start/end by that physical amount, resolved **at render** in
#'   device space — so the gap is exact at any size, dpi, and aspect ratio, with
#'   no reliance on the native scale. For [segments_grob()] the caps are
#'   per-element (scalar or length-n, recycled like the coordinates); for
#'   [lines_grob()] a single (scalar) cap trims each end of the whole polyline.
#'   `NULL` (default) leaves the endpoint untouched. When an [arrow()] is also
#'   present its head is placed at the *capped* end, so the tip lands on the
#'   boundary (e.g. a node marker) rather than under it. This is what lets a
#'   directed edge stop at a node's radius. See the acceptance notes in the
#'   package for the degenerate cases (a cap `>=` the segment length draws
#'   nothing; a zero-length segment is skipped).
#' @param offset Optional **absolute-length** [unit()] (`mm`/`cm`/`in`/`pt`; a bare
#'   numeric is `mm`) that shifts the line **perpendicular** to its own direction by
#'   that physical amount, resolved **at render** in device space. The sign picks
#'   the side (`+` left of the direction of travel, `−` right). For
#'   [segments_grob()] it is per-element (scalar or length-n) — passing a vector
#'   spreads parallel/reciprocal edges by a fixed physical spacing that tracks mm
#'   node sizes at any figure size; for [lines_grob()] a single (scalar) offset
#'   rigidly translates the whole polyline along the perpendicular of its overall
#'   direction. Applied **before** `start_cap`/`end_cap` and the arrowhead (offset,
#'   then cap, then head). `NULL`/`0` (default) leaves the geometry untouched.
#' @export
lines_grob <- function(x, y, arrow = NULL, start_cap = NULL, end_cap = NULL, offset = NULL,
                       gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  n <- .coord_n(x, y)
  start_cap <- .check_cap(start_cap, "start_cap", scalar = TRUE)
  end_cap <- .check_cap(end_cap, "end_cap", scalar = TRUE)
  offset <- .check_cap(offset, "offset", scalar = TRUE, nonneg = FALSE)
  grob_lines(x = vctrs::vec_recycle(as_unit(x, "native"), n),
             y = vctrs::vec_recycle(as_unit(y, "native"), n),
             arrow = arrow, start_cap = start_cap, end_cap = end_cap, offset = offset,
             gp = gp, name = name, vp = vp, id = id, role = role)
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
  if (nonneg) .check_extent(cap, arg)
  abs_codes <- unname(.unit_codes[c("mm", "in", "pt")])
  if (!all(vctrs::field(cap, "unit") %in% abs_codes)) {
    cli::cli_abort(c(
      "{.arg {arg}} must be an absolute-length {.cls unit} ({.val mm}/{.val cm}/{.val in}/{.val pt}).",
      i = "Caps are resolved in device space at render, so a {.val native}/{.val npc} length is not allowed."
    ))
  }
  if (scalar && .vsize(cap) > 1L) {
    cli::cli_abort("{.arg {arg}} on a {.fn lines_grob} must be a single value (it trims the whole-path ends).")
  }
  cap
}

#' Arrowheads
#'
#' Describe arrowheads to draw on the ends of a [lines_grob()] or
#' [segments_grob()] (pass as their `arrow =` argument).
#'
#' @param angle Half-angle of the head at the tip, in degrees (default 30).
#' @param length Head length as an absolute [unit()] (default `unit(0.25, "in")`).
#' @param ends Which ends get a head: `"last"` (default), `"first"`, or `"both"`.
#' @param type `"open"` (a two-barb V) or `"closed"` (a filled triangle).
#' @return A `vellum_arrow` object.
#' @examples
#' lines_grob(c(0.1, 0.9), c(0.1, 0.9), arrow = arrow(type = "closed"))
#' @export
arrow <- function(angle = 30, length = unit(0.25, "in"),
                  ends = c("last", "first", "both"), type = c("open", "closed")) {
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
  list(angle = a$angle, len = .to_inches(a$length),
       ends = switch(a$ends, first = 1L, last = 2L, both = 3L),
       closed = identical(a$type, "closed"))
}

# Encode a cap unit (or NULL) into the parallel (value, code) streams the backend
# resolves. `NULL` -> empty streams, the backend's "no cap" signal (so a scene
# without caps is byte-for-byte unchanged). Caps are validated absolute upstream,
# so the backend resolves them to a device length exactly like `size`/`r`.
.encode_cap <- function(cap) {
  if (is.null(cap)) {
    return(list(value = numeric(0), code = integer(0)))
  }
  list(value = vctrs::field(cap, "value"), code = as.integer(vctrs::field(cap, "unit")))
}

#' @rdname grob
#' @export
polygon_grob <- function(x, y, gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  n <- .coord_n(x, y)
  grob_polygon(x = vctrs::vec_recycle(as_unit(x, "native"), n),
               y = vctrs::vec_recycle(as_unit(y, "native"), n),
               gp = gp, name = name, vp = vp, id = id, role = role)
}

# Decompose a curve coordinate into (values, single unit name). Flattening is a
# linear combination of control-point values, so all coordinates on an axis must
# share one unit (a numeric defaults to "native", like lines).
.axis_unit <- function(a, default = "native") {
  if (!is_unit(a)) {
    return(list(value = as.numeric(a), unit = default))
  }
  codes <- vctrs::field(a, "unit")
  if (length(unique(codes)) > 1L) {
    cli::cli_abort("Curve coordinates on one axis must use a single unit.")
  }
  list(value = vctrs::field(a, "value"), unit = names(.unit_codes)[match(codes[1], .unit_codes)])
}

# Evaluate a Bezier (control values `p`) at parameters `t` via de Casteljau.
.bezier_eval <- function(p, t) {
  vapply(t, function(tt) {
    b <- p
    while (length(b) > 1L) b <- b[-length(b)] * (1 - tt) + b[-1] * tt
    b
  }, double(1))
}

# Cardinal (Catmull-Rom) spline through control values `p`; `tension` 0 = loose
# (smooth), 1 = straight; `per` points per segment; `closed` wraps the ends.
.cardinal <- function(p, tension, per, closed) {
  k <- length(p)
  if (k < 3L) {
    return(p)
  }
  at <- function(i) if (closed) p[((i - 1L) %% k) + 1L] else p[min(max(i, 1L), k)]
  c_ <- 1 - tension
  tt <- seq(0, 1, length.out = per + 1L)[-(per + 1L)]
  h00 <- 2 * tt^3 - 3 * tt^2 + 1
  h10 <- tt^3 - 2 * tt^2 + tt
  h01 <- -2 * tt^3 + 3 * tt^2
  h11 <- tt^3 - tt^2
  segs <- if (closed) seq_len(k) else seq_len(k - 1L)
  out <- unlist(lapply(segs, function(i) {
    p1 <- at(i); p2 <- at(i + 1L)
    m1 <- c_ * (p2 - at(i - 1L)) / 2
    m2 <- c_ * (at(i + 2L) - p1) / 2
    h00 * p1 + h10 * m1 + h01 * p2 + h11 * m2
  }), use.names = FALSE)
  c(out, at(if (closed) 1L else k))
}

#' @rdname grob
#' @param n Number of points to sample the curve at (flattened to a polyline).
#' @export
bezier_grob <- function(x, y, n = 60, gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  ax <- .axis_unit(x)
  ay <- .axis_unit(y)
  if (length(ax$value) != length(ay$value)) cli::cli_abort("{.arg x} and {.arg y} must have the same length.")
  if (length(ax$value) < 2L) cli::cli_abort("A Bezier needs at least 2 control points.")
  t <- seq(0, 1, length.out = max(2L, n))
  lines_grob(unit(.bezier_eval(ax$value, t), ax$unit), unit(.bezier_eval(ay$value, t), ay$unit),
             gp = gp, name = name, vp = vp, id = id, role = role)
}

#' @rdname grob
#' @param shape Spline smoothness in `[0, 1]`: `1` (default) a smooth
#'   Catmull-Rom curve through the points, `0` straight segments.
#' @param open If `FALSE`, the spline is closed (wraps end to start).
#' @export
spline_grob <- function(x, y, shape = 1, n = 20, open = TRUE, gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  ax <- .axis_unit(x)
  ay <- .axis_unit(y)
  if (length(ax$value) != length(ay$value)) cli::cli_abort("{.arg x} and {.arg y} must have the same length.")
  tension <- 1 - max(0, min(1, shape))
  fx <- .cardinal(ax$value, tension, max(1L, n), !open)
  fy <- .cardinal(ay$value, tension, max(1L, n), !open)
  lines_grob(unit(fx, ax$unit), unit(fy, ay$unit), gp = gp, name = name, vp = vp, id = id, role = role)
}

#' @rdname grob
#' @param r Radius ([unit()] or numeric).
#' @export
circle_grob <- function(x = 0.5, y = 0.5, r = 0.25, gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  n <- .common_n(x, y, r)
  ru <- as_unit(r)
  .check_extent(ru, "r")
  grob_circle(x = vctrs::vec_recycle(as_unit(x), n),
              y = vctrs::vec_recycle(as_unit(y), n),
              r = vctrs::vec_recycle(ru, n),
              gp = gp, name = name, vp = vp, id = id, role = role)
}

#' @rdname grob
#' @param size Point size ([unit()] or numeric).
#' @param shape Marker shape(s): `"circle"` (default), `"square"`, `"triangle"`,
#'   `"diamond"`, `"plus"`, or `"cross"`, recycled per point. Filled shapes use
#'   `gp$fill` (and outline `gp$col`); `"plus"`/`"cross"` are stroke-only.
#' @export
points_grob <- function(x, y, size = unit(2, "mm"), shape = "circle",
                        gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  n <- .coord_n(x, y)
  sz <- as_unit(size, "mm")
  .check_extent(sz, "size")
  shape <- as.character(shape)
  bad <- setdiff(unique(shape), names(.marker_codes))
  if (length(bad)) {
    cli::cli_abort("Unknown point {.arg shape}: {.val {bad}}. Use {.or {names(.marker_codes)}}.")
  }
  grob_points(x = vctrs::vec_recycle(as_unit(x), n),
              y = vctrs::vec_recycle(as_unit(y), n),
              size = vctrs::vec_recycle(sz, n),
              shape = vctrs::vec_recycle(shape, n),
              gp = gp, name = name, vp = vp, id = id, role = role)
}

#' @rdname grob
#' @param fill Per-hexagon fill colour(s), recycled to the number of hexagons. The
#'   binned-count colour mesh: each hexagon is filled with its own colour in a
#'   single batched draw. `NULL` (default) falls back to `gp$fill`. The uniform
#'   stroke comes from `gp` (`col`/`lwd`).
#' @param orientation Hexagon orientation: `"flat"` (default, flat top/bottom edge)
#'   or `"pointy"` (vertex at top). `size` is the circumradius (centre to vertex).
#' @param width,height Optional per-hexagon **full** extent (corner-to-corner) along
#'   the x and y axis, as [unit()]s recycled like `x`/`y`. When both are supplied
#'   they override `size`, resolved per-axis, so a hexagon can be *non-regular*
#'   (independent horizontal and vertical extent) and tile a non-square lattice —
#'   e.g. `width`/`height` in `"native"` units tile in data space regardless of the
#'   device aspect. `width` is the distance between the left and right vertices (for
#'   `"flat"`; the flat sides for `"pointy"`) and `height` the distance between the
#'   top and bottom edges (`"flat"`; vertices for `"pointy"`). A *regular* hexagon
#'   is `height == width * sqrt(3) / 2` (flat). Leave both `NULL` (default) to draw
#'   a regular hexagon of circumradius `size`. Must be given together.
#' @export
hexagon_grob <- function(x = 0.5, y = 0.5, size = unit(2, "mm"),
                         width = NULL, height = NULL, fill = NULL,
                         orientation = c("flat", "pointy"),
                         gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  orientation <- match.arg(orientation)
  n <- .coord_n(x, y)
  sz <- as_unit(size, "mm")
  .check_extent(sz, "size")
  if (is.null(width) != is.null(height)) {
    cli::cli_abort("{.arg width} and {.arg height} must be supplied together.")
  }
  if (!is.null(width)) {
    width <- as_unit(width, "native")
    height <- as_unit(height, "native")
    .check_extent(width, "width")
    .check_extent(height, "height")
    width <- vctrs::vec_recycle(width, n)
    height <- vctrs::vec_recycle(height, n)
  }
  if (!is.null(fill)) fill <- rep_len(fill, n)
  grob_hexagon(x = vctrs::vec_recycle(as_unit(x), n),
               y = vctrs::vec_recycle(as_unit(y), n),
               size = vctrs::vec_recycle(sz, n),
               width = width, height = height,
               fill = fill, orientation = orientation,
               gp = gp, name = name, vp = vp, id = id, role = role)
}

#' @rdname grob
#' @param r0,r1 Inner and outer radius of each sector ([unit()] or numeric;
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
#' absolute (`mm`) radius at a `"native"` centre and an [arrow()], the radius is
#' resolved to a device length at render (like a marker `size`), so the arc tracks
#' an mm size at any page size or dpi; the arrowhead sits tangent to the outer arc's
#' end. (For node-link **self-loops**, prefer [loop_grob()] — a teardrop, not a
#' ring.)
#' @export
sector_grob <- function(x = 0.5, y = 0.5, r0 = 0, r1 = 0.5, theta0 = 0, theta1 = 2 * pi,
                        fill = NULL, arrow = NULL, gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  n <- .common_n(x, y, r0, r1, theta0, theta1)
  .check_finite_num(theta0, "theta0")
  .check_finite_num(theta1, "theta1")
  if (!is.null(fill)) fill <- rep_len(fill, n)
  grob_sector(
    x = vctrs::vec_recycle(as_unit(x), n),
    y = vctrs::vec_recycle(as_unit(y), n),
    r0 = vctrs::vec_recycle(as_unit(r0, "native"), n),
    r1 = vctrs::vec_recycle(as_unit(r1, "native"), n),
    theta0 = vctrs::vec_recycle(as.numeric(theta0), n),
    theta1 = vctrs::vec_recycle(as.numeric(theta1), n),
    fill = fill, arrow = arrow, gp = gp, name = name, vp = vp, id = id, role = role
  )
}

#' @rdname grob
#' @param size Loop extent: an **absolute** [unit()] (`mm`/`cm`/`in`/`pt`; a bare
#'   numeric is `mm`), resolved to a device length **at render** so the loop tracks
#'   a node's mm size at any page size/dpi. Nested loops on one vertex pass growing
#'   `size` (same `x`/`y`/`angle`) for concentric teardrops. Recycled per loop.
#' @param foot Node radius the loop's two **feet** attach at (an **absolute**
#'   [unit()]; `0` = both feet at the vertex, like igraph). A positive `foot` puts
#'   the feet on the node's boundary so the loop visibly leaves and re-enters the
#'   node edge, and a directed loop's head lands on the boundary rather than under
#'   the marker. Recycled per loop.
#' @param angle Outward direction of the loop in **radians** (which way the teardrop
#'   bulges away from the vertex, e.g. away from the layout centroid).
#' @param width Lateral petal scale, a dimensionless ratio in `(0, 1]` (recycled per
#'   loop). `1` (default) is the full teardrop; smaller values narrow the petal's
#'   **waist** without shortening it (its `angle`-wise bulge stays `0.3 * size`), so
#'   several loops crammed into a tight angular gap on one vertex stay skinny enough
#'   not to overlap — the igraph "narrowing" factor.
#' @details
#' `loop_grob()` draws **self-loops** for node-link diagrams as an igraph-style cubic
#' **Bézier teardrop**: it leaves the vertex `(x, y)` (a `"native"` anchor), bulges
#' out to `size` along `angle`, and returns, with an optional [arrow()] head tangent
#' to the curve at the returning foot. `size` and `foot` are absolute and resolved to
#' device px **at render**, so the loop is a fixed physical size that scales with the
#' mm node markers — no native-per-mm estimation, exact at any figure size/dpi.
#' @export
loop_grob <- function(x = 0.5, y = 0.5, size = unit(4, "mm"), foot = unit(0, "mm"),
                      angle = 0, width = 1, arrow = NULL, gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  n <- .common_n(x, y, size, foot, angle, width)
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
    arrow = arrow, gp = gp, name = name, vp = vp, id = id, role = role
  )
}

#' @rdname grob
#' @param x0,y0,x1,y1 Segment start/end coordinates ([unit()] or numeric).
#' @export
segments_grob <- function(x0, y0, x1, y1, arrow = NULL, start_cap = NULL, end_cap = NULL,
                          offset = NULL, gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  n <- .common_n(x0, y0, x1, y1)
  start_cap <- .check_cap(start_cap, "start_cap")
  end_cap <- .check_cap(end_cap, "end_cap")
  offset <- .check_cap(offset, "offset", nonneg = FALSE)
  if (!is.null(start_cap)) start_cap <- vctrs::vec_recycle(start_cap, n)
  if (!is.null(end_cap)) end_cap <- vctrs::vec_recycle(end_cap, n)
  if (!is.null(offset)) offset <- vctrs::vec_recycle(offset, n)
  grob_segments(
    x0 = vctrs::vec_recycle(as_unit(x0, "native"), n),
    y0 = vctrs::vec_recycle(as_unit(y0, "native"), n),
    x1 = vctrs::vec_recycle(as_unit(x1, "native"), n),
    y1 = vctrs::vec_recycle(as_unit(y1, "native"), n),
    arrow = arrow, start_cap = start_cap, end_cap = end_cap, offset = offset,
    gp = gp, name = name, vp = vp, id = id, role = role
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
#' @export
path_grob <- function(x, y, id = NULL, rule = c("winding", "evenodd"),
                      gp = gpar(), name = NULL, vp = NULL, role = NULL) {
  rule <- match.arg(rule)
  n <- .coord_n(x, y)
  xu <- vctrs::vec_recycle(as_unit(x, "native"), n)
  yu <- vctrs::vec_recycle(as_unit(y, "native"), n)
  if (is.null(id)) {
    nper <- n
  } else {
    if (length(id) != n) cli::cli_abort("{.arg id} must have one value per point ({n}).")
    grp <- match(id, unique(id)) # group index in first-appearance order
    ord <- order(grp, seq_along(grp)) # stable: gather each id's points together
    xu <- xu[ord]; yu <- yu[ord]
    nper <- tabulate(grp)
  }
  grob_path(
    x = xu, y = yu, nper = as.integer(nper), rule = rule, gp = gp, name = name, vp = vp, role = role
  )
}

#' @rdname grob
#' @param image A raster image: a [grDevices::as.raster()]-compatible object — a
#'   matrix/array of colours or greyscale values, or a `raster` object.
#' @param interpolate Smoothly interpolate when scaling (default `TRUE`)? `FALSE`
#'   keeps hard pixel edges.
#' @export
raster_grob <- function(image, x = 0.5, y = 0.5, width = 1, height = 1,
                        interpolate = TRUE, gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  px <- .image_to_rgba(image)
  grob_raster(
    rgba = px$rgba, iw = px$iw, ih = px$ih,
    x = as_unit(x), y = as_unit(y),
    width = as_unit(width), height = as_unit(height),
    interpolate = isTRUE(interpolate), gp = gp, name = name, vp = vp, id = id, role = role
  )
}

# Convert an R image to a flat straight-RGBA integer vector (row-major, top-left,
# 4 ints per pixel) plus its pixel dimensions. A `raster` object stores its cells
# by row (top-left first), so `as.vector()` already gives the order we want.
.image_to_rgba <- function(image) {
  r <- grDevices::as.raster(image)
  d <- dim(r)
  if (is.null(d) || any(d == 0L)) cli::cli_abort("{.arg image} has no pixels.")
  ih <- d[1]; iw <- d[2]
  rgba <- grDevices::col2rgb(as.vector(r), alpha = TRUE) # 4 x N (r, g, b, alpha)
  list(rgba = as.integer(rgba), iw = as.integer(iw), ih = as.integer(ih))
}

#' @rdname grob
#' @param label Character string(s) to draw.
#' @param just Justification: `c(hjust, vjust)` as names (`"left"`, `"centre"`,
#'   `"right"`, `"bottom"`, `"top"`) or numbers in `[0, 1]`.
#' @param rot Rotation in degrees, counter-clockwise.
#' @export
text_grob <- function(label, x = 0.5, y = 0.5, just = "centre", rot = 0,
                      gp = gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  # Rich labels pass through untouched; everything else coerces to character.
  if (!S7::S7_inherits(label, vellum_label)) label <- as.character(label)
  grob_text(label = label, x = as_unit(x), y = as_unit(y),
            just = as.character(just), rot = as.numeric(rot),
            gp = gp, name = name, vp = vp, id = id, role = role)
}

#' Size a unit by a grob's extent
#'
#' `grobwidth(grob)` and `grobheight(grob)` return a [unit()] equal to the drawn
#' width/height of `grob` — handy for sizing a [viewport()] or [grid_layout()]
#' track to its contents (e.g. a margin to an axis label). The extent is measured
#' **eagerly** to absolute millimetres at construction, so it is exact for text
#' and absolute-unit (`mm`/`in`/`pt`) grobs. A grob sized in `npc`/`native` has no
#' viewport-independent extent and is measured against a fixed reference, so for
#' those prefer `npc`/`native` directly.
#'
#' @param grob A grob (or composite subtree) to measure.
#' @param mult A multiplier on the measured extent (default 1).
#' @return A `unit` (in millimetres).
#' @examples
#' grobwidth(text_grob("A wide axis label", gp = gpar(fontsize = 14)))
#' grobheight(rect_grob(height = unit(8, "mm")))
#' @export
grobwidth <- function(grob, mult = 1) unit(mult, "grobwidth", data = grob)

#' @rdname grobwidth
#' @export
grobheight <- function(grob, mult = 1) unit(mult, "grobheight", data = grob)

# A grob's drawn extent as c(width_mm, height_mm). Text uses exact (advance)
# metrics; any other grob (incl. a gtree) is rendered into a throwaway scene and
# measured by its non-transparent bounding box. Device-independent for text and
# absolute geometry; npc/native content is measured against REF_IN.
.MEASURE_DPI <- 96
.MEASURE_REF_IN <- 12
.grob_extent <- function(g) {
  if (S7::S7_inherits(g, grob_text)) {
    fs <- g@gp@fontsize %||% 12
    fam <- g@gp@fontfamily %||% ""
    face <- g@gp@fontface %||% "plain"
    if (S7::S7_inherits(g@label, vellum_label)) {
      # Rich label: measure the composed multi-run extent (points -> mm) so axis
      # gutters/tracks reserve the right space (shares `.md_compose` with drawing).
      ext <- .md_extent_pt(g@label, fam, face, fs)
      w <- ext[1] / 72 * 25.4
      h <- ext[2] / 72 * 25.4
    } else {
      labs <- .text_labels(g@label)
      if (length(labs) == 0L) return(c(0, 0))
      w <- max(vl_strwidth(labs, fam, face, fs, unit = "mm"))
      h <- max(vl_strheight(labs, fam, face, fs, unit = "mm"))
    }
    # Rotation grows the axis-aligned bounding box; report the rotated extent so a
    # grobwidth/grobheight-sized region holds slanted/vertical text.
    rot <- (g@rot %||% 0)[1]
    if (!is.null(rot) && rot %% 180 != 0) {
      th <- rot * pi / 180
      c <- abs(cos(th)); s <- abs(sin(th))
      return(c(w * c + h * s, w * s + h * c))
    }
    return(c(w, h))
  }
  sc <- Scene$new(.MEASURE_REF_IN, .MEASURE_REF_IN, .MEASURE_DPI, c(0L, 0L, 0L, 0L))
  compile(g, sc)
  bb <- sc$content_bbox() # c(min_x, min_y, max_x, max_y) px, or empty
  if (length(bb) < 4L) return(c(0, 0))
  c((bb[3] - bb[1] + 1) / .MEASURE_DPI * 25.4, (bb[4] - bb[2] + 1) / .MEASURE_DPI * 25.4)
}

# Common length across several coordinate args, allowing length-1 recycling.
.common_n <- function(...) {
  sizes <- vapply(list(...), .vsize, integer(1))
  n <- max(sizes)
  if (!all(sizes %in% c(1L, n))) {
    stop("coordinates must have compatible lengths", call. = FALSE)
  }
  n
}
