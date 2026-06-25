#' Graphical parameters
#'
#' Builds a set of graphical parameters attached to a grob or viewport. Any field
#' left `NULL` is inherited from the enclosing viewport; `alpha` multiplies down
#' the viewport tree. A colour value sets it; `NA` means "no paint".
#'
#' @param col Stroke/text colour.
#' @param fill Fill colour, or a gradient from [linear_gradient()] /
#'   [radial_gradient()].
#' @param lwd Line width (1 == 1/96 inch).
#' @param alpha Opacity multiplier in `[0, 1]`.
#' @param fontfamily Font family (text grobs).
#' @param fontface One of `"plain"`, `"bold"`, `"italic"`, `"bold.italic"`.
#' @param fontsize Font size in points.
#' @param lineheight Line-height multiple.
#' @return A `gpar` object.
#' @examples
#' gpar(col = "steelblue", lwd = 2)
#' @export
gpar <- S7::new_class(
  "gpar",
  package = "vellum",
  properties = list(
    col        = S7::new_property(S7::class_any, default = NULL),
    fill       = S7::new_property(S7::class_any, default = NULL),
    lwd        = S7::new_property(S7::class_any, default = NULL),
    alpha      = S7::new_property(S7::class_any, default = NULL),
    fontfamily = S7::new_property(S7::class_any, default = NULL),
    fontface   = S7::new_property(S7::class_any, default = NULL),
    fontsize   = S7::new_property(S7::class_any, default = NULL),
    lineheight = S7::new_property(S7::class_any, default = NULL)
  )
)

# An S7 property typed as a `unit` vector, with a quoted default evaluated at
# construction (so it works regardless of file collation order). Shared by grob
# and viewport classes; lives here because gpar.R is collated first.
.unit_prop <- function(default = "unit(0.5, \"npc\")") {
  S7::new_property(S7::new_S3_class("vellum_unit"), default = str2lang(default))
}
