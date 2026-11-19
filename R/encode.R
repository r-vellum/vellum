# --- internal helpers -------------------------------------------------------

`%||%` <- function(a, b) if (is.null(a)) b else a

# Backend value encoders: turn R colours / numbers into the form the Rust side
# expects. Shared by the compile path, paint.R, and text.R.

# PERF-7: colour parsing memo. `col2rgb` is called once per drawn grob's col/fill;
# a plot with many same-coloured elements re-parses the same string repeatedly.
# Memoise the (deterministic) parse, keyed by type + value so an integer palette
# index and a same-looking string never collide.
.col_cache <- new.env(parent = emptyenv())
.col2rgba <- function(x) {
  key <- paste0(typeof(x), as.character(x))
  v <- .col_cache[[key]]
  if (is.null(v)) {
    v <- as.integer(grDevices::col2rgb(x, alpha = TRUE)[, 1L])
    .col_cache[[key]] <- v
  }
  v
}

# Concrete colour -> length-4 integer RGBA, or NULL ("no paint" / transparent).
.rs_col <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x)) {
    return(NULL)
  }
  .col2rgba(x)
}

# Tri-state colour encoding for the backend:
#   NULL  -> NULL        (inherit)
#   NA    -> integer(0)  (explicit "no paint")
#   colour-> int[4]      (set)
.rs_col_inh <- function(x) {
  if (is.null(x)) {
    return(NULL)
  }
  # A gradient in `col` strokes with that gradient (encoded separately, into the
  # stroke record). Consumers that need one flat colour -- text, markers, the
  # pick buffer -- get its first stop, which is the closest single colour the
  # ramp has to offer.
  if (.is_paint(x)) {
    return(.col2rgba(.paint_first_colour(x)))
  }
  if (length(x) != 1L) {
    cli::cli_abort(
      "A colour must be a single value, {.code NA} (none), or {.code NULL} (inherit)."
    )
  }
  if (is.na(x)) {
    return(integer(0))
  }
  .col2rgba(x)
}

# Tri-state numeric encoding: NULL/NA -> NA_real_ (inherit); else the value.
.rs_num_inh <- function(x) {
  if (is.null(x)) {
    return(NA_real_)
  }
  if (length(x) != 1L) {
    cli::cli_abort(
      "{.arg lwd}/{.arg alpha} must be a single number or {.code NULL} (inherit)."
    )
  }
  if (is.na(x)) {
    return(NA_real_)
  }
  as.numeric(x)
}

# Optionally push a grob's own viewport, run `expr`, then pop. Also attaches the
# grob's semantic metadata (id/role/name) to the primitives `expr` emits, so the
# SVG backend can tag them; cleared afterwards so it never leaks to a later node.
.with_vp <- function(node, scene, expr) {
  .set_meta(scene, node)
  has_vp <- !is.null(node@vp)
  panel <- if (has_vp) .panel_name(node@vp) else NULL
  if (has_vp) {
    .push_vp(scene, node@vp)
  }
  if (!is.null(panel)) {
    scene$begin_panel(panel)
  }
  force(expr)
  if (!is.null(panel)) {
    scene$end_panel()
  }
  if (has_vp) {
    scene$pop_viewport(1L)
  }
  scene$set_meta("", "", "")
  invisible()
}

# Push a grob's id/role/name as the metadata for its upcoming primitives.
.set_meta <- function(scene, node) {
  id <- if ("id" %in% S7::prop_names(node)) node@id else NULL
  role <- if ("role" %in% S7::prop_names(node)) node@role else NULL
  scene$set_meta(.meta_str(id), .meta_str(role), .meta_str(.node_name(node)))
}

# A single metadata string for the backend: "" when absent/NA (= no attribute);
# a length->1 value takes its first element (grob-level identity for now).
.meta_str <- function(x) {
  if (is.null(x) || length(x) == 0L) {
    return("")
  }
  x <- x[[1L]]
  if (is.na(x)) "" else as.character(x)
}

# Per-element data keys for a batched grob, aligned to its `n` elements. Returns
# `character(0)` when the grob carries no keys (the backend then emits no
# `data-key`, so a non-interactive scene is byte-for-byte unchanged); otherwise a
# length-`n` character vector with "" for NA/absent entries (no attribute emitted
# for those elements).
# Per-segment stroke colour as a flat RGBA int vector (empty = use the shared
# gp), with the uniform gp alpha folded in exactly as the per-element fills do.
.seg_cols <- function(node, n) {
  cols <- node@ecol
  if (is.null(cols)) {
    return(integer(0))
  }
  cols <- rep_len(cols, n)
  cols[is.na(cols)] <- "transparent"
  m <- grDevices::col2rgb(cols, alpha = TRUE)
  a <- node@gp@alpha
  if (!is.null(a) && !is.na(a)) {
    m[4L, ] <- round(m[4L, ] * a)
  }
  as.integer(m)
}

# Per-segment line widths in R `lwd` units (empty = use the shared gp).
.seg_lwds <- function(node, n) {
  w <- node@elwd
  if (is.null(w)) {
    return(numeric(0))
  }
  w <- rep_len(as.numeric(w), n)
  w[!is.finite(w)] <- 0
  w
}

.keys_vec <- function(node, n) {
  k <- if ("keys" %in% S7::prop_names(node)) node@keys else NULL
  if (is.null(k)) {
    return(character(0))
  }
  k <- as.character(k)
  k[is.na(k)] <- ""
  rep_len(k, n)
}

# Per-element keys recycled to `n`, or NULL when the grob has none -- the form
# the text draw paths want, since they index it by drawn-label position.
.keys_or_null <- function(node, n) {
  k <- .keys_vec(node, n)
  if (!length(k)) NULL else k
}

# The single data key of a single-element shape grob (path/lines/polygon):
# "" when absent (the backend then emits no `data-key`). Takes the first key.
.key1 <- function(node) {
  k <- if ("keys" %in% S7::prop_names(node)) node@keys else NULL
  if (is.null(k) || length(k) == 0L) {
    return("")
  }
  k <- as.character(k[[1L]])
  if (is.na(k)) "" else k
}

# Encode a gpar's drawing fields for the backend. `fill` may be a colour, a
# gradient, or a pattern (see .encode_paint; patterns need `scene`); `stroke`
# bundles lty/lineend/linejoin/linemitre (or NULL = inherit all).
.gp4 <- function(gp, scene = NULL) {
  list(
    fill = .encode_paint(gp@fill, scene),
    col = .rs_col_inh(gp@col),
    lwd = .rs_num_inh(gp@lwd),
    alpha = .rs_num_inh(gp@alpha),
    stroke = .encode_stroke(gp, scene)
  )
}

.push_vp <- function(scene, vp) {
  cx <- .coord(vp@x, "npc", 1)
  cy <- .coord(vp@y, "npc", 1)
  cw <- .coord(vp@width, "npc", 1)
  ch <- .coord(vp@height, "npc", 1)
  lrow <- if (is.null(vp@row)) -1L else as.integer(vp@row) - 1L
  lcol <- if (is.null(vp@col)) -1L else as.integer(vp@col) - 1L
  # clip may be TRUE/FALSE (rect) or a path-like grob (arbitrary clip path).
  clip_grob <- if (S7::S7_inherits(vp@clip, grob)) vp@clip else NULL
  clip_flag <- if (is.null(clip_grob)) isTRUE(vp@clip) else TRUE
  vid <- scene$push_viewport(
    cx$value,
    cy$value,
    cw$value,
    ch$value,
    cx$code,
    cx$offset,
    cy$code,
    cy$offset,
    cw$code,
    cw$offset,
    ch$code,
    ch$offset,
    as.numeric(vp@xscale),
    as.numeric(vp@yscale),
    vp@angle,
    clip_flag,
    lrow,
    lcol,
    vp@rowspan,
    vp@colspan,
    .encode_paint(vp@gp@fill, scene),
    .rs_col_inh(vp@gp@col),
    .rs_num_inh(vp@gp@lwd),
    .rs_num_inh(vp@gp@alpha),
    .encode_stroke(vp@gp, scene)
  )
  # Debug capture: record this viewport's backend id, name, and node for the
  # layout-debug overlay / why_size() (only active during a debug render).
  if (!is.null(.debug_state$reg)) {
    reg <- .debug_state$reg
    reg$items[[length(reg$items) + 1L]] <- list(
      id = vid,
      name = vp@name,
      vp = vp
    )
  }
  if (!is.null(clip_grob)) {
    cp <- .clip_path_of(clip_grob)
    scene$set_clip_path(
      cp$x,
      cp$y,
      cp$xcode,
      cp$xoff,
      cp$ycode,
      cp$yoff,
      cp$nper,
      cp$evenodd
    )
  }
  if (!is.null(vp@layout)) .set_layout(scene, vp@layout)
}

# Extract clip-path coordinates (in the viewport's coordinate system) from a
# polygon or path grob.
.clip_path_of <- function(g) {
  if (S7::S7_inherits(g, grob_path)) {
    ex <- .coord(g@x, "native")
    ey <- .coord(g@y, "native")
    list(
      x = ex$value,
      y = ey$value,
      xcode = ex$code,
      xoff = ex$offset,
      ycode = ey$code,
      yoff = ey$offset,
      nper = as.integer(g@nper),
      evenodd = identical(g@rule, "evenodd")
    )
  } else if (S7::S7_inherits(g, grob_polygon)) {
    n <- vctrs::vec_size_common(g@x, g@y)
    ex <- .coord(g@x, "native", n)
    ey <- .coord(g@y, "native", n)
    list(
      x = ex$value,
      y = ey$value,
      xcode = ex$code,
      xoff = ex$offset,
      ycode = ey$code,
      yoff = ey$offset,
      nper = as.integer(n),
      evenodd = FALSE
    )
  } else {
    cli::cli_abort(
      "A viewport {.arg clip} grob must be a {.fn polygon_grob} or {.fn path_grob}."
    )
  }
}

.set_layout <- function(scene, layout) {
  scene$set_layout(
    vctrs::field(layout@widths, "value"),
    .code_names(layout@widths),
    vctrs::field(layout@heights, "value"),
    .code_names(layout@heights),
    isTRUE(layout@respect)
  )
}

.code_names <- function(u) {
  names(.unit_codes)[match(vctrs::field(u, "unit"), .unit_codes)]
}

.as_size <- function(x) if (is_unit(x)) x else vl_unit(x, "in")

.to_inches <- function(u) {
  v <- vctrs::field(u, "value")[1]
  switch(
    as.character(vctrs::field(u, "unit")[1]),
    "2" = v / 25.4, # mm
    "3" = v, # in
    "4" = v / 72, # pt
    cli::cli_abort("Page size must be an absolute unit (in/mm/pt).")
  )
}

.just_to_hv <- function(just) {
  hmap <- c(left = 0, centre = 0.5, center = 0.5, right = 1)
  vmap <- c(bottom = 0, centre = 0.5, center = 0.5, top = 1)
  # A single vertical-only name ("top"/"bottom") sets vjust and centres h; a single
  # horizontal-only name sets hjust and centres v (grid's single-`just` semantics).
  if (length(just) == 1L && is.character(just)) {
    if (just %in% c("top", "bottom")) {
      return(c(0.5, .just1(just, vmap)))
    }
    if (just %in% c("left", "right")) {
      return(c(.just1(just, hmap), 0.5))
    }
  }
  h <- .just1(just[1], hmap)
  v <- if (length(just) > 1) .just1(just[2], vmap) else 0.5
  c(h, v)
}
.just1 <- function(j, map) {
  if (j %in% names(map)) {
    return(unname(map[j]))
  }
  v <- suppressWarnings(as.numeric(j))
  if (is.na(v)) {
    cli::cli_abort(
      "Invalid {.arg just} value {.val {j}}; use {.or {names(map)}} or a number in [0, 1]."
    )
  }
  v
}
