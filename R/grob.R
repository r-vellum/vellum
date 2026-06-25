#' Graphical objects (grobs)
#'
#' Grobs are immutable value objects describing something to draw. Build them
#' with the constructors below, add them to a scene with [draw()], and render
#' with [render()]. Coordinates accept a [unit()] vector or a bare numeric
#' (interpreted in the `default_units`, usually `"npc"`).
#'
#' @name grob
#' @return A grob object.
NULL

# Abstract base: every grob carries a name, gpar, and an optional viewport.
grob <- S7::new_class(
  "grob", package = "vellum", abstract = TRUE,
  properties = list(
    name = S7::new_property(S7::class_any, default = NULL),
    gp   = S7::new_property(gpar, default = quote(gpar())),
    vp   = S7::new_property(S7::class_any, default = NULL)
  )
)

grob_rect <- S7::new_class("grob_rect", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    width = .unit_prop("unit(1, \"npc\")"), height = .unit_prop("unit(1, \"npc\")")
  )
)
grob_lines <- S7::new_class("grob_lines", parent = grob, package = "vellum",
  properties = list(x = .unit_prop(), y = .unit_prop()))
grob_polygon <- S7::new_class("grob_polygon", parent = grob, package = "vellum",
  properties = list(x = .unit_prop(), y = .unit_prop()))
grob_circle <- S7::new_class("grob_circle", parent = grob, package = "vellum",
  properties = list(x = .unit_prop(), y = .unit_prop(), r = .unit_prop("unit(0.25, \"npc\")")))
grob_points <- S7::new_class("grob_points", parent = grob, package = "vellum",
  properties = list(x = .unit_prop(), y = .unit_prop(), size = .unit_prop("unit(2, \"mm\")")))
grob_text <- S7::new_class("grob_text", parent = grob, package = "vellum",
  properties = list(
    label = S7::new_property(S7::class_character),
    x = .unit_prop(), y = .unit_prop(),
    just = S7::new_property(S7::class_character, default = c("centre", "centre")),
    rot  = S7::new_property(S7::class_double, default = 0)
  )
)

# --- friendly constructors --------------------------------------------------

#' @rdname grob
#' @param x,y Coordinates ([unit()] or numeric).
#' @param width,height Sizes ([unit()] or numeric).
#' @param gp Graphical parameters, from [gpar()].
#' @param name Optional name (for [edit_node()]).
#' @param vp Optional [viewport()] to draw this grob inside.
#' @export
rect_grob <- function(x = 0.5, y = 0.5, width = 1, height = 1,
                      gp = gpar(), name = NULL, vp = NULL) {
  grob_rect(x = as_unit(x), y = as_unit(y),
            width = as_unit(width), height = as_unit(height),
            gp = gp, name = name, vp = vp)
}

#' @rdname grob
#' @export
lines_grob <- function(x, y, gp = gpar(), name = NULL, vp = NULL) {
  n <- .coord_n(x, y)
  grob_lines(x = vctrs::vec_recycle(as_unit(x, "native"), n),
             y = vctrs::vec_recycle(as_unit(y, "native"), n),
             gp = gp, name = name, vp = vp)
}

#' @rdname grob
#' @export
polygon_grob <- function(x, y, gp = gpar(), name = NULL, vp = NULL) {
  n <- .coord_n(x, y)
  grob_polygon(x = vctrs::vec_recycle(as_unit(x, "native"), n),
               y = vctrs::vec_recycle(as_unit(y, "native"), n),
               gp = gp, name = name, vp = vp)
}

#' @rdname grob
#' @param r Radius ([unit()] or numeric).
#' @export
circle_grob <- function(x = 0.5, y = 0.5, r = 0.25, gp = gpar(), name = NULL, vp = NULL) {
  n <- .common_n(x, y, r)
  grob_circle(x = vctrs::vec_recycle(as_unit(x), n),
              y = vctrs::vec_recycle(as_unit(y), n),
              r = vctrs::vec_recycle(as_unit(r), n),
              gp = gp, name = name, vp = vp)
}

#' @rdname grob
#' @param size Point size ([unit()] or numeric).
#' @export
points_grob <- function(x, y, size = unit(2, "mm"), gp = gpar(), name = NULL, vp = NULL) {
  n <- .coord_n(x, y)
  grob_points(x = vctrs::vec_recycle(as_unit(x), n),
              y = vctrs::vec_recycle(as_unit(y), n),
              size = vctrs::vec_recycle(as_unit(size, "mm"), n),
              gp = gp, name = name, vp = vp)
}

#' @rdname grob
#' @param label Character string(s) to draw.
#' @param just Justification: `c(hjust, vjust)` as names (`"left"`, `"centre"`,
#'   `"right"`, `"bottom"`, `"top"`) or numbers in `[0, 1]`.
#' @param rot Rotation in degrees, counter-clockwise.
#' @export
text_grob <- function(label, x = 0.5, y = 0.5, just = "centre", rot = 0,
                      gp = gpar(), name = NULL, vp = NULL) {
  grob_text(label = as.character(label), x = as_unit(x), y = as_unit(y),
            just = as.character(just), rot = as.numeric(rot),
            gp = gp, name = name, vp = vp)
}

# Common length across several coordinate args, allowing length-1 recycling.
.common_n <- function(...) {
  sizes <- vapply(list(...), .vsize, integer(1))
  n <- max(sizes)
  if (!all(sizes %in% c(1L, n))) {
    stop("coordinates must have compatible lengths", call. = FALSE)
  }
  n
}
