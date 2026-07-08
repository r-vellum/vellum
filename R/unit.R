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
#' immediately (e.g. `unit(10, "mm") + unit(1, "in")` is `35.4mm`). A position
#' unit (`"npc"`/`"native"`) plus an absolute unit forms a **compound** unit — a
#' data/panel anchor plus an exact absolute offset — e.g.
#' `unit(1, "native") + unit(2, "mm")` is `1native+2mm`: it resolves to the
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
#' unit(1:3, "native")
#' unit(c(0.5, 1), c("npc", "in"))
#' @export
unit <- function(values, units = "npc", data = NULL) {
  values <- vctrs::vec_cast(values, double())
  if (length(values) == 0L) {
    return(new_unit())
  }
  units <- vctrs::vec_recycle(as.character(units), length(values))

  known <- c(names(.unit_codes), "cm", "char", "line", "strwidth", "strheight", "grobwidth", "grobheight")
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

#' @rdname unit
#' @param x An object.
#' @export
is_unit <- function(x) inherits(x, "vellum_unit")

# Coerce a bare numeric to a unit with `default` units; pass units through.
as_unit <- function(x, default = "npc") {
  if (is_unit(x)) x else unit(x, default)
}

# Resolve derived units (cm/char/line/strwidth/strheight/grobwidth/grobheight)
# to millimetres. `data` is a list (label + font fields) for the string/font
# kinds, or a grob (or `list(grob =)`) for grobwidth/grobheight.
.resolve_to_mm <- function(values, units, data) {
  is_grob <- !is.null(data) && S7::S7_inherits(data, grob)
  fontsize <- if (is_grob) 12 else (data$fontsize %||% 12)[1]
  lineheight <- if (is_grob) 1.2 else (data$lineheight %||% 1.2)[1]
  family <- if (is_grob) "" else (data$fontfamily %||% "")[1]
  face <- if (is_grob) "plain" else (data$fontface %||% "plain")[1]
  # Measure the grob once (its extent is shared across all grobwidth/grobheight
  # values), eagerly to device-independent mm.
  ext <- if (any(units %in% c("grobwidth", "grobheight"))) {
    g <- if (is_grob) data else data$grob
    if (is.null(g) || !S7::S7_inherits(g, grob)) {
      cli::cli_abort('{.val grobwidth}/{.val grobheight} units need a grob in {.arg data}.')
    }
    .grob_extent(g)
  } else {
    NULL
  }
  vapply(seq_along(values), function(i) {
    v <- values[i]
    switch(units[i],
      cm = v * 10,
      char = v * fontsize / 72 * 25.4,
      line = v * fontsize * lineheight / 72 * 25.4,
      strwidth = {
        if (is.null(data$label)) cli::cli_abort('{.val strwidth} units need a {.arg label} in {.arg data}.')
        v * vl_strwidth(data$label, family, face, fontsize, unit = "mm")
      },
      strheight = {
        if (is.null(data$label)) cli::cli_abort('{.val strheight} units need a {.arg label} in {.arg data}.')
        v * vl_strheight(data$label, family, face, fontsize, unit = "mm")
      },
      grobwidth = v * ext[1],
      grobheight = v * ext[2]
    )
  }, double(1))
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
    base[has_off], sign[has_off],
    format(abs(off[has_off]), trim = TRUE, ...), "mm"
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
  # `2 * (unit(1, "native") + unit(3, "mm"))` is `unit(2, "native") + 6 mm`.
  switch(op,
    "*" = new_unit(vctrs::field(x, "value") * y, vctrs::field(x, "unit"), vctrs::field(x, "offset") * y),
    "/" = new_unit(vctrs::field(x, "value") / y, vctrs::field(x, "unit"), vctrs::field(x, "offset") / y),
    "+" = ,
    "-" = .abort_unit_scalar(op),
    vctrs::stop_incompatible_op(op, x, y)
  )
}
#' @export
#' @method vec_arith.numeric vellum_unit
vec_arith.numeric.vellum_unit <- function(op, x, y, ...) {
  switch(op,
    "*" = new_unit(x * vctrs::field(y, "value"), vctrs::field(y, "unit"), x * vctrs::field(y, "offset")),
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
    i = "Wrap the number in {.fn unit} (e.g. {.code unit(5, \"mm\") {op} unit(3, \"mm\")}), or scale with {.code *}."
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
  # (the classic `unit(10,"mm") + unit(1,"in")` case, unchanged).
  both_abs <- is.na(code)
  new_unit(
    ifelse(both_abs, off, pos),
    as.integer(ifelse(both_abs, .unit_codes[["mm"]], code)),
    ifelse(both_abs, 0, off)
  )
}

# Convert an absolute unit vector (codes mm/in/pt) to millimetres, element-wise.
.abs_to_mm <- function(value, code) {
  if (length(value) && any(!is.finite(value))) {
    cli::cli_abort("Can't resolve a {.cls unit} with a non-finite value ({.val NA}/{.val NaN}/{.val Inf}).")
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
  switch(op,
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
    stop("`null` units are only valid in layouts, not coordinates", call. = FALSE)
  }
  if (!is.null(n)) {
    val <- vctrs::vec_recycle(val, n)
    code <- vctrs::vec_recycle(code, n)
    off <- vctrs::vec_recycle(off, n)
  }
  list(value = val, code = as.integer(code), offset = as.double(off))
}
