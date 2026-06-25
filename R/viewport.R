#' Viewports and layouts
#'
#' A `viewport` is a rectangular region that establishes its own coordinate
#' systems (its `xscale`/`yscale` for `"native"` units), optionally rotated,
#' clipped, and carrying inheritable graphical parameters. Push one onto a scene
#' with [push()]. A viewport may define a row/column [grid_layout()]; child
#' viewports are then placed into cells via `row`/`col`.
#'
#' @param x,y Centre of the viewport ([unit()] or numeric, in the parent).
#' @param width,height Size ([unit()] or numeric, in the parent).
#' @param xscale,yscale Length-2 native coordinate ranges.
#' @param angle Rotation in degrees, counter-clockwise about the centre.
#' @param clip Clip drawing to this viewport: `TRUE`/`FALSE` for the viewport
#'   rectangle, or a [polygon_grob()]/[path_grob()] (in this viewport's
#'   coordinates) to clip to an arbitrary path.
#' @param gp Inheritable graphical parameters, from [gpar()].
#' @param layout An optional [grid_layout()].
#' @param row,col Cell (1-based) of the parent's layout to place into.
#' @param rowspan,colspan Number of cells to span.
#' @param mask An optional mask: a grob (or list of grobs), or an [as_mask()]
#'   result. The viewport's contents are rendered as an isolated layer and the
#'   mask modulates their visibility.
#' @param name Optional name (for [edit_node()]).
#' @return A `viewport` object.
#' @examples
#' viewport(xscale = c(0, 10), yscale = c(0, 100))
#' @export
viewport <- function(x = 0.5, y = 0.5, width = 1, height = 1,
                     xscale = c(0, 1), yscale = c(0, 1), angle = 0, clip = FALSE,
                     gp = gpar(), layout = NULL,
                     row = NULL, col = NULL, rowspan = 1, colspan = 1,
                     mask = NULL, name = NULL) {
  .check_cell <- function(v, arg) {
    if (!is.null(v) && (length(v) != 1L || is.na(v) || v < 1)) {
      cli::cli_abort("{.arg {arg}} must be a single positive integer (1-based) or NULL.")
    }
  }
  .check_cell(row, "row")
  .check_cell(col, "col")
  class_viewport(
    x = as_unit(x), y = as_unit(y), width = as_unit(width), height = as_unit(height),
    xscale = as.numeric(xscale), yscale = as.numeric(yscale),
    angle = as.numeric(angle), clip = clip, gp = gp, layout = layout,
    row = row, col = col, rowspan = as.integer(rowspan), colspan = as.integer(colspan),
    mask = mask, name = name
  )
}

class_viewport <- S7::new_class(
  "class_viewport", package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    width = .unit_prop("unit(1, \"npc\")"), height = .unit_prop("unit(1, \"npc\")"),
    xscale = S7::new_property(S7::class_double, default = c(0, 1)),
    yscale = S7::new_property(S7::class_double, default = c(0, 1)),
    angle = S7::new_property(S7::class_double, default = 0),
    clip = S7::new_property(S7::class_any, default = FALSE),
    gp = S7::new_property(gpar, default = quote(gpar())),
    layout = S7::new_property(S7::class_any, default = NULL),
    row = S7::new_property(S7::class_any, default = NULL),
    col = S7::new_property(S7::class_any, default = NULL),
    rowspan = S7::new_property(S7::class_integer, default = 1L),
    colspan = S7::new_property(S7::class_integer, default = 1L),
    mask = S7::new_property(S7::class_any, default = NULL),
    name = S7::new_property(S7::class_any, default = NULL)
  )
)

#' @rdname viewport
#' @param widths,heights Track sizes as a [unit()] vector. Use `"null"` units for
#'   flexible tracks that share leftover space in proportion to their value.
#' @return `grid_layout()`: a layout object.
#' @export
grid_layout <- function(widths = unit(1, "null"), heights = unit(1, "null")) {
  stopifnot(is_unit(widths), is_unit(heights))
  class_grid_layout(widths = widths, heights = heights)
}

class_grid_layout <- S7::new_class(
  "class_grid_layout", package = "vellum",
  properties = list(
    widths = S7::new_property(S7::new_S3_class("vellum_unit")),
    heights = S7::new_property(S7::new_S3_class("vellum_unit"))
  )
)
