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
#' @param spread Optional post-aggregation spreading, applied to the shaded
#'   raster to keep sparse output visible (see [spread()] / [dynspread()]):
#'   `NULL` (default) none; a positive integer applies [spread()] with that pixel
#'   radius; `"auto"` applies [dynspread()] (radius chosen from the image density).
#' @param interpolate Passed to [raster_grob()]; `FALSE` keeps hard bin edges.
#' @param name,vp,id,role Passed to [raster_grob()] (see [grob]).
#' @return A [grob][grob] (a raster), drawable with [draw()].
#' @seealso [datashade_lines()] and [datashade_segments()] for the line/segment
#'   (dense-timeseries, network-edge) counterparts, and [dynspread()]/[spread()].
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
                      span = NULL, clip = NULL, spread = NULL,
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
  w <- .ds_weight(weight, length(x), "x")

  if (is.null(category)) {
    counts <- rs_aggregate_2d(x, y, w, width, height, xlim[1], xlim[2], ylim[1], ylim[2])
    shade <- .ds_shade(counts, colors, how, span)
  } else {
    shade <- .ds_shade_cat(x, y, w, category, width, height, xlim, ylim, colors, how, span)
  }
  .ds_finish(shade, width, height, spread, interpolate, name, vp, id, role)
}

# Weights must line up with the observations: a scalar is recycled, a full-length
# vector is used as-is, anything else is an error. (The Rust aggregators keep
# weights only when they match the count and would otherwise *silently* ignore a
# mismatched vector, so validate here.) `n` is the observation count; `arg` names
# the length reference in error messages.
.ds_weight <- function(weight, n, arg) {
  if (is.null(weight)) {
    return(NULL)
  }
  weight <- as.double(weight)
  if (length(weight) == 1L) {
    rep(weight, n)
  } else if (length(weight) == n) {
    weight
  } else {
    cli::cli_abort(c(
      "{.arg weight} must be length 1 or the same length as {.arg {arg}}.",
      i = "{.arg {arg}} has length {n}, but {.arg weight} has length {length(weight)}."
    ))
  }
}

# Shared tail for every datashade* function: reshape the flat row-major top-left
# shade vector into an `height` x `width` raster, wrap it in a `raster_grob`, and
# apply optional `spread`/dynspread. Kept in one place so the point, line, and
# segment paths produce identical grobs.
.ds_finish <- function(shade, width, height, spread, interpolate, name, vp, id, role) {
  img <- matrix(shade, nrow = height, ncol = width, byrow = TRUE)
  g <- raster_grob(img, interpolate = interpolate, name = name, vp = vp, id = id, role = role)
  .ds_apply_spread(g, spread)
}

# Resolve the `spread` convenience argument (NULL / positive integer / "auto")
# to a spreading of the finished grob. `sp` (not `spread`) so the local value
# never shadows the `spread()` function.
.ds_apply_spread <- function(g, sp) {
  if (is.null(sp)) {
    return(g)
  }
  if (identical(sp, "auto")) {
    return(dynspread(g))
  }
  sp <- as.integer(sp)
  if (length(sp) != 1L || is.na(sp) || sp < 0L) {
    cli::cli_abort('{.arg spread} must be {.code NULL}, a non-negative integer, or {.val auto}.')
  }
  if (sp == 0L) g else spread(g, px = sp)
}

#' Aggregate-then-shade dense lines and segments (datashader-style)
#'
#' The line/segment analogue of [datashade()]. Past a few hundred thousand line
#' vertices — a dense stack of timeseries, or the edges of a large graph — drawing
#' each line as a vector primitive overplots into a solid mass and balloons the
#' output. `datashade_lines()` and `datashade_segments()` instead **rasterise** the
#' lines into a canvas-sized grid in one pass: each cell accumulates the
#' (anti-aliased) coverage of the lines crossing it, so overlapping lines *add* and
#' the grid records true line density. The grid is shaded exactly like
#' [datashade()] (`colors`/`how`/`span`/`clip`) and returned as a single
#' [raster_grob()].
#'
#' - `datashade_lines()` takes a **connected polyline**: a segment is drawn between
#'   each consecutive `(x, y)`. Pass `group` to pack several series into one call —
#'   the line breaks wherever the group changes; an `NA` in `x`/`y` also breaks it.
#'   This is the dense-timeseries path.
#' - `datashade_segments()` takes **independent segments** `(x0, y0) -> (x1, y1)`,
#'   one per element. This is the network-edge / `mark_segment` path.
#'
#' Line coverage is anti-aliased (a Wu accumulator) and summed, so a line deposits
#' roughly `weight` per cell it spans and dense bundles brighten honestly rather
#' than saturating. As with [datashade()], align the raster to data axes by drawing
#' it in a [vl_viewport()] whose `xscale`/`yscale` match `xlim`/`ylim`.
#'
#' @inheritParams datashade
#' @param x,y For `datashade_lines()`, the polyline vertices (data space); a
#'   segment joins each consecutive pair.
#' @param group For `datashade_lines()`, an optional per-vertex series id (factor
#'   or vector) the same length as `x`. The line breaks between vertices whose
#'   group differs, so multiple series pack into one call. `NULL` treats all
#'   vertices as one series (still broken by `NA` coordinates).
#' @param x0,y0,x1,y1 For `datashade_segments()`, the segment endpoints (data
#'   space), one per segment; all four the same length.
#' @param weight Optional per-line weight (per start-vertex for
#'   `datashade_lines()`, per segment for `datashade_segments()`): cells
#'   accumulate summed weight instead of plain coverage. `NULL` weighs each line 1;
#'   a scalar is recycled; otherwise it must match the line/segment count.
#' @return A [grob][grob] (a raster), drawable with [draw()].
#' @seealso [datashade()] for points; [dynspread()]/[spread()] for keeping thin
#'   lines visible.
#' @examples
#' set.seed(1)
#' # Dense timeseries: 400 random walks of 500 steps, packed into one raster.
#' k <- 400; m <- 500
#' walks <- apply(matrix(rnorm(k * m), m, k), 2, cumsum)
#' t <- rep(seq_len(m), k)
#' g <- datashade_lines(t, as.vector(walks), group = rep(seq_len(k), each = m),
#'                      width = 400, height = 300)
#'
#' # Network edges: random segments shaded by edge density.
#' n <- 5000
#' e <- datashade_segments(rnorm(n), rnorm(n), rnorm(n), rnorm(n))
#' @export
datashade_lines <- function(x, y, group = NULL, weight = NULL,
                            width = 600L, height = 400L, xlim = NULL, ylim = NULL,
                            colors = c("#deebf7", "#08306b"),
                            how = c("eq_hist", "log", "cbrt", "linear"),
                            span = NULL, clip = NULL, spread = NULL,
                            interpolate = FALSE, name = NULL, vp = NULL, id = NULL, role = NULL) {
  how <- match.arg(how)
  x <- as.double(x)
  y <- as.double(y)
  n <- length(x)
  if (length(y) != n) {
    cli::cli_abort("{.arg x} and {.arg y} must have the same length.")
  }
  width <- max(1L, as.integer(width))
  height <- max(1L, as.integer(height))
  xlim <- .ds_lim(xlim, x, "xlim")
  ylim <- .ds_lim(ylim, y, "ylim")
  span <- .ds_span(span, clip)
  w <- .ds_weight(weight, n, "x")
  brk <- if (is.null(group)) {
    NULL
  } else {
    if (length(group) != n) {
      cli::cli_abort(c(
        "{.arg group} must be the same length as {.arg x}.",
        i = "{.arg x} has length {n}, but {.arg group} has length {length(group)}."
      ))
    }
    as.integer(if (is.factor(group)) group else factor(group))
  }
  counts <- rs_aggregate_lines(x, y, brk, w, width, height, xlim[1], xlim[2], ylim[1], ylim[2])
  shade <- .ds_shade(counts, colors, how, span)
  .ds_finish(shade, width, height, spread, interpolate, name, vp, id, role)
}

#' @rdname datashade_lines
#' @export
datashade_segments <- function(x0, y0, x1, y1, weight = NULL,
                               width = 600L, height = 400L, xlim = NULL, ylim = NULL,
                               colors = c("#deebf7", "#08306b"),
                               how = c("eq_hist", "log", "cbrt", "linear"),
                               span = NULL, clip = NULL, spread = NULL,
                               interpolate = FALSE, name = NULL, vp = NULL, id = NULL, role = NULL) {
  how <- match.arg(how)
  x0 <- as.double(x0)
  y0 <- as.double(y0)
  x1 <- as.double(x1)
  y1 <- as.double(y1)
  n <- length(x0)
  if (length(y0) != n || length(x1) != n || length(y1) != n) {
    cli::cli_abort("{.arg x0}, {.arg y0}, {.arg x1}, and {.arg y1} must have the same length.")
  }
  width <- max(1L, as.integer(width))
  height <- max(1L, as.integer(height))
  # Limits must span both endpoints so a segment never falls entirely off-canvas
  # just because one end sits outside the other end's range.
  xlim <- .ds_lim(xlim, c(x0, x1), "xlim")
  ylim <- .ds_lim(ylim, c(y0, y1), "ylim")
  span <- .ds_span(span, clip)
  w <- .ds_weight(weight, n, "x0")
  counts <- rs_aggregate_segments(x0, y0, x1, y1, w, width, height, xlim[1], xlim[2], ylim[1], ylim[2])
  shade <- .ds_shade(counts, colors, how, span)
  .ds_finish(shade, width, height, spread, interpolate, name, vp, id, role)
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
