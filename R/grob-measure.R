#' Size a unit by a grob's extent
#'
#' `grobwidth(grob)` and `grobheight(grob)` return a [vl_unit()] equal to the drawn
#' width/height of `grob` — handy for sizing a [vl_viewport()] or [grid_layout()]
#' track to its contents (e.g. a margin to an axis label). The extent is measured
#' **eagerly** to absolute millimetres at construction, so it is exact for text
#' and absolute-unit (`mm`/`in`/`pt`) grobs. A grob sized in `npc`/`native` has no
#' viewport-independent extent and is measured against a fixed reference, so for
#' those prefer `npc`/`native` directly.
#'
#' @param grob A grob (or composite subtree) to measure.
#' @param mult A multiplier on the measured extent (default 1).
#' @return A `unit` (in millimetres).
#' @examples
#' grobwidth(text_grob("A wide axis label", gp = vl_gpar(fontsize = 14)))
#' grobheight(rect_grob(height = vl_unit(8, "mm")))
#' @export
grobwidth <- function(grob, mult = 1) vl_unit(mult, "grobwidth", data = grob)

#' @rdname grobwidth
#' @export
grobheight <- function(grob, mult = 1) vl_unit(mult, "grobheight", data = grob)

# A grob's drawn extent as c(width_mm, height_mm). Text uses exact (advance)
# metrics; any other grob (incl. a gtree) is rendered into a throwaway scene and
# measured by its non-transparent bounding box. Device-independent for text and
# absolute geometry; npc/native content is measured against REF_IN.
.MEASURE_DPI <- 96
.MEASURE_REF_IN <- 12
.grob_extent <- function(g) {
  if (S7::S7_inherits(g, grob_text)) {
    fs <- .gp_fontsize(g@gp)
    fam <- g@gp@fontfamily %||% ""
    face <- .gp_face(g@gp)
    feat <- .gp_features(g@gp)
    if (.is_rich_label(g@label)) {
      # Rich label: measure the composed multi-run extent (points -> mm) so axis
      # gutters/tracks reserve the right space (shares `.label_compose()` with
      # drawing, for md() and tex() labels alike). A list (one label per
      # datum) reserves the largest.
      labs <- if (is.list(g@label)) g@label else list(g@label)
      ext <- vapply(
        labs,
        function(l) .label_extent_pt(l, fam, face, fs, feat),
        numeric(2)
      )
      w <- max(ext[1, ]) / 72 * 25.4
      h <- max(ext[2, ]) / 72 * 25.4
    } else if (!is.na(g@width)) {
      # Width-constrained (wrapping / auto-fit) plain text: measure the *wrapped*
      # block, not the natural line, or a `grobheight`-sized track reserves one
      # line for text that draws as several. Mirrors `.text_wrap()` +
      # `.draw_text_batch()` so the reserved extent matches the drawn glyphs: the
      # box is `width` mm wide, and its height is the stacked wrapped-line count
      # (after auto-fit shrinks the font, if `fit` is set).
      labs <- .text_labels(g@label)
      if (length(labs) == 0L) {
        return(c(0, 0))
      }
      rf <- .rs_face(face)
      wpt <- g@width / 25.4 * 72
      hpt <- if (is.na(g@height)) NULL else g@height / 25.4 * 72
      size <- fs
      if (!is.na(g@fit)) {
        size <- min(vapply(
          labs,
          .fit_size,
          double(1),
          width = wpt,
          height = hpt,
          align = g@align,
          family = fam,
          italic = rf$italic,
          weight = rf$weight,
          size = fs,
          min_size = g@fit,
          features = feat,
          USE.NAMES = FALSE
        ))
      }
      ext <- lapply(
        labs,
        .compose_wrapped,
        width = wpt,
        align = g@align,
        family = fam,
        italic = rf$italic,
        weight = rf$weight,
        size = size,
        features = feat
      )
      w <- max(vapply(ext, function(e) e$w, double(1))) / 72 * 25.4
      h <- max(vapply(ext, function(e) e$h, double(1))) / 72 * 25.4
    } else {
      labs <- .text_labels(g@label)
      if (length(labs) == 0L) {
        return(c(0, 0))
      }
      w <- max(vl_strwidth(labs, fam, face, fs, unit = "mm", features = feat))
      h <- max(vl_strheight(labs, fam, face, fs, unit = "mm", features = feat))
    }
    # Rotation grows the axis-aligned bounding box; report the rotated extent so a
    # grobwidth/grobheight-sized region holds slanted/vertical text.
    rot <- (g@rot %||% 0)[1]
    if (!is.null(rot) && rot %% 180 != 0) {
      th <- rot * pi / 180
      c <- abs(cos(th))
      s <- abs(sin(th))
      return(c(w * c + h * s, w * s + h * c))
    }
    return(c(w, h))
  }
  sc <- Scene$new(
    .MEASURE_REF_IN,
    .MEASURE_REF_IN,
    .MEASURE_DPI,
    c(0L, 0L, 0L, 0L)
  )
  compile(g, sc)
  bb <- sc$content_bbox() # c(min_x, min_y, max_x, max_y) px, or empty
  if (length(bb) < 4L) {
    return(c(0, 0))
  }
  c(
    (bb[3] - bb[1] + 1) / .MEASURE_DPI * 25.4,
    (bb[4] - bb[2] + 1) / .MEASURE_DPI * 25.4
  )
}
