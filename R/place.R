# Phase 11 -- label placement as an engine service.
#
# Everything here is geometry over *resolved* boxes: no data semantics, no
# grammar. That is what makes it belong below a plotting layer rather than
# inside one, and it is why the solver is viewport-agnostic -- it never asks
# which panel a box came from, or whether that panel is cartesian.

# The resolved per-node table, in device pixels: kind, name, box, clip box,
# element count, label. One row per node, in draw order, so the k-th row named
# X is the k-th element of the grob named X.
.resolved_nodes <- function(scene, backend = NULL) {
  b <- backend %||% .scene_to_backend(scene)
  as.data.frame(b$lint_table(), stringsAsFactors = FALSE)
}

# Obstacle boxes at the finest granularity the scene can report.
#
# A batched mark is ONE node whose box is the union of every element, so a
# 2000-point scatter's node box is the whole panel -- useless to collide
# against. `element_table()` breaks those out per element, but it only covers
# the batched and keyed marks, so anything it does not emit (text, images,
# unkeyed paths) still has to come from the per-node table.
#
# The two are joined on the node index rather than on a hardcoded list of which
# kinds `element_table()` covers, so this stays correct if that set changes.
.obstacle_boxes <- function(scene, backend = NULL) {
  b <- backend %||% .scene_to_backend(scene)
  nodes <- .resolved_nodes(scene, b)
  el <- as.data.frame(b$element_table(), stringsAsFactors = FALSE)
  cols <- c("name", "kind", "node", "x0", "y0", "x1", "y1")
  rest <- nodes[!(nodes$node %in% el$node), cols, drop = FALSE]
  rbind(if (nrow(el)) el[, cols, drop = FALSE], rest)
}

# Rows whose `name` is in `which`; NULL falls back to `default`.
.pick_nodes <- function(nodes, which, default) {
  if (is.null(which)) {
    return(default)
  }
  nodes$name %in% which
}

#' Move labels so they stop overlapping
#'
#' `vl_place()` solves label collisions over a scene's **resolved** geometry and
#' reports the displacement each label needs. `vl_repel()` applies that solution
#' and returns a new scene.
#'
#' @section Why this is an engine service:
#' Repulsion is a geometry problem over boxes: where things ended up, how big
#' they are, and what they must not touch. It carries no data semantics, so
#' every layer above vellum would otherwise reimplement it — and reimplement it
#' against numbers it can only get by rendering first.
#'
#' Because the solve happens in **device pixels** and the answer is applied as an
#' absolute millimetre offset on top of each label's existing coordinate, it does
#' not care what produced the position. A label anchored in `native` units inside
#' a polar viewport, a facet panel, or a warped coordinate system moves by the
#' same mechanism as one in `npc` on the page, and panels are all solved together
#' rather than one at a time.
#'
#' @section What it does not do:
#' It moves labels; it does not choose which to drop, shrink or abbreviate —
#' those are editorial decisions belonging to the layer that knows what the
#' labels mean. Labels that cannot be separated within `max_shift` are reported
#' with `resolved = FALSE` rather than silently piled up or quietly deleted.
#'
#' @param scene A [vl_scene()] (or anything with an [as_vellum_scene()] method).
#' @param labels Names of the grobs to move. `NULL` (default) takes every text
#'   node in the scene.
#' @param avoid Names of the grobs to treat as obstacles. `NULL` (default) takes
#'   every node that is not a label.
#' @param padding Clear space to keep around each label, in millimetres.
#' @param max_shift The furthest a label may travel from its anchor, in
#'   millimetres. Labels needing more are left at their best position and
#'   reported as unresolved.
#' @param max_iter Iteration cap for the relaxation.
#' @param pull Strength of the spring back to the anchor, in `[0, 1]`. Higher
#'   keeps labels closer to what they label; lower resolves crowding more
#'   readily.
#' @return `vl_place()`: a data frame with one row per label — `name`, `index`
#'   (which element of that grob), the original device box `x0`/`y0`/`x1`/`y1`,
#'   the shift `dx`/`dy` in millimetres, and `resolved` (did it end up clear).
#'   `vl_repel()`: a new scene.
#' @seealso [vl_empty_region()] for placing one thing in the gap rather than
#'   moving many things apart.
#' @examples
#' set.seed(1)
#' n <- 12
#' s <- vl_scene(5, 3, dpi = 96, bg = "white") |>
#'   draw(points_grob(runif(n), runif(n), gp = vl_gpar(fill = "steelblue", col = NA),
#'                    name = "pts")) |>
#'   draw(text_grob(paste0("item ", seq_len(n)), x = runif(n), y = runif(n),
#'                  gp = vl_gpar(fontsize = 9), name = "lab"))
#' head(vl_place(s))
#' @export
vl_place <- function(scene, labels = NULL, avoid = NULL, padding = 1,
                     max_shift = 10, max_iter = 200, pull = 0.1) {
  scene <- as_vellum_scene(scene)
  b <- .scene_to_backend(scene)
  nodes <- .resolved_nodes(scene, b)
  dpi <- scene@dpi
  pad <- padding / 25.4 * dpi
  cap <- max_shift / 25.4 * dpi

  # Labels come from the per-NODE table: a vectorised text grob compiles to one
  # node per label, so its node box is already the label's box -- and the node
  # table is the only place a text box appears at all.
  is_lab <- .pick_nodes(nodes, labels, nodes$kind == "text")
  lab <- nodes[is_lab, , drop = FALSE]
  # Obstacles come from the per-ELEMENT view, minus whatever the labels are.
  all_obs <- .obstacle_boxes(scene, b)
  is_obs <- .pick_nodes(all_obs, avoid, !(all_obs$node %in% lab$node))
  obs <- all_obs[is_obs, , drop = FALSE]
  empty <- data.frame(name = character(0), index = integer(0),
                      x0 = numeric(0), y0 = numeric(0), x1 = numeric(0), y1 = numeric(0),
                      dx = numeric(0), dy = numeric(0), resolved = logical(0))
  if (!nrow(lab)) {
    return(empty)
  }

  # Half-extents, padded. The solver works on centres; boxes are reconstructed
  # from centre +- half-extent throughout.
  hw <- (lab$x1 - lab$x0) / 2 + pad
  hh <- (lab$y1 - lab$y0) / 2 + pad
  ax <- (lab$x0 + lab$x1) / 2
  ay <- (lab$y0 + lab$y1) / 2
  cx <- ax
  cy <- ay

  # Keep labels on the page.
  #
  # Without this the solver will happily push a label off the canvas to resolve
  # a collision, which is strictly worse than the collision: an overlapping
  # label is hard to read, an off-canvas one is gone. Measured on a two-panel
  # scene it turned 3 off-page labels into 9.
  #
  # The bound is the label's own clip region intersected with the page, so a
  # label inside a clipped panel is kept inside that panel. It is widened to
  # include the label's anchor, which means a label the author deliberately
  # placed off-page is left where they put it -- this constrains the *solver*,
  # it does not reposition anything on its own.
  dim <- .scene_to_backend(scene)$dim()
  clip_lo_x <- pmax(0, lab$clip_x0)
  clip_lo_y <- pmax(0, lab$clip_y0)
  clip_hi_x <- pmin(dim[1], lab$clip_x1)
  clip_hi_y <- pmin(dim[2], lab$clip_y1)
  lo_x <- pmin(clip_lo_x + hw, ax)
  hi_x <- pmax(clip_hi_x - hw, ax)
  lo_y <- pmin(clip_lo_y + hh, ay)
  hi_y <- pmax(clip_hi_y - hh, ay)
  # A region narrower than the label leaves nothing to choose; pin to the anchor.
  bad <- !is.finite(lo_x) | !is.finite(hi_x) | lo_x > hi_x
  lo_x[bad] <- ax[bad]; hi_x[bad] <- ax[bad]
  bad <- !is.finite(lo_y) | !is.finite(hi_y) | lo_y > hi_y
  lo_y[bad] <- ay[bad]; hi_y[bad] <- ay[bad]
  in_bounds <- function(px, py, i) px >= lo_x[i] & px <= hi_x[i] & py >= lo_y[i] & py <= hi_y[i]

  # Resolve collisions to just BEYOND contact. Pushing to exactly zero overlap
  # leaves every separation on a floating-point knife edge, where "do these
  # boxes touch" is decided by the last bit of the arithmetic -- so labels the
  # solver had in fact separated still reported as colliding.
  eps <- 0.5
  ohw <- (obs$x1 - obs$x0) / 2
  ohh <- (obs$y1 - obs$y0) / 2
  ox <- (obs$x0 + obs$x1) / 2
  oy <- (obs$y0 + obs$y1) / 2
  n <- nrow(lab)

  # An obstacle a label cannot escape is not an obstacle -- it is background.
  #
  # This matters because the default obstacle set is "everything that is not a
  # label", which on any real plot includes the **panel background rectangle**.
  # A label inside it collides with it no matter where it goes, so it is
  # permanently unresolvable and its collision force is a constant nudge in an
  # arbitrary direction that drowns out the real ones. Measured on a two-panel
  # scene: 29 of 32 labels unresolved with the panel rect in the set, 0 without.
  #
  # An obstacle is background *for a given label* when it wholly contains that
  # label where it sits. Two cases, and the rule is right for both:
  #
  #   * a panel background, gridline block or facet strip -- the label cannot
  #     leave it, so treating it as an obstacle only injects a constant nudge in
  #     an arbitrary direction;
  #   * a bar or region the label deliberately annotates from the inside, where
  #     pushing the label *out* would be exactly wrong.
  #
  # It is judged on the label's anchor, not its current position, so the set is
  # fixed for the whole solve. Tying it to `max_shift` instead was tried and is
  # worse in a way that is easy to miss: a larger budget makes more obstacles
  # "escapable", so raising `max_shift` re-admitted the panel background and made
  # the result worse (12 unresolved at 10 mm, 22 at 25 mm).
  #
  # Naming an obstacle explicitly via `avoid` does not bypass this. An obstacle
  # that contains the label cannot be avoided by moving the label, whoever asked.
  contains_label <- function(i) {
    if (!nrow(obs)) {
      return(integer(0))
    }
    inside <- obs$x0 <= lab$x0[i] & obs$x1 >= lab$x1[i] &
      obs$y0 <= lab$y0[i] & obs$y1 >= lab$y1[i]
    which(!inside)
  }
  live <- lapply(seq_len(n), contains_label)

  # Force relaxation. Overlaps are resolved along the axis of *least* separation
  # (the minimum-translation direction), which moves a label out of a collision
  # the short way instead of drifting it diagonally.
  #
  # The best configuration seen is remembered and returned. Relaxation on a
  # crowded page does not converge monotonically -- a label that has just come
  # clear gets eased back toward its anchor and can re-collide -- so without
  # this the answer depends on which point of the oscillation `max_iter` happens
  # to land on, and can be worse than an earlier state.
  best_cx <- cx
  best_cy <- cy
  best_pen <- Inf
  for (iter in seq_len(max_iter)) {
    fx <- numeric(n)
    fy <- numeric(n)
    hit_any <- logical(n)
    pen <- 0
    moved <- FALSE
    # Label vs label.
    if (n > 1L) {
      for (i in seq_len(n - 1L)) {
        j <- seq.int(i + 1L, n)
        dx <- cx[j] - cx[i]
        dy <- cy[j] - cy[i]
        ox_ <- (hw[i] + hw[j]) - abs(dx)
        oy_ <- (hh[i] + hh[j]) - abs(dy)
        hit <- which(ox_ > 0 & oy_ > 0)
        for (k in hit) {
          jj <- j[k]
          if (ox_[k] < oy_[k]) {
            push <- sign(dx[k] %||% 0)
            if (push == 0) push <- if ((i + jj) %% 2 == 0) 1 else -1
            fx[i] <- fx[i] - push * (ox_[k] + eps) / 2
            fx[jj] <- fx[jj] + push * (ox_[k] + eps) / 2
          } else {
            push <- sign(dy[k])
            if (push == 0) push <- if ((i + jj) %% 2 == 0) 1 else -1
            fy[i] <- fy[i] - push * (oy_[k] + eps) / 2
            fy[jj] <- fy[jj] + push * (oy_[k] + eps) / 2
          }
          hit_any[i] <- TRUE
          hit_any[jj] <- TRUE
          pen <- pen + min(ox_[k], oy_[k])
          moved <- TRUE
        }
      }
    }
    # Label vs obstacle: only the label yields.
    if (nrow(obs)) {
      for (i in seq_len(n)) {
        j <- live[[i]]
        if (!length(j)) next
        dx <- cx[i] - ox[j]
        dy <- cy[i] - oy[j]
        ox_ <- (hw[i] + ohw[j]) - abs(dx)
        oy_ <- (hh[i] + ohh[j]) - abs(dy)
        hit <- which(ox_ > 0 & oy_ > 0)
        for (k in hit) {
          if (ox_[k] < oy_[k]) {
            push <- sign(dx[k])
            if (push == 0) push <- 1
            fx[i] <- fx[i] + push * (ox_[k] + eps)
          } else {
            push <- sign(dy[k])
            if (push == 0) push <- 1
            fy[i] <- fy[i] + push * (oy_[k] + eps)
          }
          hit_any[i] <- TRUE
          pen <- pen + min(ox_[k], oy_[k])
          moved <- TRUE
        }
      }
    }
    # Score by total overlap DEPTH, not by a count of collisions. A count
    # plateaus -- a label half-buried in an obstacle it cannot escape keeps the
    # tally flat while everything else improves, so the "best" configuration
    # stays pinned to the starting one. Depth falls smoothly and rewards partial
    # progress.
    if (pen < best_pen) {
      best_pen <- pen
      best_cx <- cx
      best_cy <- cy
    }
    if (!moved) {
      break
    }
    # Cool down: big moves early to escape a bad start, small ones late so the
    # configuration settles instead of ringing.
    cool <- 1 - 0.7 * (iter - 1) / max(max_iter - 1, 1)
    # Damped step, plus a spring home applied ONLY to labels that are currently
    # clear.
    #
    # Springing a colliding label as well looks natural and is wrong: the two
    # forces reach equilibrium while the overlap is still positive (push is
    # proportional to the overlap, pull to the displacement), so labels settle
    # permanently touching. Letting the push win outright while a label is in
    # collision, and only easing it home once it is free, converges to actually
    # separated labels.
    home <- ifelse(hit_any, 0, pull * cool)
    cx <- cx + 0.6 * cool * fx - home * (cx - ax)
    cy <- cy + 0.6 * cool * fy - home * (cy - ay)
    # Clamp to the travel budget, radially, so the direction found is kept.
    d <- sqrt((cx - ax)^2 + (cy - ay)^2)
    over <- d > cap
    if (any(over)) {
      f <- cap / d[over]
      cx[over] <- ax[over] + (cx[over] - ax[over]) * f
      cy[over] <- ay[over] + (cy[over] - ay[over]) * f
    }
    # ...and to the page/clip region, so a collision is never resolved by
    # pushing a label out of sight.
    cx <- pmin(pmax(cx, lo_x), hi_x)
    cy <- pmin(pmax(cy, lo_y), hi_y)
  }

  cx <- best_cx
  cy <- best_cy

  # Greedy repair. Relaxation is a local method: it slides a label out of the
  # collision it is in, and cannot consider that the far side of its anchor was
  # free all along. For each label still colliding, try candidate positions on a
  # ring of directions and radii around the anchor and take the nearest one that
  # is clear -- which is how dedicated label placers work, and what local
  # relaxation on its own reliably misses.
  hits <- function(i, px, py) {
    others <- setdiff(seq_len(n), i)
    lab_hit <- length(others) > 0 &&
      any(abs(cx[others] - px) < (hw[others] + hw[i]) - 1e-9 &
            abs(cy[others] - py) < (hh[others] + hh[i]) - 1e-9)
    j <- live[[i]]
    obs_hit <- length(j) > 0 &&
      any(abs(ox[j] - px) < (ohw[j] + hw[i]) - 1e-9 &
            abs(oy[j] - py) < (ohh[j] + hh[i]) - 1e-9)
    lab_hit || obs_hit
  }
  ang <- seq(0, 2 * pi, length.out = 17)[-17]
  for (i in seq_len(n)) {
    if (!hits(i, cx[i], cy[i])) {
      next
    }
    # Radii from just-clear to the travel budget. Nearest-first, so a label
    # never moves further than it has to.
    for (rad in seq(max(hw[i], hh[i]) * 0.6, cap, length.out = 8)) {
      px <- ax[i] + rad * cos(ang)
      py <- ay[i] + rad * sin(ang)
      ok <- which(in_bounds(px, py, i) &
                    !vapply(seq_along(ang), function(k) hits(i, px[k], py[k]), logical(1)))
      if (length(ok)) {
        # Among the clear candidates at this radius, the one closest to where
        # relaxation had already pushed the label -- so the two passes agree
        # rather than fight.
        d <- (px[ok] - cx[i])^2 + (py[ok] - cy[i])^2
        cx[i] <- px[ok][which.min(d)]
        cy[i] <- py[ok][which.min(d)]
        break
      }
    }
  }

  # Did each label end up clear of everything?
  clear <- vapply(seq_len(n), function(i) {
    others <- setdiff(seq_len(n), i)
    lab_hit <- any(abs(cx[others] - cx[i]) < (hw[others] + hw[i]) &
                     abs(cy[others] - cy[i]) < (hh[others] + hh[i]))
    j <- live[[i]]
    obs_hit <- length(j) > 0 && any(abs(ox[j] - cx[i]) < (ohw[j] + hw[i]) &
                                      abs(oy[j] - cy[i]) < (ohh[j] + hh[i]))
    !(lab_hit || obs_hit)
  }, logical(1))

  data.frame(
    name = lab$name,
    index = unlist(lapply(rle(lab$name)$lengths, seq_len), use.names = FALSE),
    x0 = lab$x0, y0 = lab$y0, x1 = lab$x1, y1 = lab$y1,
    # Device y grows downward; a unit offset is in user space, where it grows up.
    dx = (cx - ax) / dpi * 25.4,
    dy = -(cy - ay) / dpi * 25.4,
    resolved = clear,
    row.names = NULL, stringsAsFactors = FALSE
  )
}

#' @rdname vl_place
#' @export
vl_repel <- function(scene, labels = NULL, avoid = NULL, padding = 1,
                     max_shift = 10, max_iter = 200, pull = 0.1) {
  scene <- as_vellum_scene(scene)
  sol <- vl_place(scene, labels, avoid, padding, max_shift, max_iter, pull)
  if (!nrow(sol)) {
    return(scene)
  }
  for (nm in unique(sol$name)) {
    if (!nzchar(nm)) {
      next # an unnamed node cannot be addressed, so it cannot be moved
    }
    node <- get_node(scene, nm)
    if (is.null(node)) {
      next
    }
    s <- sol[sol$name == nm, , drop = FALSE]
    s <- s[order(s$index), , drop = FALSE]
    # The shift is applied as a compound `<original> + <mm>` unit. That is the
    # whole reason this works in any coordinate system: an absolute offset is
    # added at render, after the base unit has resolved, so the label keeps its
    # data anchor and moves by exactly the distance the solver asked for.
    nx <- vctrs::vec_recycle(node@x, nrow(s))
    ny <- vctrs::vec_recycle(node@y, nrow(s))
    scene <- edit_node(scene, nm,
                       x = nx + vl_unit(s$dx, "mm"),
                       y = ny + vl_unit(s$dy, "mm"))
  }
  scene
}

#' Find the largest empty rectangle in a scene
#'
#' Answers "where is there room?" — for a legend, an annotation, a watermark, or
#' anything else that has to go somewhere the marks are not.
#'
#' Occupancy is rasterised onto a grid and the answer is exact *on that grid*.
#' The approximation is deliberate: the exact maximal empty rectangle over n
#' boxes is superquadratic, and nothing is placed to sub-pixel tolerance. Raise
#' `grid` to trade time for precision. Boxes are rounded outward, so the result
#' is conservative — it will never claim space that is in fact occupied.
#'
#' @inheritParams vl_place
#' @param within Region to search, as `c(x0, y0, x1, y1)` in `npc` of the page.
#'   Defaults to the whole page.
#' @param grid Grid resolution (cells across the longer side).
#' @param unit Unit of the returned rectangle: `"npc"` (default) or `"mm"`.
#' @return A named numeric `c(x0, y0, x1, y1)`, in `unit`, using the usual
#'   y-grows-up convention. All zeros if there is no free space.
#' @examples
#' set.seed(1)
#' s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
#'   draw(points_grob(runif(40) * 0.5, runif(40),
#'                    gp = vl_gpar(fill = "steelblue", col = NA)))
#' vl_empty_region(s)
#' @export
vl_empty_region <- function(scene, avoid = NULL, within = NULL, grid = 200,
                            unit = c("npc", "mm")) {
  unit <- match.arg(unit)
  scene <- as_vellum_scene(scene)
  nodes <- .resolved_nodes(scene)
  b <- .scene_to_backend(scene)
  d <- b$dim()
  w <- d[1]
  h <- d[2]
  keep <- .pick_nodes(nodes, avoid, rep(TRUE, nrow(nodes)))
  nodes <- nodes[keep, , drop = FALSE]

  reg <- within %||% c(0, 1, 0, 1)[c(1, 3, 2, 4)]
  if (length(reg) != 4L) {
    cli::cli_abort("{.arg within} must be {.code c(x0, y0, x1, y1)}.")
  }
  # npc (y up) -> device px (y down).
  dev <- c(reg[1] * w, (1 - reg[4]) * h, reg[3] * w, (1 - reg[2]) * h)
  boxes <- if (nrow(nodes)) {
    as.numeric(t(as.matrix(nodes[, c("x0", "y0", "x1", "y1")])))
  } else {
    numeric(0)
  }
  ar <- (dev[3] - dev[1]) / max(dev[4] - dev[2], 1e-9)
  nx <- max(1L, as.integer(if (ar >= 1) grid else grid * ar))
  ny <- max(1L, as.integer(if (ar >= 1) grid / ar else grid))
  r <- rs_largest_empty_rect(boxes, dev, nx, ny)
  if (all(r == 0)) {
    return(c(x0 = 0, y0 = 0, x1 = 0, y1 = 0))
  }
  out <- c(x0 = r[1] / w, y0 = 1 - r[4] / h, x1 = r[3] / w, y1 = 1 - r[2] / h)
  if (unit == "mm") {
    out <- out * c(w, h, w, h) / scene@dpi * 25.4
  }
  out
}

#' Hull of a point set
#'
#' `vl_hull()` returns the convex hull, or a concave one that follows the point
#' set more closely — useful for outlining a cluster, or for building an
#' exclusion zone that annotations should avoid.
#'
#' The concave hull digs into the convex hull, replacing an edge with two edges
#' through the nearest unused point whenever the edge is long relative to the
#' detour. `concavity` is that threshold, and **larger means more convex**:
#'
#' * `Inf` (the default) is exactly the convex hull.
#' * `8` follows the points loosely.
#' * `4` is a good tight outline for a scattered cluster.
#' * Below about `3` the boundary starts to self-intersect.
#'
#' Self-intersection is inherent to the method, not a defect to be fixed here —
#' a boundary that threads between interior points has to cross itself
#' eventually. Inspect the result if you push it hard.
#'
#' @param x,y Point coordinates (plain numerics, in whatever space you are
#'   working in — the hull is scale-free).
#' @param concavity Threshold as above; larger is more convex, and `Inf` (the
#'   default) is the convex hull.
#' @return A data frame of the hull ring's `x`/`y`, in order, ready for
#'   [polygon_grob()]. The ring is not closed (the last point does not repeat
#'   the first).
#' @examples
#' set.seed(1)
#' pts <- data.frame(x = runif(40), y = runif(40))
#' h <- vl_hull(pts$x, pts$y)
#' vl_scene(3, 3, dpi = 96, bg = "white") |>
#'   draw(polygon_grob(h$x, h$y, gp = vl_gpar(fill = "#DCE7F5", col = "steelblue"))) |>
#'   draw(points_grob(pts$x, pts$y, gp = vl_gpar(fill = "grey25", col = NA)))
#' @export
vl_hull <- function(x, y, concavity = Inf) {
  x <- as.numeric(x)
  y <- as.numeric(y)
  n <- min(length(x), length(y))
  if (n == 0L) {
    return(data.frame(x = numeric(0), y = numeric(0)))
  }
  i <- rs_hull(x[seq_len(n)], y[seq_len(n)], as.numeric(concavity))
  data.frame(x = x[i], y = y[i])
}

#' Buffer a polygon outward
#'
#' Grows a ring by `width` in every direction — the exclusion zone around a
#' region, the halo around a cluster outline, the standoff a leader line should
#' keep.
#'
#' Corners are rounded, which is what a standoff usually wants and what keeps the
#' result well-defined at sharp angles (a mitred corner runs away to infinity as
#' the angle closes).
#'
#' **On concave rings:** the offset boundary of a concave polygon can cross
#' itself where the buffer is wider than a local feature. This function offsets
#' the ring and does not repair that, because repairing it is a boolean union —
#' a Phase 12 operation. Buffering a convex ring, or buffering by less than the
#' narrowest feature, is always well-behaved. Passing the result through
#' [vl_hull()] is a crude but effective fix when it is not.
#'
#' @param x,y The ring's coordinates, in order and not closed.
#' @param width Distance to grow by, in the same units as `x`/`y`.
#' @param arc Points per quarter-turn on rounded corners. More is smoother.
#' @return A data frame of the buffered ring's `x`/`y`.
#' @examples
#' tri <- data.frame(x = c(0.3, 0.7, 0.5), y = c(0.3, 0.35, 0.7))
#' buf <- vl_buffer(tri$x, tri$y, 0.08)
#' vl_scene(3, 3, dpi = 96, bg = "white") |>
#'   draw(polygon_grob(buf$x, buf$y, gp = vl_gpar(fill = "#F3E0DA", col = NA))) |>
#'   draw(polygon_grob(tri$x, tri$y, gp = vl_gpar(fill = "tomato", col = NA)))
#' @export
vl_buffer <- function(x, y, width, arc = 6) {
  x <- as.numeric(x)
  y <- as.numeric(y)
  n <- min(length(x), length(y))
  if (n < 3L || !is.finite(width) || width == 0) {
    return(data.frame(x = x[seq_len(n)], y = y[seq_len(n)]))
  }
  x <- x[seq_len(n)]
  y <- y[seq_len(n)]
  # Orientation decides which side is "out": offset along the outward normal, so
  # a clockwise ring is not silently shrunk.
  area2 <- sum(x * c(y[-1], y[1]) - c(x[-1], x[1]) * y)
  sgn <- if (area2 < 0) -1 else 1
  ox <- numeric(0)
  oy <- numeric(0)
  arc <- max(1L, as.integer(arc))
  for (i in seq_len(n)) {
    p <- if (i == 1L) n else i - 1L
    nx_ <- if (i == n) 1L else i + 1L
    # Outward normals of the two edges meeting at vertex i.
    e1 <- .unit_normal(x[i] - x[p], y[i] - y[p], sgn)
    e2 <- .unit_normal(x[nx_] - x[i], y[nx_] - y[i], sgn)
    a1 <- atan2(e1[2], e1[1])
    a2 <- atan2(e2[2], e2[1])
    # Sweep the shorter way round from one normal to the other; a straight
    # vertex sweeps nothing and contributes a single point.
    d <- ((a2 - a1 + pi) %% (2 * pi)) - pi
    steps <- max(1L, as.integer(ceiling(abs(d) / (pi / 2) * arc)))
    t <- seq(0, d, length.out = steps + 1L)
    ox <- c(ox, x[i] + width * cos(a1 + t))
    oy <- c(oy, y[i] + width * sin(a1 + t))
  }
  data.frame(x = ox, y = oy)
}

# Outward unit normal of the edge (dx, dy) for a ring of orientation `sgn`.
.unit_normal <- function(dx, dy, sgn) {
  len <- sqrt(dx * dx + dy * dy)
  if (!(len > 0)) {
    return(c(0, 0))
  }
  c(sgn * dy / len, -sgn * dx / len)
}
