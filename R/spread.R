# Post-aggregation spreading (datashader's spread/dynspread). Aggregated rasters
# — especially the line/segment grids and sparse point clouds — often leave
# single-pixel-wide marks that vanish when the image is displayed small or on a
# busy background. Spreading dilates each non-empty pixel over a small
# neighbourhood so isolated marks stay visible, without touching the aggregation
# itself. Operates purely on the finished RGBA raster (row-major, top-left,
# 4 ints/pixel — see `.image_to_rgba()`), so it works on any `raster_grob`.

#' Spread (dilate) the pixels of a raster grob
#'
#' Grow each non-empty pixel of a raster over a small neighbourhood so thin marks
#' stay visible. This is [datashader's](https://datashader.org) `spread`: useful
#' after [datashade()], [datashade_lines()], or [datashade_segments()] when the
#' output is sparse (single-pixel lines, isolated points). [dynspread()] chooses
#' the radius automatically from the image's density; `spread()` uses a fixed one.
#'
#' @param grob A raster [grob][grob] (e.g. from [datashade()]). Other grob kinds
#'   are returned unchanged.
#' @param px Spread radius in pixels (non-negative integer). `0` returns `grob`
#'   unchanged.
#' @param shape Neighbourhood shape: `"circle"` (default, Euclidean radius) or
#'   `"square"` (Chebyshev radius).
#' @param how How overlapping spread pixels combine: `"over"` (default) keeps the
#'   colour of the most-opaque contributor; `"add"` accumulates opacity (clamped)
#'   so overlaps darken.
#' @return A raster [grob][grob] with the spread applied.
#' @seealso [dynspread()], [datashade()], [datashade_lines()].
#' @examples
#' set.seed(1)
#' g <- datashade_segments(rnorm(2000), rnorm(2000), rnorm(2000), rnorm(2000))
#' g2 <- spread(g, px = 2)
#' @export
spread <- function(grob, px = 1L, shape = c("circle", "square"), how = c("over", "add")) {
  shape <- match.arg(shape)
  how <- match.arg(how)
  if (!S7::S7_inherits(grob, grob_raster)) {
    return(grob)
  }
  px <- as.integer(px)
  if (length(px) != 1L || is.na(px) || px < 0L) {
    cli::cli_abort("{.arg px} must be a non-negative integer.")
  }
  if (px == 0L) {
    return(grob)
  }
  ch <- .rgba_channels(grob@rgba, grob@iw, grob@ih)
  out <- .spread_channels(ch, .spread_offsets(px, shape), how)
  .grob_with_rgba(grob, .channels_to_rgba(out))
}

#' Dynamically spread a raster grob to a target density
#'
#' [datashader's](https://datashader.org) `dynspread`: pick the smallest spread
#' radius (up to `max_px`) at which the shaded pixels become "connected enough" —
#' the fraction of non-empty pixels with a non-empty neighbour reaches `threshold`
#' — then [spread()] by it. Denser images spread less, sparse ones more, so a mix
#' of dense and sparse regions all stay legible.
#'
#' @inheritParams spread
#' @param max_px Largest spread radius to consider (non-negative integer).
#' @param threshold Target fraction in `(0, 1]` of non-empty pixels that should
#'   have a non-empty neighbour; growth stops once it is reached.
#' @return A raster [grob][grob] with the chosen spread applied.
#' @seealso [spread()], [datashade()], [datashade_lines()].
#' @examples
#' set.seed(1)
#' g <- datashade_segments(rnorm(2000), rnorm(2000), rnorm(2000), rnorm(2000))
#' g2 <- dynspread(g)
#' @export
dynspread <- function(grob, max_px = 3L, threshold = 0.5, shape = c("circle", "square"),
                      how = c("over", "add")) {
  shape <- match.arg(shape)
  how <- match.arg(how)
  if (!S7::S7_inherits(grob, grob_raster)) {
    return(grob)
  }
  max_px <- as.integer(max_px)
  if (length(max_px) != 1L || is.na(max_px) || max_px < 0L) {
    cli::cli_abort("{.arg max_px} must be a non-negative integer.")
  }
  threshold <- as.double(threshold)
  if (length(threshold) != 1L || is.na(threshold) || threshold <= 0 || threshold > 1) {
    cli::cli_abort("{.arg threshold} must be a single number in (0, 1].")
  }
  ch <- .rgba_channels(grob@rgba, grob@iw, grob@ih)
  # Grow until the spread image is connected enough, then keep that radius.
  chosen <- max_px
  for (px in seq_len(max_px)) {
    sp <- .spread_channels(ch, .spread_offsets(px, shape), how)
    if (.spread_density(sp$a) >= threshold) {
      chosen <- px
      break
    }
  }
  if (chosen == 0L) {
    return(grob)
  }
  out <- .spread_channels(ch, .spread_offsets(chosen, shape), how)
  .grob_with_rgba(grob, .channels_to_rgba(out))
}

# --- internals --------------------------------------------------------------

# Split a flat straight-RGBA integer vector (4 ints/pixel, row-major top-left)
# into per-channel `ih` x `iw` matrices (also row-major, filled `byrow`).
.rgba_channels <- function(rgba, iw, ih) {
  iw <- as.integer(iw)
  ih <- as.integer(ih)
  base <- 4L * (seq_len(iw * ih) - 1L)
  mk <- function(off) matrix(rgba[base + off], nrow = ih, ncol = iw, byrow = TRUE)
  list(r = mk(1L), g = mk(2L), b = mk(3L), a = mk(4L), iw = iw, ih = ih)
}

# Re-interleave per-channel matrices into a flat straight-RGBA integer vector.
.channels_to_rgba <- function(ch) {
  n <- ch$iw * ch$ih
  out <- integer(4L * n)
  base <- 4L * (seq_len(n) - 1L)
  # `as.vector(t(m))` walks a byrow matrix back in row-major order.
  out[base + 1L] <- as.vector(t(ch$r))
  out[base + 2L] <- as.vector(t(ch$g))
  out[base + 3L] <- as.vector(t(ch$b))
  out[base + 4L] <- as.vector(t(ch$a))
  out
}

# Rebuild a raster grob keeping every property except the pixels.
.grob_with_rgba <- function(grob, rgba) {
  grob_raster(
    rgba = as.integer(rgba), iw = grob@iw, ih = grob@ih,
    x = grob@x, y = grob@y, width = grob@width, height = grob@height,
    interpolate = grob@interpolate, gp = grob@gp,
    name = grob@name, vp = grob@vp, id = grob@id, role = grob@role
  )
}

# Kernel offsets `(dr, dc)` within radius `px`, excluding the centre (the centre
# is handled by seeding the output from the source). `"circle"` uses Euclidean
# radius, `"square"` Chebyshev.
.spread_offsets <- function(px, shape) {
  g <- expand.grid(dr = -px:px, dc = -px:px)
  g <- g[!(g$dr == 0 & g$dc == 0), , drop = FALSE]
  keep <- if (shape == "circle") g$dr^2 + g$dc^2 <= px^2 else pmax(abs(g$dr), abs(g$dc)) <= px
  g[keep, , drop = FALSE]
}

# Shift a matrix so that source cell (i+dr, j+dc) lands at (i, j); out-of-bounds
# reads become `fill`. Vectorised (no per-pixel loop).
.shift_mat <- function(m, dr, dc, fill = 0L) {
  ih <- nrow(m)
  iw <- ncol(m)
  out <- matrix(fill, ih, iw)
  ri <- seq_len(ih)
  ci <- seq_len(iw)
  sr <- ri + dr
  sc <- ci + dc
  vr <- sr >= 1L & sr <= ih
  vc <- sc >= 1L & sc <= iw
  if (any(vr) && any(vc)) {
    out[ri[vr], ci[vc]] <- m[sr[vr], sc[vc]]
  }
  out
}

# Dilate the channel matrices over `offsets`. A pixel's colour is taken from the
# most-opaque source in its neighbourhood (`how = "over"`); `how = "add"` also
# accumulates opacity (clamped to 255) so overlaps darken. The output alpha marks
# which pixels are now painted.
.spread_channels <- function(ch, offsets, how) {
  or <- ch$r
  og <- ch$g
  ob <- ch$b
  oa <- ch$a
  for (k in seq_len(nrow(offsets))) {
    dr <- offsets$dr[k]
    dc <- offsets$dc[k]
    sa <- .shift_mat(ch$a, dr, dc, 0L)
    take <- sa > oa
    if (any(take)) {
      sr <- .shift_mat(ch$r, dr, dc, 0L)
      sg <- .shift_mat(ch$g, dr, dc, 0L)
      sb <- .shift_mat(ch$b, dr, dc, 0L)
      or[take] <- sr[take]
      og[take] <- sg[take]
      ob[take] <- sb[take]
      if (how == "add") {
        oa[take] <- pmin(255L, oa[take] + sa[take])
      } else {
        oa[take] <- sa[take]
      }
    } else if (how == "add") {
      oa <- pmin(255L, oa + sa)
    }
  }
  list(r = or, g = og, b = ob, a = oa, iw = ch$iw, ih = ch$ih)
}

# Connectivity of a spread image: the fraction of non-empty pixels that have at
# least one non-empty 8-neighbour. dynspread grows the radius until this reaches
# its threshold. `0` when the image is empty.
.spread_density <- function(a) {
  nonempty <- a > 0L
  total <- sum(nonempty)
  if (total == 0L) {
    return(0)
  }
  neigh <- matrix(0L, nrow(a), ncol(a))
  for (dr in -1:1) {
    for (dc in -1:1) {
      if (dr == 0L && dc == 0L) next
      neigh <- neigh + .shift_mat(nonempty, dr, dc, 0L)
    }
  }
  sum(nonempty & neigh > 0L) / total
}
