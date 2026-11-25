#' @include grob-class.R scene-build.R
NULL

# Compile an immutable scene onto a fresh backend `Scene`, memoised on the
# scene's object-identity token. A single render costs one O(1) key lookup + one
# compile; a repeat of the same content at the same device size reuses the
# compiled Scene (and, via the Scene's own lazy pixmap memo, its rasterisation).
# The scene's content-identity token, or NULL if it is not cacheable. Requires
# the "exactly one of bstate/root" invariant to hold — a scene with both set (or
# neither) has been mutated outside the builder API (a raw `set_props(root=)`), so
# it is untrustworthy: NULL, render it fresh rather than risk a stale hit.
.scene_cid <- function(scene) {
  if (!is.null(scene@bstate) && is.null(scene@root)) {
    scene@bstate$cid
  } else if (is.null(scene@bstate) && !is.null(scene@root)) {
    scene@cid
  } else {
    NULL
  }
}

# Map `options(vellum.glyph_bitmap)` to the Rust mode code (0 off / 1 auto / 2 on).
# Resolve `options(vellum.simplify)` to a tolerance in device px.
.simplify_tol <- function() {
  v <- getOption("vellum.simplify", 0.1)
  if (is.null(v) || length(v) != 1L || is.na(v) || !is.numeric(v) || v < 0) {
    cli::cli_abort(
      '{.code options(vellum.simplify)} must be a single non-negative number (device px); 0 disables.'
    )
  }
  as.numeric(v)
}

.glyph_bitmap_code <- function() {
  switch(
    as.character(getOption("vellum.glyph_bitmap", "auto")),
    off = 0L,
    on = 2L,
    auto = 1L,
    1L
  )
}

.scene_to_backend <- function(scene, debug = FALSE) {
  # Push the glyph-bitmap mode for this render (a thread-local read by the raster
  # backend when it rasterises). Cheap, so set it every call. A cached raster is
  # returned as-is without re-reading the mode; that is fine because the mode is a
  # perf-only fast path with output identical to the vector text path.
  rs_set_glyph_bitmap_mode(.glyph_bitmap_code())
  # Path simplification tolerance (device px). Sub-pixel by default, so it can
  # only drop vertices that could not have changed a pixel; 0 disables it.
  rs_set_simplify_tol(.simplify_tol())
  cid <- .scene_cid(scene)
  # Bypass for debug overlays, when disabled, or when the scene carries no id
  # (foreign-built / raw `set_props`) — compute fresh rather than risk a stale
  # hit. Absent id => never cached (fail-safe), so it can only under-hit.
  if (debug || is.null(cid) || !isTRUE(getOption("vellum.cache", TRUE))) {
    return(.compile_backend(scene, debug = debug, cid = NULL))
  }
  key <- .render_key(
    cid,
    .to_inches(scene@width),
    .to_inches(scene@height, "height"),
    scene@dpi,
    .rs_col(scene@bg) %||% c(255L, 255L, 255L, 0L),
    scene@title,
    scene@desc
  )
  hit <- .render_cache_get(key)
  if (!is.null(hit)) {
    return(hit)
  }
  s <- .compile_backend(scene, cid = cid)
  .render_cache_put(key, s)
  s
}

.compile_backend <- function(scene, debug = FALSE, cid = NULL) {
  s <- Scene$new(
    .to_inches(scene@width),
    .to_inches(scene@height, "height"),
    scene@dpi,
    .rs_col(scene@bg) %||% c(255L, 255L, 255L, 0L)
  )
  # Scene-level accessibility (name/description), emitted by the SVG/PDF
  # backends, and an explicit SVG id prefix if the scene carries one (otherwise
  # the SVG backend derives the prefix from the document's content).
  if (
    !is.null(scene@title) || !is.null(scene@desc) || !is.null(scene@a11y_prefix)
  ) {
    s$set_a11y(
      scene@title %||% "",
      scene@desc %||% "",
      scene@a11y_prefix %||% ""
    )
  }
  # Compile the root as a gtree so the root viewport's gp / scales / clip / layout
  # / mask all apply (it is pushed like any viewport), not just its layout.
  root <- .materialize_cached(scene, cid)
  if (debug) {
    # Capture the id<->name map for each pushed viewport (via `.push_vp`), then
    # draw the layout-debug overlay on top of the compiled content.
    reg <- new.env(parent = emptyenv())
    reg$items <- list()
    old <- .debug_state$reg
    .set_debug_reg(reg)
    on.exit(.set_debug_reg(old), add = TRUE)
    compile(root, s)
    .debug_state$reg <- old
    .draw_debug_overlay(s, reg$items)
  } else {
    compile(root, s)
  }
  s
}

# --- compile (tree -> imperative Scene calls) -------------------------------

compile <- S7::new_generic("compile", "node", function(node, scene) {
  S7::S7_dispatch()
})

S7::method(compile, grob_rect) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- .batch_n(node)
    ex <- .coord(node@x, "npc", n)
    ey <- .coord(node@y, "npc", n)
    ew <- .coord(node@width, "npc", n)
    eh <- .coord(node@height, "npc", n)
    g <- .gp4(node@gp, scene)
    sk <- .encode_sketch(node@sketch)
    # One batched call (one shared gpar) instead of a per-element FFI loop.
    scene$rects(
      ex$value,
      ey$value,
      ew$value,
      eh$value,
      ex$code,
      ex$offset,
      ey$code,
      ey$offset,
      ew$code,
      ew$offset,
      eh$code,
      eh$offset,
      g$fill,
      g$col,
      g$lwd,
      g$alpha,
      g$stroke,
      sk$roughness,
      sk$bowing,
      sk$fill_style,
      sk$fill_weight,
      sk$hachure_angle,
      sk$hachure_gap,
      sk$curve_tightness,
      sk$disable_multi,
      sk$preserve,
      sk$seed,
      .keys_vec(node, n)
    )
  })
}

S7::method(compile, grob_roundrect) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- .batch_n(node)
    ex <- .coord(node@x, "npc", n)
    ey <- .coord(node@y, "npc", n)
    ew <- .coord(node@width, "npc", n)
    eh <- .coord(node@height, "npc", n)
    er <- .coord(node@r, "npc", n)
    g <- .gp4(node@gp, scene)
    sk <- .encode_sketch(node@sketch)
    # `.keys_vec()` is empty when the grob has no key at all; the loop below
    # indexes it per element, so widen it to n empty strings.
    kv <- .keys_vec(node, n)
    if (!length(kv)) {
      kv <- rep("", n)
    }
    # Rounded rects are typically few (keys/labels); one FFI call each, shared gpar.
    for (i in seq_len(n)) {
      scene$roundrect(
        ex$value[i],
        ey$value[i],
        ew$value[i],
        eh$value[i],
        er$value[i],
        ex$code[i],
        ex$offset[i],
        ey$code[i],
        ey$offset[i],
        ew$code[i],
        ew$offset[i],
        eh$code[i],
        eh$offset[i],
        er$code[i],
        er$offset[i],
        g$fill,
        g$col,
        g$lwd,
        g$alpha,
        g$stroke,
        sk$roughness,
        sk$bowing,
        sk$fill_style,
        sk$fill_weight,
        sk$hachure_angle,
        sk$hachure_gap,
        sk$curve_tightness,
        sk$disable_multi,
        sk$preserve,
        sk$seed,
        kv[i]
      )
    }
  })
}

S7::method(compile, grob_lines) <- function(node, scene) {
  .with_vp(node, scene, {
    ex <- .coord(node@x)
    ey <- .coord(node@y)
    g <- .gp4(node@gp, scene)
    a <- .encode_arrow(node@arrow)
    sc <- .encode_cap(node@start_cap)
    ec <- .encode_cap(node@end_cap)
    of <- .encode_cap(node@offset)
    sk <- .encode_sketch(node@sketch)
    scene$lines(
      ex$value,
      ey$value,
      ex$code,
      ex$offset,
      ey$code,
      ey$offset,
      sc$value,
      ec$value,
      sc$code,
      ec$code,
      of$value,
      of$code,
      g$col,
      g$lwd,
      g$alpha,
      g$stroke,
      a$angle,
      a$len,
      a$ends,
      a$closed,
      sk$roughness,
      sk$bowing,
      sk$fill_style,
      sk$fill_weight,
      sk$hachure_angle,
      sk$hachure_gap,
      sk$curve_tightness,
      sk$disable_multi,
      sk$preserve,
      sk$seed,
      # Per-vertex width multipliers, or numeric(0) -- the "no profile" sentinel
      # that keeps an ordinary polyline byte-for-byte unchanged.
      as.numeric(node@lwd_profile %||% numeric(0)),
      .key1(node)
    )
  })
}

S7::method(compile, grob_polygon) <- function(node, scene) {
  .with_vp(node, scene, {
    ex <- .coord(node@x)
    ey <- .coord(node@y)
    g <- .gp4(node@gp, scene)
    sk <- .encode_sketch(node@sketch)
    scene$polygon(
      ex$value,
      ey$value,
      ex$code,
      ex$offset,
      ey$code,
      ey$offset,
      g$fill,
      g$col,
      g$lwd,
      g$alpha,
      g$stroke,
      sk$roughness,
      sk$bowing,
      sk$fill_style,
      sk$fill_weight,
      sk$hachure_angle,
      sk$hachure_gap,
      sk$curve_tightness,
      sk$disable_multi,
      sk$preserve,
      sk$seed,
      .key1(node)
    )
  })
}

# circles and points compile identically (a batched circle draw); they differ
# only in where the radius comes from and its default unit (npc vs mm).
.compile_circles <- function(node, scene, radius, rdefault, sketch = NULL) {
  .with_vp(node, scene, {
    n <- .batch_n(node)
    ex <- .coord(node@x, "npc", n)
    ey <- .coord(node@y, "npc", n)
    er <- .coord(radius, rdefault, n)
    g <- .gp4(node@gp, scene)
    sk <- .encode_sketch(sketch)
    scene$circles(
      ex$value,
      ey$value,
      er$value,
      ex$code,
      ex$offset,
      ey$code,
      ey$offset,
      er$code,
      er$offset,
      g$fill,
      g$col,
      g$lwd,
      g$alpha,
      g$stroke,
      sk$roughness,
      sk$bowing,
      sk$fill_style,
      sk$fill_weight,
      sk$hachure_angle,
      sk$hachure_gap,
      sk$curve_tightness,
      sk$disable_multi,
      sk$preserve,
      sk$seed,
      .keys_vec(node, n)
    )
  })
}

S7::method(compile, grob_circle) <- function(node, scene) {
  .compile_circles(node, scene, node@r, "npc", node@sketch)
}

S7::method(compile, grob_points) <- function(node, scene) {
  codes <- unname(.marker_codes[node@shape])
  if (all(codes == 0L)) {
    # All circles: the batched circle path (radius carries marker size, sprite
    # fast-path for dense clouds).
    .compile_circles(node, scene, node@size, "mm", node@sketch)
  } else {
    .with_vp(node, scene, {
      n <- .batch_n(node)
      ex <- .coord(node@x, "npc", n)
      ey <- .coord(node@y, "npc", n)
      es <- .coord(node@size, "mm", n)
      g <- .gp4(node@gp, scene)
      sk <- .encode_sketch(node@sketch)
      scene$markers(
        ex$value,
        ey$value,
        es$value,
        ex$code,
        ex$offset,
        ey$code,
        ey$offset,
        es$code,
        es$offset,
        vctrs::vec_recycle(as.integer(codes), n),
        g$fill,
        g$col,
        g$lwd,
        g$alpha,
        g$stroke,
        sk$roughness,
        sk$bowing,
        sk$fill_style,
        sk$fill_weight,
        sk$hachure_angle,
        sk$hachure_gap,
        sk$curve_tightness,
        sk$disable_multi,
        sk$preserve,
        sk$seed,
        .keys_vec(node, n)
      )
    })
  }
}

S7::method(compile, grob_hexagon) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- .batch_n(node)
    ex <- .coord(node@x, "npc", n)
    ey <- .coord(node@y, "npc", n)
    es <- .coord(node@size, "mm", n)
    # Non-regular geometry: per-axis full width/height (override `size`). Empty
    # streams signal the regular size-driven path to the Rust side.
    if (!is.null(node@width)) {
      ew <- .coord(node@width, "native", n)
      eh <- .coord(node@height, "native", n)
    } else {
      ew <- list(value = numeric(0), code = integer(0), offset = numeric(0))
      eh <- list(value = numeric(0), code = integer(0), offset = numeric(0))
    }
    # Per-hex fill: the binned-count colour mesh. Falls back to gp$fill, then
    # transparent. col2rgb(alpha=TRUE) flattens column-major -> per-hex RGBA
    # contiguous (chunks of 4 on the Rust side). Fold the uniform gp$alpha into
    # the per-hex fill alpha (the fill bypasses the shared-gpar resolve).
    cols <- node@fill
    if (is.null(cols)) {
      cols <- node@gp@fill
    }
    # A gradient/pattern/hatch is not a per-element colour. Send an *empty* fill
    # vector so the backend falls back to the shared `gp` paint for every element
    # -- which is what lets a batched mark take the full paint model at all. (An
    # NA-filled vector would not do: that means "explicitly transparent".)
    paint_fill <- .is_paint(cols)
    if (paint_fill) {
      frgba <- integer(0)
    } else {
      if (is.null(cols)) {
        cols <- NA
      }
      cols <- rep_len(cols, n)
      cols[is.na(cols)] <- "transparent"
      m <- grDevices::col2rgb(cols, alpha = TRUE)
      a <- node@gp@alpha
      if (!is.null(a) && !is.na(a)) {
        m[4L, ] <- round(m[4L, ] * a)
      }
      frgba <- as.integer(m)
    }
    # The per-element fill above carries the colour; keep a (possibly vector)
    # `gp$fill` out of the shared paint, which takes a single value.
    g <- .gp4(if (paint_fill) node@gp else .gp_without_fill(node@gp), scene)
    scene$hexagons(
      ex$value,
      ey$value,
      es$value,
      ew$value,
      eh$value,
      ex$code,
      ex$offset,
      ey$code,
      ey$offset,
      es$code,
      es$offset,
      ew$code,
      ew$offset,
      eh$code,
      eh$offset,
      frgba,
      identical(node@orientation, "flat"),
      g$col,
      g$lwd,
      g$alpha,
      g$stroke,
      if (paint_fill) g$fill else NULL,
      .keys_vec(node, n)
    )
  })
}

S7::method(compile, grob_sector) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- .batch_n(node)
    ex <- .coord(node@x, "npc", n)
    ey <- .coord(node@y, "npc", n)
    er0 <- .coord(node@r0, "native", n)
    er1 <- .coord(node@r1, "native", n)
    th0 <- vctrs::vec_recycle(as.numeric(node@theta0), n)
    th1 <- vctrs::vec_recycle(as.numeric(node@theta1), n)
    # Per-sector fill (like hexagons): explicit `fill`, else gp$fill, else none.
    # col2rgb(alpha=TRUE) -> contiguous RGBA quads; fold the uniform gp$alpha in.
    cols <- node@fill
    if (is.null(cols)) {
      cols <- node@gp@fill
    }
    # A gradient/pattern/hatch is not a per-element colour. Send an *empty* fill
    # vector so the backend falls back to the shared `gp` paint for every element
    # -- which is what lets a batched mark take the full paint model at all. (An
    # NA-filled vector would not do: that means "explicitly transparent".)
    paint_fill <- .is_paint(cols)
    if (paint_fill) {
      frgba <- integer(0)
    } else {
      if (is.null(cols)) {
        cols <- NA
      }
      cols <- rep_len(cols, n)
      cols[is.na(cols)] <- "transparent"
      m <- grDevices::col2rgb(cols, alpha = TRUE)
      a <- node@gp@alpha
      if (!is.null(a) && !is.na(a)) {
        m[4L, ] <- round(m[4L, ] * a)
      }
      frgba <- as.integer(m)
    }
    # The per-element fill above carries the colour; keep a (possibly vector)
    # `gp$fill` out of the shared paint, which takes a single value.
    g <- .gp4(if (paint_fill) node@gp else .gp_without_fill(node@gp), scene)
    a <- .encode_arrow(node@arrow)
    sk <- .encode_sketch(node@sketch)
    scene$sectors(
      ex$value,
      ey$value,
      er0$value,
      er1$value,
      th0,
      th1,
      ex$code,
      ex$offset,
      ey$code,
      ey$offset,
      er0$code,
      er0$offset,
      er1$code,
      er1$offset,
      frgba,
      g$col,
      g$lwd,
      g$alpha,
      g$stroke,
      a$angle,
      a$len,
      a$ends,
      a$closed,
      sk$roughness,
      sk$bowing,
      sk$fill_style,
      sk$fill_weight,
      sk$hachure_angle,
      sk$hachure_gap,
      sk$curve_tightness,
      sk$disable_multi,
      sk$preserve,
      sk$seed,
      if (paint_fill) g$fill else NULL,
      .keys_vec(node, n)
    )
  })
}

S7::method(compile, grob_loop) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- .batch_n(node)
    ex <- .coord(node@x, "npc", n)
    ey <- .coord(node@y, "npc", n)
    es <- .coord(node@size, "mm", n)
    ef <- .coord(node@foot, "mm", n)
    ang <- vctrs::vec_recycle(as.numeric(node@angle), n)
    wid <- vctrs::vec_recycle(as.numeric(node@width), n)
    g <- .gp4(node@gp, scene)
    a <- .encode_arrow(node@arrow)
    scene$add_loop(
      ex$value,
      ey$value,
      es$value,
      ef$value,
      ang,
      wid,
      ex$code,
      ex$offset,
      ey$code,
      ey$offset,
      es$code,
      es$offset,
      ef$code,
      ef$offset,
      g$col,
      g$lwd,
      g$alpha,
      g$stroke,
      a$angle,
      a$len,
      a$ends,
      a$closed
    )
  })
}

S7::method(compile, grob_segments) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- .batch_n(node)
    e0x <- .coord(node@x0, "native", n)
    e0y <- .coord(node@y0, "native", n)
    e1x <- .coord(node@x1, "native", n)
    e1y <- .coord(node@y1, "native", n)
    g <- .gp4(node@gp, scene)
    a <- .encode_arrow(node@arrow)
    sc <- .encode_cap(node@start_cap)
    ec <- .encode_cap(node@end_cap)
    of <- .encode_cap(node@offset)
    sk <- .encode_sketch(node@sketch)
    scene$segments(
      e0x$value,
      e0y$value,
      e1x$value,
      e1y$value,
      e0x$code,
      e0x$offset,
      e0y$code,
      e0y$offset,
      e1x$code,
      e1x$offset,
      e1y$code,
      e1y$offset,
      sc$value,
      ec$value,
      sc$code,
      ec$code,
      of$value,
      of$code,
      g$col,
      g$lwd,
      g$alpha,
      g$stroke,
      a$angle,
      a$len,
      a$ends,
      a$closed,
      sk$roughness,
      sk$bowing,
      sk$fill_style,
      sk$fill_weight,
      sk$hachure_angle,
      sk$hachure_gap,
      sk$curve_tightness,
      sk$disable_multi,
      sk$preserve,
      sk$seed,
      .seg_cols(node, n),
      .seg_lwds(node, n),
      .keys_vec(node, n)
    )
  })
}

S7::method(compile, grob_path) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x, node@y)
    ex <- .coord(node@x, "native", n)
    ey <- .coord(node@y, "native", n)
    g <- .gp4(node@gp, scene)
    sk <- .encode_sketch(node@sketch)
    scene$path(
      ex$value,
      ey$value,
      ex$code,
      ex$offset,
      ey$code,
      ey$offset,
      as.integer(node@nper),
      identical(node@rule, "evenodd"),
      g$fill,
      g$col,
      g$lwd,
      g$alpha,
      g$stroke,
      sk$roughness,
      sk$bowing,
      sk$fill_style,
      sk$fill_weight,
      sk$hachure_angle,
      sk$hachure_gap,
      sk$curve_tightness,
      sk$disable_multi,
      sk$preserve,
      sk$seed,
      .key1(node)
    )
  })
}

S7::method(compile, grob_raster) <- function(node, scene) {
  .with_vp(node, scene, {
    ex <- .coord(node@x, "npc", 1)
    ey <- .coord(node@y, "npc", 1)
    ew <- .coord(node@width, "npc", 1)
    eh <- .coord(node@height, "npc", 1)
    scene$image(
      node@rgba,
      node@iw,
      node@ih,
      ex$value,
      ey$value,
      ew$value,
      eh$value,
      ex$code,
      ex$offset,
      ey$code,
      ey$offset,
      ew$code,
      ew$offset,
      eh$code,
      eh$offset,
      isTRUE(node@interpolate)
    )
  })
}

S7::method(compile, grob_text) <- function(node, scene) {
  .with_vp(node, scene, {
    hv <- .just_to_hv(node@just)
    # Rich (markdown) labels take the multi-run path: one styled label composed
    # into per-glyph colour/size/baseline, drawn at each position. Plain character
    # labels keep the fast single-style batch path unchanged.
    # Rich labels take the multi-run path: a single `vellum_label` (composed once,
    # drawn at every position) or a list of them (one per datum). Plain character
    # labels keep the fast single-style batch path.
    rich <- .is_rich_label(node@label)
    n <- .batch_n(node)
    if (rich) {
      if (n == 0L) {
        return(invisible())
      }
      x <- vctrs::vec_recycle(node@x, n)
      y <- vctrs::vec_recycle(node@y, n)
      rot <- vctrs::vec_recycle(node@rot, n)
      .draw_richtext_batch(
        scene,
        node@label,
        x,
        y,
        hv[1],
        hv[2],
        rot,
        node@gp@fontfamily %||% "",
        .gp_face(node@gp),
        .gp_fontsize(node@gp),
        node@gp@col,
        node@gp@alpha,
        .gp_halo(node@gp),
        .gp_features(node@gp),
        keys = .keys_or_null(node, n)
      )
      return(invisible())
    }
    labels <- .text_labels(node@label) # seam: rich labels -> strings (plain = identity)
    if (n == 0L) {
      return(invisible())
    }
    lab <- vctrs::vec_recycle(labels, n)
    x <- vctrs::vec_recycle(node@x, n)
    y <- vctrs::vec_recycle(node@y, n)
    rot <- vctrs::vec_recycle(node@rot, n)
    # One shaping pass for all labels (repeats shaped once); see .draw_text_batch.
    # `col` is passed through as-is (NULL = inherit the viewport's gp$col, like
    # every other primitive; the root default is black, so plain text stays black).
    .draw_text_batch(
      scene,
      lab,
      x,
      y,
      hv[1],
      hv[2],
      rot,
      node@gp@fontfamily %||% "",
      .gp_face(node@gp),
      .gp_fontsize(node@gp),
      node@gp@col,
      node@gp@alpha,
      .gp_halo(node@gp),
      .gp_features(node@gp),
      .text_wrap(node),
      keys = .keys_or_null(node, n)
    )
  })
}

S7::method(compile, grob_textpath) <- function(node, scene) {
  .with_vp(node, scene, {
    hv <- .just_to_hv(node@just)
    n <- vctrs::vec_size_common(node@x, node@y)
    if (n < 2L) {
      return(invisible()) # a baseline needs at least one segment
    }
    .draw_text_path(
      scene,
      node@label,
      vctrs::vec_recycle(node@x, n),
      vctrs::vec_recycle(node@y, n),
      hv[1],
      hv[2],
      node@offset,
      node@gp@fontfamily %||% "",
      .gp_face(node@gp),
      .gp_fontsize(node@gp),
      node@gp@col,
      node@gp@alpha,
      .gp_halo(node@gp),
      .gp_features(node@gp)
    )
  })
}

# The width-constraint spec for a text grob, or NULL when it has none (which is
# the path every ordinary label takes). Millimetres become points, the unit
# shaping works in.
.text_wrap <- function(node) {
  if (is.na(node@width)) {
    return(NULL)
  }
  list(
    width = node@width / 25.4 * 72,
    height = if (is.na(node@height)) NULL else node@height / 25.4 * 72,
    align = node@align,
    fit = if (is.na(node@fit)) NULL else node@fit
  )
}

S7::method(compile, gtree) <- function(node, scene) {
  .push_vp(scene, node@vp)
  # A named viewport becomes an addressable `<g data-vellum-panel>` in the SVG
  # (a host targets it for pan/zoom); costs nothing on other backends or when
  # unnamed. Bracket the whole subtree, outside any mask/opacity group.
  panel <- .panel_name(node@vp)
  if (!is.null(panel)) {
    scene$begin_panel(panel, isTRUE(node@vp@pannable))
  }
  mask <- if (!is.null(node@vp)) node@vp@mask else NULL
  alpha <- if (!is.null(node@vp)) node@vp@alpha else NULL
  blend <- if (!is.null(node@vp)) node@vp@blend else NULL
  blend_code <- if (is.null(blend)) 0L else .blend_codes[[blend]]
  # Repaint boundary (FW4c): bracket the subtree so the raster backend can cache
  # its sub-raster, keyed on the subtree `nid`. Requires a normal blend (a blend
  # composites against the live backdrop, which a captured transparent layer
  # lacks), no blend inside it that reaches that backdrop either (VR-24, see
  # `.blend_reaches_out()`), and a known nid (a cacheable scene). Ignored by
  # SVG/PDF (they render the subtree as vector). The bracket is outermost, so it
  # captures whatever the subtree draws, including its own mask/opacity group
  # compositing below.
  cached <- !is.null(node@vp) &&
    isTRUE(node@vp@cache) &&
    blend_code == 0L &&
    !is.null(node@nid) &&
    !.blend_reaches_out(node@children)
  if (cached) {
    scene$subraster_start(node@nid)
  }
  # A group (isolated layer) is needed for a mask, a sub-1 group opacity, and/or a
  # non-normal blend mode.
  # Blur / drop shadow are group effects: they act on the composited layer, so
  # overlapping shapes inside the viewport blur (or cast one shadow) together.
  # Points -> device px, like every other absolute length.
  fx_scale <- scene$dpi() / 72
  blur_px <- if (is.null(node@vp)) 0 else (node@vp@blur %||% 0) * fx_scale
  shadow_v <- if (is.null(node@vp)) {
    numeric(0)
  } else {
    .encode_shadow(node@vp@shadow, fx_scale)
  }
  has_fx <- blur_px > 0 || length(shadow_v) > 0
  if (
    !is.null(mask) ||
      (!is.null(alpha) && alpha < 1) ||
      blend_code != 0L ||
      has_fx
  ) {
    idx <- -1L
    if (!is.null(mask)) {
      m <- .normalize_mask(mask)
      idx <- scene$mask_begin(m$code) # route mask grobs into the mask
      for (g in m$grobs) {
        compile(g, scene)
      }
      scene$mask_end()
    }
    # mask + opacity + blend installed up front; content drawn into an isolated layer
    scene$group_start(idx, alpha %||% 1, blend_code, blur_px, shadow_v)
    for (child in node@children) {
      compile(child, scene)
    }
    scene$group_end()
  } else {
    for (child in node@children) {
      compile(child, scene)
    }
  }
  if (cached) {
    scene$subraster_end()
  }
  if (!is.null(panel)) {
    scene$end_panel()
  }
  scene$pop_viewport(1L)
}

# Whether a non-normal blend among `children` composites against the backdrop
# below their parent: a blend viewport reached through viewports that open no
# group of their own. A mask, a sub-1 opacity, a blend or a blur/shadow puts
# what it holds in an isolated layer, so a blend inside one of those blends
# against that layer and is not looked into. A cached viewport's sub-raster is
# such a layer too, so it must not cache a subtree with a blend that reaches out
# (it would blend against transparency in PNG while SVG and PDF blend against
# the page, VR-24).
.blend_reaches_out <- function(children) {
  for (ch in children) {
    if (!S7::S7_inherits(ch, gtree)) {
      next
    }
    vp <- ch@vp
    if (!is.null(vp)) {
      if (!is.null(vp@blend) && .blend_codes[[vp@blend]] != 0L) {
        return(TRUE)
      }
      if (
        !is.null(vp@mask) ||
          (!is.null(vp@alpha) && vp@alpha < 1) ||
          (vp@blur %||% 0) > 0 ||
          !is.null(vp@shadow)
      ) {
        next
      }
    }
    if (.blend_reaches_out(ch@children)) {
      return(TRUE)
    }
  }
  FALSE
}

# The panel name of a viewport for `data-vellum-panel` emission: its non-empty
# `name`, else NULL (no panel group). NULL vp / unnamed vp -> NULL (no-op). The
# reserved auto-name "root" (the scene's implicit top viewport) is excluded, so a
# plain scene emits no panel group and stays byte-for-byte unchanged; only
# explicitly named viewports (e.g. a grammar's "panel-1-1") become panels.
.panel_name <- function(vp) {
  if (is.null(vp)) {
    return(NULL)
  }
  nm <- vp@name
  if (is.null(nm) || length(nm) == 0L || is.na(nm[[1]]) || !nzchar(nm[[1]])) {
    return(NULL)
  }
  nm <- as.character(nm[[1]])
  if (identical(nm, "root")) {
    return(NULL)
  }
  nm
}
