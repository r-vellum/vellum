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
#' @param lty Line type: a name (`"solid"`, `"dashed"`, `"dotted"`, `"dotdash"`,
#'   `"longdash"`, `"twodash"`), an integer code `0:6`, a hex dash string (e.g.
#'   `"44"`), or a numeric vector of on/off dash lengths. Dash lengths scale with
#'   `lwd`.
#' @param lineend Line cap: `"round"` (default), `"butt"`, or `"square"`.
#' @param linejoin Line join: `"round"` (default), `"mitre"`, or `"bevel"`.
#' @param linemitre Mitre limit (>= 1) for mitre joins; default 10.
#' @param fontfamily Font family (text grobs).
#' @param fontface One of `"plain"`, `"bold"`, `"italic"`, `"bold.italic"`.
#' @param fontsize Font size in points.
#' @param cex Multiplier applied to `fontsize` (grid semantics), so a theme can
#'   ask for a relative size without knowing the base one. `cex = 2` is exactly
#'   equivalent to doubling `fontsize`: it scales drawn text, `char`/`line`
#'   units, and [grobwidth()]/[grobheight()] measurement alike. `NULL` (the
#'   default) means 1.
#' @param lineheight Line-height multiple.
#' @return A `gpar` object.
#' @examples
#' vl_gpar(col = "steelblue", lwd = 2, lty = "dashed", lineend = "round")
#' @export
vl_gpar <- S7::new_class(
  "vl_gpar",
  package = "vellum",
  properties = list(
    col        = S7::new_property(S7::class_any, default = NULL),
    fill       = S7::new_property(S7::class_any, default = NULL),
    lwd        = S7::new_property(S7::class_any, default = NULL),
    alpha      = S7::new_property(S7::class_any, default = NULL),
    lty        = S7::new_property(S7::class_any, default = NULL),
    lineend    = S7::new_property(S7::class_any, default = NULL),
    linejoin   = S7::new_property(S7::class_any, default = NULL),
    linemitre  = S7::new_property(S7::class_any, default = NULL),
    fontfamily = S7::new_property(S7::class_any, default = NULL),
    fontface   = S7::new_property(S7::class_any, default = NULL),
    fontsize   = S7::new_property(S7::class_any, default = NULL),
    cex        = S7::new_property(S7::class_any, default = NULL),
    lineheight = S7::new_property(S7::class_any, default = NULL)
  ),
  validator = function(self) {
    x <- self@cex
    if (!is.null(x) && is.numeric(x) && any(!is.na(x) & x < 0)) {
      return("@cex must be non-negative (or NULL to inherit)")
    }
    a <- self@alpha
    # NULL/NA mean "inherit"; any concrete alpha must lie in [0, 1].
    if (!is.null(a) && is.numeric(a) && any(!is.na(a) & (a < 0 | a > 1))) {
      return("@alpha must be in [0, 1] (or NULL to inherit)")
    }
    m <- self@linemitre
    if (!is.null(m) && is.numeric(m) && any(!is.na(m) & m < 1)) {
      return("@linemitre must be >= 1")
    }
    NULL
  }
)

# The effective type size for a gpar: `fontsize` scaled by `cex`, matching grid
# (where `cex` is a multiplier on the base size, not a size itself). Both default
# to "unset", so a plain gpar gives 12pt exactly as before. This is the single
# place the two combine -- text drawing, `char`/`line` unit resolution, and grob
# measurement all route through it so they cannot disagree.
.gp_fontsize <- function(gp) {
  (gp@fontsize %||% 12) * (gp@cex %||% 1)
}

# An S7 property typed as a `unit` vector, with a quoted default evaluated at
# construction (so it works regardless of file collation order). Shared by grob
# and viewport classes; lives here because gpar.R is collated first.
.unit_prop <- function(default = "vl_unit(0.5, \"npc\")") {
  S7::new_property(S7::new_S3_class("vellum_unit"), default = str2lang(default))
}
