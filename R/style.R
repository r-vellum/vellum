#' Reusable style classes
#'
#' A `style` bundles [vl_gpar()] graphical parameters under an optional name so the
#' same look can be reused across many viewports or grobs. A `style` **is** a
#' `gpar` — it carries every graphical-parameter field and obeys the same
#' inheritance rules — with an added `name` for identification. It can therefore
#' be passed anywhere a `gp` is accepted.
#'
#' Attaching a `style` to a viewport cascades its defaults to the whole subtree
#' via the ordinary gpar inheritance (more-specific overrides less-specific), so
#' a child grob's own `gp` still wins. This is the reusable "style class" layer
#' that sits below a grammar's themes: a theme can compile *into* named styles
#' rather than setting gpar fields ad hoc on every element.
#'
#' @inheritParams vl_gpar
#' @param name Optional style-class name, for identification only; it is ignored
#'   by rendering.
#' @return A `style` object (a subclass of `gpar`).
#' @examples
#' accent <- style(col = "firebrick", lwd = 2, name = "accent")
#' # Reuse it on a viewport; children inherit unless they override.
#' vl_viewport(gp = accent)
#' @include gpar.R
#' @export
style <- S7::new_class(
  "vellum_style",
  parent = vl_gpar,
  package = "vellum",
  properties = list(
    name = S7::new_property(S7::class_any, default = NULL)
  ),
  # Spelled out rather than generated: S7 >= 1.0 generates `function(...,
  # name)` for a subclass of a class with a custom constructor, which no longer
  # matches the documented usage (R CMD check codoc).
  constructor = function(
    col = NULL,
    fill = NULL,
    lwd = NULL,
    alpha = NULL,
    lty = NULL,
    lineend = NULL,
    linejoin = NULL,
    linemitre = NULL,
    fontfamily = NULL,
    fontface = NULL,
    fontsize = NULL,
    cex = NULL,
    lineheight = NULL,
    halo_col = NULL,
    halo_width = NULL,
    features = NULL,
    antialias = NULL,
    crisp = NULL,
    dash_phase = NULL,
    name = NULL
  ) {
    S7::new_object(
      vl_gpar(
        col = col,
        fill = fill,
        lwd = lwd,
        alpha = alpha,
        lty = lty,
        lineend = lineend,
        linejoin = linejoin,
        linemitre = linemitre,
        fontfamily = fontfamily,
        fontface = fontface,
        fontsize = fontsize,
        cex = cex,
        lineheight = lineheight,
        halo_col = halo_col,
        halo_width = halo_width,
        features = features,
        antialias = antialias,
        crisp = crisp,
        dash_phase = dash_phase
      ),
      name = name
    )
  }
)
