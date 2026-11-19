#' Freeze a stroke into a fillable outline
#'
#' Converts the *stroke* of a line-like grob into a `path_grob` describing the
#' region the stroke covers — the shape you would get by tracing round the drawn
#' line. What was a one-pixel-wide path with a colour becomes an area with an
#' interior, which is what you need in order to fill it with a gradient or a
#' pattern, to send it to a cutting plotter or CNC tool, or to do geometry with
#' it.
#'
#' At constant width the expansion uses the same stroker the rasterizer uses, so
#' the outline is exactly the region that would have been inked, not a
#' reimplementation that could drift from it. A *varying* width has no such
#' reference — no rasterizer can stroke a line at a changing width — so
#' `lwd_profile` is served by vellum's own offsetter instead. See
#' `Variable width` below.
#'
#' **The result is baked at one size.** A stroke width is a device quantity, so
#' its outline only exists once a page size and resolution are chosen. Those are
#' arguments here, and the returned coordinates are absolute (mm) — the outline
#' will *not* rescale with the page the way the original stroke would. That is
#' inherent: an outline is a shape, not a stroke.
#'
#' @param grob A [lines_grob()], [polygon_grob()], or [path_grob()]. Its
#'   coordinates must be resolvable without a viewport: `npc`, an absolute unit,
#'   or `native` (read against the root's default `0..1` scale, which is what a
#'   bare numeric means).
#' @param width,height Page size in inches to resolve the geometry against.
#' @param dpi Resolution to resolve the stroke width against.
#' @param gp Optional [vl_gpar()] overriding the grob's own for the stroke
#'   parameters (`lwd`, `lineend`, `linejoin`, `linemitre`).
#' @param lwd_profile Optional numeric vector of multipliers of `lwd`, describing
#'   how the width varies along the line: `c(1, 0.2)` tapers a ribbon to a fifth
#'   of its width, `c(0, 1, 0)` is a leaf, `c(1, 0, 1)` is pinched to nothing in
#'   the middle. Values must be finite and `>= 0`, and at least one must be
#'   positive; a zero is a legal width, not an error. A single value simply
#'   scales the width. `NULL` (default) is a constant width, and takes exactly
#'   the expansion this function has always performed.
#' @param along How `lwd_profile` is positioned. `"arclength"` (default) spreads
#'   its values evenly along the *drawn length* of the stroke and interpolates
#'   between them, so the profile is independent of how the polyline happens to
#'   be sampled and any profile length works. `"vertex"` reads one value per
#'   vertex, in point order, which is what you want when the widths come from
#'   data attached to the vertices — a per-observation weight, a pressure trace.
#'   The two coincide only when the vertices are evenly spaced.
#' @return A [path_grob()] in `mm` units, with `rule = "winding"`, whose fill is
#'   the stroked region. Its `gp` starts from the source grob's stroke colour as
#'   a fill, so drawing it looks like the original line.
#' @section Variable width:
#'
#' The region swept by a round nib of varying radius is the union of the convex
#' hulls of successive pairs of end discs, so `lwd_profile` builds that union
#' rather than offsetting each vertex along its normal. The distinction matters
#' at a taper: an offset boundary would cut *into* the end disc and the tip would
#' come out waisted rather than pointed.
#'
#' Three consequences worth knowing:
#'
#' * Width varies linearly **between vertices**, so a profile is only as smooth
#'   as the polyline under it. `bezier_grob()` and `spline_grob()` flatten to a
#'   polyline before this function sees them, so a profile rides the flattened
#'   points — prefer `along = "arclength"` there, and raise their `n` if a taper
#'   looks faceted.
#' * On a closed `polygon_grob()` or `path_grob()` the profile is **cyclic**: a
#'   ring has no first vertex a reader can see, so the values wrap. `c(1, 0)` on
#'   a ring is therefore two tapers, not one.
#' * `lwd_profile = NULL` is byte-identical to previous versions. A *constant*
#'   profile such as `lwd_profile = 1` is not — it goes through the offsetter, so
#'   it agrees with tiny-skia's stroker as a picture but not to the last bit.
#'   `lineend` and `linejoin` are honoured, but only on the outer silhouette; the
#'   inner side of a join is the natural overlap either way.
#' @seealso [path_grob()], [grob], [segments_grob()] for per-*element* widths
#' @examples
#' zig <- lines_grob(c(0.1, 0.35, 0.6, 0.9), c(0.2, 0.8, 0.2, 0.8),
#'                   gp = vl_gpar(col = "steelblue", lwd = 12))
#' outline <- stroke_to_path(zig, width = 3, height = 2)
#' # A width that varies along the line: thick in the middle, tapered at both ends.
#' leaf <- stroke_to_path(zig, width = 3, height = 2, lwd_profile = c(0.15, 1, 0.15))
#' # Now fillable: a gradient across the ribbon the line traced.
#' vl_scene(3, 2) |>
#'   draw(S7::set_props(outline, gp = vl_gpar(
#'     fill = linear_gradient(c("tomato", "gold")), col = "grey20", lwd = 0.5
#'   )))
#' @export
stroke_to_path <- function(
  grob,
  width = 6,
  height = 4,
  dpi = 96,
  gp = NULL,
  lwd_profile = NULL,
  along = c("arclength", "vertex")
) {
  along <- match.arg(along)
  .check_lwd_profile(lwd_profile)
  ok <- S7::S7_inherits(grob, grob_lines) ||
    S7::S7_inherits(grob, grob_polygon) ||
    S7::S7_inherits(grob, grob_path)
  if (!ok) {
    cli::cli_abort(c(
      "{.arg grob} must be a {.fn lines_grob}, {.fn polygon_grob} or {.fn path_grob}.",
      i = "Only line-like grobs have a stroke to expand."
    ))
  }
  style <- gp %||% grob@gp
  closed <- !S7::S7_inherits(grob, grob_lines)

  # Resolve the coordinates the way a render of this size would, so the outline
  # matches what would actually have been drawn.
  px_w <- width * dpi
  px_h <- height * dpi
  xs <- .stp_px(grob@x, px_w, dpi)
  ys <- px_h - .stp_px(grob@y, px_h, dpi) # device y is top-down
  nper <- if (S7::S7_inherits(grob, grob_path) && !is.null(grob@nper)) {
    as.integer(grob@nper)
  } else {
    length(xs)
  }
  lwd_px <- (style@lwd %||% 1) * dpi / 96
  cap <- .encode_code(style@lineend, .lineend_codes, "lineend") %||% 0L
  join <- .encode_code(style@linejoin, .linejoin_codes, "linejoin") %||% 0L
  miter <- style@linemitre %||% 10
  # A constant width goes to tiny-skia's stroker, exactly as it always has; a
  # profile goes to vellum's own offsetter. Two entry points rather than a flag,
  # so no profile value can steer the constant-width case somewhere new.
  v <- if (is.null(lwd_profile)) {
    rs_stroke_to_path(xs, ys, nper, closed, lwd_px, cap, join, miter)
  } else {
    pr <- .stp_profile(xs, ys, nper, closed, lwd_px, lwd_profile, along)
    rs_stroke_to_path_var(
      pr$x,
      pr$y,
      pr$nper,
      closed,
      pr$hw,
      cap,
      join,
      miter,
      0L
    )
  }
  if (!length(v)) {
    cli::cli_abort(c(
      "The stroke expanded to nothing (a zero width, or no geometry).",
      i = if (!is.null(lwd_profile)) {
        "A zero in {.arg lwd_profile} is fine \u2014 that is a taper to a point \u2014 but {.code lwd} must still be positive and the grob needs at least two distinct points."
      }
    ))
  }
  nsub <- as.integer(v[1])
  lens <- as.integer(v[1 + seq_len(nsub)])
  tot <- sum(lens)
  off <- 1L + nsub
  ox <- v[off + seq_len(tot)]
  oy <- v[off + tot + seq_len(tot)]
  # Back to absolute mm, y-up again.
  path_grob(
    x = vl_unit(ox / dpi * 25.4, "mm"),
    y = vl_unit((px_h - oy) / dpi * 25.4, "mm"),
    id = rep(seq_len(nsub), lens),
    rule = "winding",
    gp = vl_gpar(fill = style@col %||% "black", col = NA),
    name = grob@name
  )
}

# Resolve a unit vector to device px along one axis for `stroke_to_path()`.
# Only the coordinate spaces meaningful outside a scene are accepted: `native`
# needs an xscale/yscale that does not exist without a viewport.
.stp_px <- function(u, extent_px, dpi) {
  code <- vctrs::field(u, "unit")
  val <- vctrs::field(u, "value")
  off <- vctrs::field(u, "offset") # always mm
  # `native` is resolved against the root viewport's default 0..1 scale, where it
  # coincides with `npc` -- which is what a bare numeric in `lines_grob()` means.
  # A grob destined for a viewport with a different scale must be resolved there
  # first; there is no viewport here to ask.
  rel <- unname(.unit_codes[c("npc", "native")])
  abs_codes <- unname(.unit_codes[c("mm", "in", "pt")])
  if (!all((code %in% c(rel, abs_codes)))) {
    cli::cli_abort(c(
      "{.fn stroke_to_path} needs coordinates it can resolve without a viewport.",
      x = "Found {.val null} units, which only a layout can size.",
      i = "Use {.val npc}, {.val native}, or an absolute unit."
    ))
  }
  mm_to_px <- dpi / 25.4
  base <- ifelse(
    code %in% rel,
    val * extent_px,
    .abs_to_mm(val, code) * mm_to_px
  )
  as.numeric(base) + off * mm_to_px
}

# Validate a width profile. `NULL` means constant width and is always fine.
.check_lwd_profile <- function(p) {
  if (is.null(p)) {
    return(invisible(NULL))
  }
  if (!is.numeric(p) || !length(p)) {
    cli::cli_abort(
      "{.arg lwd_profile} must be a non-empty numeric vector of {.code lwd} multipliers."
    )
  }
  if (anyNA(p) || !all(is.finite(p))) {
    cli::cli_abort(
      "{.arg lwd_profile} must not contain missing or non-finite values."
    )
  }
  if (any(p < 0)) {
    cli::cli_abort("{.arg lwd_profile} values must all be >= 0.")
  }
  if (!any(p > 0)) {
    cli::cli_abort(c(
      "{.arg lwd_profile} must have at least one value greater than zero.",
      i = "An all-zero profile has no width anywhere, so there is no region to expand."
    ))
  }
  invisible(NULL)
}

# Position a width profile along a resolved polyline, returning the (possibly
# subdivided) coordinates and a half-width per vertex, all in device px.
#
# The two parameterisations are genuinely different mechanisms, not two spellings
# of one: `"vertex"` reads one value per point, `"arclength"` spreads the values
# evenly along the drawn length and interpolates. They agree only when the
# vertices are evenly spaced, which is why `along` is an explicit argument rather
# than something inferred from `length(profile)`.
.stp_profile <- function(xs, ys, nper, closed, lwd_px, profile, along) {
  ntot <- sum(nper)
  if (identical(along, "vertex")) {
    if (length(profile) == 1L) {
      profile <- rep(profile, ntot)
    }
    if (length(profile) != ntot) {
      cli::cli_abort(c(
        "{.arg lwd_profile} must have one value per vertex when {.code along = \"vertex\"}.",
        x = "Got {length(profile)} value{?s} for {ntot} vertex/vertices.",
        i = 'Use the default {.code along = "arclength"} to spread the values evenly along the line instead.'
      ))
    }
    return(list(
      x = as.numeric(xs),
      y = as.numeric(ys),
      nper = as.integer(nper),
      hw = 0.5 * lwd_px * as.numeric(profile)
    ))
  }

  # Arc length, per sub-path independently, so every stroke in a multi-sub-path
  # grob carries the whole profile rather than one profile spanning all of them.
  k <- length(profile)
  # On a ring the profile is cyclic: a ring has no first vertex a reader can see,
  # so wrapping is the only reading that does not put a width step at whichever
  # vertex the input happened to start from.
  pv <- if (closed && k > 1L) c(profile, profile[1L]) else profile
  # A single value is a constant multiplier; there is nothing to interpolate.
  if (length(pv) == 1L) {
    pv <- c(pv, pv)
  }
  stations <- seq(0, 1, length.out = length(pv))

  ox <- oy <- ohw <- numeric(0)
  onper <- integer(0)
  at <- 0L
  for (cnt in as.integer(nper)) {
    if (cnt < 1L) {
      next
    }
    idx <- at + seq_len(cnt)
    at <- at + cnt
    px <- as.numeric(xs)[idx]
    py <- as.numeric(ys)[idx]
    if (cnt < 2L) {
      ox <- c(ox, px)
      oy <- c(oy, py)
      ohw <- c(ohw, rep(0.5 * lwd_px * pv[1L], cnt))
      onper <- c(onper, cnt)
      next
    }
    # Subdivide so a fine profile is not thrown away on a coarse polyline: aim
    # for two stations per profile interval, keeping every original vertex
    # because the corners carry the joins.
    cx <- px
    cy <- py
    if (k > 2L) {
      seg <- sqrt(diff(px)^2 + diff(py)^2)
      total <- sum(seg) +
        if (closed) {
          sqrt((px[1L] - px[cnt])^2 + (py[1L] - py[cnt])^2)
        } else {
          0
        }
      step <- total / max(1L, min(2L * (k - 1L), 1000L))
      if (is.finite(step) && step > 0) {
        cx <- px[1L]
        cy <- py[1L]
        for (i in seq_len(cnt - 1L)) {
          m <- max(1L, ceiling(seg[i] / step))
          t <- seq_len(m) / m
          cx <- c(cx, px[i] + t * (px[i + 1L] - px[i]))
          cy <- c(cy, py[i] + t * (py[i + 1L] - py[i]))
        }
      }
    }
    m <- length(cx)
    d <- sqrt(diff(cx)^2 + diff(cy)^2)
    ring_close <- if (closed) {
      sqrt((cx[1L] - cx[m])^2 + (cy[1L] - cy[m])^2)
    } else {
      0
    }
    cum <- c(0, cumsum(d))
    total <- cum[m] + ring_close
    hw <- if (!is.finite(total) || total <= 0) {
      rep(0.5 * lwd_px * pv[1L], m)
    } else {
      0.5 *
        lwd_px *
        stats::approx(stations, pv, xout = cum / total, rule = 2)$y
    }
    ox <- c(ox, cx)
    oy <- c(oy, cy)
    ohw <- c(ohw, hw)
    onper <- c(onper, m)
  }
  list(x = ox, y = oy, nper = as.integer(onper), hw = ohw)
}
