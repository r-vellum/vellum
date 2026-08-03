#' Units of measurement
#'
#' A `unit` is a vectorised `(value, unit)` pair used for coordinates and sizes.
#' Each element carries its own unit, so a single `unit` vector can mix
#' coordinate systems and a primitive can use different units on the x and y
#' axes (e.g. `x` in `"native"`, `y` in `"npc"`).
#'
#' Supported units:
#' * `"npc"` — normalised parent coordinates (0 = bottom/left, 1 = top/right)
#' * `"native"` — the enclosing viewport's `xscale`/`yscale`
#' * `"mm"`, `"cm"`, `"in"`, `"pt"` — absolute lengths
#' * `"char"`, `"line"` — font-relative (need `fontsize`/`lineheight` via `data`)
#' * `"strwidth"`, `"strheight"` — size of a string (need `label` via `data`)
#'
#' Font- and string-relative units are resolved to absolute millimetres at
#' construction (text metrics are available device-independently), so a stored
#' `unit` only ever holds one of the core backend units.
#'
#' Arithmetic: `+` and `-` combine two units of the *same* code, or two
#' *absolute* units (`"mm"`/`"cm"`/`"in"`/`"pt"`), which resolve to `"mm"`
#' immediately (e.g. `vl_unit(10, "mm") + vl_unit(1, "in")` is `35.4mm`). A position
#' unit (`"npc"`/`"native"`) plus an absolute unit forms a **compound** unit — a
#' data/panel anchor plus an exact absolute offset — e.g.
#' `vl_unit(1, "native") + vl_unit(2, "mm")` is `1native+2mm`: it resolves to the
#' native position shifted right by exactly 2 mm at render, at any scale or
#' aspect. Mixing two *different* position bases (e.g. `"npc"` and `"native"`)
#' still errors, as it cannot be reduced to one unit. `unit * scalar` scales the
#' base value and the offset together.
#'
#' @param values Numeric vector of magnitudes.
#' @param units Character vector of unit names, recycled against `values`.
#' @param data Optional list supplying context for derived units:
#'   `label`, `fontfamily`, `fontface`, `fontsize`, `lineheight`.
#' @return A `unit` vector.
#' @examples
#' vl_unit(1:3, "native")
#' vl_unit(c(0.5, 1), c("npc", "in"))
#' @export
vl_unit <- function(values, units = "npc", data = NULL) {
  values <- vctrs::vec_cast(values, double())
  if (length(values) == 0L) {
    return(new_unit())
  }
  units <- vctrs::vec_recycle(as.character(units), length(values))

  known <- c(
    names(.unit_codes),
    "cm",
    "char",
    "line",
    "strwidth",
    "strheight",
    "grobwidth",
    "grobheight"
  )
  bad <- setdiff(unique(units), known)
  if (length(bad)) {
    cli::cli_abort("Unknown unit{?s}: {.val {bad}}.")
  }
  # "null" (flexible) units are allowed in the type but only meaningful in
  # layouts; `.coord()` rejects them for primitive coordinates.

  out_val <- values
  out_code <- integer(length(values))
  core <- units %in% names(.unit_codes)
  out_code[core] <- unname(.unit_codes[units[core]])

  derived <- !core
  if (any(derived)) {
    out_val[derived] <- .resolve_to_mm(values[derived], units[derived], data)
    out_code[derived] <- .unit_codes[["mm"]]
  }
  new_unit(out_val, out_code)
}

# Integer unit codes. These are part of the R<->Rust ABI: they MUST match
# `Unit::from_code` in `src/rust/src/units.rs`.
.unit_codes <- c(npc = 0L, native = 1L, mm = 2L, `in` = 3L, pt = 4L, null = 5L)

# The units a primitive coordinate / gradient / pattern may use: every code
# above except the layout-only "null". Single source of truth for that whitelist
# (used by paint.R). Derived units (cm/char/strwidth/...) resolve to these.
.coord_units <- setdiff(names(.unit_codes), "null")

# A unit vector is a vctrs record of three parallel fields: `value` (the base
# magnitude), `unit` (the base code, see `.unit_codes`), and `offset` — an
# absolute offset in millimetres added at render (the compound `native + mm` /
# `npc + mm` unit). `offset` is 0 for an ordinary single-code unit; it is
# produced only by `base ± absolute` arithmetic (see `vec_arith`).
new_unit <- function(value = double(), unit = integer(), offset = NULL) {
  if (is.null(offset)) {
    offset <- rep(0, length(value))
  }
  vctrs::new_rcrd(
    list(value = value, unit = unit, offset = offset),
    class = "vellum_unit"
  )
}

#' @rdname vl_unit
#' @param x An object.
#' @export
is_unit <- function(x) inherits(x, "vellum_unit")

#' Convert a unit to another unit, in a scene's context
#'
#' The counterpart to grid's `convertWidth()`/`convertHeight()`/`convertX()`/
#' `convertY()`: resolve a [vl_unit()] vector to a plain number in some other
#' unit. [why_size()] explains a *named node's* resolved size and
#' [scene_model()] reports resolved boxes for *keyed elements*; this answers the
#' remaining question — "how big is this particular unit, here?" — which a layer
#' built on vellum needs whenever it has to size something itself.
#'
#' Absolute units (`mm`, `cm`, `in`, `pt`) convert with no context, so `scene`
#' may be omitted. Relative units (`npc`, `native`) need to know the region they
#' are relative to, and therefore need a `scene` — and, for anything other than
#' the whole page, the `name` of a viewport in it.
#'
#' Where grid uses four functions, this uses two arguments: `axis` picks the
#' x or y extent, and `what` distinguishes a **length** from a **position**.
#' They differ only for `native`, and only when the scale does not start at
#' zero: on `xscale = c(10, 20)`, `unit(12, "native")` is *two tenths* of the
#' width as a position, but *twelve tenths* as a length.
#'
#' @param u A [vl_unit()] vector (or a bare numeric, read as `npc`).
#' @param to Target unit: `"mm"` (default), `"cm"`, `"in"`, `"pt"`, `"px"`,
#'   `"npc"`, or `"native"`.
#' @param scene A [vl_scene()] (or anything with an [as_vellum_scene()] method)
#'   giving the context. Required unless every input *and* `to` is absolute.
#' @param name Name of the viewport to resolve against. `NULL` (default) uses
#'   the whole page.
#' @param axis Which extent relative units refer to: `"x"` (default) or `"y"`.
#' @param what `"length"` (default) for a size, `"position"` for a coordinate.
#'   Only affects `native`.
#' @return A numeric vector the same length as `u`, in `to` units.
#' @seealso [why_size()], [scene_model()], [vl_unit()]
#' @examples
#' s <- vl_scene(4, 3, dpi = 100)
#' vl_convert(vl_unit(1, "in"), "mm") # absolute: no scene needed
#' vl_convert(vl_unit(0.5, "npc"), "mm", s) # half the page width
#' vl_convert(vl_unit(0.5, "npc"), "mm", s, axis = "y")
#'
#' # A named viewport, and the length/position distinction on a shifted scale.
#' s2 <- s |> push(vl_viewport(width = 0.5, xscale = c(10, 20), name = "panel"))
#' vl_convert(vl_unit(12, "native"), "mm", s2, name = "panel")
#' vl_convert(vl_unit(12, "native"), "mm", s2, name = "panel", what = "position")
#' @export
vl_convert <- function(
  u,
  to = "mm",
  scene = NULL,
  name = NULL,
  axis = c("x", "y"),
  what = c("length", "position")
) {
  axis <- match.arg(axis)
  what <- match.arg(what)
  to <- match.arg(to, c("mm", "cm", "in", "pt", "px", "npc", "native"))
  if (!is_unit(u)) {
    u <- as_unit(u)
  }
  if (vctrs::vec_size(u) == 0L) {
    return(numeric(0))
  }
  p <- .unit_parts(u)
  null_code <- .unit_codes[["null"]]
  if (any(!is.na(p$code) & p$code == null_code)) {
    cli::cli_abort(c(
      "Can't convert a {.val null} unit.",
      i = "{.val null} is a flexible layout weight, not a length; it only has a size once a layout solves."
    ))
  }
  # Relative input, or a relative/device target, needs a resolved region.
  needs_ctx <- !all(is.na(p$code)) || to %in% c("npc", "native", "px")
  ctx <- if (needs_ctx) .convert_context(scene, name, axis) else NULL

  npc_code <- .unit_codes[["npc"]]
  native_code <- .unit_codes[["native"]]
  # Everything lands in mm first (`p$off` is already mm), then converts out.
  rel <- rep(0, length(p$pos))
  is_npc <- !is.na(p$code) & p$code == npc_code
  is_nat <- !is.na(p$code) & p$code == native_code
  rel[is_npc] <- p$pos[is_npc] * ctx$extent_mm
  if (any(is_nat)) {
    span <- ctx$hi - ctx$lo
    if (!is.finite(span) || span == 0) {
      cli::cli_abort(
        "Can't convert {.val native} units: the viewport's {axis}-scale is degenerate."
      )
    }
    v <- p$pos[is_nat]
    frac <- if (identical(what, "position")) (v - ctx$lo) / span else v / span
    rel[is_nat] <- frac * ctx$extent_mm
  }
  mm <- rel + p$off

  switch(
    to,
    mm = mm,
    cm = mm / 10,
    `in` = mm / 25.4,
    pt = mm / 25.4 * 72,
    px = mm / 25.4 * ctx$dpi,
    npc = mm / ctx$extent_mm,
    native = {
      span <- ctx$hi - ctx$lo
      f <- mm / ctx$extent_mm * span
      if (identical(what, "position")) f + ctx$lo else f
    }
  )
}

# Resolve the region relative units are measured against: the whole page, or a
# named viewport in the scene. Returns its extent along `axis` in mm, that axis'
# scale, and the scene dpi.
.convert_context <- function(scene, name, axis) {
  if (is.null(scene)) {
    cli::cli_abort(c(
      "{.arg scene} is required to convert relative units.",
      i = "{.val npc}/{.val native} have no size until a scene gives them one; {.val mm}/{.val cm}/{.val in}/{.val pt} convert without one."
    ))
  }
  scene <- as_vellum_scene(scene)
  if (is.null(name)) {
    inches <- if (identical(axis, "x")) {
      .to_inches(scene@width)
    } else {
      .to_inches(scene@height)
    }
    # The page's implicit root viewport spans 0..1 in native.
    return(list(extent_mm = inches * 25.4, lo = 0, hi = 1, dpi = scene@dpi))
  }
  cap <- .capture_geometry(scene)
  item <- Find(function(it) identical(it$name, name), cap$items)
  if (is.null(item)) {
    cli::cli_abort(c(
      "No viewport named {.val {name}} in the scene.",
      i = "Named viewports in this scene: {.or {.val {Filter(Negate(is.null), lapply(cap$items, `[[`, \"name\"))}}}."
    ))
  }
  i <- match(item$id, cap$geom$id)
  px <- if (identical(axis, "x")) cap$geom$w_px[i] else cap$geom$h_px[i]
  sc <- if (identical(axis, "x")) item$vp@xscale else item$vp@yscale
  list(extent_mm = px / cap$dpi * 25.4, lo = sc[1], hi = sc[2], dpi = cap$dpi)
}

# Coerce a bare numeric to a unit with `default` units; pass units through.
as_unit <- function(x, default = "npc") {
  if (is_unit(x)) x else vl_unit(x, default)
}

# Resolve derived units (cm/char/line/strwidth/strheight/grobwidth/grobheight)
# to millimetres. `data` is a list (label + font fields) for the string/font
# kinds, or a grob (or `list(grob =)`) for grobwidth/grobheight.
.resolve_to_mm <- function(values, units, data) {
  is_grob <- !is.null(data) && S7::S7_inherits(data, grob)
  # `cex` multiplies `fontsize` (grid semantics), so `char`/`line`/`strwidth`/
  # `strheight` all scale with it -- see `.gp_fontsize()`.
  fontsize <- if (is_grob) {
    12
  } else {
    (data$fontsize %||% 12)[1] * (data$cex %||% 1)[1]
  }
  lineheight <- if (is_grob) 1.2 else (data$lineheight %||% 1.2)[1]
  family <- if (is_grob) "" else (data$fontfamily %||% "")[1]
  face <- if (is_grob) "plain" else (data$fontface %||% "plain")[1]
  # Measure the grob once (its extent is shared across all grobwidth/grobheight
  # values), eagerly to device-independent mm.
  ext <- if (any(units %in% c("grobwidth", "grobheight"))) {
    g <- if (is_grob) data else data$grob
    if (is.null(g) || !S7::S7_inherits(g, grob)) {
      cli::cli_abort(
        '{.val grobwidth}/{.val grobheight} units need a grob in {.arg data}.'
      )
    }
    .grob_extent(g)
  } else {
    NULL
  }
  vapply(
    seq_along(values),
    function(i) {
      v <- values[i]
      switch(
        units[i],
        cm = v * 10,
        char = v * fontsize / 72 * 25.4,
        line = v * fontsize * lineheight / 72 * 25.4,
        strwidth = {
          if (is.null(data$label)) {
            cli::cli_abort(
              '{.val strwidth} units need a {.arg label} in {.arg data}.'
            )
          }
          v * vl_strwidth(data$label, family, face, fontsize, unit = "mm")
        },
        strheight = {
          if (is.null(data$label)) {
            cli::cli_abort(
              '{.val strheight} units need a {.arg label} in {.arg data}.'
            )
          }
          v * vl_strheight(data$label, family, face, fontsize, unit = "mm")
        },
        grobwidth = v * ext[1],
        grobheight = v * ext[2]
      )
    },
    double(1)
  )
}

# --- vctrs machinery --------------------------------------------------------

#' @export
#' @method format vellum_unit
format.vellum_unit <- function(x, ...) {
  v <- vctrs::field(x, "value")
  u <- names(.unit_codes)[match(vctrs::field(x, "unit"), .unit_codes)]
  off <- vctrs::field(x, "offset")
  base <- paste0(format(v, trim = TRUE, ...), u)
  # A compound unit shows its absolute mm offset, e.g. "1native+2mm".
  has_off <- !is.na(off) & off != 0
  sign <- ifelse(off >= 0, "+", "-")
  base[has_off] <- paste0(
    base[has_off],
    sign[has_off],
    format(abs(off[has_off]), trim = TRUE, ...),
    "mm"
  )
  base
}

#' @export
#' @method vec_ptype_abbr vellum_unit
vec_ptype_abbr.vellum_unit <- function(x, ...) "unit"

# Double-dispatch coercion methods. Registered in `.onLoad` via
# `vctrs::s3_register()` (R/zzz.R) — the intermediate generic they belong to
# (`vec_ptype2.vellum_unit`) does not exist as a standalone object, so a plain
# NAMESPACE `S3method()` directive cannot resolve it.
vec_ptype2.vellum_unit.vellum_unit <- function(x, y, ...) new_unit()
vec_cast.vellum_unit.vellum_unit <- function(x, to, ...) x

#' @export
#' @method vec_arith vellum_unit
vec_arith.vellum_unit <- function(op, x, y, ...) {
  UseMethod("vec_arith.vellum_unit", y)
}
#' @export
#' @method vec_arith.vellum_unit default
vec_arith.vellum_unit.default <- function(op, x, y, ...) {
  vctrs::stop_incompatible_op(op, x, y)
}
#' @export
#' @method vec_arith.vellum_unit numeric
vec_arith.vellum_unit.numeric <- function(op, x, y, ...) {
  # Scaling multiplies the base value *and* the absolute offset, so
  # `2 * (vl_unit(1, "native") + vl_unit(3, "mm"))` is `vl_unit(2, "native") + 6 mm`.
  switch(
    op,
    "*" = new_unit(
      vctrs::field(x, "value") * y,
      vctrs::field(x, "unit"),
      vctrs::field(x, "offset") * y
    ),
    "/" = new_unit(
      vctrs::field(x, "value") / y,
      vctrs::field(x, "unit"),
      vctrs::field(x, "offset") / y
    ),
    "+" = ,
    "-" = .abort_unit_scalar(op),
    vctrs::stop_incompatible_op(op, x, y)
  )
}
#' @export
#' @method vec_arith.numeric vellum_unit
vec_arith.numeric.vellum_unit <- function(op, x, y, ...) {
  switch(
    op,
    "*" = new_unit(
      x * vctrs::field(y, "value"),
      vctrs::field(y, "unit"),
      x * vctrs::field(y, "offset")
    ),
    "+" = ,
    "-" = .abort_unit_scalar(op),
    vctrs::stop_incompatible_op(op, x, y)
  )
}
# `+`/`-` between a unit and a bare number is ambiguous (which unit is the scalar
# in?), so it errors — but with a hint, not a bare vctrs incompatibility message.
.abort_unit_scalar <- function(op) {
  cli::cli_abort(c(
    "Can't {op} a {.cls unit} and a bare number.",
    i = "Wrap the number in {.fn unit} (e.g. {.code vl_unit(5, \"mm\") {op} vl_unit(3, \"mm\")}), or scale with {.code *}."
  ))
}
#' @export
#' @method vec_arith.vellum_unit vellum_unit
# Decompose a unit vector into (position value, position code, absolute mm
# offset), element-wise. A position unit (npc/native) contributes its value and
# code and carries its offset; an absolute unit (mm/in/pt) has no position code
# (NA) and folds its magnitude + any offset into the mm offset. This is the
# normal form the compound arithmetic combines.
.unit_parts <- function(u) {
  v <- vctrs::field(u, "value")
  code <- vctrs::field(u, "unit")
  off <- vctrs::field(u, "offset")
  abs_codes <- unname(.unit_codes[c("mm", "in", "pt")])
  is_abs <- code %in% abs_codes
  list(
    pos = ifelse(is_abs, 0, v),
    code = ifelse(is_abs, NA_integer_, code),
    off = ifelse(is_abs, .abs_to_mm(v, code) + off, off)
  )
}
#' @export
#' @method vec_arith.vellum_unit vellum_unit
vec_arith.vellum_unit.vellum_unit <- function(op, x, y, ...) {
  if (!op %in% c("+", "-")) {
    vctrs::stop_incompatible_op(op, x, y)
  }
  rc <- vctrs::vec_recycle_common(x, y)
  x <- rc[[1L]]
  y <- rc[[2L]]
  s <- if (op == "+") 1 else -1
  xu <- vctrs::field(x, "unit")
  yu <- vctrs::field(y, "unit")
  if (identical(xu, yu)) {
    # Same code on both sides: add/subtract values (and offsets), keep the code.
    return(new_unit(
      vctrs::field(x, "value") + s * vctrs::field(y, "value"),
      xu,
      vctrs::field(x, "offset") + s * vctrs::field(y, "offset")
    ))
  }
  ax <- .unit_parts(x)
  ay <- .unit_parts(y)

  # The result's position base: whichever side has one. Two *different* position
  # bases (npc vs native) can't be reduced to one unit and error; a position base
  # combined with an absolute unit becomes a compound `base + mm` (B1).
  conflict <- !is.na(ax$code) & !is.na(ay$code) & ax$code != ay$code
  if (any(conflict)) {
    cli::cli_abort(c(
      "Can only add or subtract {.cls unit}s with the same base ({.val npc}/{.val native}), optionally offset by an absolute unit ({.val mm}/{.val cm}/{.val in}/{.val pt}).",
      i = "A mix of two different position bases (e.g. {.val npc} and {.val native}) can't be reduced to one unit."
    ))
  }
  code <- ifelse(is.na(ax$code), ay$code, ax$code)
  pos <- ax$pos + s * ay$pos
  off <- ax$off + s * ay$off
  # No position base on either side => a pure absolute result, resolved to mm
  # (the classic `vl_unit(10,"mm") + vl_unit(1,"in")` case, unchanged).
  both_abs <- is.na(code)
  new_unit(
    ifelse(both_abs, off, pos),
    as.integer(ifelse(both_abs, .unit_codes[["mm"]], code)),
    ifelse(both_abs, 0, off)
  )
}

# Convert an absolute unit vector (codes mm/in/pt) to millimetres, element-wise.
.abs_to_mm <- function(value, code) {
  if (length(value) && !all(is.finite(value))) {
    cli::cli_abort(
      "Can't resolve a {.cls unit} with a non-finite value ({.val NA}/{.val NaN}/{.val Inf})."
    )
  }
  factor <- rep(NA_real_, length(value))
  factor[code == .unit_codes[["mm"]]] <- 1
  factor[code == .unit_codes[["in"]]] <- 25.4
  factor[code == .unit_codes[["pt"]]] <- 25.4 / 72
  value * factor
}
#' @export
#' @method vec_arith.vellum_unit MISSING
vec_arith.vellum_unit.MISSING <- function(op, x, y, ...) {
  switch(
    op,
    "-" = new_unit(-vctrs::field(x, "value"), vctrs::field(x, "unit")),
    "+" = x,
    vctrs::stop_incompatible_op(op, x, y)
  )
}

# --- coordinate encoding (the only unit <-> backend seam) -------------------

# Number of coordinates in `v` (a unit vector or bare numeric).
.vsize <- function(v) if (is_unit(v)) vctrs::vec_size(v) else length(v)

# Common length for two coordinate vectors, allowing length-1 recycling.
.coord_n <- function(x, y) {
  nx <- .vsize(x)
  ny <- .vsize(y)
  n <- max(nx, ny)
  if (!(nx %in% c(1L, n) && ny %in% c(1L, n))) {
    stop("`x` and `y` must have the same length", call. = FALSE)
  }
  n
}

# Encode `v` to list(value = double[n], code = int[n]) in `default` units if `v`
# is a bare numeric. Recycles to `n` when given.
.coord <- function(v, default = "npc", n = NULL) {
  if (is_unit(v)) {
    val <- vctrs::field(v, "value")
    code <- vctrs::field(v, "unit")
    off <- vctrs::field(v, "offset")
  } else {
    val <- as.double(v)
    code <- rep(.unit_codes[[default]], length(val))
    off <- rep(0, length(val))
  }
  if (any(code == .unit_codes[["null"]])) {
    stop(
      "`null` units are only valid in layouts, not coordinates",
      call. = FALSE
    )
  }
  if (!is.null(n)) {
    val <- vctrs::vec_recycle(val, n)
    code <- vctrs::vec_recycle(code, n)
    off <- vctrs::vec_recycle(off, n)
  }
  list(value = val, code = as.integer(code), offset = as.double(off))
}
