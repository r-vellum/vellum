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

# npc/px -> device px, sharing `hit_test()`'s convention (npc y is up).
.probe_px <- function(scene, x, y, units) {
  d <- .scene_to_backend(as_vellum_scene(scene))$dim()
  if (identical(units, "npc")) c(x * d[1], (1 - y) * d[2]) else c(x, y)
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
#' edge for open polylines, and **zero anywhere inside** a closed polygon or
#' path — so clicking the middle of a choropleth region hits that region.
#'
#' Marks vellum cannot describe more precisely than a box — labels, rounded rects
#' — fall back to their box, which for a label is a fair description of the
#' target anyway.
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
vl_nearest <- function(scene, x, y, units = c("npc", "px"), n = 1L,
                       max_dist = Inf) {
  units <- match.arg(units)
  p <- .probe_px(scene, x, y, units)
  t <- .pick_table(scene, p[1], p[2])
  if (!length(t$key)) {
    return(data.frame(key = character(0), kind = character(0), dist = numeric(0)))
  }
  out <- data.frame(key = t$key, kind = t$kind, dist = t$dist,
                    stringsAsFactors = FALSE)
  out <- out[out$dist <= max_dist, , drop = FALSE]
  out <- out[order(out$dist), , drop = FALSE]
  utils::head(out, max(0L, as.integer(n)))
}

#' The true geometry of a scene's addressable elements
#'
#' Returns the resolved device-pixel geometry of every **keyed** element: the two
#' endpoints of a segment, the vertices of a line or polygon, the centre of a
#' round mark, the opposite corners of a rect.
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
#' | `path` | *k* | all rings' vertices concatenated |
#' | `point` | 1 | the centre |
#' | `rect` | 2 | opposite corners |
#' | `text`, `roundrect` | 2 | the bounding box's corners |
#'
#' Coordinates are device pixels with y growing **down**, matching
#' [scene_model()]'s boxes and the rendered SVG's coordinate system.
#'
#' @inheritParams vl_nearest
#' @return A data frame of `key`, `kind`, `vertex` (1-based within the element),
#'   `x` and `y`. Zero rows if the scene has no keyed elements.
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
  empty <- data.frame(key = character(0), kind = character(0),
                      vertex = integer(0), x = numeric(0), y = numeric(0),
                      stringsAsFactors = FALSE)
  if (!length(t$key) || !length(t$x)) {
    return(empty)
  }
  n <- as.integer(t$n)
  data.frame(
    key = rep(t$key, n),
    kind = rep(t$kind, n),
    vertex = unlist(lapply(n, seq_len), use.names = FALSE),
    x = t$x, y = t$y,
    stringsAsFactors = FALSE
  )
}
