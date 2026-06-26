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
grob_segments <- S7::new_class("grob_segments", parent = grob, package = "vellum",
  properties = list(x0 = .unit_prop(), y0 = .unit_prop(), x1 = .unit_prop(), y1 = .unit_prop()))
grob_path <- S7::new_class("grob_path", parent = grob, package = "vellum",
  properties = list(
    x = .unit_prop(), y = .unit_prop(),
    nper = S7::new_property(S7::class_integer, default = integer(0)),
    rule = S7::new_property(S7::class_character, default = "winding")
  )
)
grob_raster <- S7::new_class("grob_raster", parent = grob, package = "vellum",
  properties = list(
    rgba = S7::new_property(S7::class_integer, default = integer(0)),
    iw = S7::new_property(S7::class_integer, default = 0L),
    ih = S7::new_property(S7::class_integer, default = 0L),
    x = .unit_prop(), y = .unit_prop(),
    width = .unit_prop("unit(1, \"npc\")"), height = .unit_prop("unit(1, \"npc\")"),
    interpolate = S7::new_property(S7::class_logical, default = TRUE)
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
  w <- as_unit(width)
  h <- as_unit(height)
  .check_extent(w, "width")
  .check_extent(h, "height")
  grob_rect(x = as_unit(x), y = as_unit(y), width = w, height = h,
            gp = gp, name = name, vp = vp)
}

# An extent (width/height/radius/size) must be non-negative. Checks the resolved
# numeric value of a unit vector (absolute/derived kinds are already in mm; npc/
# native lengths are likewise non-negative when sensible).
.check_extent <- function(u, arg) {
  v <- vctrs::field(u, "value")
  if (length(v) && any(v < 0, na.rm = TRUE)) {
    cli::cli_abort("{.arg {arg}} must be non-negative.")
  }
  invisible(u)
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
  ru <- as_unit(r)
  .check_extent(ru, "r")
  grob_circle(x = vctrs::vec_recycle(as_unit(x), n),
              y = vctrs::vec_recycle(as_unit(y), n),
              r = vctrs::vec_recycle(ru, n),
              gp = gp, name = name, vp = vp)
}

#' @rdname grob
#' @param size Point size ([unit()] or numeric).
#' @export
points_grob <- function(x, y, size = unit(2, "mm"), gp = gpar(), name = NULL, vp = NULL) {
  n <- .coord_n(x, y)
  sz <- as_unit(size, "mm")
  .check_extent(sz, "size")
  grob_points(x = vctrs::vec_recycle(as_unit(x), n),
              y = vctrs::vec_recycle(as_unit(y), n),
              size = vctrs::vec_recycle(sz, n),
              gp = gp, name = name, vp = vp)
}

#' @rdname grob
#' @param x0,y0,x1,y1 Segment start/end coordinates ([unit()] or numeric).
#' @export
segments_grob <- function(x0, y0, x1, y1, gp = gpar(), name = NULL, vp = NULL) {
  n <- .common_n(x0, y0, x1, y1)
  grob_segments(
    x0 = vctrs::vec_recycle(as_unit(x0, "native"), n),
    y0 = vctrs::vec_recycle(as_unit(y0, "native"), n),
    x1 = vctrs::vec_recycle(as_unit(x1, "native"), n),
    y1 = vctrs::vec_recycle(as_unit(y1, "native"), n),
    gp = gp, name = name, vp = vp
  )
}

#' @rdname grob
#' @param id Optional vector (one per point) grouping points into closed
#'   sub-paths: all points sharing an `id` form one sub-path (so a hole is a
#'   separate `id`), grouped in first-appearance order \(à la grid\). `NULL`
#'   makes a single sub-path.
#' @param rule Fill rule: `"winding"` (non-zero, default) or `"evenodd"`.
#' @export
path_grob <- function(x, y, id = NULL, rule = c("winding", "evenodd"),
                      gp = gpar(), name = NULL, vp = NULL) {
  rule <- match.arg(rule)
  n <- .coord_n(x, y)
  xu <- vctrs::vec_recycle(as_unit(x, "native"), n)
  yu <- vctrs::vec_recycle(as_unit(y, "native"), n)
  if (is.null(id)) {
    nper <- n
  } else {
    if (length(id) != n) cli::cli_abort("{.arg id} must have one value per point ({n}).")
    grp <- match(id, unique(id)) # group index in first-appearance order
    ord <- order(grp, seq_along(grp)) # stable: gather each id's points together
    xu <- xu[ord]; yu <- yu[ord]
    nper <- tabulate(grp)
  }
  grob_path(
    x = xu, y = yu, nper = as.integer(nper), rule = rule, gp = gp, name = name, vp = vp
  )
}

#' @rdname grob
#' @param image A raster image: a [grDevices::as.raster()]-compatible object — a
#'   matrix/array of colours or greyscale values, or a `raster` object.
#' @param interpolate Smoothly interpolate when scaling (default `TRUE`)? `FALSE`
#'   keeps hard pixel edges.
#' @export
raster_grob <- function(image, x = 0.5, y = 0.5, width = 1, height = 1,
                        interpolate = TRUE, gp = gpar(), name = NULL, vp = NULL) {
  px <- .image_to_rgba(image)
  grob_raster(
    rgba = px$rgba, iw = px$iw, ih = px$ih,
    x = as_unit(x), y = as_unit(y),
    width = as_unit(width), height = as_unit(height),
    interpolate = isTRUE(interpolate), gp = gp, name = name, vp = vp
  )
}

# Convert an R image to a flat straight-RGBA integer vector (row-major, top-left,
# 4 ints per pixel) plus its pixel dimensions. A `raster` object stores its cells
# by row (top-left first), so `as.vector()` already gives the order we want.
.image_to_rgba <- function(image) {
  r <- grDevices::as.raster(image)
  d <- dim(r)
  if (is.null(d) || any(d == 0L)) cli::cli_abort("{.arg image} has no pixels.")
  ih <- d[1]; iw <- d[2]
  rgba <- grDevices::col2rgb(as.vector(r), alpha = TRUE) # 4 x N (r, g, b, alpha)
  list(rgba = as.integer(rgba), iw = as.integer(iw), ih = as.integer(ih))
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

#' Size a unit by a grob's extent
#'
#' `grobwidth(grob)` and `grobheight(grob)` return a [unit()] equal to the drawn
#' width/height of `grob` — handy for sizing a [viewport()] or [grid_layout()]
#' track to its contents (e.g. a margin to an axis label). The extent is measured
#' **eagerly** to absolute millimetres at construction, so it is exact for text
#' and absolute-unit (`mm`/`in`/`pt`) grobs. A grob sized in `npc`/`native` has no
#' viewport-independent extent and is measured against a fixed reference, so for
#' those prefer `npc`/`native` directly.
#'
#' @param grob A grob (or composite subtree) to measure.
#' @param mult A multiplier on the measured extent (default 1).
#' @return A `unit` (in millimetres).
#' @examples
#' grobwidth(text_grob("A wide axis label", gp = gpar(fontsize = 14)))
#' grobheight(rect_grob(height = unit(8, "mm")))
#' @export
grobwidth <- function(grob, mult = 1) unit(mult, "grobwidth", data = grob)

#' @rdname grobwidth
#' @export
grobheight <- function(grob, mult = 1) unit(mult, "grobheight", data = grob)

# A grob's drawn extent as c(width_mm, height_mm). Text uses exact (advance)
# metrics; any other grob (incl. a gtree) is rendered into a throwaway scene and
# measured by its non-transparent bounding box. Device-independent for text and
# absolute geometry; npc/native content is measured against REF_IN.
.MEASURE_DPI <- 96
.MEASURE_REF_IN <- 12
.grob_extent <- function(g) {
  if (S7::S7_inherits(g, grob_text)) {
    labs <- as.character(g@label)
    if (length(labs) == 0L) return(c(0, 0))
    fs <- g@gp@fontsize %||% 12
    fam <- g@gp@fontfamily %||% ""
    face <- g@gp@fontface %||% "plain"
    w <- max(vapply(labs, function(l) rs_strwidth(l, fam, face, fs, unit = "mm"), double(1)))
    h <- max(vapply(labs, function(l) rs_strheight(l, fam, face, fs, unit = "mm"), double(1)))
    return(c(w, h))
  }
  sc <- Scene$new(.MEASURE_REF_IN, .MEASURE_REF_IN, .MEASURE_DPI, c(0L, 0L, 0L, 0L))
  compile(g, sc)
  bb <- sc$content_bbox() # c(min_x, min_y, max_x, max_y) px, or empty
  if (length(bb) < 4L) return(c(0, 0))
  c((bb[3] - bb[1] + 1) / .MEASURE_DPI * 25.4, (bb[4] - bb[2] + 1) / .MEASURE_DPI * 25.4)
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
