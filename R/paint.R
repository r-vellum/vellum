#' Gradient fills
#'
#' Create a linear or radial gradient to use as a `fill` in [vl_gpar()]. A gradient
#' interpolates between colour *stops*. Its geometry (`x1`/`y1`/... or
#' `cx`/`cy`/`r`) is given in the coordinate system named by `units` and is
#' resolved against the viewport at draw time, so the gradient transforms with
#' the grob just like its outline.
#'
#' A radial gradient runs between two circles: the *focal* (start) circle
#' `fx`/`fy`/`fr` at stop offset 0 and the *outer* (end) circle `cx`/`cy`/`r` at
#' offset 1. By default they are concentric (`fx = cx`, `fy = cy`, `fr = 0`) —
#' the classic centred highlight. Offsetting `fx`/`fy` moves the highlight
#' off-centre (as for a sphere lit from one side); a non-zero `fr` gives an
#' annular ramp between the two circles.
#'
#' By default stops are blended in sRGB (each backend's native behaviour). Set
#' `interpolation = "oklab"` to blend in the perceptually-uniform Oklab space
#' instead, which removes the muddy, over-dark midtones and hue drift of sRGB
#' blending — the ramp stays even and vivid. `interpolation = "oklch"` blends in
#' the polar form of the same space (lightness, chroma, hue): hue and chroma move
#' independently, so a ramp between two saturated colours keeps its chroma through
#' the middle instead of dipping toward grey the way a straight line in Oklab can
#' — at the cost of sweeping through the intermediate hues along the shorter arc
#' (e.g. blue→yellow passes through green). All modes work identically on the
#' raster, SVG, and PDF backends.
#'
#' @param colours A vector of two or more colours (any R colour spec). With
#'   `stops = NULL` they are spread evenly across `[0, 1]`.
#' @param stops Optional offsets in `[0, 1]`, one per colour. Defaults to evenly
#'   spaced.
#' @param x1,y1,x2,y2 Start and end points of a linear gradient (default a
#'   left-to-right sweep in `npc`).
#' @param cx,cy,r Centre and radius of a radial gradient's *outer* circle — the
#'   end of the ramp (stop offset 1). Default centred, radius `0.5` npc.
#' @param fx,fy,fr Centre and radius of the *focal* (start) circle — the origin
#'   of the ramp (stop offset 0). Defaults (`fx = cx`, `fy = cy`, `fr = 0`) give
#'   the ordinary concentric gradient; move `fx`/`fy` to place the highlight
#'   off-centre, or raise `fr` for an annular ramp between two circles. Radii must
#'   be non-negative.
#' @param units Coordinate system for the geometry: one of `"npc"`, `"native"`,
#'   `"mm"`, `"in"`, `"pt"`.
#' @param extend How the gradient behaves outside `[0, 1]`: `"pad"` (clamp to the
#'   end stops), `"repeat"`, or `"reflect"`.
#' @param interpolation Colour space the stops are blended in: `"srgb"` (default),
#'   `"oklab"` (perceptually uniform), or `"oklch"` (perceptual, hue-preserving).
#'   See Details.
#' @return A `vellum_gradient` object, suitable for `vl_gpar(fill = ...)`.
#' @examples
#' linear_gradient(c("white", "navy"))
#' linear_gradient(c("blue", "yellow"), interpolation = "oklab")
#' linear_gradient(c("blue", "yellow"), interpolation = "oklch")
#' radial_gradient(c("yellow", "red"), cx = 0.5, cy = 0.5, r = 0.5)
#' # off-centre highlight (a lit sphere): focal point up and to the left
#' radial_gradient(c("white", "navy"), cx = 0.5, cy = 0.5, r = 0.6,
#'                 fx = 0.35, fy = 0.65)
#' @name gradients
NULL

#' @rdname gradients
#' @export
linear_gradient <- function(colours, stops = NULL, x1 = 0, y1 = 0, x2 = 1, y2 = 0,
                            units = "npc", extend = "pad", interpolation = "srgb") {
  .new_gradient("linear", colours, stops, c(x1, y1, x2, y2), units, extend, interpolation)
}

#' @rdname gradients
#' @export
radial_gradient <- function(colours, stops = NULL, cx = 0.5, cy = 0.5, r = 0.5,
                            fx = cx, fy = cy, fr = 0,
                            units = "npc", extend = "pad", interpolation = "srgb") {
  if (!is.numeric(r) || !is.numeric(fr) || anyNA(c(r, fr)) || r < 0 || fr < 0) {
    cli::cli_abort("Radial gradient radii {.arg r}/{.arg fr} must be non-negative.")
  }
  .new_gradient("radial", colours, stops, c(cx, cy, r, fx, fy, fr), units, extend, interpolation)
}

.gradient_extend <- c("pad", "repeat", "reflect")
.gradient_interpolation <- c("srgb", "oklab", "oklch")

.new_gradient <- function(kind, colours, stops, coords, units, extend, interpolation = "srgb") {
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
  if (any(!is.finite(stops) | stops < 0 | stops > 1)) {
    cli::cli_abort("{.arg stops} must be finite offsets in [0, 1].")
  }
  if (is.unsorted(stops)) {
    cli::cli_abort("{.arg stops} must be non-decreasing.")
  }
  units <- match.arg(units, .coord_units)
  extend <- match.arg(extend, .gradient_extend)
  interpolation <- match.arg(interpolation, .gradient_interpolation)
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
      extend = extend,
      interpolation = interpolation
    ),
    class = "vellum_gradient"
  )
}

#' @export
print.vellum_gradient <- function(x, ...) {
  cli::cli_text("<vellum_gradient: {x$kind}> {length(x$colours)} stop{?s}, units = {.val {x$units}}")
  invisible(x)
}

# Encode a fill (solid colour, gradient, or pattern) for the backend. Solids
# reuse the tri-state colour encoding (NULL inherit / integer(0) none / int[4]
# set); a gradient/pattern becomes a list the Rust `parse_paint` decodes (`kind`
# distinguishes). Patterns need the rendering context (`scene`, a backend Scene)
# to rasterize their tile grob.
.encode_paint <- function(x, scene = NULL) {
  if (inherits(x, "vellum_pattern")) {
    return(.encode_pattern(x, scene))
  }
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
    extend = g$extend,
    interpolation = g$interpolation %||% "srgb"
  )
}

#' Tiling-pattern fills
#'
#' Create a pattern that fills a shape by tiling a grob. The grob is drawn once
#' into a tile occupying the unit square (`0..1` npc), then repeated across a cell
#' of size `width` x `height` (in `units`) anchored at `(x, y)`. Like gradients,
#' the cell geometry is resolved against the viewport at draw time.
#'
#' The tile is rendered to a raster image (sized from `width`/`height` at the
#' scene's resolution) and embedded: PNG raster, SVG `<image>` in a `<pattern>`.
#' The PDF backend has no image support yet, so a pattern degrades to the tile's
#' average colour there.
#'
#' @param grob A grob, or a list of grobs, drawn into the tile (their `0..1` npc
#'   coordinates map to the tile, painted in order).
#' @param width,height Size of one tile cell (default `0.1` npc).
#' @param x,y Cell centre (default centred).
#' @param units Coordinate system for the geometry; see [linear_gradient()].
#' @param extend Tiling mode: `"repeat"` (default), `"reflect"`, or `"pad"`.
#'   (SVG renders all modes as `repeat`.)
#' @return A `vellum_pattern` object, suitable for `vl_gpar(fill = ...)`.
#' @examples
#' dots <- circle_grob(r = 0.25, gp = vl_gpar(fill = "white", col = NA))
#' vl_pattern(dots, width = 0.08, height = 0.08)
#' @export
vl_pattern <- function(grob, width = 0.1, height = 0.1, x = 0.5, y = 0.5,
                    units = "npc", extend = "repeat") {
  units <- match.arg(units, .coord_units)
  extend <- match.arg(extend, .gradient_extend)
  if (!all(is.finite(c(width, height, x, y)))) {
    cli::cli_abort("Pattern geometry must be finite.")
  }
  structure(
    list(grob = grob, width = width, height = height, x = x, y = y,
         units = units, extend = extend),
    class = "vellum_pattern"
  )
}

#' @export
print.vellum_pattern <- function(x, ...) {
  cli::cli_text("<vellum_pattern> cell {x$width} x {x$height} {.val {x$units}}, extend = {.val {x$extend}}")
  invisible(x)
}

# Render the pattern's tile grob to RGBA bytes and package the cell geometry.
# `scene` is the backend Scene currently being compiled (for dpi + page size).
.encode_pattern <- function(p, scene) {
  if (is.null(scene)) {
    cli::cli_abort("A pattern fill can only be used inside a scene being rendered.")
  }
  dpi <- scene$dpi()
  page <- scene$dim() # c(width_px, height_px)
  # Tile resolution. Absolute units give physical px directly; for npc/native we
  # use ONE reference dimension for both axes so the tile's aspect ratio equals
  # width:height. The backend then scales that tile into the cell resolved
  # against the actual viewport (which may be non-square) -- so the only stretch
  # is the genuine viewport aspect, not the page aspect.
  ref <- min(page)
  tw <- max(1L, as.integer(round(.paint_len_px(p$width, p$units, ref, dpi))))
  th <- max(1L, as.integer(round(.paint_len_px(p$height, p$units, ref, dpi))))
  tile <- Scene$new(tw / dpi, th / dpi, dpi, c(0L, 0L, 0L, 0L))
  nodes <- if (inherits(p$grob, "S7_object")) list(p$grob) else as.list(p$grob)
  for (nd in nodes) compile(nd, tile)
  list(
    kind = "pattern",
    tile = tile$rgba(),
    tw = tile$dim()[1],
    th = tile$dim()[2],
    coords = as.double(c(p$x, p$y, p$width, p$height)),
    units = p$units,
    extend = p$extend
  )
}

#' Masks
#'
#' Wrap a grob (or list of grobs) as a mask for `vl_viewport(mask = ...)`. The mask
#' content is rendered to an isolated layer; its coverage then modulates the
#' visibility of the viewport's contents.
#'
#' @param grob A grob, or a list of grobs, drawn in the masked viewport's
#'   coordinate system.
#' @param type `"alpha"` (default) uses the mask's opacity as coverage;
#'   `"luminance"` uses its brightness (white shows, black hides).
#' @return A `vellum_mask` object.
#' @examples
#' as_mask(circle_grob(r = 0.4, gp = vl_gpar(fill = "white", col = NA)))
#' @export
as_mask <- function(grob, type = c("alpha", "luminance")) {
  type <- match.arg(type)
  structure(list(grobs = .as_grob_list(grob), type = type), class = "vellum_mask")
}

#' @export
print.vellum_mask <- function(x, ...) {
  cli::cli_text("<vellum_mask> type = {.val {x$type}}, {length(x$grobs)} grob{?s}")
  invisible(x)
}

# A grob or list of grobs -> a flat list of grobs.
.as_grob_list <- function(x) {
  if (inherits(x, "S7_object")) list(x) else as.list(x)
}

# Normalize a viewport `mask` (a vellum_mask, or a bare grob/list defaulting to
# alpha) to list(type_code, grobs). type code: alpha = 0, luminance = 1.
.normalize_mask <- function(m) {
  if (inherits(m, "vellum_mask")) {
    list(code = if (m$type == "luminance") 1L else 0L, grobs = m$grobs)
  } else {
    list(code = 0L, grobs = .as_grob_list(m))
  }
}

# --- stroke style encoding (lty / lineend / linejoin / linemitre) -----------

# Standard R dash patterns as on/off nibble lengths (scaled by lwd in Rust).
.lty_patterns <- list(
  blank = numeric(0), solid = numeric(0),
  dashed = c(4, 4), dotted = c(1, 3), dotdash = c(1, 3, 4, 3),
  longdash = c(7, 3), twodash = c(2, 2, 6, 2)
)
.lty_names <- c("blank", "solid", "dashed", "dotted", "dotdash", "longdash", "twodash") # codes 0:6
.lineend_codes <- c(round = 0L, butt = 1L, square = 2L)
.linejoin_codes <- c(round = 0L, mitre = 1L, miter = 1L, bevel = 2L)

# lty -> a value the backend decodes: NULL (inherit), numeric(0) (solid),
# NA_real_ (blank = no line), or numeric dash nibbles.
.encode_lty <- function(lty) {
  if (is.null(lty)) {
    return(NULL)
  }
  if (is.numeric(lty)) {
    if (length(lty) == 1L) {
      if (is.na(lty)) {
        return(NA_real_) # blank
      }
      nm <- .lty_names[as.integer(lty) + 1L]
      if (!is.na(nm) && nm == "blank") {
        return(NA_real_)
      }
      return(if (is.na(nm)) numeric(0) else .lty_patterns[[nm]])
    }
    return(as.double(lty)) # explicit on/off lengths
  }
  if (is.character(lty)) {
    nm <- lty[1]
    if (identical(nm, "blank")) {
      return(NA_real_)
    }
    if (!is.null(.lty_patterns[[nm]])) {
      return(.lty_patterns[[nm]])
    }
    v <- strtoi(strsplit(nm, "")[[1]], base = 16L) # hex dash string, e.g. "44"
    if (length(v) == 0L || anyNA(v)) {
      cli::cli_abort("Invalid {.arg lty} {.val {nm}}.")
    }
    return(as.double(v))
  }
  cli::cli_abort("{.arg lty} must be a name, code, hex string, or numeric vector.")
}

.encode_code <- function(x, table, arg) {
  if (is.null(x)) {
    return(NULL)
  }
  if (is.numeric(x)) {
    v <- as.integer(x)
    ok <- unique(unname(table))
    if (any(is.na(v)) || !all(v %in% ok)) {
      cli::cli_abort(c(
        "{.arg {arg}} code must be one of {.val {ok}}.",
        i = "Or use a name: {.or {names(table)}}."
      ))
    }
    return(v)
  }
  code <- table[match.arg(as.character(x), names(table))]
  unname(as.integer(code))
}

# Pack a gpar's stroke style into a list for the backend, or NULL if all inherit.
.encode_stroke <- function(gp) {
  lty <- .encode_lty(gp@lty)
  lineend <- .encode_code(gp@lineend, .lineend_codes, "lineend")
  linejoin <- .encode_code(gp@linejoin, .linejoin_codes, "linejoin")
  linemitre <- if (is.null(gp@linemitre)) NULL else as.double(gp@linemitre)
  if (is.null(lty) && is.null(lineend) && is.null(linejoin) && is.null(linemitre)) {
    return(NULL)
  }
  list(lty = lty, lineend = lineend, linejoin = linejoin, linemitre = linemitre)
}

# A length resolved to device pixels for tile sizing. npc/native are taken
# against the page extent `total_px`; absolute units use the dpi.
.paint_len_px <- function(value, units, total_px, dpi) {
  switch(units,
    npc = value * total_px,
    native = value * total_px,
    mm = value / 25.4 * dpi,
    `in` = value * dpi,
    pt = value / 72 * dpi,
    value * total_px
  )
}
