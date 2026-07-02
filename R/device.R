# FW6 (device-shim, interop): render grid-based graphics — ggplot2, lattice, and
# any grid grob/gtable — through the vellum backend.
#
# Rather than implement an R graphics *device* in Rust (raw unsafe FFI to R's C
# graphics engine; a panic there crashes R), we translate: an offscreen grid
# device resolves every coordinate, viewport and unit to absolute device inches
# (via `grid::deviceLoc` / `convertWidth`), and each grid leaf grob is emitted as
# a page-absolute vellum grob. So the grid tree is flattened — vellum need not
# reproduce grid's viewport model. Covers the common grobs; exotic/custom grobs
# are skipped with a warning. A native base-graphics device is future work.

#' Render grid graphics (ggplot2 / lattice / grid) through vellum
#'
#' `as_vellum()` converts a grid grob tree — or a ggplot2 plot — into a
#' [vl_scene()] by letting an offscreen grid device resolve all coordinates to
#' absolute units, then emitting vellum grobs. `render_grid()` does that and
#' writes the result. This is the interop path (grid-based graphics rendered by
#' vellum's deterministic backend); a native graphics device is future work.
#'
#' @param x A grid grob/gTree/gtable, or a ggplot object.
#' @param width,height Page size in inches.
#' @param dpi,bg As in [vl_scene()].
#' @return `as_vellum()`: a `vellum_scene`. `render_grid()`: `path`, invisibly.
#' @examples
#' \dontrun{
#' library(ggplot2)
#' p <- ggplot(mtcars, aes(wt, mpg)) + geom_point()
#' render_grid(p, "plot.png", width = 6, height = 4)
#' }
#' @export
as_vellum <- function(x, width = 7, height = 7, dpi = 96, bg = "white") {
  grob <- .as_grid_grob(x)
  grDevices::pdf(nullfile(), width = width, height = height)
  on.exit(grDevices::dev.off(), add = TRUE)
  grid::grid.newpage()
  acc <- new.env(parent = emptyenv())
  acc$grobs <- list()
  .gv_walk(grob, acc, list())
  s <- vl_scene(width = width, height = height, dpi = dpi, bg = bg)
  for (g in acc$grobs) s <- draw(s, g)
  s
}

#' @rdname as_vellum
#' @param path Output file (`.png`/`.svg`/`.pdf`).
#' @param text Passed to [render()] (SVG text mode).
#' @export
render_grid <- function(x, path, width = 7, height = 7, dpi = 96, bg = "white",
                        text = c("native", "outline")) {
  render(as_vellum(x, width, height, dpi, bg), path, text = match.arg(text))
}

# Coerce supported inputs to a grid grob.
.as_grid_grob <- function(x) {
  if (inherits(x, "ggplot")) {
    if (!requireNamespace("ggplot2", quietly = TRUE)) {
      cli::cli_abort("{.pkg ggplot2} is needed to render a ggplot.")
    }
    return(ggplot2::ggplotGrob(x))
  }
  if (inherits(x, c("grob", "gTree", "gDesc"))) {
    return(x)
  }
  cli::cli_abort("{.fn as_vellum} needs a grid grob/gTree or a ggplot object.")
}

# --- the walk ---------------------------------------------------------------
# Recurse the grid tree, pushing viewports so grid's converters resolve in the
# right context; accumulate effective gpar; emit vellum grobs for leaves.

.gv_emit <- function(acc, g) {
  if (!is.null(g)) acc$grobs[[length(acc$grobs) + 1L]] <- g
}

.gv_walk <- function(grob, acc, gp) {
  if (is.null(grob) || inherits(grob, "zeroGrob")) {
    return(invisible())
  }
  # Use grid's own grob protocol: makeContext resolves vp/childrenvp/gp, and
  # makeContent generates a gTree's actual children (this is what gtable/ggplot
  # rely on). Defaults are identity, so plain grobs are unaffected.
  grob <- tryCatch(grid::makeContext(grob), error = function(e) grob)
  gp <- .gv_merge_gp(gp, grob$gp)
  own_tok <- .gv_enter(grob$vp)

  if (inherits(grob, "gTree")) {
    cvp <- grob$childrenvp
    cn <- 0L
    if (!is.null(cvp)) {
      before <- .vp_depth_now()
      grid::pushViewport(cvp)
      cn <- .vp_depth_now() - before
    }
    grob <- tryCatch(grid::makeContent(grob), error = function(e) grob)
    kids <- grob$children
    for (nm in (grob$childrenOrder %||% names(kids))) .gv_walk(kids[[nm]], acc, gp)
    if (cn > 0L) grid::popViewport(cn)
  } else {
    .gv_leaf(grob, acc, gp)
  }
  .gv_leave(own_tok, grob$vp)
  invisible()
}

# Current viewport-stack depth (0 at the page root).
.vp_depth_now <- function() {
  p <- grid::current.vpPath()
  if (is.null(p)) 0L else length(strsplit(as.character(p), "::", fixed = TRUE)[[1]])
}

# Enter a grob's vp: a viewport/stack/list is pushed; a vpPath is navigated.
# Returns a signed token (>0 pushed, <0 navigated) measuring the depth change.
.gv_enter <- function(vp) {
  if (is.null(vp)) {
    return(0L)
  }
  before <- .vp_depth_now()
  if (inherits(vp, "vpPath")) {
    grid::downViewport(vp)
    return(-(.vp_depth_now() - before))
  }
  grid::pushViewport(vp)
  .vp_depth_now() - before
}
.gv_leave <- function(token, vp) {
  if (is.null(vp) || token == 0L) {
    return(invisible())
  }
  if (token < 0L) grid::upViewport(-token) else grid::popViewport(token)
}

# --- leaf conversion --------------------------------------------------------

.gv_leaf <- function(grob, acc, gp) {
  switch(class(grob)[1],
    rect = .gv_rect(grob, gp, acc),
    lines = .gv_lines(grob, gp, acc),
    polyline = .gv_polyline(grob, gp, acc),
    segments = .gv_segments(grob, gp, acc),
    polygon = .gv_polygon(grob, gp, acc),
    pathgrob = .gv_polygon(grob, gp, acc),
    circle = .gv_circle(grob, gp, acc),
    points = .gv_points(grob, gp, acc),
    text = .gv_text(grob, gp, acc),
    rastergrob = .gv_raster(grob, gp, acc),
    # Unknown leaf: try the grob protocol (custom grobs) once, else skip quietly.
    {
      drawn <- tryCatch(grid::makeContent(grob), error = function(e) NULL)
      if (!is.null(drawn) && inherits(drawn, "gTree")) .gv_walk(drawn, acc, gp)
    }
  )
}

# device-inch positions (y up from the bottom-left, matching vellum's "in").
.gv_xy <- function(x, y) {
  loc <- grid::deviceLoc(x, y, valueOnly = TRUE)
  list(x = loc$x, y = loc$y)
}
.in <- function(v) unit(v, "in")
.cw <- function(u) grid::convertWidth(u, "in", valueOnly = TRUE)
.ch <- function(u) grid::convertHeight(u, "in", valueOnly = TRUE)

# grid allows per-element (vector) gpar, but a vellum grob carries one gpar; so
# group `n` elements by their distinct style (+ any `extra` per-element keys such
# as pch/size) and return a list of index vectors, one per group.
.gv_style_fields <- c("col", "fill", "lwd", "lty", "alpha", "lineend", "linejoin",
                      "linemitre", "fontface", "fontfamily", "fontsize", "lineheight")
.gv_groups <- function(gp, n, extra = list()) {
  # Group by EXACT per-element style: encode each field's distinct values as
  # integer codes (match against unique) — `format()` would merge numerically
  # close but distinct values (e.g. continuous alpha/size) and mislabel a group.
  code <- function(v) {
    v <- rep_len(v, n)
    match(v, unique(v))
  }
  cols <- list()
  for (f in .gv_style_fields) if (!is.null(gp[[f]])) cols[[f]] <- code(gp[[f]])
  for (nm in names(extra)) cols[[nm]] <- code(extra[[nm]])
  if (!length(cols)) {
    return(list(seq_len(n)))
  }
  unname(split(seq_len(n), do.call(paste, c(cols, sep = "\036"))))
}
# Scalar gpar for element `i` (each gp field reduced to its i-th value).
.gv_gpar_at <- function(gp, i) {
  for (f in names(gp)) {
    v <- gp[[f]]
    if (length(v) > 1L) gp[[f]] <- v[((i - 1L) %% length(v)) + 1L]
  }
  .gv_to_gpar(gp)
}

.gv_rect <- function(g, gp, acc) {
  loc <- .gv_xy(g$x, g$y)
  w <- .cw(g$width)
  h <- .ch(g$height)
  n <- max(length(loc$x), length(loc$y), length(w), length(h))
  loc$x <- rep_len(loc$x, n); loc$y <- rep_len(loc$y, n); w <- rep_len(w, n); h <- rep_len(h, n)
  hv <- .gv_just(g$just, g$hjust, g$vjust)
  cx <- loc$x + (0.5 - hv[1]) * w
  cy <- loc$y + (0.5 - hv[2]) * h
  for (idx in .gv_groups(gp, n)) {
    .gv_emit(acc, rect_grob(.in(cx[idx]), .in(cy[idx]), .in(abs(w[idx])), .in(abs(h[idx])), gp = .gv_gpar_at(gp, idx[1])))
  }
}

.gv_lines <- function(g, gp, acc) {
  loc <- .gv_xy(g$x, g$y)
  if (length(loc$x) >= 2L) {
    .gv_emit(acc, lines_grob(.in(loc$x), .in(loc$y), arrow = .gv_arrow(g$arrow), gp = .gv_gpar_at(gp, 1L)))
  }
}

# grid groups multi-line/polygon points by `id` (per point) or `id.lengths` (run
# lengths); resolve either to a per-point id vector.
.gv_ids <- function(g, n) {
  if (!is.null(g$id)) {
    return(g$id)
  }
  if (!is.null(g$id.lengths)) {
    return(rep(seq_along(g$id.lengths), g$id.lengths))
  }
  rep(1L, n)
}

# Group point indices by `id` in FIRST-APPEARANCE order (grid's convention), so a
# per-group gpar is recycled across groups in the same order grid draws them.
# `split()` would reorder by sorted id, mismatching gpar for non-ascending ids.
.gv_id_groups <- function(id) {
  ug <- unique(id)
  lapply(ug, function(u) which(id == u))
}

.gv_polyline <- function(g, gp, acc) {
  loc <- .gv_xy(g$x, g$y)
  id <- .gv_ids(g, length(loc$x))
  grp <- .gv_id_groups(id)
  for (j in seq_along(grp)) {
    k <- grp[[j]]
    if (length(k) >= 2L) .gv_emit(acc, lines_grob(.in(loc$x[k]), .in(loc$y[k]), arrow = .gv_arrow(g$arrow), gp = .gv_gpar_at(gp, j)))
  }
}

.gv_segments <- function(g, gp, acc) {
  a <- .gv_xy(g$x0, g$y0)
  b <- .gv_xy(g$x1, g$y1)
  n <- length(a$x)
  for (idx in .gv_groups(gp, n)) {
    .gv_emit(acc, segments_grob(.in(a$x[idx]), .in(a$y[idx]), .in(b$x[idx]), .in(b$y[idx]),
                                arrow = .gv_arrow(g$arrow), gp = .gv_gpar_at(gp, idx[1])))
  }
}

.gv_polygon <- function(g, gp, acc) {
  loc <- .gv_xy(g$x, g$y)
  id <- .gv_ids(g, length(loc$x))
  grp <- .gv_id_groups(id)
  for (j in seq_along(grp)) {
    k <- grp[[j]]
    if (length(k) >= 3L) .gv_emit(acc, polygon_grob(.in(loc$x[k]), .in(loc$y[k]), gp = .gv_gpar_at(gp, j)))
  }
}

.gv_circle <- function(g, gp, acc) {
  loc <- .gv_xy(g$x, g$y)
  r <- .cw(g$r)
  n <- max(length(loc$x), length(r))
  loc$x <- rep_len(loc$x, n); loc$y <- rep_len(loc$y, n); r <- rep_len(r, n)
  for (idx in .gv_groups(gp, n)) {
    .gv_emit(acc, circle_grob(.in(loc$x[idx]), .in(loc$y[idx]), .in(r[idx]), gp = .gv_gpar_at(gp, idx[1])))
  }
}

.gv_points <- function(g, gp, acc) {
  loc <- .gv_xy(g$x, g$y)
  n <- length(loc$x)
  size <- rep_len(.cw(g$size) / 2, n) # grid size ~ diameter; vellum size is a radius
  pch <- rep_len(g$pch %||% 1L, n)
  for (idx in .gv_groups(gp, n, list(.pch = pch, .size = size))) {
    i <- idx[1]
    shp <- .gv_pch(pch[i])
    vgp <- .gv_gpar_at(gp, i)
    if (shp$fill && is.null(vgp@fill)) vgp@fill <- vgp@col
    .gv_emit(acc, points_grob(.in(loc$x[idx]), .in(loc$y[idx]), size = .in(size[idx]), shape = shp$shape, gp = vgp))
  }
}

.gv_text <- function(g, gp, acc) {
  loc <- .gv_xy(g$x, g$y)
  lab <- as.character(g$label)
  n <- max(length(loc$x), length(lab))
  if (n == 0L) {
    return(invisible())
  }
  loc$x <- rep_len(loc$x, n); loc$y <- rep_len(loc$y, n); lab <- rep_len(lab, n)
  fs <- (gp$fontsize %||% 12) * (gp$cex %||% 1)
  gp$fontsize <- fs
  rot <- g$rot %||% 0
  just <- .gv_just_names(g$just, g$hjust, g$vjust)
  for (idx in .gv_groups(gp, n)) {
    .gv_emit(acc, text_grob(lab[idx], .in(loc$x[idx]), .in(loc$y[idx]), just = just,
                            rot = rep_len(rot, n)[idx], gp = .gv_gpar_at(gp, idx[1])))
  }
}

.gv_raster <- function(g, gp, acc) {
  loc <- .gv_xy(g$x, g$y)
  w <- .cw(g$width)
  h <- .ch(g$height)
  hv <- .gv_just(g$just, g$hjust, g$vjust)
  .gv_emit(acc, raster_grob(g$raster, .in(loc$x[1] + (0.5 - hv[1]) * w[1]), .in(loc$y[1] + (0.5 - hv[2]) * h[1]),
                            .in(abs(w[1])), .in(abs(h[1])), interpolate = isTRUE(g$interpolate), gp = .gv_to_gpar(gp)))
}

# --- gpar / unit helpers ----------------------------------------------------

.gv_merge_gp <- function(parent, child) {
  if (is.null(child)) {
    return(parent)
  }
  # `[.gpar` recycles fields to the index length, so unclass to a plain list
  # before subsetting (otherwise scalars get expanded).
  child <- unclass(child)
  ch <- child[!vapply(child, is.null, logical(1))]
  utils::modifyList(parent, ch)
}

.gv_to_gpar <- function(gp) {
  ff <- gp$fontface
  if (!is.null(ff) && is.numeric(ff)) {
    ff <- c("plain", "bold", "italic", "bold.italic")[ff]
  }
  gpar(
    col = gp$col, fill = gp$fill, lwd = gp$lwd, lty = gp$lty,
    alpha = gp$alpha, lineend = gp$lineend, linejoin = gp$linejoin,
    linemitre = gp$linemitre, fontfamily = gp$fontfamily, fontface = ff,
    fontsize = gp$fontsize, lineheight = gp$lineheight
  )
}

# grid just -> c(hjust, vjust) fractions.
.gv_just <- function(just, hjust, hjust2) {
  hmap <- c(left = 0, centre = 0.5, center = 0.5, right = 1, bottom = 0, top = 1)
  h <- 0.5
  v <- 0.5
  if (!is.null(just)) {
    j <- just
    if (is.numeric(j)) {
      h <- j[1]
      v <- if (length(j) > 1) j[2] else 0.5
    } else {
      if (j[1] %in% names(hmap)) h <- hmap[[j[1]]]
      if (length(j) > 1 && j[2] %in% names(hmap)) v <- hmap[[j[2]]]
    }
  }
  if (!is.null(hjust)) h <- hjust[1]
  if (!is.null(hjust2)) v <- hjust2[1]
  c(h, v)
}

# grid just -> vellum text `just` as exact fractions (text_grob parses numeric
# strings), so non-standard justifications survive instead of snapping to thirds.
.gv_just_names <- function(just, hjust, vjust) {
  as.character(.gv_just(just, hjust, vjust))
}

# Map an R pch to a vellum marker shape + whether it is solid-filled.
.gv_pch <- function(pch) {
  pch <- (pch %||% 1L)[1]
  if (is.character(pch)) {
    return(list(shape = "circle", fill = FALSE))
  }
  # Solid pch (15-20) take col as fill; 21-25 keep their own gp$fill/border.
  filled <- pch %in% c(15:20)
  shape <- switch(as.character(pch),
    "0" = "square", "15" = "square", "22" = "square",
    "1" = "circle", "16" = "circle", "19" = "circle", "20" = "circle", "21" = "circle",
    "2" = "triangle", "6" = "triangle", "17" = "triangle", "24" = "triangle", "25" = "triangle",
    "5" = "diamond", "18" = "diamond", "23" = "diamond",
    "3" = "plus", "4" = "cross",
    "circle"
  )
  list(shape = shape, fill = filled)
}

# grid arrow -> vellum arrow().
.gv_arrow <- function(a) {
  if (is.null(a)) {
    return(NULL)
  }
  ends <- c("first", "last", "both")[a$ends %||% 2L]
  type <- c("open", "closed")[a$type %||% 1L]
  len <- tryCatch(unit(.cw(a$length), "in"), error = function(e) unit(0.1, "in"))
  arrow(angle = a$angle %||% 30, length = len, ends = ends, type = type)
}
