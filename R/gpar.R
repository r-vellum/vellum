#' Graphical parameters
#'
#' Builds a set of graphical parameters attached to a grob or viewport. Any field
#' left `NULL` is inherited from the enclosing viewport; `alpha` multiplies down
#' the viewport tree. A colour value sets it; `NA` means "no paint".
#'
#' @param col Stroke/text colour, or a gradient from [linear_gradient()] /
#'   [radial_gradient()] to **stroke with a gradient** — the same paint model as
#'   `fill`, applied to the stroked region instead of the enclosed one. A
#'   gradient here affects stroked paths; text and markers fall back to its first
#'   stop, since a glyph run has no path to run a ramp along.
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
#' @param halo_col Halo colour for text (a "shadowtext" outline drawn *under*
#'   the glyphs, so a label stays legible over dense marks or map imagery).
#'   `NULL` (default) means no halo. Needs `halo_width` to be visible.
#' @param halo_width Halo thickness in points -- the visible width outside the
#'   glyph. `NULL` or `0` means no halo. A good starting point is roughly an
#'   eighth of `fontsize`.
#' @param features OpenType font features, as a named numeric vector of
#'   four-character feature tags -- e.g. `c(tnum = 1)` for tabular (fixed-width)
#'   figures so axis labels stop jittering between ticks, `c(smcp = 1)` for small
#'   caps, `c(onum = 1)` for oldstyle figures, `c(liga = 0)` to switch ligatures
#'   off, or `c(kern = 0)` to disable kerning. `NULL` (default) uses the font's
#'   own defaults. A feature the font does not carry is silently ignored --
#'   that is HarfBuzz's behaviour, not something vellum can check for you.
#' @param antialias Anti-alias this element's edges? `NULL` (default) inherits;
#'   the root default is `TRUE`. `FALSE` gives hard pixel edges, which is what
#'   pixel art, QR codes, and heatmap cells that must tile without a seam want.
#' @param crisp Snap axis-parallel strokes onto the pixel grid? `NULL` (default)
#'   inherits; the root default is `FALSE`. A 1-px rule at a fractional
#'   coordinate straddles two pixel rows and renders as two grey ones rather than
#'   one solid — the reason gridlines look muddy on screen. `TRUE` snaps
#'   horizontal and vertical runs so they land on whole pixels. Diagonals are
#'   unaffected (there is no grid to snap them to), and it only applies to raster
#'   output — a vector format has no pixel grid.
#' @param dash_phase How far into the dash pattern a dashed line starts, as a
#'   multiple of `lwd` (so it scales with the line width exactly as the dash
#'   nibbles do). Use it to line up dashes across adjacent strokes, or animate it
#'   for marching ants. `NULL` (default) means 0. Ignored for a solid line.
#' @param lineheight Line-height multiple.
#' @return A `gpar` object.
#' @examples
#' vl_gpar(col = "steelblue", lwd = 2, lty = "dashed", lineend = "round")
#' @export
vl_gpar <- S7::new_class(
  "vl_gpar",
  package = "vellum",
  properties = list(
    col = S7::new_property(S7::class_any, default = NULL),
    fill = S7::new_property(S7::class_any, default = NULL),
    lwd = S7::new_property(S7::class_any, default = NULL),
    alpha = S7::new_property(S7::class_any, default = NULL),
    lty = S7::new_property(S7::class_any, default = NULL),
    lineend = S7::new_property(S7::class_any, default = NULL),
    linejoin = S7::new_property(S7::class_any, default = NULL),
    linemitre = S7::new_property(S7::class_any, default = NULL),
    fontfamily = S7::new_property(S7::class_any, default = NULL),
    fontface = S7::new_property(S7::class_any, default = NULL),
    fontsize = S7::new_property(S7::class_any, default = NULL),
    cex = S7::new_property(S7::class_any, default = NULL),
    lineheight = S7::new_property(S7::class_any, default = NULL),
    halo_col = S7::new_property(S7::class_any, default = NULL),
    halo_width = S7::new_property(S7::class_any, default = NULL),
    features = S7::new_property(S7::class_any, default = NULL),
    antialias = S7::new_property(S7::class_any, default = NULL),
    crisp = S7::new_property(S7::class_any, default = NULL),
    dash_phase = S7::new_property(S7::class_any, default = NULL)
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
    hw <- self@halo_width
    if (!is.null(hw) && is.numeric(hw) && any(!is.na(hw) & hw < 0)) {
      return("@halo_width must be non-negative (or NULL for no halo)")
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

# The text halo as `list(col, width_pt)`, or NULL when there is none. A halo needs
# both a colour and a positive width; either alone is a no-op, so the backends
# never see a half-specified halo.
# Normalise `gp@features` to a named integer vector, or NULL. Accepts a named
# numeric/logical vector; a `font_feature()` object from systemfonts passes
# straight through (it is what `textshaping::shape_text()` wants anyway).
.gp_features <- function(gp) {
  f <- gp@features
  if (is.null(f) || length(f) == 0L) {
    return(NULL)
  }
  if (inherits(f, "font_feature")) {
    return(f)
  }
  nm <- names(f)
  if (is.null(nm) || !all(nzchar(nm))) {
    cli::cli_abort(c(
      "{.arg features} must be a {.emph named} vector of OpenType tags.",
      i = 'For example {.code c(tnum = 1)} or {.code c(liga = 0)}.'
    ))
  }
  bad <- nm[nchar(nm) != 4L]
  if (length(bad)) {
    cli::cli_abort(c(
      "OpenType feature tags are exactly four characters.",
      x = "Not a tag: {.val {bad}}."
    ))
  }
  stats::setNames(as.integer(f), nm)
}

.gp_halo <- function(gp) {
  col <- gp@halo_col
  w <- gp@halo_width %||% 0
  if (
    is.null(col) || length(col) == 0L || all(is.na(col)) || !isTRUE(w[1] > 0)
  ) {
    return(NULL)
  }
  list(col = col[1], width = as.numeric(w[1]))
}

# An S7 property typed as a `unit` vector, with a quoted default evaluated at
# construction (so it works regardless of file collation order). Shared by grob
# and viewport classes; lives here because gpar.R is collated first.
.unit_prop <- function(default = "vl_unit(0.5, \"npc\")") {
  S7::new_property(S7::new_S3_class("vellum_unit"), default = str2lang(default))
}
