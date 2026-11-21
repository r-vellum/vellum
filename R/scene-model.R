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
#   * single-shape (path/lines/polygon) — one row per grob, and only
#     when keyed (mirroring `element_table()`'s `key.is_some()` guard); a single
#     sf feature's polygon/linestring is one such element.
#   * batched-but-keyed-only (text, roundrect) — a vectorised text/roundrect grob
#     compiles to one node per label/box, each carrying its own key, and
#     `element_table()` emits only the keyed ones (`Node::Text`/`Node::RoundRect`
#     are both guarded by `key.is_some()`). So they count like a batch but, like
#     the single shapes, contribute nothing at all when unkeyed. Labels are the
#     case that makes this distinction worth having: a plot is full of unkeyed
#     axis text that must not turn into thousands of phantom elements. (Roundrect
#     was previously in the single-shape set, which undercounted a multi-box keyed
#     grob — one row in the walk against N boxes from the backend — and aborted
#     `scene_model()`. It is a batch, not a single shape.)
.sm_mark_of <- function(node) {
  if (S7::S7_inherits(node, grob_rect)) {
    "rect"
  } else if (S7::S7_inherits(node, grob_points)) {
    "point"
  } else if (S7::S7_inherits(node, grob_circle)) {
    "circle"
  } else if (S7::S7_inherits(node, grob_hexagon)) {
    "hexagon"
  } else if (S7::S7_inherits(node, grob_sector)) {
    "sector"
  } else if (S7::S7_inherits(node, grob_segments)) {
    "segment"
  } else if (S7::S7_inherits(node, grob_path)) {
    "path"
  } else if (S7::S7_inherits(node, grob_lines)) {
    "line"
  } else if (S7::S7_inherits(node, grob_polygon)) {
    "polygon"
  } else if (S7::S7_inherits(node, grob_roundrect)) {
    "roundrect"
  } else if (S7::S7_inherits(node, grob_text)) {
    "text"
  } else {
    NA_character_
  }
}

.SM_SINGLE <- c("path", "line", "polygon")
.SM_KEYED_BATCH <- c("text", "roundrect")

# Element count of a batched keyable grob: the same `.batch_n()` that its
# constructor recycles `key`/`meta` to and that `compile()` draws, so the walk
# and the backend's element table cannot disagree on n. (Reading `.vsize(x)`
# here undercounted a rect with scalar `x` and vector `y`.)
.sm_n <- function(node) .batch_n(node)

# The single data key of a single-shape grob (first key), or NA when unkeyed.
.sm_key1 <- function(node) {
  k <- node@keys
  if (is.null(k) || length(k) == 0L) {
    return(NA_character_)
  }
  k <- as.character(k[[1L]])
  if (is.na(k) || !nzchar(k)) NA_character_ else k
}

#' A serializable, per-element model of a scene
#'
#' `scene_model()` walks a rendered scene and returns one row per drawn element of
#' the *keyable* marks, pairing each element's grammar-supplied identity — its data `key`, free-form
#' `meta`, grob `id`/`name`, and enclosing `panel` — with its resolved device-pixel
#' bounding box. It is the host-agnostic bridge underlying interactivity: a host
#' renders the SVG (each element tagged with `data-key`, see [scene_svg()]) and
#' uses this table to map an event back to the originating datum.
#'
#' Elements are returned in paint order. Batched marks (points, circles, rects,
#' hexagons, sectors, segments) always emit one row per element, with
#' `key`/`meta` `NA`/`NULL` when drawn without them, so a plain scene still
#' yields a geometry table. Round rects and text emit a row only for keyed
#' elements, and paths, lines and polygons one row per grob only when keyed.
#' `vignette("scene-contract")` is the full contract.
#'
#' @param scene A [vl_scene()] (or anything coercible via `as_vellum_scene()`).
#' @param meta The form of the elements' `meta` column. `"records"` (the
#'   default) is a list-column with one record per element. `"columns"` is a
#'   data-frame column instead, with one row per element and one column per
#'   field. In it a field is a plain vector when every element that carries it
#'   holds one atomic value of one type (`NA` for the elements without it), and
#'   a list-column (`NULL` where absent) otherwise. The columnar form skips the
#'   per-element records, so a host reading many elements should ask for it.
#' @return A list with two data frames:
#'   * `elements` — one row per element: `key`, `mark`, `id`, `name`, `panel`, the
#'     device-px bbox `x0,y0,x1,y1`, its centre/size `x,y,w,h`, and a `meta`
#'     column (see the `meta` argument).
#'   * `panels` — one row per named panel that encloses at least one element:
#'     `name`, its elements' bounding box `x0,y0,x1,y1`, the panel viewport's
#'     device-px rectangle `px0,py0,px1,py1`, its native ranges
#'     `xscale_lo,xscale_hi,yscale_lo,yscale_hi`, and a `meta` list-column.
#' @seealso [scene_svg()]
#' @export
scene_model <- function(scene, meta = c("records", "columns")) {
  meta_form <- .check_choice(meta, c("records", "columns"), "meta")
  scene <- as_vellum_scene(scene)
  root <- .materialize(scene)

  # Collect per-grob chunks (avoid growing vectors element-by-element).
  chunks <- list()
  walk <- function(node, panel) {
    if (S7::S7_inherits(node, gtree)) {
      p <- .panel_name(node@vp) %||% panel
      for (ch in node@children) {
        walk(ch, p)
      }
      return(invisible())
    }
    mark <- .sm_mark_of(node)
    if (is.na(mark)) {
      return(invisible())
    }
    if (mark %in% .SM_KEYED_BATCH) {
      # Keyed-only batch: one row per label, but only if the grob has keys at
      # all. Individual NA keys within a keyed grob still count, because the
      # backend emitted a node for each.
      n <- .sm_n(node)
      if (n == 0L || is.null(node@keys)) {
        return(invisible())
      }
      k <- rep_len(as.character(node@keys), n)
      keep <- !is.na(k) & nzchar(k)
      if (!any(keep)) {
        return(invisible())
      }
      keys <- k[keep]
      meta <- .sm_meta(node@meta, n, which(keep))
      n <- length(keys)
    } else if (mark %in% .SM_SINGLE) {
      # A single-shape mark: one element, and only in scene_model when keyed
      # (element_table() skips unkeyed paths/lines/polygons).
      key1 <- .sm_key1(node)
      if (is.na(key1)) {
        return(invisible())
      }
      n <- 1L
      keys <- key1
      meta <- .sm_meta(node@meta, 1L)
    } else {
      n <- .sm_n(node)
      if (n == 0L) {
        return(invisible())
      }
      keys <- if (is.null(node@keys)) {
        rep(NA_character_, n)
      } else {
        k <- as.character(node@keys)
        k[!nzchar(k)] <- NA_character_
        rep_len(k, n)
      }
      meta <- .sm_meta(node@meta, n)
    }
    id <- .meta_str(node@id)
    id <- if (nzchar(id)) id else NA_character_
    nm <- .node_name(node) %||% NA_character_
    chunks[[length(chunks) + 1L]] <<- list(
      mark = rep(mark, n),
      key = keys,
      id = rep(id, n),
      name = rep(as.character(nm), n),
      panel = rep(panel %||% NA_character_, n),
      n = n,
      meta = meta
    )
    invisible()
  }
  for (ch in root@children) {
    walk(ch, .panel_name(root@vp))
  }

  # One compile that also captures the viewport id<->name map (via `.push_vp`), so
  # `panels` can carry each panel viewport's resolved pixel rect, native scale, and
  # `meta`. Element geometry (device px) is taken from the same backend, in paint order.
  cap <- .sm_compile_capture(scene)
  et <- cap$backend$element_table()

  if (!length(chunks)) {
    empty <- data.frame(
      key = character(),
      mark = character(),
      id = character(),
      name = character(),
      panel = character(),
      x0 = numeric(),
      y0 = numeric(),
      x1 = numeric(),
      y1 = numeric(),
      x = numeric(),
      y = numeric(),
      w = numeric(),
      h = numeric(),
      stringsAsFactors = FALSE
    )
    empty$meta <- if (meta_form == "columns") .meta_df(list(), 0L) else list()
    return(list(elements = empty, panels = .sm_empty_panels()))
  }

  pull <- function(field) unlist(lapply(chunks, `[[`, field), use.names = FALSE)
  mark <- pull("mark")
  key <- pull("key")
  id <- pull("id")
  name <- pull("name")
  panel <- pull("panel")
  meta <- if (meta_form == "columns") {
    .sm_meta_columns(chunks)
  } else {
    .sm_meta_records(chunks)
  }

  gx0 <- et$x0
  gy0 <- et$y0
  gx1 <- et$x1
  gy1 <- et$y1

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
    cli::cli_abort(
      "scene_model(): element order/key mismatch between grammar and backend."
    )
  }

  elements <- data.frame(
    key = key,
    mark = mark,
    id = id,
    name = name,
    panel = panel,
    x0 = gx0,
    y0 = gy0,
    x1 = gx1,
    y1 = gy1,
    x = (gx0 + gx1) / 2,
    y = (gy0 + gy1) / 2,
    w = gx1 - gx0,
    h = gy1 - gy0,
    stringsAsFactors = FALSE
  )
  elements$meta <- meta

  list(
    elements = elements,
    panels = .sm_panels(
      panel,
      gx0,
      gy0,
      gx1,
      gy1,
      cap$items,
      cap$backend$resolved_geometry()
    )
  )
}

# --- Element meta: records and columns (VR-19) ---------------------------------
#
# A grob's `meta` is either a list of records (one per element) or a data frame
# (one row per element, one column per field). `scene_model()` hands it on as
# records (the default, the documented list-column) or as columns
# (`meta = "columns"`, a data-frame column), converting whichever form a grob
# carried. The columnar path never builds a per-element list, which is what
# keeps a big keyed plot cheap end to end: vellumplot writes columns, and
# vellumwidget reads them.
#
# Row `i` of a columnar meta is the record `list(<field> = <column>[[i]], ...)`,
# fields in column order, where a NULL entry of a list-column leaves its field
# out. Going the other way, a field becomes a plain vector when every element
# carrying it holds one plain atomic value of one type (an element without it
# reads `NA`), and a list-column (`NULL` where absent) otherwise. A factor
# column of a data-frame meta reads as character. The first entry of a name in a
# record wins, a NULL value counts as absent, and unnamed entries have no column.

# One grob's meta for the `n` elements it contributes (`idx`: which of them, when
# not all are kept): NULL, a list of records, or a data frame.
.sm_meta <- function(meta, n, idx = NULL) {
  if (is.null(meta)) {
    return(NULL)
  }
  if (is.data.frame(meta)) {
    m <- nrow(meta)
    rows <- if (m == n) seq_len(n) else rep_len(seq_len(m), n)
    if (!is.null(idx)) {
      rows <- rows[idx]
    }
    if (length(rows) == m && identical(rows, seq_len(m))) {
      return(meta)
    }
    return(vctrs::vec_slice(meta, rows))
  }
  meta <- rep_len(meta, n)
  if (is.null(idx)) meta else meta[idx]
}

# A data frame (one row per element) of `cols`, a named list of n-long columns.
.meta_df <- function(cols, n) {
  structure(
    cols,
    names = names(cols) %||% character(),
    class = "data.frame",
    row.names = .set_row_names(n)
  )
}

# Records mode: one record per element, in paint order.
.sm_meta_records <- function(chunks) {
  pieces <- lapply(chunks, function(ch) {
    m <- ch$meta
    if (is.null(m)) {
      vector("list", ch$n)
    } else if (is.data.frame(m)) {
      .meta_df_records(m)
    } else {
      m
    }
  })
  unlist(pieces, recursive = FALSE)
}

# Columns mode: one data frame, a column per field across every chunk.
.sm_meta_columns <- function(chunks) {
  ns <- vapply(chunks, `[[`, integer(1), "n")
  sets <- lapply(chunks, function(ch) {
    m <- ch$meta
    if (is.null(m)) {
      NULL
    } else if (is.data.frame(m)) {
      lapply(as.list(m), .meta_unfactor)
    } else {
      .meta_records_cols(m)
    }
  })
  fields <- unique(unlist(lapply(sets, names), use.names = FALSE))
  cols <- lapply(fields, function(f) {
    .meta_bind(lapply(sets, `[[`, f), ns)
  })
  names(cols) <- fields
  .meta_df(cols, sum(ns))
}

.meta_unfactor <- function(v) if (is.factor(v)) as.character(v) else v

# The records of a columnar meta: row i is `list(<field> = <col>[[i]], ...)`,
# without the fields whose list-column entry is NULL.
.meta_df_records <- function(df) {
  n <- nrow(df)
  if (!length(df)) {
    return(rep(list(list()), n))
  }
  is_lst <- vapply(df, is.list, logical(1))
  cols <- lapply(as.list(df), function(v) if (is.list(v)) v else as.list(v))
  recs <- .mapply(list, cols, NULL)
  if (any(is_lst)) {
    nul <- Reduce(`|`, lapply(cols[is_lst], function(l) lengths(l) == 0L))
    nul[nul] <- Reduce(
      `|`,
      lapply(cols[is_lst], function(l) vapply(l[nul], is.null, logical(1)))
    )
    if (any(nul)) {
      recs[nul] <- lapply(recs[nul], function(r) {
        r <- r[!vapply(r, is.null, logical(1))]
        if (length(r)) r else list()
      })
    }
  }
  recs
}

# The columns of a list of records (see the header for the rules).
.meta_records_cols <- function(recs) {
  n <- length(recs)
  recs <- unname(recs)
  # A named atomic record reads like a list; anything else that is not a list
  # (or NULL) has no fields.
  odd <- !vapply(recs, is.list, logical(1)) & !vapply(recs, is.null, logical(1))
  if (any(odd)) {
    recs[odd] <- lapply(recs[odd], function(r) {
      if (is.atomic(r) && !is.null(names(r))) as.list(r) else list()
    })
  }
  flat <- unlist(recs, recursive = FALSE, use.names = TRUE)
  owner <- rep.int(seq_len(n), lengths(recs))
  if (length(flat) != length(owner)) {
    # `unlist()` flattened differently from the records (e.g. a record holding
    # a data frame): read them one by one.
    recs <- lapply(recs, function(r) if (is.null(r)) list() else as.list(r))
    flat <- do.call(c, recs)
    owner <- rep.int(seq_len(n), lengths(recs))
  }
  nm <- names(flat) %||% rep("", length(flat))
  nm[is.na(nm)] <- ""
  fields <- unique(nm[nzchar(nm)])
  cols <- lapply(fields, function(f) {
    hit <- which(nm == f)
    hit <- hit[!duplicated(owner[hit])]
    vals <- unname(flat[hit])
    own <- owner[hit]
    nul <- lengths(vals) == 0L
    nul[nul] <- vapply(vals[nul], is.null, logical(1))
    if (any(nul)) {
      vals <- vals[!nul]
      own <- own[!nul]
    }
    kind <- vapply(
      vals,
      function(v) {
        if (is.atomic(v) && length(v) == 1L && !is.object(v)) typeof(v) else ""
      },
      character(1)
    )
    if (length(vals) && all(nzchar(kind)) && all(kind == kind[[1L]])) {
      out <- vector(kind[[1L]], n)
      out[] <- NA
      out[own] <- unlist(vals, use.names = FALSE)
    } else {
      out <- vector("list", n)
      out[own] <- vals
    }
    out
  })
  names(cols) <- fields
  cols
}

# One field across the chunks: `pieces` holds each chunk's column (NULL where
# the chunk lacks the field), `ns` the chunk sizes.
.meta_bind <- function(pieces, ns) {
  has <- !vapply(pieces, is.null, logical(1))
  if (sum(has) == 1L && all(has)) {
    return(pieces[[1L]])
  }
  if (!any(vapply(pieces[has], is.list, logical(1)))) {
    ptype <- tryCatch(
      do.call(vctrs::vec_ptype_common, unname(pieces[has])),
      error = function(e) NULL
    )
    if (!is.null(ptype)) {
      pieces[!has] <- lapply(ns[!has], function(k) vctrs::vec_init(ptype, k))
      return(do.call(vctrs::vec_c, c(unname(pieces), list(.ptype = ptype))))
    }
  }
  pieces <- lapply(seq_along(pieces), function(i) {
    p <- pieces[[i]]
    if (is.null(p)) {
      vector("list", ns[[i]])
    } else if (is.list(p)) {
      unname(p)
    } else {
      as.list(unname(p))
    }
  })
  do.call(c, pieces)
}

.sm_empty_panels <- function() {
  d <- data.frame(
    name = character(),
    x0 = numeric(),
    y0 = numeric(),
    x1 = numeric(),
    y1 = numeric(),
    px0 = numeric(),
    py0 = numeric(),
    px1 = numeric(),
    py1 = numeric(),
    xscale_lo = numeric(),
    xscale_hi = numeric(),
    yscale_lo = numeric(),
    yscale_hi = numeric(),
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
  if (is.na(i)) {
    return(NULL)
  }
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
  if (!n) {
    return(.sm_empty_panels())
  }
  ex0 <- ey0 <- ex1 <- ey1 <- numeric(n)
  px0 <- py0 <- px1 <- py1 <- rep(NA_real_, n)
  xsl <- xsh <- ysl <- ysh <- rep(NA_real_, n)
  meta <- vector("list", n)
  rows <- split(seq_along(panel), factor(panel, levels = pn))
  for (j in seq_len(n)) {
    p <- pn[j]
    i <- rows[[j]]
    ex0[j] <- min(x0[i])
    ey0[j] <- min(y0[i])
    ex1[j] <- max(x1[i])
    ey1[j] <- max(y1[i])
    it <- Find(function(t) identical(as.character(t$name), p), items)
    if (!is.null(it)) {
      r <- .sm_vp_rect(geom, it$id)
      if (!is.null(r)) {
        px0[j] <- r[["px0"]]
        py0[j] <- r[["py0"]]
        px1[j] <- r[["px1"]]
        py1[j] <- r[["py1"]]
      }
      xs <- it$vp@xscale
      ys <- it$vp@yscale
      if (length(xs) == 2L) {
        xsl[j] <- xs[1L]
        xsh[j] <- xs[2L]
      }
      if (length(ys) == 2L) {
        ysl[j] <- ys[1L]
        ysh[j] <- ys[2L]
      }
      # `meta[[j]] <- NULL` would DELETE the slot (R gotcha); the list is
      # pre-filled with NULLs, so only assign when the viewport carries meta.
      if (!is.null(it$vp@meta)) meta[[j]] <- it$vp@meta
    }
  }
  out <- data.frame(
    name = pn,
    x0 = ex0,
    y0 = ey0,
    x1 = ex1,
    y1 = ey1,
    px0 = px0,
    py0 = py0,
    px1 = px1,
    py1 = py1,
    xscale_lo = xsl,
    xscale_hi = xsh,
    yscale_lo = ysl,
    yscale_hi = ysh,
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
  .set_debug_reg(reg)
  on.exit(.set_debug_reg(old), add = TRUE)
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
      cid,
      .to_inches(scene@width),
      .to_inches(scene@height, "height"),
      scene@dpi,
      .rs_col(scene@bg) %||% c(255L, 255L, 255L, 0L),
      scene@title,
      scene@desc
    )
    .render_cache_put(key, backend)
  }
  list(backend = backend, items = reg$items)
}
