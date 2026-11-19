# Decompose a curve coordinate into (values, single unit name). Flattening is a
# linear combination of control-point values, so all coordinates on an axis must
# share one unit (a bare numeric is read in `default`, the constructor's
# `default_units`).
.axis_unit <- function(a, default = "npc") {
  if (!is_unit(a)) {
    return(list(value = as.numeric(a), unit = default))
  }
  codes <- vctrs::field(a, "unit")
  if (length(unique(codes)) > 1L) {
    cli::cli_abort("Curve coordinates on one axis must use a single unit.")
  }
  list(
    value = vctrs::field(a, "value"),
    unit = names(.unit_codes)[match(codes[1], .unit_codes)]
  )
}

# Evaluate a Bezier (control values `p`) at parameters `t` via de Casteljau.
.bezier_eval <- function(p, t) {
  vapply(
    t,
    function(tt) {
      b <- p
      while (length(b) > 1L) {
        b <- b[-length(b)] * (1 - tt) + b[-1] * tt
      }
      b
    },
    double(1)
  )
}

# Cardinal (Catmull-Rom) spline through control values `p`; `tension` 0 = loose
# (smooth), 1 = straight; `per` points per segment; `closed` wraps the ends.
.cardinal <- function(p, tension, per, closed) {
  k <- length(p)
  if (k < 3L) {
    return(p)
  }
  at <- function(i) {
    if (closed) p[((i - 1L) %% k) + 1L] else p[min(max(i, 1L), k)]
  }
  c_ <- 1 - tension
  tt <- seq(0, 1, length.out = per + 1L)[-(per + 1L)]
  h00 <- 2 * tt^3 - 3 * tt^2 + 1
  h10 <- tt^3 - 2 * tt^2 + tt
  h01 <- -2 * tt^3 + 3 * tt^2
  h11 <- tt^3 - tt^2
  segs <- if (closed) seq_len(k) else seq_len(k - 1L)
  out <- unlist(
    lapply(segs, function(i) {
      p1 <- at(i)
      p2 <- at(i + 1L)
      m1 <- c_ * (p2 - at(i - 1L)) / 2
      m2 <- c_ * (at(i + 2L) - p1) / 2
      h00 * p1 + h10 * m1 + h01 * p2 + h11 * m2
    }),
    use.names = FALSE
  )
  c(out, at(if (closed) 1L else k))
}
