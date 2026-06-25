#' Create a drawing scene
#'
#' A scene is a drawing surface backed by the Rust renderer. Build it up with
#' [rs_viewport()] and the primitive functions ([rs_rect()], [rs_lines()],
#' [rs_polygon()], [rs_circle()]), then write it out with [rs_render()].
#'
#' This is the M1 (vertical-slice) API: a single viewport with a scale, a flat
#' list of primitives, and raster (PNG) output. It is intentionally minimal and
#' will be superseded by the S7 API in a later milestone.
#'
#' @param width,height Device size in inches.
#' @param dpi Resolution in dots per inch.
#' @param bg Background colour (any R colour, or `NA` for transparent).
#' @return A `Scene` object (mutated in place by the primitive functions).
#' @export
rs_scene <- function(width = 6, height = 4, dpi = 96, bg = "white") {
  Scene$new(width, height, dpi, .rs_col(bg) %||% c(255L, 255L, 255L, 0L))
}

#' Set the scene's viewport
#'
#' Defines the single drawing region (M1 supports one viewport) as a centre and
#' size in normalised page coordinates, together with the native scales used by
#' `units = "native"` coordinates.
#'
#' @param scene A [rs_scene()].
#' @param x,y Viewport centre, in normalised page coordinates (0..1).
#' @param width,height Viewport size, in normalised page coordinates.
#' @param xscale,yscale Length-2 numeric ranges for native coordinates.
#' @return `scene`, invisibly.
#' @export
rs_viewport <- function(scene, x = 0.5, y = 0.5, width = 1, height = 1,
                        xscale = c(0, 1), yscale = c(0, 1)) {
  scene$set_viewport(x, y, width, height, as.numeric(xscale), as.numeric(yscale))
  invisible(scene)
}

#' Draw a rectangle
#'
#' @param scene A [rs_scene()].
#' @param x,y Rectangle centre.
#' @param width,height Rectangle size.
#' @param units Coordinate system for the above: one of `"npc"`, `"native"`,
#'   `"mm"`, `"in"`, `"pt"`.
#' @param fill,col Fill and border colours (`NA` for none).
#' @param lwd Border line width (1 == 1/96 inch).
#' @param alpha Opacity multiplier in `[0, 1]`.
#' @return `scene`, invisibly.
#' @export
rs_rect <- function(scene, x = 0.5, y = 0.5, width = 1, height = 1,
                    units = "npc", fill = NA, col = "black", lwd = 1, alpha = 1) {
  units <- .rs_units(units)
  scene$rect(x, y, width, height, units, .rs_col(fill), .rs_col(col), lwd, alpha)
  invisible(scene)
}

#' Draw a polyline
#'
#' @param scene A [rs_scene()].
#' @param x,y Parallel coordinate vectors.
#' @param units Coordinate system; see [rs_rect()].
#' @param col Line colour (`NA` for none).
#' @param lwd Line width (1 == 1/96 inch).
#' @param alpha Opacity multiplier in `[0, 1]`.
#' @return `scene`, invisibly.
#' @export
rs_lines <- function(scene, x, y, units = "npc", col = "black", lwd = 1, alpha = 1) {
  units <- .rs_units(units)
  scene$lines(as.numeric(x), as.numeric(y), units, .rs_col(col), lwd, alpha)
  invisible(scene)
}

#' Draw a polygon
#'
#' @inheritParams rs_lines
#' @param fill Fill colour (`NA` for none).
#' @return `scene`, invisibly.
#' @export
rs_polygon <- function(scene, x, y, units = "npc", fill = NA, col = "black", lwd = 1, alpha = 1) {
  units <- .rs_units(units)
  scene$polygon(as.numeric(x), as.numeric(y), units, .rs_col(fill), .rs_col(col), lwd, alpha)
  invisible(scene)
}

#' Draw a circle
#'
#' @param scene A [rs_scene()].
#' @param x,y Centre.
#' @param r Radius. With `units = "npc"` it is taken against the smaller
#'   viewport dimension so the circle stays round.
#' @param units Coordinate system; see [rs_rect()].
#' @param fill,col Fill and border colours (`NA` for none).
#' @param lwd Border line width (1 == 1/96 inch).
#' @param alpha Opacity multiplier in `[0, 1]`.
#' @return `scene`, invisibly.
#' @export
rs_circle <- function(scene, x = 0.5, y = 0.5, r = 0.25,
                      units = "npc", fill = NA, col = "black", lwd = 1, alpha = 1) {
  units <- .rs_units(units)
  scene$circle(x, y, r, units, .rs_col(fill), .rs_col(col), lwd, alpha)
  invisible(scene)
}

#' Render a scene to a PNG file
#'
#' @param scene A [rs_scene()].
#' @param path Output file path.
#' @return `path`, invisibly.
#' @export
rs_render <- function(scene, path) {
  scene$render_png(path)
  invisible(path)
}

#' Inspect a rendered scene
#'
#' `rs_pixel()` renders the scene and returns the RGBA value of one device pixel
#' (top-left origin, 0-based) as `c(r, g, b, a)`. `rs_dim()` returns the device
#' size in pixels. Primarily for testing.
#'
#' @param scene A [rs_scene()].
#' @param x,y Pixel coordinates (0-based, from the top-left).
#' @return `rs_pixel()`: integer `c(r, g, b, a)`. `rs_dim()`: integer
#'   `c(width, height)`.
#' @export
rs_pixel <- function(scene, x, y) {
  scene$pixel(as.integer(x), as.integer(y))
}

#' @rdname rs_pixel
#' @export
rs_dim <- function(scene) {
  scene$dim()
}

# --- internal helpers -------------------------------------------------------

# Resolve an R colour to a length-4 integer RGBA vector, or NULL for "no paint"
# (NA / transparent). Reuses R's full colour vocabulary via col2rgb().
.rs_col <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x)) {
    return(NULL)
  }
  as.integer(grDevices::col2rgb(x, alpha = TRUE)[, 1L])
}

.rs_units <- function(units) {
  match.arg(units, c("npc", "native", "mm", "in", "pt"))
}

`%||%` <- function(a, b) if (is.null(a)) b else a
