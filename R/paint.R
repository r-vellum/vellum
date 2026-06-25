#' Gradient fills
#'
#' Create a linear or radial gradient to use as a `fill` in [gpar()]. A gradient
#' interpolates between colour *stops*. Its geometry (`x1`/`y1`/... or
#' `cx`/`cy`/`r`) is given in the coordinate system named by `units` and is
#' resolved against the viewport at draw time, so the gradient transforms with
#' the grob just like its outline.
#'
#' @param colours A vector of two or more colours (any R colour spec). With
#'   `stops = NULL` they are spread evenly across `[0, 1]`.
#' @param stops Optional offsets in `[0, 1]`, one per colour. Defaults to evenly
#'   spaced.
#' @param x1,y1,x2,y2 Start and end points of a linear gradient (default a
#'   left-to-right sweep in `npc`).
#' @param cx,cy,r Centre and radius of a radial gradient (default centred,
#'   radius `0.5` npc).
#' @param units Coordinate system for the geometry: one of `"npc"`, `"native"`,
#'   `"mm"`, `"in"`, `"pt"`.
#' @param extend How the gradient behaves outside `[0, 1]`: `"pad"` (clamp to the
#'   end stops), `"repeat"`, or `"reflect"`.
#' @return A `vellum_gradient` object, suitable for `gpar(fill = ...)`.
#' @examples
#' linear_gradient(c("white", "navy"))
#' radial_gradient(c("yellow", "red"), cx = 0.5, cy = 0.5, r = 0.5)
#' @name gradients
NULL

#' @rdname gradients
#' @export
linear_gradient <- function(colours, stops = NULL, x1 = 0, y1 = 0, x2 = 1, y2 = 0,
                            units = "npc", extend = "pad") {
  .new_gradient("linear", colours, stops, c(x1, y1, x2, y2), units, extend)
}

#' @rdname gradients
#' @export
radial_gradient <- function(colours, stops = NULL, cx = 0.5, cy = 0.5, r = 0.5,
                            units = "npc", extend = "pad") {
  .new_gradient("radial", colours, stops, c(cx, cy, r), units, extend)
}

.gradient_units <- c("npc", "native", "mm", "in", "pt")
.gradient_extend <- c("pad", "repeat", "reflect")

.new_gradient <- function(kind, colours, stops, coords, units, extend) {
  n <- length(colours)
  if (n < 1L) {
    cli::cli_abort("A gradient needs at least one colour.")
  }
  if (is.null(stops)) {
    stops <- if (n == 1L) 0 else seq(0, 1, length.out = n)
  }
  if (length(stops) != n) {
    cli::cli_abort("{.arg stops} must have one offset per colour ({n}).")
  }
  units <- match.arg(units, .gradient_units)
  extend <- match.arg(extend, .gradient_extend)
  if (!all(is.finite(coords))) {
    cli::cli_abort("Gradient coordinates must be finite.")
  }
  structure(
    list(
      kind = kind,
      colours = colours,
      stops = as.double(stops),
      coords = as.double(coords),
      units = units,
      extend = extend
    ),
    class = "vellum_gradient"
  )
}

#' @export
print.vellum_gradient <- function(x, ...) {
  cli::cli_text("<vellum_gradient: {x$kind}> {length(x$colours)} stop{?s}, units = {.val {x$units}}")
  invisible(x)
}

# Encode a fill (solid colour or gradient) for the backend. Solids reuse the
# tri-state colour encoding (NULL inherit / integer(0) none / int[4] set); a
# gradient becomes a list the Rust `parse_paint` decodes (`kind` distinguishes).
.encode_paint <- function(x) {
  if (inherits(x, "vellum_gradient")) {
    return(.encode_gradient(x))
  }
  .rs_col_inh(x)
}

.encode_gradient <- function(g) {
  rgba <- grDevices::col2rgb(g$colours, alpha = TRUE) # 4 x n: rows r, g, b, alpha
  list(
    kind = g$kind,
    coords = g$coords,
    units = g$units,
    col = as.integer(rgba), # column-major -> flat r,g,b,a per stop
    offset = pmin(pmax(g$stops, 0), 1),
    extend = g$extend
  )
}
