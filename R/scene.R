#' Create a drawing scene
#'
#' A scene is a drawing surface backed by the Rust renderer. Build it up with
#' viewports ([rs_push_viewport()]) and the primitive functions ([rs_rect()],
#' [rs_lines()], [rs_polygon()], [rs_circle()], [rs_text()]), then write it out
#' with [rs_render()].
#'
#' @param width,height Device size in inches.
#' @param dpi Resolution in dots per inch.
#' @param bg Background colour (any R colour, or `NA` for transparent).
#' @return A `Scene` object (mutated in place by the other functions).
#' @keywords internal
rs_scene <- function(width = 6, height = 4, dpi = 96, bg = "white") {
  Scene$new(width, height, dpi, .rs_col(bg) %||% c(255L, 255L, 255L, 0L))
}

# --- viewports --------------------------------------------------------------

#' Push, pop, and navigate viewports
#'
#' Viewports form a tree. `rs_push_viewport()` creates a child of the current
#' viewport and makes it current; subsequent drawing goes into it. A viewport is
#' placed either by centre/size in its parent's coordinates, or — if `row`/`col`
#' are given — into a cell of the parent's [rs_layout()]. Viewports may rotate
#' (`angle`), clip their contents (`clip`), and set inheritable graphical
#' parameters (`gp`).
#'
#' @param scene A [rs_scene()].
#' @param x,y Viewport centre in parent coordinates (ignored if `row`/`col`).
#' @param width,height Viewport size in parent coordinates (ignored if
#'   `row`/`col`).
#' @param units Coordinate system for the above; see [rs_rect()].
#' @param xscale,yscale Length-2 native coordinate ranges for this viewport.
#' @param angle Rotation in degrees, counter-clockwise about the centre.
#' @param clip Clip drawing to this viewport's rectangle?
#' @param gp Inheritable graphical parameters, from [rs_gpar()].
#' @param row,col Cell position (1-based) within the parent's layout. If both are
#'   given, the viewport is placed in that cell instead of by centre/size.
#' @param rowspan,colspan Number of cells to span.
#' @return `rs_push_viewport()` returns the new viewport's id; the others return
#'   `scene`, invisibly.
#' @keywords internal
rs_push_viewport <- function(scene, x = 0.5, y = 0.5, width = 1, height = 1,
                             units = "npc", xscale = c(0, 1), yscale = c(0, 1),
                             angle = 0, clip = FALSE, gp = rs_gpar(),
                             row = NULL, col = NULL, rowspan = 1, colspan = 1) {
  units <- .rs_units(units)
  lrow <- if (is.null(row)) -1L else as.integer(row) - 1L
  lcol <- if (is.null(col)) -1L else as.integer(col) - 1L
  cx <- .coord(x, units, 1); cy <- .coord(y, units, 1)
  cw <- .coord(width, units, 1); ch <- .coord(height, units, 1)
  scene$push_viewport(
    cx$value, cy$value, cw$value, ch$value, cx$code, cy$code, cw$code, ch$code,
    as.numeric(xscale), as.numeric(yscale), angle, isTRUE(clip),
    lrow, lcol, as.integer(rowspan), as.integer(colspan),
    .encode_paint(gp$fill), .rs_col_inh(gp$col), .rs_num_inh(gp$lwd), .rs_num_inh(gp$alpha)
  )
}

#' @rdname rs_push_viewport
#' @param n Number of levels to move up.
#' @keywords internal
rs_pop_viewport <- function(scene, n = 1) {
  scene$pop_viewport(as.integer(n))
  invisible(scene)
}

#' @rdname rs_push_viewport
#' @keywords internal
rs_up_viewport <- function(scene, n = 1) {
  scene$pop_viewport(as.integer(n))
  invisible(scene)
}

#' Set the current viewport (convenience)
#'
#' Resets to the root viewport and pushes a single child with the given scales.
#' A convenience for the common single-panel case; for nested viewports use
#' [rs_push_viewport()].
#'
#' @inheritParams rs_push_viewport
#' @return `scene`, invisibly.
#' @keywords internal
rs_viewport <- function(scene, x = 0.5, y = 0.5, width = 1, height = 1,
                        xscale = c(0, 1), yscale = c(0, 1)) {
  scene$to_root()
  rs_push_viewport(scene, x = x, y = y, width = width, height = height,
                   xscale = xscale, yscale = yscale)
  invisible(scene)
}

#' Define a row/column layout on the current viewport
#'
#' Attaches a grid layout to the current viewport. Child viewports are then
#' placed into cells via the `row`/`col` arguments of [rs_push_viewport()].
#' Track sizes mix absolute units with flexible `"null"` weights (which share the
#' leftover space in proportion to their value).
#'
#' @param scene A [rs_scene()].
#' @param widths,heights Track sizes: a bare numeric vector (treated as `"null"`
#'   weights), or an [rs_unit()] spec mixing absolute units and `"null"`.
#' @return `scene`, invisibly.
#' @keywords internal
rs_layout <- function(scene, widths, heights) {
  widths <- .as_track(widths)
  heights <- .as_track(heights)
  scene$set_layout(widths$values, widths$units, heights$values, heights$units)
  invisible(scene)
}

#' Layout track sizes
#'
#' A lightweight `(value, unit)` spec for [rs_layout()] tracks. The unit
#' `"null"` marks a flexible track whose value is its weight. (This is a minimal
#' helper for layouts; a full unit type arrives in a later milestone.)
#'
#' @param values Numeric track sizes (or weights, for `"null"`).
#' @param units Unit(s): `"null"`, `"npc"`, `"mm"`, `"in"`, or `"pt"`, recycled
#'   to the length of `values`.
#' @return A track-spec list.
#' @keywords internal
rs_unit <- function(values, units = "null") {
  list(values = as.numeric(values),
       units = rep(as.character(units), length.out = length(values)))
}

# --- primitives -------------------------------------------------------------

#' Draw a rectangle
#'
#' @param scene A [rs_scene()].
#' @param x,y Rectangle centre.
#' @param width,height Rectangle size.
#' @param units Coordinate system: one of `"npc"`, `"native"`, `"mm"`, `"in"`,
#'   `"pt"`.
#' @param fill,col Fill and border colours. A colour sets it, `NA` means none,
#'   and `NULL` inherits from the enclosing viewport's `gp`.
#' @param lwd Border line width (1 == 1/96 inch); `NULL` inherits.
#' @param alpha Opacity multiplier in `[0, 1]`; `NULL` inherits.
#' @return `scene`, invisibly.
#' @keywords internal
rs_rect <- function(scene, x = 0.5, y = 0.5, width = 1, height = 1,
                    units = "npc", fill = NA, col = "black", lwd = 1, alpha = 1) {
  units <- .rs_units(units)
  cx <- .coord(x, units, 1); cy <- .coord(y, units, 1)
  cw <- .coord(width, units, 1); ch <- .coord(height, units, 1)
  scene$rect(cx$value, cy$value, cw$value, ch$value, cx$code, cy$code, cw$code, ch$code,
             .encode_paint(fill), .rs_col_inh(col), .rs_num_inh(lwd), .rs_num_inh(alpha))
  invisible(scene)
}

#' Draw a polyline
#'
#' @param scene A [rs_scene()].
#' @param x,y Parallel coordinate vectors.
#' @param units Coordinate system; see [rs_rect()].
#' @param col Line colour (`NA` none, `NULL` inherit).
#' @param lwd Line width (1 == 1/96 inch); `NULL` inherits.
#' @param alpha Opacity multiplier in `[0, 1]`; `NULL` inherits.
#' @return `scene`, invisibly.
#' @keywords internal
rs_lines <- function(scene, x, y, units = "npc", col = "black", lwd = 1, alpha = 1) {
  units <- .rs_units(units)
  n <- .coord_n(x, y)
  cx <- .coord(x, units, n); cy <- .coord(y, units, n)
  scene$lines(cx$value, cy$value, cx$code, cy$code,
              .rs_col_inh(col), .rs_num_inh(lwd), .rs_num_inh(alpha))
  invisible(scene)
}

#' Draw a polygon
#'
#' @inheritParams rs_lines
#' @param fill Fill colour (`NA` none, `NULL` inherit).
#' @return `scene`, invisibly.
#' @keywords internal
rs_polygon <- function(scene, x, y, units = "npc", fill = NA, col = "black", lwd = 1, alpha = 1) {
  units <- .rs_units(units)
  n <- .coord_n(x, y)
  cx <- .coord(x, units, n); cy <- .coord(y, units, n)
  scene$polygon(cx$value, cy$value, cx$code, cy$code,
                .encode_paint(fill), .rs_col_inh(col), .rs_num_inh(lwd), .rs_num_inh(alpha))
  invisible(scene)
}

#' Draw a circle
#'
#' @param scene A [rs_scene()].
#' @param x,y Centre.
#' @param r Radius. With `units = "npc"` it is taken against the smaller
#'   viewport dimension so the circle stays round.
#' @param units Coordinate system; see [rs_rect()].
#' @param fill,col Fill and border colours (`NA` none, `NULL` inherit).
#' @param lwd Border line width (1 == 1/96 inch); `NULL` inherits.
#' @param alpha Opacity multiplier in `[0, 1]`; `NULL` inherits.
#' @return `scene`, invisibly.
#' @keywords internal
rs_circle <- function(scene, x = 0.5, y = 0.5, r = 0.25,
                      units = "npc", fill = NA, col = "black", lwd = 1, alpha = 1) {
  units <- .rs_units(units)
  cx <- .coord(x, units, 1); cy <- .coord(y, units, 1); cr <- .coord(r, units, 1)
  scene$circle(cx$value, cy$value, cr$value, cx$code, cy$code, cr$code,
               .encode_paint(fill), .rs_col_inh(col), .rs_num_inh(lwd), .rs_num_inh(alpha))
  invisible(scene)
}

# --- rendering / inspection -------------------------------------------------

#' Render a scene to a PNG file
#'
#' @param scene A [rs_scene()].
#' @param path Output file path.
#' @return `path`, invisibly.
#' @keywords internal
rs_render <- function(scene, path) {
  scene$render_png(path)
  invisible(path)
}

#' Inspect a rendered scene
#'
#' `rs_pixel()` renders the scene and returns the RGBA of one device pixel
#' (top-left origin, 0-based). `rs_dim()` returns the device size in pixels.
#' `rs_raster()` returns the whole image. Primarily for testing.
#'
#' @param scene A [rs_scene()].
#' @param x,y Pixel coordinates (0-based, from the top-left).
#' @return `rs_pixel()`: integer `c(r, g, b, a)`. `rs_dim()`: integer
#'   `c(width, height)`. `rs_raster()`: integer array `c(4, width, height)`.
#' @keywords internal
rs_pixel <- function(scene, x, y) {
  scene$pixel(as.integer(x), as.integer(y))
}

#' @rdname rs_pixel
#' @keywords internal
rs_dim <- function(scene) {
  scene$dim()
}

#' @rdname rs_pixel
#' @keywords internal
rs_raster <- function(scene) {
  d <- scene$dim()
  array(scene$rgba(), dim = c(4L, d[1], d[2]))
}

# --- gpar -------------------------------------------------------------------

#' Graphical parameters
#'
#' Builds an inheritable set of graphical parameters for [rs_push_viewport()].
#' Any field left `NULL` is inherited from the enclosing viewport; `alpha`
#' multiplies down the viewport tree.
#'
#' @param col Stroke/text colour (a colour, `NA` for none, or `NULL` to inherit).
#' @param fill Fill colour (a colour, `NA` for none, or `NULL` to inherit).
#' @param lwd Line width (1 == 1/96 inch), or `NULL` to inherit.
#' @param alpha Opacity multiplier in `[0, 1]`, or `NULL` to inherit.
#' @return A gpar list.
#' @keywords internal
rs_gpar <- function(col = NULL, fill = NULL, lwd = NULL, alpha = NULL) {
  list(col = col, fill = fill, lwd = lwd, alpha = alpha)
}

# --- internal helpers -------------------------------------------------------

# Concrete colour -> length-4 integer RGBA, or NULL ("no paint" / transparent).
.rs_col <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x)) {
    return(NULL)
  }
  as.integer(grDevices::col2rgb(x, alpha = TRUE)[, 1L])
}

# Tri-state colour encoding for the backend:
#   NULL  -> NULL        (inherit)
#   NA    -> integer(0)  (explicit "no paint")
#   colour-> int[4]      (set)
.rs_col_inh <- function(x) {
  if (is.null(x)) {
    return(NULL)
  }
  if (length(x) != 1L) {
    stop("a colour must be a single value, `NA` (none), or `NULL` (inherit)", call. = FALSE)
  }
  if (is.na(x)) {
    return(integer(0))
  }
  as.integer(grDevices::col2rgb(x, alpha = TRUE)[, 1L])
}

# Tri-state numeric encoding: NULL/NA -> NA_real_ (inherit); else the value.
.rs_num_inh <- function(x) {
  if (is.null(x)) {
    return(NA_real_)
  }
  if (length(x) != 1L) {
    stop("`lwd`/`alpha` must be a single number or `NULL` (inherit)", call. = FALSE)
  }
  if (is.na(x)) {
    return(NA_real_)
  }
  as.numeric(x)
}

.rs_units <- function(units) {
  match.arg(units, c("npc", "native", "mm", "in", "pt"))
}

.as_track <- function(x) {
  if (is.list(x) && !is.null(x$values)) {
    return(x)
  }
  rs_unit(x, "null")
}

`%||%` <- function(a, b) if (is.null(a)) b else a
