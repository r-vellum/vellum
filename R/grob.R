#' Graphical objects (grobs)
#'
#' Grobs are immutable value objects describing something to draw. Build them
#' with the constructors below, add them to a scene with [draw()], and render
#' with [render()]. Coordinates accept a [vl_unit()] vector or a bare numeric
#' (interpreted in the `default_units`, usually `"npc"`).
#'
#' @name grob
#' @return A grob object.
NULL

# Abstract base: every grob carries a name, gpar, and an optional viewport.
# `id`/`role` are optional semantic metadata: a stable identifier and an ARIA
# role, emitted by the SVG backend as `data-vellum-id` / `role` for interactivity,
# accessibility, and testing. They are ignored by the raster and PDF backends.
#
# `keys`/`meta` are optional PER-ELEMENT metadata for batched grobs (interactivity
# foundation, see `_docs/DESIGN-INTERACTIVITY.md`). `keys` is a character vector,
# one data key per drawn element (recycled to the element count like `fill`),
# emitted by the SVG backend as `data-key` on each primitive — the join key a host
# uses to map a hover/click back to a datum. `meta` is a free-form per-element list
# (e.g. tooltip text / field values) that never crosses to the backend; it rides
# on the R scene and surfaces via [scene_model()]. Both default `NULL` (absent), so
# a scene without interactivity is byte-for-byte unchanged and pays nothing.
grob <- S7::new_class(
  "grob", package = "vellum", abstract = TRUE,
  properties = list(
    name = S7::new_property(S7::class_any, default = NULL),
    gp   = S7::new_property(vl_gpar, default = quote(vl_gpar())),
    vp   = S7::new_property(S7::class_any, default = NULL),
    id   = S7::new_property(S7::class_any, default = NULL),
    role = S7::new_property(S7::class_any, default = NULL),
    keys = S7::new_property(S7::class_any, default = NULL),
    meta = S7::new_property(S7::class_any, default = NULL)
  )
)

# Recycle a per-element `key` vector to `n` (coerced to character); NULL -> NULL
# so an absent key emits no `data-key` and costs nothing.
.recycle_keys <- function(key, n) {
  if (is.null(key)) return(NULL)
  rep_len(as.character(key), n)
}

# Recycle a per-element `meta` list to `n`. `meta` is a list of records (one per
# element); a length-1 list is recycled to every element. NULL -> NULL.
.recycle_meta <- function(meta, n) {
  if (is.null(meta)) return(NULL)
  if (!is.list(meta)) {
    cli::cli_abort("{.arg meta} must be a list, one entry (record) per element.")
  }
  rep_len(meta, n)
}

grob_rect <- S7::new_class("grob_rect", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    width = .unit_prop("vl_unit(1, \"npc\")"), height = .unit_prop("vl_unit(1, \"npc\")"),
    sketch = S7::new_property(S7::class_any, default = NULL)
  )
)
grob_roundrect <- S7::new_class("grob_roundrect", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    width = .unit_prop("vl_unit(1, \"npc\")"), height = .unit_prop("vl_unit(1, \"npc\")"),
    r = .unit_prop("vl_unit(0.1, \"npc\")"),
    sketch = S7::new_property(S7::class_any, default = NULL)
  )
)
grob_lines <- S7::new_class("grob_lines", parent = grob, package = "vellum",
  properties = list(x = .unit_prop(), y = .unit_prop(),
                    arrow = S7::new_property(S7::class_any, default = NULL),
                    start_cap = S7::new_property(S7::class_any, default = NULL),
                    end_cap = S7::new_property(S7::class_any, default = NULL),
                    offset = S7::new_property(S7::class_any, default = NULL),
                    sketch = S7::new_property(S7::class_any, default = NULL)))
grob_polygon <- S7::new_class("grob_polygon", parent = grob, package = "vellum",
  properties = list(x = .unit_prop(), y = .unit_prop(),
                    sketch = S7::new_property(S7::class_any, default = NULL)))
grob_circle <- S7::new_class("grob_circle", parent = grob, package = "vellum",
  properties = list(x = .unit_prop(), y = .unit_prop(), r = .unit_prop("vl_unit(0.25, \"npc\")"),
                    sketch = S7::new_property(S7::class_any, default = NULL)))
grob_points <- S7::new_class("grob_points", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(), size = .unit_prop("vl_unit(2, \"mm\")"),
    shape = S7::new_property(S7::class_character, default = "circle"),
    sketch = S7::new_property(S7::class_any, default = NULL)
  ),
  # Guard the shape here too (not only in points_grob): an unknown shape reaching
  # the compile method would otherwise map to NA and fail with a cryptic `if(NA)`.
  validator = function(self) {
    bad <- setdiff(unique(self@shape), names(.marker_codes))
    if (length(bad)) {
      sprintf("unknown point shape(s): %s", paste(bad, collapse = ", "))
    }
  })

grob_hexagon <- S7::new_class("grob_hexagon", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(), size = .unit_prop("vl_unit(2, \"mm\")"),
    width = S7::new_property(S7::class_any, default = NULL),
    height = S7::new_property(S7::class_any, default = NULL),
    fill = S7::new_property(S7::class_any, default = NULL),
    orientation = S7::new_property(S7::class_character, default = "flat")
  ))

grob_sector <- S7::new_class("grob_sector", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    r0 = .unit_prop("vl_unit(0, \"native\")"), r1 = .unit_prop("vl_unit(0.5, \"native\")"),
    theta0 = S7::new_property(S7::class_double, default = 0),
    theta1 = S7::new_property(S7::class_double, default = 0),
    fill = S7::new_property(S7::class_any, default = NULL),
    arrow = S7::new_property(S7::class_any, default = NULL),
    sketch = S7::new_property(S7::class_any, default = NULL)
  ))

# Marker shape names -> backend codes (must match the `markers` arm in scene.rs).
.marker_codes <- c(circle = 0L, square = 1L, triangle = 2L, diamond = 3L, plus = 4L,
                   cross = 5L, triangle_down = 6L, star = 7L)
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
    # A plain character vector, a single rich label, or a list of rich labels
    # (one per datum — the per-datum mark_text case).
    label = S7::new_property(S7::new_union(S7::class_character, vellum_label, S7::class_list)),
    x = .unit_prop(), y = .unit_prop(),
    just = S7::new_property(S7::class_character, default = c("centre", "centre")),
    rot  = S7::new_property(S7::class_double, default = 0),
    # Width-constrained text. `width`/`height` are absolute millimetres (see
    # `text_grob()`), NA when unset; `align` is line alignment within the box and
    # `fit` the floor for auto-fit sizing (NA = no auto-fit).
    width  = S7::new_property(S7::class_double, default = NA_real_),
    height = S7::new_property(S7::class_double, default = NA_real_),
    align  = S7::new_property(S7::class_character, default = "left"),
    fit    = S7::new_property(S7::class_double, default = NA_real_)
  )
)
grob_textpath <- S7::new_class("grob_textpath", parent = grob, package = "vellum",
  properties = list(
    label = S7::new_property(S7::class_character),
    x = .unit_prop(), y = .unit_prop(),
    just = S7::new_property(S7::class_character, default = c("centre", "centre")),
    # Baseline shift perpendicular to the path, in points (+ = left of travel).
    offset = S7::new_property(S7::class_double, default = 0)
  )
)
grob_segments <- S7::new_class("grob_segments", parent = grob, package = "vellum",
  properties = list(x0 = .unit_prop(), y0 = .unit_prop(), x1 = .unit_prop(), y1 = .unit_prop(),
                    arrow = S7::new_property(S7::class_any, default = NULL),
                    start_cap = S7::new_property(S7::class_any, default = NULL),
                    end_cap = S7::new_property(S7::class_any, default = NULL),
                    offset = S7::new_property(S7::class_any, default = NULL),
                    sketch = S7::new_property(S7::class_any, default = NULL),
                    ecol = S7::new_property(S7::class_any, default = NULL),
                    elwd = S7::new_property(S7::class_any, default = NULL)))

grob_loop <- S7::new_class("grob_loop", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    size = .unit_prop("vl_unit(4, \"mm\")"), foot = .unit_prop("vl_unit(0, \"mm\")"),
    angle = S7::new_property(S7::class_double, default = 0),
    width = S7::new_property(S7::class_double, default = 1),
    arrow = S7::new_property(S7::class_any, default = NULL)
  ))
grob_path <- S7::new_class("grob_path", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    nper = S7::new_property(S7::class_integer, default = integer(0)),
    rule = S7::new_property(S7::class_character, default = "winding"),
    sketch = S7::new_property(S7::class_any, default = NULL)
  )
)
grob_raster <- S7::new_class("grob_raster", parent = grob, package = "vellum",
  properties = list(
    rgba = S7::new_property(S7::class_integer, default = integer(0)),
    iw = S7::new_property(S7::class_integer, default = 0L),
    ih = S7::new_property(S7::class_integer, default = 0L),
    x = .unit_prop(), y = .unit_prop(),
    width = .unit_prop("vl_unit(1, \"npc\")"), height = .unit_prop("vl_unit(1, \"npc\")"),
    interpolate = S7::new_property(S7::class_logical, default = TRUE)
  )
)

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
rect_grob <- function(x = 0.5, y = 0.5, width = 1, height = 1,
                      sketch = NULL, gp = vl_gpar(), name = NULL, vp = NULL, id = NULL, role = NULL,
                      key = NULL, meta = NULL) {
  w <- as_unit(width)
  h <- as_unit(height)
  .check_extent(w, "width")
  .check_extent(h, "height")
  n <- .common_n(x, y, w, h)
  grob_rect(x = as_unit(x), y = as_unit(y), width = w, height = h,
            sketch = sketch, gp = gp, name = name, vp = vp, id = id, role = role,
            keys = .recycle_keys(key, n), meta = .recycle_meta(meta, n))
}

#' @rdname grob
#' @param r Corner radius ([vl_unit()] or numeric). An `"npc"`/numeric radius is
#'   isotropic (a fraction of the shorter side, like grid's `"snpc"`), so corners
#'   stay circular on non-square rectangles; clamped to half the shorter side.
#' @export
roundrect_grob <- function(x = 0.5, y = 0.5, width = 1, height = 1, r = 0.1,
                           sketch = NULL, gp = vl_gpar(), name = NULL, vp = NULL, id = NULL,
                           role = NULL, key = NULL, meta = NULL) {
  w <- as_unit(width)
  h <- as_unit(height)
  rr <- as_unit(r)
  .check_extent(w, "width")
  .check_extent(h, "height")
  .check_extent(rr, "r")
  # A roundrect grob is a *batch*: one box per (x, y, w, h, r) element, like
  # `rect_grob()`. Recycle keys/meta to that element count (not to 1, which
  # silently dropped every key past the first on a multi-box grob).
  n <- .common_n(x, y, w, h, rr)
  grob_roundrect(x = as_unit(x), y = as_unit(y), width = w, height = h, r = rr,
                 sketch = sketch, gp = gp, name = name, vp = vp, id = id, role = role,
                 keys = .recycle_keys(key, n), meta = .recycle_meta(meta, n))
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
#' @export
lines_grob <- function(x, y, arrow = NULL, start_cap = NULL, end_cap = NULL, offset = NULL,
                       sketch = NULL, gp = vl_gpar(), name = NULL, vp = NULL, id = NULL, role = NULL,
                       key = NULL, meta = NULL) {
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
  grob_lines(x = vctrs::vec_recycle(as_unit(x, "native"), n),
             y = vctrs::vec_recycle(as_unit(y, "native"), n),
             arrow = arrow, start_cap = start_cap, end_cap = end_cap, offset = offset,
             sketch = sketch, gp = gp, name = name, vp = vp, id = id, role = role,
             keys = .recycle_keys(key, 1L), meta = .recycle_meta(meta, 1L))
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
#' @param length Head length as an absolute [vl_unit()] (default `vl_unit(0.25, "in")`).
#' @param ends Which ends get a head: `"last"` (default), `"first"`, or `"both"`.
#' @param type `"open"` (a two-barb V) or `"closed"` (a filled triangle).
#' @return A `vellum_arrow` object.
#' @examples
#' lines_grob(c(0.1, 0.9), c(0.1, 0.9), arrow = vl_arrow(type = "closed"))
#' @export
vl_arrow <- function(angle = 30, length = vl_unit(0.25, "in"),
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

# Fill-style names -> the integer codes `sketch.rs` decodes (FillStyle::from_code).
.sketch_fill_codes <- c(solid = 0L, hachure = 1L, crosshatch = 2L, zigzag = 3L, dots = 4L)

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
sketch <- function(roughness = 1, bowing = 1,
                   fill_style = c("hachure", "solid", "crosshatch", "zigzag", "dots"),
                   fill_weight = NULL, hachure_angle = -41, hachure_gap = NULL,
                   curve_tightness = 0, disable_multi_stroke = FALSE,
                   preserve_vertices = FALSE, seed = 1L) {
  fill_style <- match.arg(fill_style)
  if (!is.numeric(roughness) || length(roughness) != 1L || is.na(roughness) || roughness < 0) {
    cli::cli_abort("{.arg roughness} must be a single number >= 0.")
  }
  structure(
    list(
      roughness = as.numeric(roughness)[1], bowing = as.numeric(bowing)[1],
      fill_style = fill_style,
      fill_weight = if (is.null(fill_weight)) -1 else as.numeric(fill_weight)[1],
      hachure_angle = as.numeric(hachure_angle)[1],
      hachure_gap = if (is.null(hachure_gap)) -1 else as.numeric(hachure_gap)[1],
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
    return(list(roughness = -1, bowing = 0, fill_style = 0L, fill_weight = -1,
                hachure_angle = 0, hachure_gap = -1, curve_tightness = 0,
                disable_multi = FALSE, preserve = FALSE, seed = 1))
  }
  if (!inherits(s, "vellum_sketch")) {
    cli::cli_abort("{.arg sketch} must be a {.fn sketch} object or {.code NULL}.")
  }
  list(roughness = s$roughness, bowing = s$bowing,
       fill_style = unname(.sketch_fill_codes[[s$fill_style]]),
       fill_weight = s$fill_weight, hachure_angle = s$hachure_angle,
       hachure_gap = s$hachure_gap, curve_tightness = s$curve_tightness,
       disable_multi = s$disable_multi_stroke, preserve = s$preserve_vertices,
       seed = s$seed)
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
polygon_grob <- function(x, y, sketch = NULL, gp = vl_gpar(), name = NULL, vp = NULL, id = NULL,
                         role = NULL, key = NULL, meta = NULL) {
  n <- .coord_n(x, y)
  grob_polygon(x = vctrs::vec_recycle(as_unit(x, "native"), n),
               y = vctrs::vec_recycle(as_unit(y, "native"), n),
               sketch = sketch, gp = gp, name = name, vp = vp, id = id, role = role,
               keys = .recycle_keys(key, 1L), meta = .recycle_meta(meta, 1L))
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
bezier_grob <- function(x, y, n = 60, gp = vl_gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  ax <- .axis_unit(x)
  ay <- .axis_unit(y)
  if (length(ax$value) != length(ay$value)) cli::cli_abort("{.arg x} and {.arg y} must have the same length.")
  if (length(ax$value) < 2L) cli::cli_abort("A Bezier needs at least 2 control points.")
  t <- seq(0, 1, length.out = max(2L, n))
  lines_grob(vl_unit(.bezier_eval(ax$value, t), ax$unit), vl_unit(.bezier_eval(ay$value, t), ay$unit),
             gp = gp, name = name, vp = vp, id = id, role = role)
}

#' @rdname grob
#' @param shape Spline smoothness in `[0, 1]`: `1` (default) a smooth
#'   Catmull-Rom curve through the points, `0` straight segments.
#' @param open If `FALSE`, the spline is closed (wraps end to start).
#' @export
spline_grob <- function(x, y, shape = 1, n = 20, open = TRUE, gp = vl_gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
  ax <- .axis_unit(x)
  ay <- .axis_unit(y)
  if (length(ax$value) != length(ay$value)) cli::cli_abort("{.arg x} and {.arg y} must have the same length.")
  tension <- 1 - max(0, min(1, shape))
  fx <- .cardinal(ax$value, tension, max(1L, n), !open)
  fy <- .cardinal(ay$value, tension, max(1L, n), !open)
  lines_grob(vl_unit(fx, ax$unit), vl_unit(fy, ay$unit), gp = gp, name = name, vp = vp, id = id, role = role)
}

#' @rdname grob
#' @param r Radius ([vl_unit()] or numeric).
#' @export
circle_grob <- function(x = 0.5, y = 0.5, r = 0.25, sketch = NULL, gp = vl_gpar(), name = NULL, vp = NULL, id = NULL, role = NULL,
                        key = NULL, meta = NULL) {
  n <- .common_n(x, y, r)
  ru <- as_unit(r)
  .check_extent(ru, "r")
  grob_circle(x = vctrs::vec_recycle(as_unit(x), n),
              y = vctrs::vec_recycle(as_unit(y), n),
              r = vctrs::vec_recycle(ru, n),
              sketch = sketch, gp = gp, name = name, vp = vp, id = id, role = role,
              keys = .recycle_keys(key, n), meta = .recycle_meta(meta, n))
}

#' @rdname grob
#' @param size Point size ([vl_unit()] or numeric).
#' @param shape Marker shape(s): `"circle"` (default), `"square"`, `"triangle"`,
#'   `"diamond"`, `"plus"`, `"cross"`, `"triangle_down"`, or `"star"`, recycled per
#'   point. Filled shapes (all but `"plus"`/`"cross"`) paint `gp$fill` and outline
#'   with `gp$col`, so an *open* marker is `fill = NA` with a `col`, a *filled* one
#'   sets `fill`; `"plus"`/`"cross"` are stroke-only line glyphs.
#' @export
points_grob <- function(x, y, size = vl_unit(2, "mm"), shape = "circle",
                        sketch = NULL, gp = vl_gpar(), name = NULL, vp = NULL, id = NULL, role = NULL,
                        key = NULL, meta = NULL) {
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
              sketch = sketch, gp = gp, name = name, vp = vp, id = id, role = role,
              keys = .recycle_keys(key, n), meta = .recycle_meta(meta, n))
}

#' @rdname grob
#' @param fill Per-hexagon fill colour(s), recycled to the number of hexagons. The
#'   binned-count colour mesh: each hexagon is filled with its own colour in a
#'   single batched draw. `NULL` (default) falls back to `gp$fill`. The uniform
#'   stroke comes from `gp` (`col`/`lwd`).
#' @param orientation Hexagon orientation: `"flat"` (default, flat top/bottom edge)
#'   or `"pointy"` (vertex at top). `size` is the circumradius (centre to vertex).
#' @export
hexagon_grob <- function(x = 0.5, y = 0.5, size = vl_unit(2, "mm"),
                         width = NULL, height = NULL, fill = NULL,
                         orientation = c("flat", "pointy"),
                         gp = vl_gpar(), name = NULL, vp = NULL, id = NULL, role = NULL,
                         key = NULL, meta = NULL) {
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
               gp = gp, name = name, vp = vp, id = id, role = role,
               keys = .recycle_keys(key, n), meta = .recycle_meta(meta, n))
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
sector_grob <- function(x = 0.5, y = 0.5, r0 = 0, r1 = 0.5, theta0 = 0, theta1 = 2 * pi,
                        fill = NULL, arrow = NULL, sketch = NULL, gp = vl_gpar(), name = NULL, vp = NULL, id = NULL, role = NULL,
                        key = NULL, meta = NULL) {
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
    fill = fill, arrow = arrow, sketch = sketch, gp = gp, name = name, vp = vp, id = id, role = role,
    keys = .recycle_keys(key, n), meta = .recycle_meta(meta, n)
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
loop_grob <- function(x = 0.5, y = 0.5, size = vl_unit(4, "mm"), foot = vl_unit(0, "mm"),
                      angle = 0, width = 1, arrow = NULL, gp = vl_gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
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
#' @param x0,y0,x1,y1 Segment start/end coordinates ([vl_unit()] or numeric).
#' @export
segments_grob <- function(x0, y0, x1, y1, arrow = NULL, start_cap = NULL, end_cap = NULL,
                          offset = NULL, sketch = NULL, gp = vl_gpar(), name = NULL, vp = NULL, id = NULL, role = NULL,
                          key = NULL, meta = NULL, col = NULL, lwd = NULL) {
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
    sketch = sketch, gp = gp, name = name, vp = vp, id = id, role = role,
    keys = .recycle_keys(key, n), meta = .recycle_meta(meta, n),
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
path_grob <- function(x, y, id = NULL, rule = c("winding", "evenodd"),
                      sketch = NULL, gp = vl_gpar(), name = NULL, vp = NULL, role = NULL,
                      key = NULL, meta = NULL) {
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
    x = xu, y = yu, nper = as.integer(nper), rule = rule,
    sketch = sketch, gp = gp, name = name, vp = vp, role = role,
    keys = .recycle_keys(key, 1L), meta = .recycle_meta(meta, 1L)
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
raster_grob <- function(image, x = 0.5, y = 0.5, width = 1, height = 1,
                        interpolate = TRUE, gp = vl_gpar(), name = NULL, vp = NULL, id = NULL, role = NULL) {
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
  if (is.character(image) && length(image) == 1L && !grepl("^#", image)) {
    return(.png_to_rgba(image))
  }
  fast <- .array_to_rgba(image)
  if (!is.null(fast)) {
    return(fast)
  }
  r <- grDevices::as.raster(image)
  d <- dim(r)
  if (is.null(d) || any(d == 0L)) cli::cli_abort("{.arg image} has no pixels.")
  ih <- d[1]; iw <- d[2]
  rgba <- grDevices::col2rgb(as.vector(r), alpha = TRUE) # 4 x N (r, g, b, alpha)
  list(rgba = as.integer(rgba), iw = as.integer(iw), ih = as.integer(ih))
}

# Fast path for a numeric array in [0, 1] -- the form `png::readPNG()` returns and
# the most common way an image reaches us. The general path above routes through
# `as.raster()`, which builds one "#rrggbb" string per pixel, and that string
# round-trip is 77-93% of the cost of drawing an image (0.21 s at 1 Mpx, 0.84 s at
# 4 Mpx). Here the channels are scaled straight to bytes and interleaved, with no
# character vector at any point.
#
# Returns NULL for anything it does not handle (colour names, factors, integer
# rasters, out-of-range or non-finite values), so the caller falls back.
#
# Byte-exactness: `as.integer(255 * v + 0.5)` reproduces R's own `ScaleColor`
# (`(unsigned int)(255 * x + 0.5)`) used by `rgb()` underneath `as.raster()`, so
# this path and the fallback agree pixel for pixel -- asserted in `test-image.R`.
.array_to_rgba <- function(image) {
  if (!is.numeric(image) || is.object(image)) {
    return(NULL)
  }
  d <- dim(image)
  # `as.raster()` accepts only 3- or 4-plane arrays; match that exactly so this
  # path never widens what `raster_grob()` accepts.
  if (length(d) != 3L || any(d[1:2] == 0L) || !(d[3] %in% c(3L, 4L))) {
    return(NULL)
  }
  if (anyNA(image) || min(image) < 0 || max(image) > 1) {
    return(NULL)
  }
  ih <- d[1]; iw <- d[2]; nc <- d[3]
  n <- ih * iw
  # `image` is column-major (row, col, channel); the general path flattens the
  # raster the same way, so channel slices line up element for element.
  # `as.raster.array()` transposes each plane before building its strings, so the
  # flattened raster runs across rows; transpose here to match element for element.
  ch <- function(k) as.integer(255 * t(image[, , k]) + 0.5)
  px <- if (nc == 3L) {
    list(ch(1), ch(2), ch(3), rep.int(255L, n))
  } else {
    list(ch(1), ch(2), ch(3), ch(4))
  }
  out <- integer(4L * n)
  out[seq.int(1L, by = 4L, length.out = n)] <- px[[1]]
  out[seq.int(2L, by = 4L, length.out = n)] <- px[[2]]
  out[seq.int(3L, by = 4L, length.out = n)] <- px[[3]]
  out[seq.int(4L, by = 4L, length.out = n)] <- px[[4]]
  list(rgba = out, iw = as.integer(iw), ih = as.integer(ih))
}

# Read a PNG file straight to RGBA in Rust. The `png` crate is already vendored
# for the SVG/pattern encode path, so a file path needs no R image package.
.png_to_rgba <- function(path) {
  path <- path.expand(path)
  if (!file.exists(path)) {
    cli::cli_abort("{.arg image} file does not exist: {.path {path}}.")
  }
  v <- rs_read_png(path)
  iw <- v[1]; ih <- v[2]
  if (iw <= 0L || ih <= 0L) cli::cli_abort("{.arg image} has no pixels.")
  # Rust emits row-major RGBA, top-left first -- already the order the scene wants.
  # (`as.raster.array()` transposes each plane before building its strings, so the
  # `as.raster()` path flattens row-major too; no permutation is needed here.)
  list(rgba = as.integer(v[-(1:2)]), iw = as.integer(iw), ih = as.integer(ih))
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
text_grob <- function(label, x = 0.5, y = 0.5, just = "centre", rot = 0,
                      gp = vl_gpar(), name = NULL, vp = NULL, id = NULL, role = NULL,
                      width = NULL, height = NULL, align = "left", fit = FALSE,
                      key = NULL, meta = NULL) {
  # Rich labels pass through untouched; everything else coerces to character.
  if (!S7::S7_inherits(label, vellum_label)) label <- as.character(label)
  align <- match.arg(align, c("left", "centre", "center", "right", "justify"))
  if (!isFALSE(fit) && is.null(width)) {
    cli::cli_abort("{.arg fit} needs a {.arg width} to fit into.")
  }
  grob_text(label = label, x = as_unit(x), y = as_unit(y),
            just = as.character(just), rot = as.numeric(rot),
            width = .abs_mm(width, "width"), height = .abs_mm(height, "height"),
            align = align,
            fit = if (isFALSE(fit)) NA_real_ else if (isTRUE(fit)) 4 else as.numeric(fit),
            gp = gp, name = name, vp = vp, id = id, role = role,
            keys = .recycle_keys(key, .vsize(as_unit(x))),
            meta = .recycle_meta(meta, .vsize(as_unit(x))))
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
text_path_grob <- function(label, x, y, just = "centre", offset = 0,
                           gp = vl_gpar(), name = NULL, vp = NULL, id = NULL,
                           role = NULL) {
  label <- as.character(label)
  if (length(label) != 1L) {
    cli::cli_abort("{.arg label} must be a single string; got {length(label)}.")
  }
  grob_textpath(label = label, x = as_unit(x), y = as_unit(y),
                just = as.character(just), offset = as.numeric(offset),
                gp = gp, name = name, vp = vp, id = id, role = role)
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

#' Size a unit by a grob's extent
#'
#' `grobwidth(grob)` and `grobheight(grob)` return a [vl_unit()] equal to the drawn
#' width/height of `grob` — handy for sizing a [vl_viewport()] or [grid_layout()]
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
#' grobwidth(text_grob("A wide axis label", gp = vl_gpar(fontsize = 14)))
#' grobheight(rect_grob(height = vl_unit(8, "mm")))
#' @export
grobwidth <- function(grob, mult = 1) vl_unit(mult, "grobwidth", data = grob)

#' @rdname grobwidth
#' @export
grobheight <- function(grob, mult = 1) vl_unit(mult, "grobheight", data = grob)

# A grob's drawn extent as c(width_mm, height_mm). Text uses exact (advance)
# metrics; any other grob (incl. a gtree) is rendered into a throwaway scene and
# measured by its non-transparent bounding box. Device-independent for text and
# absolute geometry; npc/native content is measured against REF_IN.
.MEASURE_DPI <- 96
.MEASURE_REF_IN <- 12
.grob_extent <- function(g) {
  if (S7::S7_inherits(g, grob_text)) {
    fs <- .gp_fontsize(g@gp)
    fam <- g@gp@fontfamily %||% ""
    face <- g@gp@fontface %||% "plain"
    feat <- .gp_features(g@gp)
    if (S7::S7_inherits(g@label, vellum_label)) {
      # Rich label: measure the composed multi-run extent (points -> mm) so axis
      # gutters/tracks reserve the right space (shares `.md_compose` with drawing).
      ext <- .md_extent_pt(g@label, fam, face, fs, feat)
      w <- ext[1] / 72 * 25.4
      h <- ext[2] / 72 * 25.4
    } else {
      labs <- .text_labels(g@label)
      if (length(labs) == 0L) return(c(0, 0))
      w <- max(vl_strwidth(labs, fam, face, fs, unit = "mm", features = feat))
      h <- max(vl_strheight(labs, fam, face, fs, unit = "mm", features = feat))
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

#' Freeze a stroke into a fillable outline
#'
#' Converts the *stroke* of a line-like grob into a `path_grob` describing the
#' region the stroke covers — the shape you would get by tracing round the drawn
#' line. What was a one-pixel-wide path with a colour becomes an area with an
#' interior, which is what you need in order to fill it with a gradient or a
#' pattern, to send it to a cutting plotter or CNC tool, or to do geometry with
#' it.
#'
#' The expansion uses the same stroker the rasterizer uses, so the outline is
#' exactly the region that would have been inked, not a reimplementation that
#' could drift from it.
#'
#' **The result is baked at one size.** A stroke width is a device quantity, so
#' its outline only exists once a page size and resolution are chosen. Those are
#' arguments here, and the returned coordinates are absolute (mm) — the outline
#' will *not* rescale with the page the way the original stroke would. That is
#' inherent: an outline is a shape, not a stroke.
#'
#' @param grob A [lines_grob()], [polygon_grob()], or [path_grob()]. Its
#'   coordinates must be resolvable without a viewport: `npc`, an absolute unit,
#'   or `native` (read against the root's default `0..1` scale, which is what a
#'   bare numeric means).
#' @param width,height Page size in inches to resolve the geometry against.
#' @param dpi Resolution to resolve the stroke width against.
#' @param gp Optional [vl_gpar()] overriding the grob's own for the stroke
#'   parameters (`lwd`, `lineend`, `linejoin`, `linemitre`).
#' @return A [path_grob()] in `mm` units, with `rule = "winding"`, whose fill is
#'   the stroked region. Its `gp` starts from the source grob's stroke colour as
#'   a fill, so drawing it looks like the original line.
#' @seealso [path_grob()], [grob]
#' @examples
#' zig <- lines_grob(c(0.1, 0.35, 0.6, 0.9), c(0.2, 0.8, 0.2, 0.8),
#'                   gp = vl_gpar(col = "steelblue", lwd = 12))
#' outline <- stroke_to_path(zig, width = 3, height = 2)
#' # Now fillable: a gradient across the ribbon the line traced.
#' vl_scene(3, 2) |>
#'   draw(S7::set_props(outline, gp = vl_gpar(
#'     fill = linear_gradient(c("tomato", "gold")), col = "grey20", lwd = 0.5
#'   )))
#' @export
stroke_to_path <- function(grob, width = 6, height = 4, dpi = 96, gp = NULL) {
  ok <- S7::S7_inherits(grob, grob_lines) || S7::S7_inherits(grob, grob_polygon) ||
    S7::S7_inherits(grob, grob_path)
  if (!ok) {
    cli::cli_abort(c(
      "{.arg grob} must be a {.fn lines_grob}, {.fn polygon_grob} or {.fn path_grob}.",
      i = "Only line-like grobs have a stroke to expand."
    ))
  }
  style <- gp %||% grob@gp
  closed <- !S7::S7_inherits(grob, grob_lines)

  # Resolve the coordinates the way a render of this size would, so the outline
  # matches what would actually have been drawn.
  px_w <- width * dpi
  px_h <- height * dpi
  xs <- .stp_px(grob@x, px_w, dpi)
  ys <- px_h - .stp_px(grob@y, px_h, dpi) # device y is top-down
  nper <- if (S7::S7_inherits(grob, grob_path) && !is.null(grob@nper)) {
    as.integer(grob@nper)
  } else {
    length(xs)
  }
  lwd_px <- (style@lwd %||% 1) * dpi / 96
  v <- rs_stroke_to_path(
    xs, ys, nper, closed, lwd_px,
    .encode_code(style@lineend, .lineend_codes, "lineend") %||% 0L,
    .encode_code(style@linejoin, .linejoin_codes, "linejoin") %||% 0L,
    style@linemitre %||% 10
  )
  if (!length(v)) {
    cli::cli_abort("The stroke expanded to nothing (a zero width, or no geometry).")
  }
  nsub <- as.integer(v[1])
  lens <- as.integer(v[1 + seq_len(nsub)])
  tot <- sum(lens)
  off <- 1L + nsub
  ox <- v[off + seq_len(tot)]
  oy <- v[off + tot + seq_len(tot)]
  # Back to absolute mm, y-up again.
  path_grob(
    x = vl_unit(ox / dpi * 25.4, "mm"),
    y = vl_unit((px_h - oy) / dpi * 25.4, "mm"),
    id = rep(seq_len(nsub), lens),
    rule = "winding",
    gp = vl_gpar(fill = style@col %||% "black", col = NA),
    name = grob@name
  )
}

# Resolve a unit vector to device px along one axis for `stroke_to_path()`.
# Only the coordinate spaces meaningful outside a scene are accepted: `native`
# needs an xscale/yscale that does not exist without a viewport.
.stp_px <- function(u, extent_px, dpi) {
  code <- vctrs::field(u, "unit")
  val <- vctrs::field(u, "value")
  off <- vctrs::field(u, "offset") # always mm
  # `native` is resolved against the root viewport's default 0..1 scale, where it
  # coincides with `npc` -- which is what a bare numeric in `lines_grob()` means.
  # A grob destined for a viewport with a different scale must be resolved there
  # first; there is no viewport here to ask.
  rel <- unname(.unit_codes[c("npc", "native")])
  abs_codes <- unname(.unit_codes[c("mm", "in", "pt")])
  if (any(!(code %in% c(rel, abs_codes)))) {
    cli::cli_abort(c(
      "{.fn stroke_to_path} needs coordinates it can resolve without a viewport.",
      x = "Found {.val null} units, which only a layout can size.",
      i = "Use {.val npc}, {.val native}, or an absolute unit."
    ))
  }
  mm_to_px <- dpi / 25.4
  base <- ifelse(code %in% rel, val * extent_px, .abs_to_mm(val, code) * mm_to_px)
  as.numeric(base) + off * mm_to_px
}
