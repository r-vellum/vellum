# ============================================================================
# P0 BOOTSTRAP / CORRECTNESS ORACLE — THROWAWAY (remove once the Rust tween in
# `src/rust/src/tween.rs` is proven against it; see _docs/GAPS-ANIMATION.md §9).
#
# A pure-R scene interpolation ("tween") that lerps between two compiled vellum
# scenes, plus a magick frame loop that encodes the tweened frames to an animated
# image. It exists to (a) validate the tween math and (b) be the golden oracle the
# Rust `render_animation()` is asserted equal to. None of this is exported; it is
# reached only from tests via `vellum:::`. Deleting this file (and its test) is a
# no-op for the shipped package.
#
# The behaviour defined here is the *specification* the Rust port must match:
#   * unit geometry, same base code -> lerp (value, offset); cross base -> snap
#   * plain-number geometry (theta, rot, angle) -> lerp
#   * colour (col/fill, solid) -> Oklab lerp (ported byte-compatibly from
#     src/rust/src/oklab.rs), alpha lerped linearly
#   * bounded gp (alpha, lwd, fontsize, linemitre, lineheight) -> lerp
#   * discrete/structural (shape, lty, fontface, label, ...) -> snap at t>=0.5
#   * enter (only in B) fades 0->target; exit (only in A) fades target->0
#   * differing vertex counts -> crossfade (no continuous morph)
# ============================================================================

# --- Oklab colour interpolation (port of src/rust/src/oklab.rs) --------------
# Ported verbatim (same coefficients) so the R oracle and the Rust engine agree
# to within float tolerance. Operates on 0:255 sRGB channels.

.tw_srgb_to_linear <- function(c) {
  c <- c / 255
  ifelse(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055)^2.4)
}

.tw_linear_to_srgb <- function(c) {
  c <- pmin(pmax(c, 0), 1)
  v <- ifelse(c <= 0.0031308, c * 12.92, 1.055 * c^(1 / 2.4) - 0.055)
  round(pmin(pmax(v * 255, 0), 255))
}

# sRGB (0:255 r,g,b) -> Oklab (L, a, b), vectorised.
.tw_rgb_to_oklab <- function(r, g, b) {
  r <- .tw_srgb_to_linear(r)
  g <- .tw_srgb_to_linear(g)
  b <- .tw_srgb_to_linear(b)
  l <- 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
  m <- 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
  s <- 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
  l_ <- l^(1 / 3)
  m_ <- m^(1 / 3)
  s_ <- s^(1 / 3)
  list(
    L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
    a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
    b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
  )
}

# Oklab (L, a, b) -> sRGB (0:255 r,g,b), vectorised.
.tw_oklab_to_rgb <- function(L, A, B) {
  l_ <- L + 0.3963377774 * A + 0.2158037573 * B
  m_ <- L - 0.1055613458 * A - 0.0638541728 * B
  s_ <- L - 0.0894841775 * A - 1.2914855480 * B
  l <- l_^3
  m <- m_^3
  s <- s_^3
  list(
    r = .tw_linear_to_srgb(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
    g = .tw_linear_to_srgb(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
    b = .tw_linear_to_srgb(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
  )
}

# Interpolate two colour vectors in Oklab at fraction `t`; alpha lerped linearly.
# `NA` (no-paint) or non-string (gradient/pattern) endpoints don't lerp: they snap
# to whichever side `t` is nearer (t<0.5 -> a, else b). Returns hex strings.
.tw_tween_col <- function(a, b, t) {
  n <- max(length(a), length(b))
  if (n == 0L) return(a)
  a <- rep_len(a, n)
  b <- rep_len(b, n)
  snap_side <- if (t < 0.5) a else b
  # elements both plain colour strings -> Oklab lerp; else snap
  lerpable <- !is.na(a) & !is.na(b) & is.character(a) & is.character(b)
  out <- snap_side
  if (any(lerpable)) {
    ca <- grDevices::col2rgb(a[lerpable], alpha = TRUE)
    cb <- grDevices::col2rgb(b[lerpable], alpha = TRUE)
    oa <- .tw_rgb_to_oklab(ca[1, ], ca[2, ], ca[3, ])
    ob <- .tw_rgb_to_oklab(cb[1, ], cb[2, ], cb[3, ])
    L <- oa$L + (ob$L - oa$L) * t
    A <- oa$a + (ob$a - oa$a) * t
    B <- oa$b + (ob$b - oa$b) * t
    rgb <- .tw_oklab_to_rgb(L, A, B)
    alpha <- round(ca[4, ] + (cb[4, ] - ca[4, ]) * t)
    out[lerpable] <- grDevices::rgb(rgb$r, rgb$g, rgb$b, alpha, maxColorValue = 255)
  }
  out
}

# --- numeric / unit interpolation -------------------------------------------

.tw_lerp <- function(a, b, t) a + (b - a) * t

# Lerp two `vellum_unit` vectors. Same base code -> lerp (value, offset); a
# differing base code on any element snaps that element to the near side (a proper
# cross-base resolve needs the device transform, which the Rust engine has and
# this oracle does not — hand-built oracle scenes use matching bases).
.tw_tween_unit <- function(ua, ub, t) {
  rc <- vctrs::vec_recycle_common(ua, ub)
  ua <- rc[[1L]]
  ub <- rc[[2L]]
  va <- vctrs::field(ua, "value")
  ca <- vctrs::field(ua, "unit")
  oa <- vctrs::field(ua, "offset")
  vb <- vctrs::field(ub, "value")
  cb <- vctrs::field(ub, "unit")
  ob <- vctrs::field(ub, "offset")
  same <- ca == cb
  value <- ifelse(same, .tw_lerp(va, vb, t), if (t < 0.5) va else vb)
  offset <- ifelse(same, .tw_lerp(oa, ob, t), if (t < 0.5) oa else ob)
  code <- ifelse(same | t < 0.5, ca, cb)
  new_unit(value, as.integer(code), offset)
}

# Tween two `vl_gpar`s. `base` supplies the discrete/snap fields (it is A's gp when
# t<0.5 else B's). col/fill lerp in Oklab; lwd/alpha/linemitre/fontsize/lineheight
# lerp numerically; everything else stays from `base`.
.tw_tween_gp <- function(ga, gb, t) {
  base <- if (t < 0.5) ga else gb
  col <- .tw_gp_col(ga@col, gb@col, t, base@col)
  fill <- .tw_gp_col(ga@fill, gb@fill, t, base@fill)
  numf <- function(a, b, bs) {
    if (is.null(a) || is.null(b) || !is.numeric(a) || !is.numeric(b)) return(bs)
    rc <- vctrs::vec_recycle_common(a, b)
    .tw_lerp(rc[[1L]], rc[[2L]], t)
  }
  S7::set_props(
    base,
    col = col, fill = fill,
    lwd = numf(ga@lwd, gb@lwd, base@lwd),
    alpha = numf(ga@alpha, gb@alpha, base@alpha),
    linemitre = numf(ga@linemitre, gb@linemitre, base@linemitre),
    fontsize = numf(ga@fontsize, gb@fontsize, base@fontsize),
    lineheight = numf(ga@lineheight, gb@lineheight, base@lineheight)
  )
}

# A gp colour field lerps only when both sides are plain colour strings; a NULL
# (inherit), gradient, or pattern on either side snaps to `base`.
.tw_gp_col <- function(a, b, t, base) {
  if (is.null(a) || is.null(b) || !is.character(a) || !is.character(b)) {
    return(base)
  }
  .tw_tween_col(a, b, t)
}

# --- per-class interpolatable geometry --------------------------------------
# Unit-typed geometry slots and plain-number geometry slots, per grob class.
# Anything not listed is discrete and snaps with `base`.

.tw_unit_slots <- list(
  grob_rect = c("x", "y", "width", "height"),
  grob_roundrect = c("x", "y", "width", "height", "r"),
  grob_circle = c("x", "y", "r"),
  grob_points = c("x", "y", "size"),
  grob_hexagon = c("x", "y", "size"),
  grob_sector = c("x", "y", "r0", "r1"),
  grob_segments = c("x0", "y0", "x1", "y1"),
  grob_lines = c("x", "y"),
  grob_polygon = c("x", "y"),
  grob_path = c("x", "y"),
  grob_text = c("x", "y"),
  grob_loop = c("x", "y", "size", "foot"),
  grob_raster = c("x", "y", "width", "height")
)

.tw_num_slots <- list(
  grob_sector = c("theta0", "theta1"),
  grob_text = c("rot"),
  grob_loop = c("angle", "width")
)

# Grob classes whose x/y are a polyline/polygon vertex list: a differing vertex
# count between keyframes has no continuous morph, so crossfade instead.
.tw_vertex_classes <- c("grob_lines", "grob_polygon", "grob_path")

.tw_class <- function(node) {
  cl <- class(node)[1L]
  sub("^vellum::", "", cl)
}

# Fade a whole subtree (or leaf) by factor `f`: multiply every leaf grob's gp
# alpha. Used for enter (f = t) and exit (f = 1 - t).
.tw_fade <- function(node, f) {
  if (S7::S7_inherits(node, gtree)) {
    kids <- lapply(node@children, .tw_fade, f = f)
    return(S7::set_props(node, children = kids))
  }
  a0 <- node@gp@alpha
  a0 <- if (is.null(a0)) 1 else a0
  S7::set_props(node, gp = S7::set_props(node@gp, alpha = f * a0))
}

# Tween two matched leaf grobs of the same class. Returns a list of grobs (one,
# or two for a crossfade). `base` supplies discrete slots (snaps at t = 0.5).
.tw_tween_leaf <- function(a, b, t) {
  cls <- .tw_class(a)
  if (!identical(cls, .tw_class(b))) {
    # class changed -> no morph; crossfade.
    return(list(.tw_fade(a, 1 - t), .tw_fade(b, t)))
  }
  units <- .tw_unit_slots[[cls]]
  # vertex-count mismatch on a polyline/polygon/path -> crossfade.
  if (cls %in% .tw_vertex_classes &&
      .vsize(a@x) != .vsize(b@x)) {
    return(list(.tw_fade(a, 1 - t), .tw_fade(b, t)))
  }
  base <- if (t < 0.5) a else b
  props <- list()
  for (s in units) {
    props[[s]] <- .tw_tween_unit(S7::prop(a, s), S7::prop(b, s), t)
  }
  for (s in .tw_num_slots[[cls]]) {
    props[[s]] <- .tw_lerp(S7::prop(a, s), S7::prop(b, s), t)
  }
  out <- if (length(props)) do.call(S7::set_props, c(list(base), props)) else base
  out <- S7::set_props(out, gp = .tw_tween_gp(a@gp, b@gp, t))
  list(out)
}

# Identity key of a node for cross-scene matching: its `id`, else NA.
.tw_node_key <- function(node) {
  id <- node@id
  if (is.null(id) || length(id) == 0L) return(NA_character_)
  id <- as.character(id)[1L]
  if (is.na(id) || !nzchar(id)) NA_character_ else id
}

# Pair up two children lists. If every child on both sides has a unique non-NA
# `id`, match by id (so enter/exit is detected); otherwise zip by position, with
# trailing extras entering/exiting.
.tw_match_children <- function(a_kids, b_kids) {
  na <- length(a_kids)
  nb <- length(b_kids)
  ida <- vapply(a_kids, .tw_node_key, character(1))
  idb <- vapply(b_kids, .tw_node_key, character(1))
  by_id <- na > 0L && nb > 0L &&
    !anyNA(ida) && !anyNA(idb) &&
    !anyDuplicated(ida) && !anyDuplicated(idb)
  if (by_id) {
    keys <- union(ida, idb)
    lapply(keys, function(k) {
      ia <- match(k, ida)
      ib <- match(k, idb)
      list(
        a = if (is.na(ia)) NULL else a_kids[[ia]],
        b = if (is.na(ib)) NULL else b_kids[[ib]]
      )
    })
  } else {
    n <- max(na, nb)
    lapply(seq_len(n), function(i) {
      list(
        a = if (i <= na) a_kids[[i]] else NULL,
        b = if (i <= nb) b_kids[[i]] else NULL
      )
    })
  }
}

# Recursively tween two subtrees (gtrees or leaves), returning a list of grobs.
.tw_tween_node <- function(a, b, t) {
  if (is.null(a)) return(list(.tw_fade(b, t)))       # enter
  if (is.null(b)) return(list(.tw_fade(a, 1 - t)))   # exit
  a_tree <- S7::S7_inherits(a, gtree)
  b_tree <- S7::S7_inherits(b, gtree)
  if (a_tree && b_tree) {
    base <- if (t < 0.5) a else b
    pairs <- .tw_match_children(a@children, b@children)
    kids <- unlist(
      lapply(pairs, function(p) .tw_tween_node(p$a, p$b, t)),
      recursive = FALSE
    )
    return(list(S7::set_props(base, children = kids)))
  }
  if (!a_tree && !b_tree) {
    return(.tw_tween_leaf(a, b, t))
  }
  # gtree vs leaf: no morph, crossfade the two.
  list(.tw_fade(a, 1 - t), .tw_fade(b, t))
}

# --- public (internal) oracle surface ---------------------------------------

# Interpolate between two compiled scenes at fraction `t` in [0, 1]. Returns a new
# `vellum_scene` whose tree is the tweened node list. Page size / dpi / background
# come from the near-side scene.
.scene_tween <- function(scene_a, scene_b, t) {
  t <- max(0, min(1, t))
  ra <- .materialize(as_vellum_scene(scene_a))
  rb <- .materialize(as_vellum_scene(scene_b))
  rt <- .tw_tween_node(ra, rb, t)[[1L]]
  base <- if (t < 0.5) scene_a else scene_b
  vellum_scene(
    width = base@width, height = base@height, dpi = base@dpi, bg = base@bg,
    root = rt, cid = NULL
  )
}

# --- easing (minimal; the full library is the R-side schedule in P3+) --------

.tw_ease <- function(t, name = "linear") {
  switch(name,
    linear = t,
    `quad-in` = t * t,
    `quad-out` = 1 - (1 - t)^2,
    `quad-in-out` = ifelse(t < 0.5, 2 * t * t, 1 - (-2 * t + 2)^2 / 2),
    `cubic-in` = t^3,
    `cubic-out` = 1 - (1 - t)^3,
    `cubic-in-out` = ifelse(t < 0.5, 4 * t^3, 1 - (-2 * t + 2)^3 / 2),
    `sine-in-out` = -(cos(pi * t) - 1) / 2,
    cli::cli_abort("Unknown easing {.val {name}}.")
  )
}

# Build a per-frame schedule for K keyframes: `nframes` frames per inter-keyframe
# segment, plus a final frame resting on the last keyframe. Returns a data frame
# with `i` (the segment's left keyframe index) and eased `t` in [0, 1).
.anim_schedule <- function(nkeys, nframes, ease = "linear") {
  if (nkeys < 2L) cli::cli_abort("Need at least 2 keyframes.")
  segs <- nkeys - 1L
  i <- rep(seq_len(segs), each = nframes)
  lin <- rep((seq_len(nframes) - 1L) / nframes, times = segs)
  out <- data.frame(i = i, t = .tw_ease(lin, ease))
  rbind(out, data.frame(i = segs, t = 1))
}

# Render a scene to a magick image (via the vellum_scene as.raster method).
.tw_scene_image <- function(scene) {
  magick::image_read(grDevices::as.raster(as_vellum_scene(scene)))
}

# Pure-R animation: tween K keyframe scenes per `schedule` and encode the frames
# to `path` (any magick-writable animated container, e.g. .gif) at `fps`. This is
# the reference the Rust `render_animation()` reproduces.
.render_animation_r <- function(keyframes, schedule, path, fps = 25) {
  if (!requireNamespace("magick", quietly = TRUE)) {
    cli::cli_abort("The {.pkg magick} package is required for the pure-R animation loop.")
  }
  frames <- lapply(seq_len(nrow(schedule)), function(k) {
    i <- schedule$i[k]
    .tw_scene_image(.scene_tween(keyframes[[i]], keyframes[[i + 1L]], schedule$t[k]))
  })
  anim <- magick::image_animate(
    magick::image_join(frames),
    fps = fps, optimize = TRUE, dispose = "previous"
  )
  magick::image_write(anim, path)
  invisible(path)
}

# Convenience: K keyframes -> animated file in one call.
.animate_r <- function(keyframes, path, nframes = 25, fps = 25, ease = "linear") {
  sched <- .anim_schedule(length(keyframes), nframes, ease)
  .render_animation_r(keyframes, sched, path, fps = fps)
}
