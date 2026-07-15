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
#' # Categorical shading (`count_cat`)
#'
#' Pass `category` (a factor or vector, one value per point) to shade by *category*
#' rather than plain density: each category is aggregated into its own count grid in
#' the same single pass, and each cell is coloured by the **count-weighted average**
#' of the category hues it contains, with opacity driven by the cell's total density
#' (via `how`). This reveals which category dominates where *and* where categories
#' mix, without overplotting bias. When `category` is set, `colors` is a per-category
#' hue vector (named by level, or one colour per level in level order) instead of a
#' low-to-high ramp.
#'
#' @param x,y Point coordinates (plain numerics, in data space).
#' @param weight Optional per-point weight; cells accumulate the summed weight
#'   instead of a plain count. `NULL` counts. A scalar is recycled to every
#'   point; otherwise `weight` must be the same length as `x`.
#' @param width,height Aggregation grid size in cells (= output raster pixels).
#' @param xlim,ylim Data range to bin over; default the finite range of `x`/`y`.
#' @param category Optional per-point category (factor or vector) selecting
#'   categorical (`count_cat`) shading; see Details. `NULL` (default) shades by
#'   plain density.
#' @param colors For density shading, two or more colours forming the low-to-high
#'   ramp. For categorical shading (`category` set), a per-category hue vector —
#'   named by category level, or one colour per level in level order.
#' @param how Density-to-colour mapping: `"eq_hist"` (histogram equalisation —
#'   datashader's default, reveals structure across orders of magnitude), `"log"`,
#'   `"cbrt"` (cube root), or `"linear"`. Also drives the per-cell opacity under
#'   categorical shading.
#' @param span Optional `c(lo, hi)` density values mapped to the ends of the
#'   colour ramp / opacity range; densities outside are clamped. `NULL` (default)
#'   uses the full observed range.
#' @param clip Optional percentile pair in `[0, 1]` (e.g. `c(0.01, 0.99)`) deriving
#'   `span` from the quantiles of the non-empty cell densities — a robust way to
#'   keep a few extreme cells from flattening the rest. Overrides `span`.
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
#'
#' # Categorical: colour each cell by which group dominates it
#' grp <- sample(c("a", "b"), n, replace = TRUE)
#' gc <- datashade(x, y, category = grp, colors = c(a = "#e41a1c", b = "#377eb8"))
#' @export
datashade <- function(x, y, weight = NULL, width = 600L, height = 400L,
                      xlim = NULL, ylim = NULL,
                      category = NULL,
                      colors = c("#deebf7", "#08306b"),
                      how = c("eq_hist", "log", "cbrt", "linear"),
                      span = NULL, clip = NULL,
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
  span <- .ds_span(span, clip)
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

  if (is.null(category)) {
    counts <- rs_aggregate_2d(x, y, w, width, height, xlim[1], xlim[2], ylim[1], ylim[2])
    shade <- .ds_shade(counts, colors, how, span)
  } else {
    shade <- .ds_shade_cat(x, y, w, category, width, height, xlim, ylim, colors, how, span)
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

# Validate `span` / `clip`. `clip` (percentile pair in [0,1]) is resolved against
# the data later, so here it just rides through as an attribute on the returned
# value; `span` (absolute) is checked for shape. Returns NULL, a length-2 absolute
# span, or a length-2 percentile pair tagged `clip = TRUE`.
.ds_span <- function(span, clip) {
  if (!is.null(clip)) {
    clip <- as.double(clip)
    if (length(clip) != 2L || anyNA(clip) || any(clip < 0) || any(clip > 1) || clip[1] >= clip[2]) {
      cli::cli_abort("{.arg clip} must be two increasing percentiles in [0, 1], e.g. {.code c(0.01, 0.99)}.")
    }
    return(structure(clip, clip = TRUE))
  }
  if (is.null(span)) {
    return(NULL)
  }
  span <- as.double(span)
  if (length(span) != 2L || !all(is.finite(span)) || span[1] >= span[2]) {
    cli::cli_abort("{.arg span} must be two increasing finite numbers {.code c(lo, hi)}.")
  }
  span
}

# Map positive densities to [0, 1] for the colour ramp / opacity. `span` (absolute
# or a percentile pair tagged `clip`) clamps the density range before the `how`
# transform; NULL uses the full range.
.ds_scale <- function(v, how, span = NULL) {
  if (!is.null(span)) {
    lohi <- if (isTRUE(attr(span, "clip"))) {
      stats::quantile(v, probs = as.double(span), names = FALSE, na.rm = TRUE)
    } else {
      span
    }
    if (lohi[1] < lohi[2]) v <- pmin(pmax(v, lohi[1]), lohi[2])
  }
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

# Shade a single count grid through the low-to-high `colors` ramp: empty cells are
# transparent, non-empty cells map their (optionally clamped, `how`-transformed)
# density onto the ramp. The reusable colormap step (DESIGN §12); the categorical
# path below reuses `.ds_scale` for its per-cell opacity.
.ds_shade <- function(counts, colors, how, span = NULL) {
  shade <- rep("transparent", length(counts))
  nz <- counts > 0
  if (any(nz)) {
    v <- counts[nz]
    t <- .ds_scale(v, how, span)
    cols <- grDevices::colorRamp(colors)(t) # n x 3 in 0..255
    shade[nz] <- grDevices::rgb(cols[, 1], cols[, 2], cols[, 3], maxColorValue = 255)
  }
  shade
}

# Categorical (`count_cat`) shading: aggregate one count grid per category in a
# single pass, then colour each non-empty cell by the count-weighted average of the
# category hues it holds, with opacity from the cell's total density (`how`/`span`).
.ds_shade_cat <- function(x, y, w, category, width, height, xlim, ylim, colors, how, span) {
  if (length(category) != length(x)) {
    cli::cli_abort(c(
      "{.arg category} must be the same length as {.arg x}.",
      i = "{.arg x} has length {length(x)}, but {.arg category} has length {length(category)}."
    ))
  }
  f <- if (is.factor(category)) category else factor(category)
  levels <- levels(f)
  ncat <- length(levels)
  if (ncat == 0L) cli::cli_abort("{.arg category} has no levels to shade.")
  hues <- .ds_cat_colors(colors, levels)
  hue_rgb <- t(grDevices::col2rgb(hues)) # ncat x 3 (rows in level order)

  cat_idx <- as.integer(f) - 1L # 0-based; NA -> NA
  cat_idx[is.na(cat_idx)] <- -1L # dropped by the aggregator

  ncell <- as.integer(width) * as.integer(height)
  grid <- rs_aggregate_2d_cat(
    x, y, cat_idx, ncat, w, width, height, xlim[1], xlim[2], ylim[1], ylim[2]
  )
  # Category-major flat grid -> ncell x ncat matrix (column k = category k's grid).
  gm <- matrix(grid, nrow = ncell, ncol = ncat)
  total <- rowSums(gm)

  shade <- rep("transparent", ncell)
  nz <- total > 0
  if (any(nz)) {
    # Count-weighted average of the category RGBs, per non-empty cell.
    mixed <- (gm[nz, , drop = FALSE] %*% hue_rgb) / total[nz]
    alpha <- .ds_scale(total[nz], how, span) # opacity from total density
    shade[nz] <- grDevices::rgb(
      mixed[, 1], mixed[, 2], mixed[, 3], alpha * 255, maxColorValue = 255
    )
  }
  shade
}

# Resolve a per-category hue vector covering every level: a named vector is
# reordered/subset to the levels (all must be present); an unnamed vector must have
# one colour per level, taken in level order.
.ds_cat_colors <- function(colors, levels) {
  ncat <- length(levels)
  if (!is.null(names(colors))) {
    miss <- setdiff(levels, names(colors))
    if (length(miss)) {
      cli::cli_abort(c(
        "{.arg colors} must name a colour for every {.arg category} level.",
        i = "Missing: {.val {miss}}."
      ))
    }
    return(unname(colors[levels]))
  }
  if (length(colors) != ncat) {
    cli::cli_abort(c(
      "{.arg colors} must have one colour per {.arg category} level (or be named by level).",
      i = "{.arg category} has {ncat} level{?s}; supply that many colours (got {length(colors)})."
    ))
  }
  colors
}
