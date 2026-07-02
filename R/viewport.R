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
#' @param alpha Optional group opacity in `[0, 1]`. The viewport's contents are
#'   composited as a single isolated layer at this opacity, so overlapping
#'   elements do not accumulate (unlike per-element `gpar(alpha=)`). `NULL`
#'   (default) means fully opaque.
#' @param blend Optional blend mode for compositing the viewport's contents (as an
#'   isolated layer) onto the backdrop below it. One of `"normal"` (default),
#'   `"multiply"`, `"screen"`, `"overlay"`, `"darken"`, `"lighten"`,
#'   `"color-dodge"`, `"color-burn"`, `"hard-light"`, `"soft-light"`,
#'   `"difference"`, `"exclusion"`, `"hue"`, `"saturation"`, `"color"`, or
#'   `"luminosity"` (the CSS `mix-blend-mode` set). `NULL`/`"normal"` is ordinary
#'   over-compositing.
#' @param name Optional name (for [edit_node()]).
#' @param cache Repaint boundary (`TRUE`/`FALSE`, default `FALSE`). Flag this
#'   viewport's subtree as a cached sub-raster: on render it is rasterised once to
#'   its own layer and, on later renders where the subtree is **unchanged**, the
#'   cached pixels are composited instead of re-drawing the subtree. This makes
#'   partial redraw cheap — highlight/hover ([edit_node()] one element and
#'   re-render) or animation (one subtree changes, others static) re-rasterise
#'   only what changed. Raster/[display()] only; SVG/PDF ignore it and render the
#'   subtree as vector (no fidelity loss). Ignored when the viewport also sets a
#'   non-normal `blend` (a blend needs the live backdrop). See
#'   [vl_clear_render_cache()].
#' @return A `viewport` object.
#' @examples
#' viewport(xscale = c(0, 10), yscale = c(0, 100))
#' @export
viewport <- function(x = 0.5, y = 0.5, width = 1, height = 1,
                     xscale = c(0, 1), yscale = c(0, 1), angle = 0, clip = FALSE,
                     gp = gpar(), layout = NULL,
                     row = NULL, col = NULL, rowspan = 1, colspan = 1,
                     mask = NULL, alpha = NULL, blend = NULL, name = NULL,
                     cache = FALSE) {
  .check_cell <- function(v, arg) {
    if (!is.null(v) && (length(v) != 1L || is.na(v) || v < 1)) {
      cli::cli_abort("{.arg {arg}} must be a single positive integer (1-based) or NULL.")
    }
  }
  .check_cell(row, "row")
  .check_cell(col, "col")
  if (!is.null(alpha) && (length(alpha) != 1L || is.na(alpha) || alpha < 0 || alpha > 1)) {
    cli::cli_abort("{.arg alpha} must be a single number in {.val {c(0, 1)}} or NULL.")
  }
  if (!is.null(blend)) {
    blend <- match.arg(as.character(blend), names(.blend_codes))
  }
  if (length(cache) != 1L || is.na(cache) || !is.logical(cache)) {
    cli::cli_abort("{.arg cache} must be a single {.cls logical}.")
  }
  class_viewport(
    x = as_unit(x), y = as_unit(y), width = as_unit(width), height = as_unit(height),
    xscale = as.numeric(xscale), yscale = as.numeric(yscale),
    angle = as.numeric(angle), clip = clip, gp = gp, layout = layout,
    row = row, col = col, rowspan = as.integer(rowspan), colspan = as.integer(colspan),
    mask = mask, alpha = alpha, blend = blend, name = name, cache = cache
  )
}

# Blend-mode codes. Part of the R<->Rust ABI: MUST match `BlendKind::from_code`
# in `src/rust/src/render.rs`.
.blend_codes <- c(
  normal = 0L, multiply = 1L, screen = 2L, overlay = 3L, darken = 4L, lighten = 5L,
  `color-dodge` = 6L, `color-burn` = 7L, `hard-light` = 8L, `soft-light` = 9L,
  difference = 10L, exclusion = 11L, hue = 12L, saturation = 13L, color = 14L,
  luminosity = 15L
)

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
    alpha = S7::new_property(S7::class_any, default = NULL),
    blend = S7::new_property(S7::class_any, default = NULL),
    name = S7::new_property(S7::class_any, default = NULL),
    cache = S7::new_property(S7::class_logical, default = FALSE)
  )
)

#' @rdname viewport
#' @param widths,heights Track sizes as a [unit()] vector. Use `"null"` units for
#'   flexible tracks that share leftover space in proportion to their value.
#' @param respect Logical; if `TRUE`, lock the layout's aspect grid-style: one unit
#'   of `"null"` width is forced to the same physical (device) size as one unit of
#'   `"null"` height. The axis whose `null` unit would be larger shrinks to match
#'   and the whole grid is centered in its parent (so absolute gutter tracks stay
#'   attached to the flexible cells). Encode a desired cell aspect in the `null`
#'   track weights — a cell of `null` width-weight `w` by height-weight `h` then
#'   renders with device aspect `w:h`. Default `FALSE` (tracks just fill the
#'   parent). This is how a fixed-aspect panel (e.g. `coord_fixed()`, maps) is
#'   built on top of vellum.
#' @return `grid_layout()`: a layout object.
#' @export
grid_layout <- function(widths = unit(1, "null"), heights = unit(1, "null"), respect = FALSE) {
  stopifnot(is_unit(widths), is_unit(heights))
  if (length(respect) != 1L || is.na(respect) || !is.logical(respect)) {
    cli::cli_abort("{.arg respect} must be a single {.cls logical}.")
  }
  class_grid_layout(widths = widths, heights = heights, respect = respect)
}

class_grid_layout <- S7::new_class(
  "class_grid_layout", package = "vellum",
  properties = list(
    widths = S7::new_property(S7::new_S3_class("vellum_unit")),
    heights = S7::new_property(S7::new_S3_class("vellum_unit")),
    respect = S7::new_property(S7::class_logical, default = FALSE)
  )
)
