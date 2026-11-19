# Shared argument validators.
#
# Small, general checks the constructors (and anything else taking user input)
# share, so every argument of one kind fails with the same message and the
# rules live in one place. Each helper either returns its (possibly coerced)
# input or aborts with a cli error attributed to `call`, which defaults to the
# function that called the helper -- so the user sees `rect_grob()` in the
# error, not `.check_scalar()`.
#
# Conventions:
# * `arg` is the argument name as the user typed it, used in the message.
# * `allow_null = TRUE` lets an optional argument pass through as `NULL`.
# * Helpers validate; they do not recycle. Recycling has one path,
#   `.recycle_elems()`, driven by the element count from `.elem_n()`.

# --- units ------------------------------------------------------------------

# Unit names a bare numeric can be read in. Every unit `vl_unit()` knows except
# the layout-only "null" and the kinds that need a label or grob to resolve
# (strwidth/strheight/grobwidth/grobheight): those have no meaning for a bare
# number with no context. `char`/`line` resolve against the default font size.
.default_unit_names <- c(
  "npc",
  "native",
  "mm",
  "cm",
  "in",
  "pt",
  "char",
  "line"
)

# Validate a `default_units` argument: one unit name from the list above.
.check_default_units <- function(
  default_units,
  arg = "default_units",
  call = parent.frame()
) {
  if (
    !is.character(default_units) ||
      length(default_units) != 1L ||
      is.na(default_units) ||
      !default_units %in% .default_unit_names
  ) {
    cli::cli_abort(
      c(
        "{.arg {arg}} must be a single unit name.",
        i = "Use one of {.or {.val {(.default_unit_names)}}}."
      ),
      call = call
    )
  }
  default_units
}

# Coerce a position/size argument to a unit vector: a [vl_unit()] passes
# through untouched, a bare numeric is read in `default_units`. Anything else
# (a string, a list, a factor) is an error rather than a silent cast. `NULL`
# passes through when `allow_null`.
.as_unit_arg <- function(
  x,
  arg,
  default_units = "npc",
  allow_null = FALSE,
  call = parent.frame()
) {
  if (is.null(x)) {
    if (allow_null) {
      return(NULL)
    }
    cli::cli_abort("{.arg {arg}} must not be {.code NULL}.", call = call)
  }
  if (is_unit(x)) {
    return(x)
  }
  if (!is.numeric(x) && !(is.logical(x) && all(is.na(x)))) {
    cli::cli_abort(
      "{.arg {arg}} must be a {.cls vellum_unit} or a numeric vector, not {.obj_type_friendly {x}}.",
      call = call
    )
  }
  vl_unit(as.double(x), default_units)
}

# An extent (width/height/radius/size) must be non-negative. Checks the stored
# value of a unit vector (derived kinds are already in mm; npc/native lengths
# are likewise non-negative when sensible).
.check_extent <- function(u, arg, call = parent.frame()) {
  v <- if (is_unit(u)) vctrs::field(u, "value") else u
  if (length(v) && any(v < 0, na.rm = TRUE)) {
    cli::cli_abort("{.arg {arg}} must be non-negative.", call = call)
  }
  invisible(u)
}

# --- plain values -----------------------------------------------------------

# A single value of one type: "numeric", "integer" (whole numbers, any numeric
# storage), "character" or "logical". `NA` is refused unless `allow_na`.
.check_scalar <- function(
  x,
  arg,
  type = c("numeric", "integer", "character", "logical"),
  allow_null = FALSE,
  allow_na = FALSE,
  call = parent.frame()
) {
  type <- match.arg(type)
  if (is.null(x) && allow_null) {
    return(x)
  }
  ok_type <- switch(
    type,
    numeric = is.numeric(x),
    integer = is.numeric(x) && (is.na(x[1]) || x[1] == round(x[1])),
    character = is.character(x),
    logical = is.logical(x)
  )
  if (!ok_type || length(x) != 1L || (!allow_na && is.na(x))) {
    what <- switch(
      type,
      numeric = "a single number",
      integer = "a single whole number",
      character = "a single string",
      logical = "a single {.code TRUE} or {.code FALSE}"
    )
    cli::cli_abort(
      paste0("{.arg {arg}} must be ", what, "."),
      call = call
    )
  }
  x
}

# Every element of a numeric vector lies in `[min, max]`. `inclusive` is a
# length-2 logical for the lower/upper bound (open bound when FALSE). Non-finite
# values (NA/NaN/Inf) are refused unless `allow_na`, in which case NA passes
# and is left for the caller to treat as missing.
.check_range <- function(
  x,
  arg,
  min = -Inf,
  max = Inf,
  inclusive = c(TRUE, TRUE),
  allow_null = FALSE,
  allow_na = FALSE,
  call = parent.frame()
) {
  if (is.null(x) && allow_null) {
    return(x)
  }
  if (!is.numeric(x)) {
    cli::cli_abort(
      "{.arg {arg}} must be numeric, not {.obj_type_friendly {x}}.",
      call = call
    )
  }
  v <- if (allow_na) x[!is.na(x)] else x
  if (length(v) && !all(is.finite(v))) {
    cli::cli_abort(
      "{.arg {arg}} must be finite (no {.val NA}/{.val NaN}/{.val Inf}).",
      call = call
    )
  }
  lo_ok <- if (inclusive[1]) v >= min else v > min
  hi_ok <- if (inclusive[2]) v <= max else v < max
  if (!all(lo_ok & hi_ok)) {
    interval <- paste0(
      if (inclusive[1]) "[" else "(",
      format(min),
      ", ",
      format(max),
      if (inclusive[2]) "]" else ")"
    )
    cli::cli_abort(
      "{.arg {arg}} must lie in {interval}.",
      call = call
    )
  }
  x
}

# A numeric angle/parameter vector must be finite (no NA/NaN/Inf). Non-finite
# angles otherwise reach the backend and, for arc/sector spans, blow up the
# segment count (see the render-time clamp in `sector_path`). Returns the
# values as double.
.check_finite_num <- function(v, arg, call = parent.frame()) {
  v <- as.numeric(v)
  if (length(v) && !all(is.finite(v))) {
    cli::cli_abort(
      "{.arg {arg}} must be finite (no {.val NA}/{.val NaN}/{.val Inf}).",
      call = call
    )
  }
  invisible(v)
}

# A colour vector R understands: names, hex strings, palette indices, or `NA`
# (transparent) when `allow_na`. Paint objects (gradients/patterns) are not
# colours; callers that take either test `.is_paint()` first.
.check_colour <- function(
  x,
  arg,
  allow_null = FALSE,
  allow_na = TRUE,
  call = parent.frame()
) {
  if (is.null(x) && allow_null) {
    return(x)
  }
  if (!is.character(x) && !is.numeric(x) && !(is.logical(x) && all(is.na(x)))) {
    cli::cli_abort(
      "{.arg {arg}} must be a colour (a name, a hex string or {.val NA}), not {.obj_type_friendly {x}}.",
      call = call
    )
  }
  if (!allow_na && anyNA(x)) {
    cli::cli_abort("{.arg {arg}} must not contain {.val NA}.", call = call)
  }
  cand <- unique(x[!is.na(x)])
  bad <- cand[vapply(
    cand,
    function(cl) {
      inherits(try(grDevices::col2rgb(cl), silent = TRUE), "try-error")
    },
    logical(1)
  )]
  if (length(bad)) {
    cli::cli_abort(
      "{.arg {arg}} has invalid colour{?s}: {.val {bad}}.",
      call = call
    )
  }
  x
}

# One string from a fixed set, like `match.arg()` but with a cli message and
# no partial matching. `x` may be the full `choices` vector (an untouched
# default), which selects the first choice, as `match.arg()` does.
.check_choice <- function(x, choices, arg, call = parent.frame()) {
  if (identical(x, choices)) {
    return(choices[[1L]])
  }
  if (!is.character(x) || length(x) != 1L || is.na(x) || !x %in% choices) {
    cli::cli_abort(
      "{.arg {arg}} must be one of {.or {.val {choices}}}, not {.val {x}}.",
      call = call
    )
  }
  x
}

# --- recycling --------------------------------------------------------------

# Recycle every non-NULL entry of the named list `vals` to `n`, the batch
# element count from `.elem_n()`. Unit vectors and plain vectors both recycle
# under vctrs rules (length 1 or `n`), so a constructor computes `n` once and
# recycles all its per-element arguments through this one path.
.recycle_elems <- function(vals, n) {
  lapply(vals, function(v) if (is.null(v)) NULL else vctrs::vec_recycle(v, n))
}
