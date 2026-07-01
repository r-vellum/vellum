#' Reusable style classes
#'
#' A `style` bundles [gpar()] graphical parameters under an optional name so the
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
#' @inheritParams gpar
#' @param name Optional style-class name, for identification only; it is ignored
#'   by rendering.
#' @return A `style` object (a subclass of `gpar`).
#' @examples
#' accent <- style(col = "firebrick", lwd = 2, name = "accent")
#' # Reuse it on a viewport; children inherit unless they override.
#' viewport(gp = accent)
#' @include gpar.R
#' @export
style <- S7::new_class(
  "vellum_style",
  parent = gpar,
  package = "vellum",
  properties = list(
    name = S7::new_property(S7::class_any, default = NULL)
  )
)
