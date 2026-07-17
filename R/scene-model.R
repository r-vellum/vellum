# Scene model: a serializable, per-element description of a rendered scene — the
# host-agnostic contract an interactivity host (e.g. an htmlwidget) consumes to
# map a hover/click on an SVG element back to its datum. See
# `_docs/DESIGN-INTERACTIVITY.md` (Phase 1). Pure interactivity metadata: a static
# render never calls this, and grobs without `key`/`meta` still appear (geometry
# only), so nothing here changes what is drawn.

# Marks whose grobs carry per-element identity, mapped to the Rust
# `element_table()` node kinds so the semantic (R) and geometry (Rust) tables zip
# positionally, in paint order. Two families:
#   * batched (rect/point/circle/hexagon/sector/segment) — one row per element,
#     always (keys may be NA), mirroring the batched arms of `element_table()`.
#   * single-shape (path/lines/polygon) — one row per grob, and only when keyed
#     (mirroring `element_table()`'s `key.is_some()` guard); a single sf feature's
#     polygon/linestring is one such element.
.sm_mark_of <- function(node) {
  if (S7::S7_inherits(node, grob_rect)) "rect"
  else if (S7::S7_inherits(node, grob_points)) "point"
  else if (S7::S7_inherits(node, grob_circle)) "circle"
  else if (S7::S7_inherits(node, grob_hexagon)) "hexagon"
  else if (S7::S7_inherits(node, grob_sector)) "sector"
  else if (S7::S7_inherits(node, grob_segments)) "segment"
  else if (S7::S7_inherits(node, grob_path)) "path"
  else if (S7::S7_inherits(node, grob_lines)) "line"
  else if (S7::S7_inherits(node, grob_polygon)) "polygon"
  else NA_character_
}

.SM_SINGLE <- c("path", "line", "polygon")

# Element count of a batched keyable grob (its recycled common length).
.sm_n <- function(node) {
  if (S7::S7_inherits(node, grob_segments)) .vsize(node@x0) else .vsize(node@x)
}

# The single data key of a single-shape grob (first key), or NA when unkeyed.
.sm_key1 <- function(node) {
  k <- node@keys
  if (is.null(k) || length(k) == 0L) return(NA_character_)
  k <- as.character(k[[1L]])
  if (is.na(k) || !nzchar(k)) NA_character_ else k
}

#' A serializable, per-element model of a scene
#'
#' `scene_model()` walks a rendered scene and returns one row per drawn element of
#' the *keyable* marks (points, circles, rects, hexagons, sectors, segments),
#' pairing each element's grammar-supplied identity — its data `key`, free-form
#' `meta`, grob `id`/`name`, and enclosing `panel` — with its resolved device-pixel
#' bounding box. It is the host-agnostic bridge underlying interactivity: a host
#' renders the SVG (each element tagged with `data-key`, see [scene_svg()]) and
#' uses this table to map an event back to the originating datum.
#'
#' Elements are returned in paint order. `key`/`meta` are `NA`/`NULL` for marks
#' drawn without them, so a plain scene still yields a geometry table.
#'
#' @param scene A [vl_scene()] (or anything coercible via `as_vellum_scene()`).
#' @return A list with two data frames:
#'   * `elements` — one row per element: `key`, `mark`, `id`, `name`, `panel`, the
#'     device-px bbox `x0,y0,x1,y1`, its centre/size `x,y,w,h`, and a `meta`
#'     list-column.
#'   * `panels` — one row per named panel: `name` and its elements' bounding box
#'     `x0,y0,x1,y1`.
#' @seealso [scene_svg()]
#' @export
scene_model <- function(scene) {
  scene <- as_vellum_scene(scene)
  root <- .materialize(scene)

  # Collect per-grob chunks (avoid growing vectors element-by-element).
  chunks <- list()
  walk <- function(node, panel) {
    if (S7::S7_inherits(node, gtree)) {
      p <- .panel_name(node@vp) %||% panel
      for (ch in node@children) walk(ch, p)
      return(invisible())
    }
    mark <- .sm_mark_of(node)
    if (is.na(mark)) return(invisible())
    if (mark %in% .SM_SINGLE) {
      # A single-shape mark: one element, and only in scene_model when keyed
      # (element_table() skips unkeyed paths/lines/polygons).
      key1 <- .sm_key1(node)
      if (is.na(key1)) return(invisible())
      n <- 1L
      keys <- key1
      meta <- if (is.null(node@meta)) vector("list", 1L) else node@meta[1L]
    } else {
      n <- .sm_n(node)
      if (n == 0L) return(invisible())
      keys <- if (is.null(node@keys)) {
        rep(NA_character_, n)
      } else {
        k <- as.character(node@keys)
        k[!nzchar(k)] <- NA_character_
        rep_len(k, n)
      }
      meta <- if (is.null(node@meta)) vector("list", n) else rep_len(node@meta, n)
    }
    id <- .meta_str(node@id)
    id <- if (nzchar(id)) id else NA_character_
    nm <- .node_name(node) %||% NA_character_
    chunks[[length(chunks) + 1L]] <<- list(
      mark = rep(mark, n), key = keys, id = rep(id, n),
      name = rep(as.character(nm), n),
      panel = rep(panel %||% NA_character_, n), meta = meta
    )
    invisible()
  }
  for (ch in root@children) walk(ch, .panel_name(root@vp))

  # One compile that also captures the viewport id<->name map (via `.push_vp`), so
  # `panels` can carry each panel viewport's resolved pixel rect, native scale, and
  # `meta`. Element geometry (device px) is taken from the same backend, in paint order.
  cap <- .sm_compile_capture(scene)
  et <- cap$backend$element_table()

  if (!length(chunks)) {
    empty <- data.frame(
      key = character(), mark = character(), id = character(), name = character(),
      panel = character(), x0 = numeric(), y0 = numeric(), x1 = numeric(),
      y1 = numeric(), x = numeric(), y = numeric(), w = numeric(), h = numeric(),
      stringsAsFactors = FALSE
    )
    empty$meta <- list()
    return(list(elements = empty, panels = .sm_empty_panels()))
  }

  pull <- function(field) unlist(lapply(chunks, `[[`, field), use.names = FALSE)
  mark <- pull("mark"); key <- pull("key"); id <- pull("id")
  name <- pull("name"); panel <- pull("panel")
  meta <- unlist(lapply(chunks, `[[`, "meta"), recursive = FALSE)

  gx0 <- et$x0; gy0 <- et$y0; gx1 <- et$x1; gy1 <- et$y1

  # The R (semantic) and Rust (geometry) tables must enumerate the same elements
  # in the same order. Guard the positional zip: counts must match, and the key
  # column must agree at every position (a drift would be a compiler bug).
  if (length(gx0) != length(mark)) {
    cli::cli_abort(c(
      "scene_model(): element count mismatch between the grammar walk and the backend.",
      i = "{length(mark)} element{?s} from grobs, {length(gx0)} from the backend."
    ))
  }
  et_key <- et$key
  et_key[!nzchar(et_key)] <- NA_character_
  if (!identical(et_key, key)) {
    cli::cli_abort("scene_model(): element order/key mismatch between grammar and backend.")
  }

  elements <- data.frame(
    key = key, mark = mark, id = id, name = name, panel = panel,
    x0 = gx0, y0 = gy0, x1 = gx1, y1 = gy1,
    x = (gx0 + gx1) / 2, y = (gy0 + gy1) / 2, w = gx1 - gx0, h = gy1 - gy0,
    stringsAsFactors = FALSE
  )
  elements$meta <- meta

  list(
    elements = elements,
    panels = .sm_panels(panel, gx0, gy0, gx1, gy1, cap$items, cap$backend$resolved_geometry())
  )
}

.sm_empty_panels <- function() {
  d <- data.frame(
    name = character(),
    x0 = numeric(), y0 = numeric(), x1 = numeric(), y1 = numeric(),
    px0 = numeric(), py0 = numeric(), px1 = numeric(), py1 = numeric(),
    xscale_lo = numeric(), xscale_hi = numeric(),
    yscale_lo = numeric(), yscale_hi = numeric(),
    stringsAsFactors = FALSE
  )
  d$meta <- list()
  d
}

# Device-px rectangle of a resolved viewport: the bbox of its four local corners
# mapped through the local->device affine `transform = c(sx, ky, kx, sy, tx, ty)`.
# Returns `c(px0, py0, px1, py1)` or NULL when the id is absent.
.sm_vp_rect <- function(geom, id) {
  i <- match(id, geom$id)
  if (is.na(i)) return(NULL)
  tf <- geom$transform[[i]]
  w <- geom$w_px[i]
  h <- geom$h_px[i]
  cx <- c(0, w, w, 0)
  cy <- c(0, 0, h, h)
  dx <- tf[1] * cx + tf[3] * cy + tf[5]
  dy <- tf[2] * cx + tf[4] * cy + tf[6]
  c(px0 = min(dx), py0 = min(dy), px1 = max(dx), py1 = max(dy))
}

# One row per named panel. Besides the element-extent bbox (`x0..y1`, kept for
# back-compat) each row now carries the panel viewport's resolved device-px
# rectangle (`px0..py1`, the true data region, not just where marks landed), its
# native coordinate ranges (`xscale_*`/`yscale_*`), and its free-form `meta` — the
# geometry a host needs to map device px <-> native for that panel. Values are `NA`
# / `NULL` for a panel whose viewport was not captured (e.g. a foreign scene).
.sm_panels <- function(panel, x0, y0, x1, y1, items, geom) {
  pn <- unique(panel[!is.na(panel)])
  n <- length(pn)
  if (!n) return(.sm_empty_panels())
  ex0 <- ey0 <- ex1 <- ey1 <- numeric(n)
  px0 <- py0 <- px1 <- py1 <- rep(NA_real_, n)
  xsl <- xsh <- ysl <- ysh <- rep(NA_real_, n)
  meta <- vector("list", n)
  for (j in seq_len(n)) {
    p <- pn[j]
    i <- which(!is.na(panel) & panel == p)
    ex0[j] <- min(x0[i]); ey0[j] <- min(y0[i]); ex1[j] <- max(x1[i]); ey1[j] <- max(y1[i])
    it <- Find(function(t) identical(as.character(t$name), p), items)
    if (!is.null(it)) {
      r <- .sm_vp_rect(geom, it$id)
      if (!is.null(r)) { px0[j] <- r[["px0"]]; py0[j] <- r[["py0"]]; px1[j] <- r[["px1"]]; py1[j] <- r[["py1"]] }
      xs <- it$vp@xscale; ys <- it$vp@yscale
      if (length(xs) == 2L) { xsl[j] <- xs[1L]; xsh[j] <- xs[2L] }
      if (length(ys) == 2L) { ysl[j] <- ys[1L]; ysh[j] <- ys[2L] }
      # `meta[[j]] <- NULL` would DELETE the slot (R gotcha); the list is
      # pre-filled with NULLs, so only assign when the viewport carries meta.
      if (!is.null(it$vp@meta)) meta[[j]] <- it$vp@meta
    }
  }
  out <- data.frame(
    name = pn, x0 = ex0, y0 = ey0, x1 = ex1, y1 = ey1,
    px0 = px0, py0 = py0, px1 = px1, py1 = py1,
    xscale_lo = xsl, xscale_hi = xsh, yscale_lo = ysl, yscale_hi = ysh,
    stringsAsFactors = FALSE
  )
  out$meta <- meta
  out
}

# Compile the scene once, capturing the viewport id<->name/`vp` map (as the debug
# path does) without drawing any overlay, so `scene_model()` can get element
# geometry, resolved viewport geometry, and the panel viewport objects from one
# consistent backend. Bypasses the render cache (a cache hit would skip the compile
# and so capture no map); scene_model is a once-per-build call, not the render path.
.sm_compile_capture <- function(scene) {
  reg <- new.env(parent = emptyenv())
  reg$items <- list()
  old <- .debug_state$reg
  .debug_state$reg <- reg
  on.exit(.debug_state$reg <- old, add = TRUE)
  cid <- .scene_cid(scene)
  backend <- .compile_backend(scene, cid = cid)
  # A cache *hit* would skip the id<->name capture (`.push_vp` only records during a
  # compile), so we always compile here rather than reuse a cached backend. But
  # write the freshly compiled backend to the render cache, so the `scene_svg()` /
  # `render()` that typically follows in the same build reuses it instead of
  # compiling a second time. Mirrors the cache guard in `.scene_to_backend()`
  # (only with a scene id, and only when caching is enabled).
  if (!is.null(cid) && isTRUE(getOption("vellum.cache", TRUE))) {
    key <- .render_key(
      cid, .to_inches(scene@width), .to_inches(scene@height),
      scene@dpi, .rs_col(scene@bg) %||% c(255L, 255L, 255L, 0L),
      scene@title, scene@desc
    )
    .render_cache_put(key, backend)
  }
  list(backend = backend, items = reg$items)
}
