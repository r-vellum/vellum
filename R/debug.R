#' @include api.R
NULL

# Active debug-capture registry. While `$reg` is an environment, `.push_vp`
# records each pushed viewport's (backend id, name, node) into `reg$items`, so a
# debug render / `why_size()` can map resolved geometry back to named viewports.
# NULL outside a debug pass (the normal render path pays nothing).
.debug_state <- new.env(parent = emptyenv())
.debug_state$reg <- NULL

# Palette for viewport region outlines (cycled by viewport index).
.debug_palette <- c("#E41A1C", "#377EB8", "#4DAF4A", "#984EA3", "#FF7F00", "#A65628")

# Map a viewport-local point (lx, ly, px) through its resolved transform
# `tf = c(sx, ky, kx, sy, tx, ty)` to device px, then to root npc (y up).
.dev_to_npc <- function(tf, lx, ly, W, H) {
  dx <- tf[1] * lx + tf[3] * ly + tf[5]
  dy <- tf[2] * lx + tf[4] * ly + tf[6]
  c(dx / W, 1 - dy / H)
}

# Draw the layout-debug overlay onto a compiled backend scene `s`: every
# viewport region (outlined + labelled by name), its layout track boundaries,
# and its clip region. Built purely from `s$resolved_geometry()` so it is exact
# and backend-independent (the engine drawing its own resolved layout).
.draw_debug_overlay <- function(s, items) {
  g <- s$resolved_geometry()
  d <- s$dim()
  W <- d[1]
  H <- d[2]
  name_by_id <- lapply(items, function(it) it$name)
  names(name_by_id) <- vapply(items, function(it) as.character(it$id), character(1))
  grobs <- list()
  add <- function(x) grobs[[length(grobs) + 1L]] <<- x

  for (i in seq_along(g$id)) {
    vid <- g$id[i]
    tf <- g$transform[[i]]
    w <- g$w_px[i]
    h <- g$h_px[i]
    col <- .debug_palette[((i - 1L) %% length(.debug_palette)) + 1L]
    # Region outline: the four local corners mapped to root npc.
    corners <- vapply(
      list(c(0, 0), c(w, 0), c(w, h), c(0, h)),
      function(p) .dev_to_npc(tf, p[1], p[2], W, H), double(2)
    )
    add(polygon_grob(
      x = corners[1, ], y = corners[2, ],
      gp = vl_gpar(col = col, fill = NA, lwd = 1)
    ))
    # Track boundaries (interior layout edges only).
    if (isTRUE(g$has_layout[i] == 1L)) {
      xe <- g$xedges[[i]]
      ye <- g$yedges[[i]]
      xo <- g$xoff[i]
      yo <- g$yoff[i]
      y_lo <- yo + ye[1]
      y_hi <- yo + ye[length(ye)]
      for (k in seq_along(xe)[-c(1L, length(xe))]) {
        a <- .dev_to_npc(tf, xo + xe[k], y_lo, W, H)
        b <- .dev_to_npc(tf, xo + xe[k], y_hi, W, H)
        add(segments_grob(a[1], a[2], b[1], b[2], gp = vl_gpar(col = col, lwd = 0.5, lty = "dashed")))
      }
      x_lo <- xo + xe[1]
      x_hi <- xo + xe[length(xe)]
      for (k in seq_along(ye)[-c(1L, length(ye))]) {
        a <- .dev_to_npc(tf, x_lo, yo + ye[k], W, H)
        b <- .dev_to_npc(tf, x_hi, yo + ye[k], W, H)
        add(segments_grob(a[1], a[2], b[1], b[2], gp = vl_gpar(col = col, lwd = 0.5, lty = "dashed")))
      }
    }
    # Clip region (device-space bbox -> npc), dashed.
    if (isTRUE(g$has_clip[i] == 1L)) {
      cl <- g$clip[[i]]
      cx <- c(cl[1], cl[3], cl[3], cl[1]) / W
      cy <- 1 - c(cl[2], cl[2], cl[4], cl[4]) / H
      add(polygon_grob(x = cx, y = cy, gp = vl_gpar(col = "#FF7F00", fill = NA, lwd = 0.75, lty = "dotted")))
    }
    # Name label at the region's top-left corner.
    nm <- name_by_id[[as.character(vid)]]
    if (!is.null(nm) && !is.na(nm) && nzchar(nm)) {
      tl <- .dev_to_npc(tf, 0, 0, W, H)
      add(text_grob(nm, x = tl[1], y = tl[2], just = c("left", "top"),
                    gp = vl_gpar(col = col, fontsize = 8)))
    }
  }
  for (gr in grobs) compile(gr, s)
  invisible()
}

# Compile `scene` purely to capture resolved geometry + the viewport id<->name
# map, without rendering or drawing an overlay. Used by `why_size()`.
.capture_geometry <- function(scene) {
  s <- Scene$new(.to_inches(scene@width), .to_inches(scene@height), scene@dpi,
                 .rs_col(scene@bg) %||% c(255L, 255L, 255L, 0L))
  reg <- new.env(parent = emptyenv())
  reg$items <- list()
  old <- .debug_state$reg
  .debug_state$reg <- reg
  on.exit(.debug_state$reg <- old, add = TRUE)
  compile(.materialize(scene), s)
  .debug_state$reg <- old
  list(geom = s$resolved_geometry(), items = reg$items, dim = s$dim(), dpi = scene@dpi)
}

# Describe which layout track(s) sized a cell-placed viewport.
.describe_track <- function(layout, vp) {
  if (is.null(layout)) {
    return("placed in a parent cell, but the parent layout could not be read")
  }
  parts <- character(0)
  if (!is.null(vp@col)) {
    tw <- layout@widths[as.integer(vp@col)]
    parts <- c(parts, sprintf("column %d width track = %s", as.integer(vp@col), format(tw)))
  }
  if (!is.null(vp@row)) {
    th <- layout@heights[as.integer(vp@row)]
    parts <- c(parts, sprintf("row %d height track = %s", as.integer(vp@row), format(th)))
  }
  paste(parts, collapse = "; ")
}

#' Explain why a node has its resolved size
#'
#' Reports the resolved width and height of a named viewport (or grob) and what
#' determined them — the layout track it was placed in, or the units of its own
#' width/height. The layout companion to the visual `render(scene, debug = TRUE)`
#' overlay; together they make coordinate debugging first-class rather than an
#' exercise in archaeology.
#'
#' @param scene A [vl_scene()] (or anything with an [as_vellum_scene()] method).
#' @param name A node name (set via the `name` argument of a viewport/grob).
#' @return A `vellum_why_size` record (a list with `name`, `width_mm`,
#'   `height_mm`, and `determined_by`), printed legibly.
#' @examples
#' s <- vl_scene(4, 3) |>
#'   push(vl_viewport(name = "panel", width = vl_unit(2, "in"), height = vl_unit(1, "in")))
#' why_size(s, "panel")
#' @export
why_size <- function(scene, name) {
  scene <- as_vellum_scene(scene)
  root <- .materialize(scene)
  p <- .find_path(root, name)
  if (is.null(p)) cli::cli_abort("No node named {.val {name}}.")
  node <- .get_at(root, p)
  cap <- .capture_geometry(scene)
  item <- Find(function(it) identical(it$name, name), cap$items)

  if (is.null(item)) {
    # A grob (or unnamed-viewport) node: no resolved viewport of its own.
    out <- list(
      name = name,
      width_mm = NA_real_,
      height_mm = NA_real_,
      determined_by = "this is a grob; its size follows its own coordinates within its enclosing viewport"
    )
  } else {
    geom <- cap$geom
    i <- match(item$id, geom$id)
    vp <- item$vp
    determined <- if (!is.null(vp@row) || !is.null(vp@col)) {
      parent <- if (length(p) >= 1L) .get_at(root, p[-length(p)]) else NULL
      lay <- if (!is.null(parent) && S7::S7_inherits(parent, gtree)) parent@vp@layout else NULL
      .describe_track(lay, vp)
    } else {
      sprintf("placed by size: width = %s, height = %s", format(vp@width), format(vp@height))
    }
    out <- list(
      name = name,
      width_mm = geom$w_px[i] / cap$dpi * 25.4,
      height_mm = geom$h_px[i] / cap$dpi * 25.4,
      determined_by = determined
    )
  }
  structure(out, class = "vellum_why_size")
}

#' @export
print.vellum_why_size <- function(x, ...) {
  cli::cli_h3("why_size({.val {x$name}})")
  if (!is.na(x$width_mm)) {
    cli::cli_text("Resolved size: {.val {round(x$width_mm, 2)}} mm wide x {.val {round(x$height_mm, 2)}} mm tall")
  }
  cli::cli_text("Determined by: {x$determined_by}")
  invisible(x)
}
