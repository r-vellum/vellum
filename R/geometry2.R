# Phase 12 -- geometry operations II: boolean path ops, contours, SVG import.

# Op codes are part of the R<->Rust ABI; they must match `Op::from_code` in
# `src/rust/src/booleans.rs`.
.PATH_OPS <- c(union = 0L, intersect = 1L, difference = 2L, xor = 3L)

# Pull the ring structure out of anything ring-shaped: a path/polygon grob, or a
# plain list/data frame of x and y.
.as_rings <- function(g, arg) {
  if (S7::S7_inherits(g, grob_path)) {
    return(list(
      x = .ring_px(g@x),
      y = .ring_px(g@y),
      nper = as.integer(g@nper %||% length(g@x))
    ))
  }
  if (S7::S7_inherits(g, grob_polygon)) {
    return(list(x = .ring_px(g@x), y = .ring_px(g@y), nper = length(g@x)))
  }
  if (is.list(g) && all(c("x", "y") %in% names(g))) {
    # Through `.ring_px` like the grob branches, not `as.numeric()`: a list may
    # hold units too, and they need the same single-coordinate-space check.
    x <- .ring_px(g$x)
    y <- .ring_px(g$y)
    n <- min(length(x), length(y))
    return(list(
      x = x[seq_len(n)],
      y = y[seq_len(n)],
      nper = as.integer(g$nper %||% n)
    ))
  }
  cli::cli_abort(c(
    "{.arg {arg}} must be a {.fn path_grob}, a {.fn polygon_grob}, or a list with {.field x} and {.field y}.",
    i = "Boolean operations are defined on closed rings."
  ))
}

# Ring coordinates as plain numbers. Booleans are a coordinate-space operation:
# the operands must already be in one space, and mixing units would silently
# produce a shape that is correct in neither.
.ring_px <- function(u) {
  if (!is_unit(u)) {
    return(as.numeric(u))
  }
  code <- vctrs::field(u, "unit")
  off <- vctrs::field(u, "offset")
  if (length(unique(code)) > 1L || any(off != 0)) {
    cli::cli_abort(c(
      "Boolean operands must use a single, offset-free unit.",
      i = "A boolean is computed in one coordinate space; mixed units have no common space to compute in."
    ))
  }
  as.numeric(vctrs::field(u, "value"))
}

#' Boolean operations on paths
#'
#' Combine two shapes as **geometry**: union, intersection, difference or
#' exclusive-or over their closed rings.
#'
#' @section Why geometry and not a mask:
#' vellum can already clip one shape by another at render time, and for simply
#' *showing* an intersection that is often enough. A boolean result is different
#' in kind: it is an ordinary path, so it can be measured, hit-tested,
#' simplified, filled with a gradient, stroked, exported as `<path>` data, and
#' fed into another boolean. A mask can do none of those, rasterises, and
#' degrades on some PDF paths.
#'
#' @section Rings, holes and the fill rule:
#' `rule` says how to interpret the **inputs** — whether a ring inside another
#' ring is a hole (`"evenodd"`) or a separate island (`"nonzero"`). It must match
#' the rule the operands were drawn with, or the answer will be correct for a
#' shape you did not mean.
#'
#' The **result** always uses the non-zero rule: holes come back wound opposite
#' to their outer ring, which is how the returned `path_grob()` is set up.
#'
#' Operands must be in a single coordinate space — one unit, no offsets — since
#' a boolean has to be computed somewhere, and mixed units have no common space.
#'
#' @param a,b The operands: a [path_grob()], a [polygon_grob()], or a list with
#'   `x`, `y` and optionally `nper` (points per ring).
#' @param op One of `"union"`, `"intersect"`, `"difference"` (`a` minus `b`), or
#'   `"xor"`.
#' @param rule Fill rule for interpreting the inputs: `"nonzero"` (default) or
#'   `"evenodd"`.
#' @param gp,name,vp,role Passed to the returned [path_grob()].
#' @return A [path_grob()] with `rule = "winding"`. An empty result (a
#'   disjoint intersection, say) gives a grob with no points, which draws
#'   nothing.
#' @examples
#' sq <- function(x0, y0, s = 0.4) {
#'   list(x = c(x0, x0 + s, x0 + s, x0), y = c(y0, y0, y0 + s, y0 + s))
#' }
#' a <- sq(0.2, 0.3)
#' b <- sq(0.45, 0.4)
#' vl_scene(3, 2, dpi = 96, bg = "white") |>
#'   draw(vl_path_op(a, b, "union", gp = vl_gpar(fill = "#DCE7F5", col = "steelblue")))
#' @export
vl_path_op <- function(
  a,
  b,
  op = c("union", "intersect", "difference", "xor"),
  rule = c("nonzero", "evenodd"),
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  role = NULL
) {
  op <- match.arg(op)
  rule <- match.arg(rule)
  ra <- .as_rings(a, "a")
  rb <- .as_rings(b, "b")
  res <- rs_path_op(
    ra$x,
    ra$y,
    ra$nper,
    rb$x,
    rb$y,
    rb$nper,
    .PATH_OPS[[op]],
    identical(rule, "evenodd")
  )
  if (!length(res$nper)) {
    return(path_grob(
      numeric(0),
      numeric(0),
      gp = gp,
      name = name,
      vp = vp,
      role = role
    ))
  }
  path_grob(
    res$x,
    res$y,
    id = rep(seq_along(res$nper), res$nper),
    rule = "winding",
    gp = gp,
    name = name,
    vp = vp,
    role = role
  )
}

#' Contour lines from a grid
#'
#' Marching squares over a matrix, chained into polylines. Use it for density
#' isolines over a [datashade()] surface, level curves of a fitted model, or any
#' other gridded field.
#'
#' Segments are chained into continuous lines rather than returned loose. That
#' matters beyond tidiness: an unchained contour restarts its dash pattern in
#' every grid cell, cannot be simplified or measured, and cannot be filled.
#' Closed rings come back closed.
#'
#' Cells with a non-finite corner are skipped, so a contour **breaks** around
#' missing data rather than being drawn through it.
#'
#' @param z A numeric matrix, with **rows indexing x and columns indexing y** —
#'   `dim(z) == c(length(x), length(y))`, the same convention as
#'   [graphics::image()], [graphics::contour()] and [graphics::persp()], and the
#'   shape `outer(xs, ys, f)` produces.
#' @param levels Contour levels. Defaults to 5 levels spanning the finite range
#'   of `z`, excluding the extremes (a contour at the minimum or maximum is
#'   either empty or the whole boundary).
#' @param xlim,ylim The coordinate range the grid spans. Cell *centres* are
#'   placed at the ends of these ranges, matching `image()`.
#' @return A data frame with one row per point: `level`, `id` (a distinct
#'   contour line), `x`, `y`, and `closed`. Draw it with
#'   `lines_grob(x, y, id = id)`.
#' @examples
#' # A ring contour around a Gaussian bump.
#' # rows index x, columns index y -- exactly what `outer(xs, ys, f)` gives.
#' g <- outer(seq(-3, 3, length.out = 60), seq(-3, 3, length.out = 60),
#'            function(x, y) exp(-(x^2 + y^2) / 2))
#' head(vl_contour(g, levels = c(0.2, 0.5, 0.8)))
#' @export
vl_contour <- function(z, levels = NULL, xlim = c(0, 1), ylim = c(0, 1)) {
  z <- as.matrix(z)
  if (!is.numeric(z)) {
    cli::cli_abort("{.arg z} must be a numeric matrix.")
  }
  # Rows index x, columns index y, matching base R. See `@param z`.
  nx <- nrow(z)
  ny <- ncol(z)
  empty <- data.frame(
    level = numeric(0),
    id = integer(0),
    x = numeric(0),
    y = numeric(0),
    closed = logical(0)
  )
  if (nx < 2L || ny < 2L) {
    return(empty)
  }
  if (is.null(levels)) {
    rng <- range(z[is.finite(z)])
    if (!length(rng) || diff(rng) <= 0) {
      return(empty)
    }
    # Interior levels only: one at the extreme is empty or the whole boundary.
    levels <- seq(rng[1], rng[2], length.out = 7)[2:6]
  }
  # The Rust kernel wants row-major with x fastest-varying, y outer. R stores a
  # matrix column-major, so with columns indexing y that is exactly
  # `as.numeric(z)` -- all x for the first y, then all x for the second, and so
  # on. No transpose needed, which is also why the previous code's `t(z)` was
  # the bug: it fed the grid in transposed and every contour came back reflected
  # across the diagonal.
  flat <- as.numeric(z)
  # Grid coordinates count cells from 0; map them onto xlim/ylim with cell
  # centres at the ends, which is what `image()` does.
  sx <- if (nx > 1L) diff(xlim) / (nx - 1L) else 0
  sy <- if (ny > 1L) diff(ylim) / (ny - 1L) else 0

  out <- vector("list", length(levels))
  next_id <- 0L
  for (k in seq_along(levels)) {
    r <- rs_contour_lines(flat, nx, ny, levels[k])
    if (!length(r$nper)) {
      next
    }
    ids <- next_id + rep(seq_along(r$nper), r$nper)
    next_id <- next_id + length(r$nper)
    out[[k]] <- data.frame(
      level = levels[k],
      id = ids,
      x = xlim[1] + r$x * sx,
      y = ylim[1] + r$y * sy,
      closed = rep(r$closed, r$nper)
    )
  }
  out <- out[!vapply(out, is.null, logical(1))]
  if (!length(out)) {
    return(empty)
  }
  do.call(rbind, out)
}

#' @rdname vl_contour
#' @param contours The data frame returned by `vl_contour()`.
#' @param gp,name,vp,role Passed to each [lines_grob()] the contours become.
#' @param close Draw closed contours as closed rings. `TRUE` (the default) joins
#'   the last point back to the first for contours `vl_contour()` marked
#'   `closed`; open contours are never closed.
#' @export
#' @examples
#' # Draw them: one grob per contour, because each is its own polyline.
#' # rows index x, columns index y -- exactly what `outer(xs, ys, f)` gives.
#' g <- outer(seq(-3, 3, length.out = 60), seq(-3, 3, length.out = 60),
#'            function(x, y) exp(-(x^2 + y^2) / 2))
#' vl_scene(3, 3, dpi = 96, bg = "white") |>
#'   push(vl_viewport(xscale = c(-3, 3), yscale = c(-3, 3))) |>
#'   draw(contour_grob(vl_contour(g, levels = c(0.2, 0.5, 0.8)),
#'                     gp = vl_gpar(col = "steelblue"))) |>
#'   pop() |>
#'   (\(s) s)()
contour_grob <- function(
  contours,
  close = TRUE,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  role = NULL
) {
  if (!nrow(contours)) {
    return(list())
  }
  # One grob per contour, not one grob with an `id`. `lines_grob()` draws a
  # single polyline -- its `id` is the accessibility identifier, not a grouping
  # variable like `path_grob()`'s -- so a shared grob would run a straight line
  # from the end of each contour to the start of the next.
  split(contours, contours$id) |>
    lapply(function(p) {
      xs <- vl_unit(p$x, "native")
      ys <- vl_unit(p$y, "native")
      if (isTRUE(close) && isTRUE(p$closed[1])) {
        # A ring: repeat the first point so the stroke closes. (A `path_grob()`
        # would close it implicitly but would also close *open* contours, which
        # would invent a boundary that is not there.)
        xs <- c(xs, xs[1])
        ys <- c(ys, ys[1])
      }
      lines_grob(xs, ys, gp = gp, name = name, vp = vp, role = role)
    }) |>
    unname()
}

#' SVG path data as scene geometry
#'
#' `vl_svg_path()` parses the `d` attribute of an SVG `<path>` into rings;
#' `svg_grob()` wraps that up as a drawable [path_grob()].
#'
#' This is what makes vector icons usable as marks. Icon sets — Font Awesome,
#' Bootstrap Icons, Lucide, Material — ship one `<path d="...">` per glyph, so
#' `d` is the unit of exchange, and the result here is real geometry: crisp at
#' any size, fillable with a gradient, strokable, and exported as `<path>` data
#' rather than an embedded bitmap.
#'
#' @section Coordinate system:
#' SVG's y axis points **down** and vellum's points up, so `svg_grob()` flips it
#' by default (`flip_y = TRUE`) — otherwise every icon arrives upside-down. The
#' geometry is then scaled so the longer side of its reference box maps to
#' `size`, preserving aspect, and centred on `x`/`y`. `vl_svg_path()` returns the
#' raw parsed coordinates without any of that, for callers doing their own
#' placement.
#'
#' @section Sizing across an icon set — the viewBox:
#' Icon sets draw every glyph inside one shared `viewBox` (commonly
#' `"0 0 24 24"`) and pad each glyph within it, so a glyph's own ink fills only
#' part of the box. Sizing to the *ink* would blow each glyph up to `size`
#' individually — a sparse glyph would render far larger than a dense one from
#' the same set, and a lone icon larger than its nominal box. Pass the set's
#' `viewbox` (the four numbers `c(xmin, ymin, width, height)`, or the raw
#' attribute string `"0 0 24 24"`) and `size` maps the *box* instead, so every
#' glyph keeps its intended relative and absolute size. If you hand `svg_grob()`
#' a whole `<svg>…</svg>` element (see below) its `viewBox` is used automatically.
#' With no viewBox at all, sizing falls back to the path's own ink bounds.
#'
#' @section What is supported:
#' The whole `d` grammar: `M`/`L`/`H`/`V`/`C`/`S`/`Q`/`T`/`A`/`Z` in absolute and
#' relative forms, implicit repeated commands, the smooth-curve reflection rules,
#' and elliptical arcs. Curves are flattened to polylines.
#'
#' `svg_grob()` also accepts a whole `<svg>` element as `d`: it reads the
#' `<path>` geometry and the document `viewBox` (needs the \pkg{xml2} package).
#' Only `<path>` elements are read — other drawable shapes (`<circle>`, `<rect>`,
#' `<line>`, …) are not path data and are reported with a warning, not silently
#' dropped. The rest of SVG is still out of scope: no stylesheets, gradients,
#' `<use>`, clip paths, or element transforms — this reads geometry, not
#' documents.
#'
#' Malformed data yields whatever parsed before the problem rather than an
#' error: a truncated icon is easier to diagnose than a stack trace.
#'
#' @param d A character string of SVG path data, or (for `svg_grob()`) a whole
#'   `<svg>` element to read `<path>` geometry and the `viewBox` from.
#' @param x,y Centre of the drawn icon.
#' @param size Size of the reference box's longer side, as a [vl_unit()] — the
#'   viewBox when one is given, otherwise the path's own bounding box.
#' @param flip_y Flip the y axis to convert from SVG's convention. Leave `TRUE`
#'   unless your `d` is already in a y-up space.
#' @param viewbox The icon's SVG `viewBox` as `c(xmin, ymin, width, height)` or
#'   the attribute string `"xmin ymin width height"`, so `size` scales the box
#'   rather than the glyph's ink. `NULL` (default) uses a whole-`<svg>`
#'   document's own viewBox if present, else the path's ink bounds.
#' @param gp,name,vp,id,role Passed to the returned [path_grob()].
#' @return `vl_svg_path()`: a data frame of `x`, `y`, `id`, `closed`.
#'   `svg_grob()`: a [path_grob()].
#' @examples
#' # A five-pointed star, as an icon set would ship it.
#' star <- "M12 2 L15 9 L22 9.3 L16.5 13.8 L18.5 21 L12 17 L5.5 21 L7.5 13.8 L2 9.3 L9 9 Z"
#' vl_scene(3, 2, dpi = 96, bg = "white") |>
#'   draw(svg_grob(star, x = 0.5, y = 0.5, size = vl_unit(15, "mm"),
#'                 gp = vl_gpar(fill = "#F1C40F", col = "grey30")))
#'
#' # As per-point markers, which is what raster icons cannot do crisply.
#' set.seed(1)
#' s <- vl_scene(4, 2, dpi = 96, bg = "white")
#' for (i in 1:6) {
#'   s <- draw(s, svg_grob(star, x = i / 7, y = runif(1) * 0.6 + 0.2,
#'                         size = vl_unit(6, "mm"),
#'                         gp = vl_gpar(fill = "#2C6FA6", col = NA)))
#' }
#' s
#' @export
vl_svg_path <- function(d) {
  d <- as.character(d)
  if (length(d) != 1L || is.na(d)) {
    cli::cli_abort("{.arg d} must be a single string of SVG path data.")
  }
  r <- rs_svg_path(d)
  if (!length(r$nper)) {
    return(data.frame(
      x = numeric(0),
      y = numeric(0),
      id = integer(0),
      closed = logical(0)
    ))
  }
  data.frame(
    x = r$x,
    y = r$y,
    id = rep(seq_along(r$nper), r$nper),
    closed = rep(r$closed, r$nper)
  )
}

#' @rdname vl_svg_path
#' @export
svg_grob <- function(
  d,
  x = 0.5,
  y = 0.5,
  size = vl_unit(10, "mm"),
  flip_y = TRUE,
  viewbox = NULL,
  gp = vl_gpar(),
  name = NULL,
  vp = NULL,
  id = NULL,
  role = NULL
) {
  empty <- function() {
    path_grob(
      numeric(0),
      numeric(0),
      gp = gp,
      name = name,
      vp = vp,
      role = role
    )
  }
  parsed <- .svg_grob_input(d, viewbox)
  p <- vl_svg_path(parsed$d)
  if (!nrow(p)) {
    return(empty())
  }
  if (isTRUE(flip_y)) {
    p$y <- -p$y
  }
  # Map the longer side of the reference box to `size` and centre it on (x, y).
  # With a viewBox the box is the viewBox, so every glyph in a set (which shares
  # one viewBox but inks a different fraction of it) keeps its intended relative
  # size; without one, the box is the path's own ink bounds -- a lone glyph then
  # simply fills `size`.
  frame <- .svg_norm_frame(p, parsed$viewbox, flip_y)
  if (is.null(frame)) {
    return(empty())
  }
  # `unit * numeric` is elementwise, not recycling, so widen the scalars to the
  # point count before combining them.
  n <- nrow(p)
  su <- vctrs::vec_recycle(as_unit(size), n)
  cx <- vctrs::vec_recycle(as_unit(x), n)
  cy <- vctrs::vec_recycle(as_unit(y), n)
  path_grob(
    x = cx + su * ((p$x - frame$cx) / frame$span),
    y = cy + su * ((p$y - frame$cy) / frame$span),
    id = p$id,
    rule = "evenodd",
    gp = gp,
    name = name,
    vp = vp,
    role = role
  )
}

# Resolve `svg_grob()`'s `d`/`viewbox` inputs: normalise a user-supplied
# `viewbox`, and when `d` is a whole `<svg>` element (not bare path data) pull
# the `<path>` geometry and the document's own `viewBox` out of it. An explicit
# `viewbox` argument always wins over the document's.
.svg_grob_input <- function(d, viewbox) {
  vb <- .parse_viewbox(viewbox)
  d <- as.character(d)
  if (length(d) == 1L && !is.na(d) && grepl("<svg", d, ignore.case = TRUE)) {
    ex <- .svg_extract(d)
    d <- ex$d
    vb <- vb %||% ex$viewbox
  }
  list(d = d, viewbox = vb)
}

# The (centre, span) that maps a reference box's longer side to `size`. Uses the
# viewBox when given (its centre flipped to match the flipped path), else the
# path's ink bounds. NULL for a degenerate (zero-span) box.
.svg_norm_frame <- function(p, viewbox, flip_y) {
  if (!is.null(viewbox)) {
    span <- max(viewbox[3L], viewbox[4L])
    cx <- viewbox[1L] + viewbox[3L] / 2
    cy <- viewbox[2L] + viewbox[4L] / 2
    if (isTRUE(flip_y)) {
      cy <- -cy
    }
  } else {
    rx <- range(p$x)
    ry <- range(p$y)
    span <- max(diff(rx), diff(ry))
    cx <- mean(rx)
    cy <- mean(ry)
  }
  if (span <= 0) {
    return(NULL)
  }
  list(cx = cx, cy = cy, span = span)
}

# Normalise a `viewbox` argument to numeric `c(xmin, ymin, width, height)`, or
# NULL. Accepts that vector or the raw SVG `viewBox` attribute string
# ("xmin ymin width height", space- or comma-separated).
.parse_viewbox <- function(vb) {
  if (is.null(vb)) {
    return(NULL)
  }
  if (is.character(vb)) {
    if (length(vb) != 1L || is.na(vb)) {
      cli::cli_abort(
        "A {.arg viewbox} string must be a single {.val xmin ymin width height}."
      )
    }
    vb <- as.numeric(strsplit(trimws(vb), "[[:space:],]+")[[1L]])
  }
  vb <- suppressWarnings(as.numeric(vb))
  if (length(vb) != 4L || anyNA(vb)) {
    cli::cli_abort(
      "{.arg viewbox} must be four numbers {.code c(xmin, ymin, width, height)}, or that as a string."
    )
  }
  if (!(vb[3L] > 0 && vb[4L] > 0)) {
    cli::cli_abort("{.arg viewbox} width and height must be positive.")
  }
  vb
}

# Pull path geometry and the viewBox out of a whole `<svg>` string. Needs xml2
# (a Suggests). Only `<path>` elements are read -- other drawable shapes
# (`<circle>`, `<rect>`, ...) are not path data and are reported, not silently
# dropped.
.svg_extract <- function(svg) {
  if (!requireNamespace("xml2", quietly = TRUE)) {
    cli::cli_abort(c(
      "Reading a whole {.code <svg>} element in {.fn svg_grob} needs the {.pkg xml2} package.",
      i = "Install it, or pass just the {.code d} path string (with a {.arg viewbox})."
    ))
  }
  doc <- tryCatch(
    xml2::read_xml(svg),
    error = function(e) {
      cli::cli_abort("Could not parse the {.code <svg>} string.", parent = e)
    }
  )
  vb_attr <- xml2::xml_attr(doc, "viewBox")
  vb <- if (!is.na(vb_attr)) .parse_viewbox(vb_attr) else NULL
  # local-name() so it matches whether or not the SVG carries a namespace.
  paths <- xml2::xml_find_all(doc, ".//*[local-name()='path']")
  ds <- xml2::xml_attr(paths, "d")
  ds <- ds[!is.na(ds)]
  others <- xml2::xml_find_all(
    doc,
    ".//*[local-name()='circle' or local-name()='rect' or local-name()='ellipse' or local-name()='line' or local-name()='polyline' or local-name()='polygon']"
  )
  if (length(others)) {
    cli::cli_warn(
      "{.fn svg_grob} reads {.code <path>} elements only; ignored {length(others)} other shape{?s} in the SVG."
    )
  }
  list(d = paste(ds, collapse = " "), viewbox = vb)
}
