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

  known <- c(names(.unit_codes), "cm", "char", "line", "strwidth", "strheight")
  bad <- setdiff(unique(units), known)
  if (length(bad)) {
    cli::cli_abort("Unknown unit{?s}: {.val {bad}}.")
  }
  if ("null" %in% units) {
    cli::cli_abort('{.val null} units are only valid in layouts, not coordinates.')
  }

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

new_unit <- function(value = double(), unit = integer()) {
  vctrs::new_rcrd(list(value = value, unit = unit), class = "vellum_unit")
}

#' @rdname unit
#' @param x An object.
#' @export
is_unit <- function(x) inherits(x, "vellum_unit")

# Coerce a bare numeric to a unit with `default` units; pass units through.
as_unit <- function(x, default = "npc") {
  if (is_unit(x)) x else unit(x, default)
}

# Resolve derived units (cm/char/line/strwidth/strheight) to millimetres.
.resolve_to_mm <- function(values, units, data) {
  fontsize <- (data$fontsize %||% 12)[1]
  lineheight <- (data$lineheight %||% 1.2)[1]
  family <- (data$fontfamily %||% "")[1]
  face <- (data$fontface %||% "plain")[1]
  vapply(seq_along(values), function(i) {
    v <- values[i]
    switch(units[i],
      cm = v * 10,
      char = v * fontsize / 72 * 25.4,
      line = v * fontsize * lineheight / 72 * 25.4,
      strwidth = {
        if (is.null(data$label)) cli::cli_abort('{.val strwidth} units need a {.arg label} in {.arg data}.')
        v * rs_strwidth(data$label, family, face, fontsize, unit = "mm")
      },
      strheight = {
        if (is.null(data$label)) cli::cli_abort('{.val strheight} units need a {.arg label} in {.arg data}.')
        v * rs_strheight(data$label, family, face, fontsize, unit = "mm")
      }
    )
  }, double(1))
}

# --- vctrs machinery --------------------------------------------------------

#' @export
#' @method format vellum_unit
format.vellum_unit <- function(x, ...) {
  v <- vctrs::field(x, "value")
  u <- names(.unit_codes)[match(vctrs::field(x, "unit"), .unit_codes)]
  paste0(format(v, trim = TRUE, ...), u)
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
  switch(op,
    "*" = new_unit(vctrs::field(x, "value") * y, vctrs::field(x, "unit")),
    "/" = new_unit(vctrs::field(x, "value") / y, vctrs::field(x, "unit")),
    vctrs::stop_incompatible_op(op, x, y)
  )
}
#' @export
#' @method vec_arith.numeric vellum_unit
vec_arith.numeric.vellum_unit <- function(op, x, y, ...) {
  switch(op,
    "*" = new_unit(x * vctrs::field(y, "value"), vctrs::field(y, "unit")),
    vctrs::stop_incompatible_op(op, x, y)
  )
}
#' @export
#' @method vec_arith.vellum_unit vellum_unit
vec_arith.vellum_unit.vellum_unit <- function(op, x, y, ...) {
  rc <- vctrs::vec_recycle_common(x, y)
  x <- rc[[1L]]
  y <- rc[[2L]]
  if (!identical(vctrs::field(x, "unit"), vctrs::field(y, "unit"))) {
    cli::cli_abort("Can only add or subtract {.cls unit}s with the same unit.")
  }
  u <- vctrs::field(x, "unit")
  switch(op,
    "+" = new_unit(vctrs::field(x, "value") + vctrs::field(y, "value"), u),
    "-" = new_unit(vctrs::field(x, "value") - vctrs::field(y, "value"), u),
    vctrs::stop_incompatible_op(op, x, y)
  )
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
  } else {
    val <- as.double(v)
    code <- rep(.unit_codes[[default]], length(val))
  }
  if (!is.null(n)) {
    val <- vctrs::vec_recycle(val, n)
    code <- vctrs::vec_recycle(code, n)
  }
  list(value = val, code = as.integer(code))
}
