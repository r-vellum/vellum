#' Aggregate-then-shade a large point cloud (datashader-style)
#'
#' For data beyond the point where drawing one marker each is practical
#' (overplotted, millions of points), the fast and *overplotting-honest* approach
#' is not to draw markers faster but to **not draw markers at all**: bin the points
#' into a canvas-sized grid in one pass, then colour each cell by its density. This
#' is what makes [datashader](https://datashader.org) fast — aggregation decouples
#' cost from both point count and overplotting. `datashade()` returns a single
#' [raster_grob()] you draw like any other grob.
#'
#' The points are binned over `xlim` x `ylim` into a `width` x `height` grid, so to
#' line the image up with data axes draw it inside a [vl_viewport()] whose `xscale` /
#' `yscale` match `xlim` / `ylim` (it fills the viewport, npc `0..1`). For crisp
#' bins make `width`/`height` match the viewport's pixel size and keep
#' `interpolate = FALSE`.
#'
#' @param x,y Point coordinates (plain numerics, in data space).
#' @param weight Optional per-point weight; cells accumulate the summed weight
#'   instead of a plain count. `NULL` counts. A scalar is recycled to every
#'   point; otherwise `weight` must be the same length as `x`.
#' @param width,height Aggregation grid size in cells (= output raster pixels).
#' @param xlim,ylim Data range to bin over; default the finite range of `x`/`y`.
#' @param colors Two or more colours forming the low-to-high density ramp.
#' @param how Density-to-colour mapping: `"eq_hist"` (histogram equalisation —
#'   datashader's default, reveals structure across orders of magnitude), `"log"`,
#'   `"cbrt"` (cube root), or `"linear"`.
#' @param interpolate Passed to [raster_grob()]; `FALSE` keeps hard bin edges.
#' @param name,vp,id,role Passed to [raster_grob()] (see [grob]).
#' @return A [grob][grob] (a raster), drawable with [draw()].
#' @examples
#' set.seed(1)
#' n <- 1e6
#' x <- rnorm(n); y <- x * 0.5 + rnorm(n)
#' g <- datashade(x, y, width = 400, height = 300)
#' s <- vl_scene(6, 4.5) |>
#'   push(vl_viewport(xscale = range(x), yscale = range(y))) |>
#'   draw(g)
#' @export
datashade <- function(x, y, weight = NULL, width = 600L, height = 400L,
                      xlim = NULL, ylim = NULL,
                      colors = c("#deebf7", "#08306b"),
                      how = c("eq_hist", "log", "cbrt", "linear"),
                      interpolate = FALSE, name = NULL, vp = NULL, id = NULL, role = NULL) {
  how <- match.arg(how)
  x <- as.double(x)
  y <- as.double(y)
  if (length(x) != length(y)) {
    cli::cli_abort("{.arg x} and {.arg y} must have the same length.")
  }
  width <- max(1L, as.integer(width))
  height <- max(1L, as.integer(height))
  xlim <- .ds_lim(xlim, x, "xlim")
  ylim <- .ds_lim(ylim, y, "ylim")
  # Weights must line up with the points: a scalar is recycled, a full-length
  # vector is used as-is, anything else is an error. (The Rust aggregator keeps
  # weights only when they match the point count and would otherwise *silently*
  # ignore a mismatched vector, so validate here.)
  w <- if (is.null(weight)) {
    NULL
  } else {
    weight <- as.double(weight)
    if (length(weight) == 1L) {
      rep(weight, length(x))
    } else if (length(weight) == length(x)) {
      weight
    } else {
      cli::cli_abort(c(
        "{.arg weight} must be length 1 or the same length as {.arg x}.",
        i = "{.arg x} has length {length(x)}, but {.arg weight} has length {length(weight)}."
      ))
    }
  }

  counts <- rs_aggregate_2d(x, y, w, width, height, xlim[1], xlim[2], ylim[1], ylim[2])

  shade <- rep("transparent", length(counts))
  nz <- counts > 0
  if (any(nz)) {
    v <- counts[nz]
    t <- .ds_scale(v, how)
    cols <- grDevices::colorRamp(colors)(t) # n x 3 in 0..255
    shade[nz] <- grDevices::rgb(cols[, 1], cols[, 2], cols[, 3], maxColorValue = 255)
  }
  img <- matrix(shade, nrow = height, ncol = width, byrow = TRUE)
  raster_grob(img, interpolate = interpolate, name = name, vp = vp, id = id, role = role)
}

# Resolve a limit pair, defaulting to the finite data range; widen a degenerate
# (zero-span) range so binning has a non-zero extent.
.ds_lim <- function(lim, v, arg) {
  if (is.null(lim)) {
    fin <- v[is.finite(v)]
    if (length(fin) == 0L) cli::cli_abort("{.arg {arg}} is needed: {.arg {sub('lim','',arg)}} has no finite values.")
    lim <- range(fin)
  }
  lim <- as.double(lim)
  if (length(lim) != 2L || !all(is.finite(lim))) cli::cli_abort("{.arg {arg}} must be two finite numbers.")
  if (lim[1] == lim[2]) lim <- lim + c(-0.5, 0.5)
  lim
}

# Map positive densities to [0, 1] for the colour ramp.
.ds_scale <- function(v, how) {
  rescale <- function(z) {
    rng <- range(z)
    if (rng[1] == rng[2]) return(rep(1, length(z)))
    (z - rng[1]) / (rng[2] - rng[1])
  }
  switch(how,
    eq_hist = (rank(v, ties.method = "average") - 0.5) / length(v),
    log = rescale(log(v)),
    cbrt = rescale(v^(1 / 3)),
    linear = rescale(v)
  )
}
