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
linear_gradient <- function(
  colours,
  stops = NULL,
  x1 = 0,
  y1 = 0,
  x2 = 1,
  y2 = 0,
  units = "npc",
  extend = "pad",
  interpolation = "srgb"
) {
  .new_gradient(
    "linear",
    colours,
    stops,
    c(x1, y1, x2, y2),
    units,
    extend,
    interpolation
  )
}

#' @rdname gradients
#' @export
radial_gradient <- function(
  colours,
  stops = NULL,
  cx = 0.5,
  cy = 0.5,
  r = 0.5,
  fx = cx,
  fy = cy,
  fr = 0,
  units = "npc",
  extend = "pad",
  interpolation = "srgb"
) {
  if (!is.numeric(r) || !is.numeric(fr) || anyNA(c(r, fr)) || r < 0 || fr < 0) {
    cli::cli_abort(
      "Radial gradient radii {.arg r}/{.arg fr} must be non-negative."
    )
  }
  .new_gradient(
    "radial",
    colours,
    stops,
    c(cx, cy, r, fx, fy, fr),
    units,
    extend,
    interpolation
  )
}

.gradient_extend <- c("pad", "repeat", "reflect")
.gradient_interpolation <- c("srgb", "oklab", "oklch")

.new_gradient <- function(
  kind,
  colours,
  stops,
  coords,
  units,
  extend,
  interpolation = "srgb"
) {
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
  cli::cli_text(
    "<vellum_gradient: {x$kind}> {length(x$colours)} stop{?s}, units = {.val {x$units}}"
  )
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
  if (inherits(x, "vellum_hatch")) {
    return(.encode_hatch(x, scene))
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
#' scene's resolution) and embedded on every backend: PNG raster, SVG `<image>`
#' in a `<pattern>`, and a PDF tiling pattern with the tile as an embedded image
#' XObject. Only a degenerate tile or cell size fails, leaving the shape unfilled
#' with a degrade warning.
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
vl_pattern <- function(
  grob,
  width = 0.1,
  height = 0.1,
  x = 0.5,
  y = 0.5,
  units = "npc",
  extend = "repeat"
) {
  units <- match.arg(units, .coord_units)
  extend <- match.arg(extend, .gradient_extend)
  if (!all(is.finite(c(width, height, x, y)))) {
    cli::cli_abort("Pattern geometry must be finite.")
  }
  structure(
    list(
      grob = grob,
      width = width,
      height = height,
      x = x,
      y = y,
      units = units,
      extend = extend
    ),
    class = "vellum_pattern"
  )
}

#' @export
print.vellum_pattern <- function(x, ...) {
  cli::cli_text(
    "<vellum_pattern> cell {x$width} x {x$height} {.val {x$units}}, extend = {.val {x$extend}}"
  )
  invisible(x)
}

# Render the pattern's tile grob to RGBA bytes and package the cell geometry.
# `scene` is the backend Scene currently being compiled (for dpi + page size).
.encode_pattern <- function(p, scene) {
  if (is.null(scene)) {
    cli::cli_abort(
      "A pattern fill can only be used inside a scene being rendered."
    )
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
  for (nd in nodes) {
    compile(nd, tile)
  }
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
  structure(
    list(grobs = .as_grob_list(grob), type = type),
    class = "vellum_mask"
  )
}

#' @export
print.vellum_mask <- function(x, ...) {
  cli::cli_text(
    "<vellum_mask> type = {.val {x$type}}, {length(x$grobs)} grob{?s}"
  )
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
  blank = numeric(0),
  solid = numeric(0),
  dashed = c(4, 4),
  dotted = c(1, 3),
  dotdash = c(1, 3, 4, 3),
  longdash = c(7, 3),
  twodash = c(2, 2, 6, 2)
)
.lty_names <- c(
  "blank",
  "solid",
  "dashed",
  "dotted",
  "dotdash",
  "longdash",
  "twodash"
) # codes 0:6
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
  cli::cli_abort(
    "{.arg lty} must be a name, code, hex string, or numeric vector."
  )
}

.encode_code <- function(x, table, arg) {
  if (is.null(x)) {
    return(NULL)
  }
  if (is.numeric(x)) {
    v <- as.integer(x)
    ok <- unique(unname(table))
    if (anyNA(v) || !all(v %in% ok)) {
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
# The stroke sub-record crossing to Rust. `antialias`/`crisp` ride here rather
# than as top-level gpar fields because this list is already folded with
# inheritance on the Rust side, so they cascade for free.
.encode_stroke <- function(gp, scene = NULL) {
  lty <- .encode_lty(gp@lty)
  lineend <- .encode_code(gp@lineend, .lineend_codes, "lineend")
  linejoin <- .encode_code(gp@linejoin, .linejoin_codes, "linejoin")
  linemitre <- if (is.null(gp@linemitre)) NULL else as.double(gp@linemitre)
  antialias <- .encode_flag(gp@antialias, "antialias")
  crisp <- .encode_flag(gp@crisp, "crisp")
  # A gradient handed to `col` strokes with that gradient. It rides the stroke
  # record so it inherits like every other stroke property.
  paint <- if (.is_paint(gp@col)) .encode_paint(gp@col, scene) else NULL
  phase <- if (is.null(gp@dash_phase)) NULL else as.double(gp@dash_phase)
  if (
    is.null(lty) &&
      is.null(lineend) &&
      is.null(linejoin) &&
      is.null(linemitre) &&
      is.null(antialias) &&
      is.null(crisp) &&
      is.null(paint) &&
      is.null(phase)
  ) {
    return(NULL)
  }
  list(
    lty = lty,
    lineend = lineend,
    linejoin = linejoin,
    linemitre = linemitre,
    antialias = antialias,
    crisp = crisp,
    paint = paint,
    phase = phase
  )
}

# TRUE for a gradient/pattern object (as opposed to a colour).
.is_paint <- function(x) {
  inherits(x, "vellum_gradient") ||
    inherits(x, "vellum_pattern") ||
    inherits(x, "vellum_hatch")
}

# A tri-state flag: NULL inherits, TRUE/FALSE set.
.encode_flag <- function(x, arg) {
  if (is.null(x)) {
    return(NULL)
  }
  if (length(x) != 1L || is.na(x) || !is.logical(x)) {
    cli::cli_abort(
      "{.arg {arg}} must be {.val TRUE}, {.val FALSE}, or {.val NULL} to inherit."
    )
  }
  x
}

# A length resolved to device pixels for tile sizing. npc/native are taken
# against the page extent `total_px`; absolute units use the dpi.
.paint_len_px <- function(value, units, total_px, dpi) {
  switch(
    units,
    npc = value * total_px,
    native = value * total_px,
    mm = value / 25.4 * dpi,
    `in` = value * dpi,
    pt = value / 72 * dpi,
    value * total_px
  )
}

#' Drop shadow for a viewport group
#'
#' Describes a shadow cast by everything drawn inside a [vl_viewport()]: the
#' group's own silhouette, tinted, blurred and offset, painted underneath it.
#' Because it is a *group* effect, overlapping shapes inside the viewport cast
#' one shadow together rather than each casting its own onto the others.
#'
#' @param dx,dy Offset in points; positive `dy` moves the shadow down.
#' @param blur Blur radius in points. `0` gives a hard offset silhouette.
#' @param col Shadow colour; usually a translucent black.
#' @return A `vellum_shadow` object, for `vl_viewport(shadow = )`.
#' @seealso [vl_viewport()]
#' @examples
#' vl_scene(3, 2) |>
#'   push(vl_viewport(width = 0.6, height = 0.6, shadow = vl_shadow())) |>
#'   draw(circle_grob(gp = vl_gpar(fill = "steelblue", col = NA))) |>
#'   pop()
#' @export
vl_shadow <- function(dx = 2, dy = 2, blur = 3, col = "#00000059") {
  num <- function(v, arg) {
    if (length(v) != 1L || is.na(v) || !is.numeric(v)) {
      cli::cli_abort("{.arg {arg}} must be a single number.")
    }
    as.numeric(v)
  }
  if (num(blur, "blur") < 0) {
    cli::cli_abort("{.arg blur} must be non-negative.")
  }
  structure(
    list(
      dx = num(dx, "dx"),
      dy = num(dy, "dy"),
      blur = num(blur, "blur"),
      col = col
    ),
    class = "vellum_shadow"
  )
}

#' @export
print.vellum_shadow <- function(x, ...) {
  cli::cli_text(
    "{.cls vellum_shadow} dx={x$dx} dy={x$dy} blur={x$blur} col={.val {x$col}}"
  )
  invisible(x)
}

# Encode a shadow for the backend: c(dx, dy, blur, r, g, b, a) in device px.
# `NULL` -> numeric(0), which the Rust side reads as "no shadow".
.encode_shadow <- function(shadow, scale) {
  if (is.null(shadow)) {
    return(numeric(0))
  }
  if (!inherits(shadow, "vellum_shadow")) {
    cli::cli_abort("{.arg shadow} must come from {.fn vl_shadow}.")
  }
  rgba <- .col2rgba(shadow$col)
  if (is.null(rgba)) {
    return(numeric(0))
  }
  c(shadow$dx * scale, shadow$dy * scale, shadow$blur * scale, as.numeric(rgba))
}

# The single colour that best stands in for a paint, for consumers that cannot
# use a ramp (text, markers). The first stop, or black if there is none.
.paint_first_colour <- function(x) {
  if (inherits(x, "vellum_gradient") && length(x$colours)) {
    return(x$colours[[1]])
  }
  "black"
}

#' Hatch fill
#'
#' Fills a shape with ruled parallel lines. Unlike [vl_pattern()], which
#' rasterises a tile, a hatch is **geometry**: it stays crisp at any zoom, prints
#' correctly, and survives being converted to greyscale.
#'
#' That last point is the reason to reach for it. A colour encoding that fails
#' for a red/green-blind reader — which [render()]'s `cvd` argument will show you
#' and [vl_lint()] will flag — is fixed by encoding with *texture* as well as
#' hue. Hatching is the standard way to do that.
#'
#' @param angle Direction of the rules, in degrees counter-clockwise from
#'   horizontal. Distinct angles (0, 45, 90, 135) read as distinct categories.
#' @param spacing Distance between rules, in points.
#' @param width Rule width, in points.
#' @param col Rule colour.
#' @param bg Optional background painted behind the rules. `NA` (default) leaves
#'   whatever is underneath showing through.
#' @return A `vellum_hatch` object, usable anywhere a `fill` is.
#' @seealso [vl_pattern()] for a tiled grob, [linear_gradient()], [vl_lint()]
#' @examples
#' vl_scene(3, 2) |>
#'   draw(rect_grob(width = 0.8, height = 0.8, gp = vl_gpar(
#'     fill = vl_hatch(angle = 45, spacing = 4), col = "grey30"
#'   )))
#' @export
vl_hatch <- function(
  angle = 45,
  spacing = 3,
  width = 0.75,
  col = "black",
  bg = NA
) {
  num1 <- function(v, arg) {
    if (length(v) != 1L || is.na(v) || !is.numeric(v)) {
      cli::cli_abort("{.arg {arg}} must be a single number.")
    }
    as.numeric(v)
  }
  spacing <- num1(spacing, "spacing")
  width <- num1(width, "width")
  if (spacing <= 0) {
    cli::cli_abort("{.arg spacing} must be positive.")
  }
  if (width <= 0) {
    cli::cli_abort("{.arg width} must be positive.")
  }
  structure(
    list(
      angle = num1(angle, "angle"),
      spacing = spacing,
      width = width,
      col = col,
      bg = bg
    ),
    class = "vellum_hatch"
  )
}

#' @export
print.vellum_hatch <- function(x, ...) {
  cli::cli_text(
    "{.cls vellum_hatch} {x$angle}deg, spacing {x$spacing}pt, width {x$width}pt, {.val {x$col}}"
  )
  invisible(x)
}

# Encode a hatch for the backend. Spacing/width are points on the R side and
# device px on the Rust side, converted here with the scene dpi -- the same
# convention the text halo uses, so a hatch keeps its proportions at any dpi.
.encode_hatch <- function(h, scene) {
  scale <- if (is.null(scene)) 1 else scene$dpi() / 72
  rgba <- .col2rgba(h$col)
  if (is.null(rgba)) {
    return(NULL)
  }
  list(
    kind = "hatch",
    angle = h$angle,
    spacing = h$spacing * scale,
    width = h$width * scale,
    col = rgba,
    bg = .col2rgba(h$bg)
  )
}
