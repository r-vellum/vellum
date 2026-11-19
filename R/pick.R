# Phase 15 -- true-geometry hit-testing.
#
# `scene_model()` reports bounding boxes. That is exactly right for a rectangular
# brush and wrong for anything diagonal or thin: a segment's bbox is the whole
# rectangle its endpoints span, so a bbox-distance "nearest" matches it from
# anywhere in that rectangle. A host with only boxes has to work around it --
# vellumwidget excludes graph edges from open-space hover for precisely this
# reason. These two functions supply the geometry the box was standing in for.

# The pick table for a scene at one probe point, in device px.
#
# Deliberately NOT a data frame: `key`/`kind`/`dist`/`n` are per element while
# `x`/`y` are per vertex, so coercing the whole thing would recycle the short
# columns and silently invent elements.
.pick_table <- function(scene, px, py) {
  scene <- as_vellum_scene(scene)
  .scene_to_backend(scene)$pick_table(px, py)
}

# A probe point is one finite number per axis.
.check_probe <- function(x, y, call = parent.frame()) {
  .check_number(x, "x", call = call)
  .check_number(y, "y", call = call)
  invisible()
}

#' Find the marks nearest a point, by true geometry
#'
#' Ranks a scene's keyed elements by their distance to a point — measuring to the
#' **actual geometry**, not to a bounding box.
#'
#' @section Why not the bounding box:
#' For a round or upright mark the two agree. For anything diagonal or thin they
#' do not, and the difference is not subtle: a line from the bottom-left of a
#' panel to the top-right has a bounding box covering the *entire panel*, so a
#' box-based "what is nearest" reports it from anywhere in the plot. That is why
#' a host holding only boxes has to exclude such marks from hover rather than
#' rank them wrongly.
#'
#' Distances are: to the disc for round marks (zero inside), to the rectangle for
#' rects (zero inside), perpendicular to the segment for segments, to the nearest
#' edge for open polylines, and **zero anywhere inside** a closed polygon, path,
#' hexagon or sector — so clicking the middle of a choropleth region hits that
#' region. A label is measured to its box, turned with the label when it is
#' rotated.
#'
#' "Inside" follows the shape's fill rule, the one it is painted with: a point
#' in a polygon's hole is **not** inside (an `"evenodd"` path, or a
#' `"winding"` one whose inner ring runs the other way), and its distance is to
#' the nearest edge, the hole's own boundary.
#'
#' The geometry is the one the renderer draws: a segment or line drawn with an
#' `offset` or end caps is measured where it lands, not where its coordinates
#' would put it. Distances are to a stroke's centre-line.
#'
#' @section For a client-side host:
#' A browser cannot call back into R on every mouse move. Use
#' [element_geometry()] instead: it returns the same true geometry once, and the
#' client computes distances locally. `vl_nearest()` is for hosts that *can* ask
#' — a Shiny app, a test, a script.
#'
#' @param scene A [vl_scene()] (or anything with an [as_vellum_scene()] method).
#' @param x,y The probe point.
#' @param units `"npc"` (default, y up) or `"px"` (device pixels, y down) — the
#'   same convention as [hit_test()].
#' @param n How many nearest elements to return.
#' @param max_dist Ignore anything further than this many device pixels.
#' @return A data frame of `key`, `kind` and `dist` (device px), nearest first.
#'   Zero rows if nothing is in range. Only *keyed* elements are considered —
#'   an unkeyed mark is not addressable, so reporting it would be no use.
#' @seealso [element_geometry()] for the geometry itself, [scene_model()] for
#'   bounding boxes, [hit_test()] for "which grob is under this pixel".
#' @examples
#' s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
#'   draw(segments_grob(0.1, 0.1, 0.9, 0.9, key = "diagonal")) |>
#'   draw(points_grob(0.8, 0.2, key = "corner"))
#'
#' # Near the corner the diagonal's *bounding box* also contains this point,
#' # but its geometry is far away.
#' vl_nearest(s, 0.8, 0.2)
#' @export
vl_nearest <- function(
  scene,
  x,
  y,
  units = c("npc", "px"),
  n = 1L,
  max_dist = Inf
) {
  units <- .check_choice(units, c("npc", "px"), "units")
  .check_probe(x, y)
  .check_number(n, "n", min = 0)
  .check_scalar(n, "n", "integer")
  .check_number(max_dist, "max_dist", min = 0, allow_inf = TRUE)
  b <- .scene_to_backend(as_vellum_scene(scene))
  p <- unlist(.to_px(b$dim(), x, y, units))
  # Answered from the scene's cached spatial index (built on the first query,
  # reused until the scene changes): only the grid cells near the probe are
  # measured, instead of the whole pick table per call.
  t <- b$nearest_table(
    p[1],
    p[2],
    as.integer(min(n, .Machine$integer.max)),
    max_dist
  )
  data.frame(
    key = t$key,
    kind = t$kind,
    dist = t$dist,
    stringsAsFactors = FALSE
  )
}

# npc/px -> device px for a vector of coordinates (npc y is up).
.to_px <- function(dim, x, y, units) {
  if (identical(units, "npc")) {
    list(x * dim[1], (1 - y) * dim[2])
  } else {
    list(x, y)
  }
}

# A region query's result: `key`, `kind`, one row per element, paint order.
.region_frame <- function(t) {
  data.frame(key = t$key, kind = t$kind, stringsAsFactors = FALSE)
}

#' Select the marks in a rectangle or a lasso, by true geometry
#'
#' `vl_brush()` returns the keyed elements of a scene that meet an
#' axis-aligned rectangle; `vl_lasso()` those that meet a free-form polygon.
#' Both test the elements' **actual geometry** -- the same recorded shapes
#' [vl_nearest()] measures -- so a diagonal segment is selected only if the
#' line itself enters the region, not because its bounding box does. They are
#' meant for server-side brushing and lasso selection (a Shiny app receiving a
#' brush or lasso from the client) and share one cached spatial index with
#' [vl_nearest()].
#'
#' @section Which elements are selected:
#' `mode` decides how an element must meet the region:
#'
#' * `"intersect"` (default): any part of the element touches the region -- a
#'   point whose disc overlaps it, a line that passes through it, a polygon
#'   that overlaps it (including a region wholly inside the polygon). A polygon
#'   with a hole does not meet a region that lies entirely in the hole.
#' * `"contain"`: all of the element lies inside the region -- the whole disc
#'   of a point, every vertex of a line or polygon (and, for a lasso, no edge
#'   leaving it).
#' * `"centre"`: the centre of the element's bounding box lies inside the
#'   region. This is the rule vellumwidget's client-side lasso uses, so a
#'   server can reproduce a client selection exactly.
#'
#' Lines and segments are tested along their centre-line, as in
#' [vl_nearest()]; the stroke width is not added. Elements with nothing drawn
#' (an `NA` position) are never selected. The lasso polygon is closed
#' implicitly and filled with the even-odd rule, so a self-crossing lasso
#' selects what a client's ray-casting test would.
#'
#' @section Performance:
#' The first query on a scene builds a uniform grid over its keyed elements;
#' every later [vl_nearest()], `vl_brush()` or `vl_lasso()` on the same scene
#' visits only the cells the query touches. The index lives with the compiled
#' scene, so an edited scene (a new object) gets a fresh one.
#'
#' @inheritParams vl_nearest
#' @param xmin,xmax,ymin,ymax The rectangle's edges, in `units`. Their order
#'   does not matter.
#' @param x,y For `vl_lasso()`, the polygon's vertices, in `units` (at least
#'   three; the last joins the first).
#' @param mode `"intersect"` (default), `"contain"` or `"centre"`; see below.
#' @return A data frame of `key` and `kind`, one row per selected element, in
#'   paint order. A datum drawn as several elements (an error bar's segments)
#'   contributes several rows; use `unique(res$key)` for the selected keys. Only
#'   keyed elements are considered.
#' @seealso [vl_nearest()] for the nearest marks to a point,
#'   [element_geometry()] for the geometry itself.
#' @examples
#' s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
#'   draw(segments_grob(0.1, 0.1, 0.9, 0.9, key = "diagonal")) |>
#'   draw(points_grob(c(0.2, 0.8), c(0.8, 0.2), key = c("tl", "br")))
#'
#' # The diagonal's bounding box covers this corner, but the line does not.
#' vl_brush(s, 0.7, 0.9, 0.1, 0.3)
#' vl_brush(s, 0.4, 0.6, 0.4, 0.6)
#'
#' # A triangle around the top-left point
#' vl_lasso(s, c(0.05, 0.4, 0.05), c(0.6, 0.95, 0.95))
#' @name vl_brush
NULL

#' @rdname vl_brush
#' @export
vl_brush <- function(
  scene,
  xmin,
  xmax,
  ymin,
  ymax,
  units = c("npc", "px"),
  mode = c("intersect", "contain", "centre")
) {
  units <- .check_choice(units, c("npc", "px"), "units")
  mode <- .check_choice(mode, c("intersect", "contain", "centre"), "mode")
  .check_number(xmin, "xmin")
  .check_number(xmax, "xmax")
  .check_number(ymin, "ymin")
  .check_number(ymax, "ymax")
  b <- .scene_to_backend(as_vellum_scene(scene))
  p <- .to_px(b$dim(), c(xmin, xmax), c(ymin, ymax), units)
  .region_frame(b$brush_table(p[[1]][1], p[[2]][1], p[[1]][2], p[[2]][2], mode))
}

#' @rdname vl_brush
#' @export
vl_lasso <- function(
  scene,
  x,
  y,
  units = c("npc", "px"),
  mode = c("intersect", "contain", "centre")
) {
  units <- .check_choice(units, c("npc", "px"), "units")
  mode <- .check_choice(mode, c("intersect", "contain", "centre"), "mode")
  if (!is.numeric(x) || !is.numeric(y) || length(x) != length(y)) {
    cli::cli_abort(
      "{.arg x} and {.arg y} must be numeric vectors of the same length."
    )
  }
  if (length(x) < 3L || anyNA(x) || anyNA(y) || !all(is.finite(c(x, y)))) {
    cli::cli_abort(
      "{.arg x} and {.arg y} must give at least three finite vertices."
    )
  }
  b <- .scene_to_backend(as_vellum_scene(scene))
  p <- .to_px(b$dim(), as.double(x), as.double(y), units)
  .region_frame(b$lasso_table(p[[1]], p[[2]], mode))
}

#' The true geometry of a scene's addressable elements
#'
#' Returns the resolved device-pixel geometry of every **keyed** element: the two
#' endpoints of a segment, the vertices of a line or polygon, the centre of a
#' round mark, the opposite corners of a rect. It is recorded from the render
#' itself, so a segment or line drawn with an `offset` or end caps is reported
#' where it is drawn.
#'
#' This is what a host needs to hit-test *exactly* without asking the engine per
#' event. [scene_model()] gives bounding boxes, which are right for a brush and
#' misleading for diagonal or thin marks; this gives the shape the box was
#' standing in for, once, so a browser can compute point-to-geometry distances
#' locally at whatever rate it likes.
#'
#' @section Reading the result:
#' One row per vertex, grouped by `key`. What the vertices mean depends on
#' `kind`:
#'
#' | `kind` | rows | meaning |
#' |---|---|---|
#' | `segment` | 2 | the endpoints |
#' | `line`, `polygon` | *k* | the vertices, in order; `polygon` is closed |
#' | `path` | *k* | all rings' vertices concatenated; `ring` separates them |
#' | `hexagon`, `sector` | *k* | the outline, one closed ring |
#' | `point` | 1 | the centre |
#' | `rect`, `roundrect` | 2 | the bounding box's opposite corners |
#' | `text` | 4 | the label's box, as a closed ring (turned with a rotated label) |
#'
#' Coordinates are device pixels with y growing **down**, matching
#' [scene_model()]'s boxes and the rendered SVG's coordinate system.
#'
#' `ring` groups the vertices of a multi-ring `path` -- a polygon with a hole, or
#' a multipart feature -- so a host can hit-test it the way the engine does.
#' Without it the concatenated vertices are lossy: treating them as one closed
#' ring invents a phantom edge from each ring's last vertex to the next ring's
#' first. Split on `ring` for the edges. A label set along a path has one ring
#' per glyph box; every other kind is a single ring, so `ring` is `1`
#' throughout.
#'
#' `rule` is the fill rule an element's rings are filled under, one value per
#' element repeated on each of its rows: `"nonzero"` or `"evenodd"` for a shape
#' with an interior, `NA` for one without (a `segment`, a `line`, a `point`).
#' Containment is decided once across **all** of an element's rings under that
#' rule -- even-odd parity of the crossings, or a nonzero sum of winding numbers
#' -- so a point in a hole is outside. That is how [vl_nearest()] decides it,
#' and how the shape is painted.
#'
#' @inheritParams vl_nearest
#' @return A data frame of `key`, `kind`, `vertex` (1-based within the element),
#'   `ring` (1-based within the element), `x`, `y` and `rule`. Zero rows if the
#'   scene has no keyed elements.
#' @seealso [vl_nearest()], [scene_model()]
#' @examples
#' s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
#'   draw(segments_grob(0.1, 0.1, 0.9, 0.9, key = "diagonal"))
#' element_geometry(s)
#' @export
element_geometry <- function(scene) {
  # The probe point is irrelevant to the geometry; the walk computes both in one
  # pass, and (0, 0) keeps the distances it also returns cheap and meaningless
  # rather than subtly wrong-looking.
  t <- .pick_table(scene, 0, 0)
  empty <- data.frame(
    key = character(0),
    kind = character(0),
    vertex = integer(0),
    ring = integer(0),
    x = numeric(0),
    y = numeric(0),
    rule = character(0),
    stringsAsFactors = FALSE
  )
  if (!length(t$key) || !length(t$x)) {
    return(empty)
  }
  n <- as.integer(t$n)
  data.frame(
    key = rep(t$key, n),
    kind = rep(t$kind, n),
    vertex = unlist(lapply(n, seq_len), use.names = FALSE),
    ring = as.integer(t$ring),
    x = t$x,
    y = t$y,
    rule = rep(ifelse(nzchar(t$rule), t$rule, NA_character_), n),
    stringsAsFactors = FALSE
  )
}

# --- hit-testing ------------------------------------------------------------

#' Hit-test a scene
#'
#' Find the topmost node drawn under a point. The geometry is recorded by the
#' same walk that renders the scene, so offsets, caps and rotation are where they
#' are drawn; grobs are tested in reverse paint order against that geometry and
#' their viewport's clip, so the result is clip- and overlap-exact. A filled
#' shape is matched by its fill rule, a marker by its disc, text by its (rotated)
#' box, and lines and segments by a band of half their stroke width (at least
#' 2 px). grid ships no equivalent: `grid.locator()` waits for one interactive
#' click and returns coordinates rather than a node.
#'
#' @param scene A [vl_scene()] (or anything with an [as_vellum_scene()] method).
#' @param x,y Query point, in `units`: `"npc"` (default; the page, `0..1` with y
#'   up) or `"px"` (device pixels, top-left origin, y down).
#' @param units `"npc"` or `"px"`.
#' @return The hit node's `name` (character); `NA_character_` if the topmost grob
#'   there is unnamed; or `NULL` if nothing is drawn at the point.
#' @export
hit_test <- function(scene, x, y, units = c("npc", "px")) {
  units <- .check_choice(units, c("npc", "px"), "units")
  .check_probe(x, y)
  scene <- as_vellum_scene(scene)
  pk <- .pick_backend(scene)
  d <- pk$scene$dim()
  if (units == "npc") {
    px <- x * d[1]
    py <- (1 - y) * d[2] # npc y is up; device y is down
  } else {
    px <- x
    py <- y
  }
  id <- pk$scene$hit_test(as.integer(round(px)), as.integer(round(py)))
  if (id < 0L) {
    return(NULL)
  }
  pk$names[[id + 1L]] # name, or NA_character_ for an unnamed grob
}

# The pick-compiled backend for a scene plus its id -> name map, memoised like
# the render cache (`.scene_to_backend()`): keyed on the scene's content id and
# device size, so N `hit_test()` calls on one scene cost one compile, and the
# backend's own memoised pick recording is reused across them. An edit gives the
# scene a new content id, so it misses; a scene with no id (foreign-built / raw
# `set_props`) or `options(vellum.cache = FALSE)` compiles fresh every time.
# Kept apart from `.render_cache` because the pick compile differs from the
# render compile (pick ids, no masks), so the two can never share an entry.
.pick_backend <- function(scene) {
  cid <- .scene_cid(scene)
  bg <- .rs_col(scene@bg) %||% c(255L, 255L, 255L, 0L)
  cacheable <- !is.null(cid) && isTRUE(getOption("vellum.cache", TRUE))
  if (cacheable) {
    key <- .render_key(
      cid,
      .to_inches(scene@width),
      .to_inches(scene@height, "height"),
      scene@dpi,
      bg
    )
    hit <- .pick_cache[[key]]
    if (!is.null(hit)) {
      .pick_cache$.order <- c(setdiff(.pick_cache$.order, key), key)
      return(hit)
    }
  }
  s <- Scene$new(
    .to_inches(scene@width),
    .to_inches(scene@height, "height"),
    scene@dpi,
    bg
  )
  reg <- new.env(parent = emptyenv())
  reg$n <- 0L
  reg$names <- list()
  .compile_pick(s, .materialize_cached(scene, if (cacheable) cid), reg)
  out <- list(scene = s, names = reg$names)
  if (cacheable) {
    ord <- setdiff(.pick_cache$.order, key)
    while (length(ord) >= .render_cache_cap()) {
      rm(list = ord[[1L]], envir = .pick_cache)
      ord <- ord[-1L]
    }
    assign(key, out, envir = .pick_cache)
    .pick_cache$.order <- c(ord, key)
  }
  out
}

# Compile for picking: like the render compile, but assign each leaf grob a
# sequential pick id (paint order) and record its name, so hit_test can map the
# pick-buffer colour back to a node. Masks are ignored (content is drawn plainly).
.compile_pick <- function(scene, node, reg) {
  if (S7::S7_inherits(node, gtree)) {
    .push_vp(scene, node@vp)
    for (ch in node@children) {
      .compile_pick(scene, ch, reg)
    }
    scene$pop_viewport(1L)
  } else {
    id <- reg$n
    reg$n <- id + 1L
    reg$names[[id + 1L]] <- .node_name(node) %||% NA_character_
    scene$set_pick(id)
    compile(node, scene)
  }
}
