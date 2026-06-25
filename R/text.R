#' Draw text
#'
#' Text is shaped with the [textshaping](https://github.com/r-lib/textshaping)
#' package (HarfBuzz) and the font is resolved by
#' [systemfonts](https://github.com/r-lib/systemfonts), the same stack used by
#' \pkg{ragg} and \pkg{svglite}. Glyph outlines are then rasterized by the Rust
#' backend, so text geometry matches the rest of the R graphics ecosystem.
#'
#' @param scene A [rs_scene()].
#' @param label A single string to draw.
#' @param x,y Anchor position.
#' @param units Coordinate system for the anchor; see [rs_rect()].
#' @param hjust,vjust Justification of the text block relative to the anchor, in
#'   `[0, 1]` (`0` = left/bottom, `0.5` = centre, `1` = right/top).
#' @param rot Rotation in degrees, counter-clockwise about the anchor.
#' @param family Font family (e.g. `"sans"`, `"serif"`, `"mono"`, or a specific
#'   family name). `""` uses the system default.
#' @param fontface One of `"plain"`, `"bold"`, `"italic"`, `"bold.italic"`.
#' @param fontsize Font size in points.
#' @param cex Multiplier applied to `fontsize`.
#' @param col Text colour (`NA` for none).
#' @param alpha Opacity multiplier in `[0, 1]`.
#' @return `scene`, invisibly.
#' @keywords internal
rs_text <- function(scene, label, x = 0.5, y = 0.5, units = "npc",
                    hjust = 0.5, vjust = 0.5, rot = 0,
                    family = "", fontface = "plain", fontsize = 12, cex = 1,
                    col = "black", alpha = 1) {
  units <- .rs_units(units)
  .draw_text(scene, label, as_unit(x, units), as_unit(y, units),
             hjust, vjust, rot, family, fontface, fontsize, cex, col, alpha)
  invisible(scene)
}

#' Measure text
#'
#' Returns the rendered width of a string for layout purposes, using the same
#' shaping as [rs_text()]. Device-independent (does not need an open scene).
#'
#' @inheritParams rs_text
#' @param unit Output unit: one of `"in"`, `"pt"`, `"mm"`, `"cm"`.
#' @return The text width as a single number in `unit`.
#' @export
rs_strwidth <- function(label, family = "", fontface = "plain",
                        fontsize = 12, cex = 1, unit = "in") {
  unit <- match.arg(unit, c("in", "pt", "mm", "cm"))
  face <- .rs_face(fontface)
  # res = 72 -> width in points.
  w_pt <- textshaping::shape_text(
    as.character(label)[1],
    family = family, italic = face$italic, weight = face$weight,
    size = fontsize * cex, res = 72
  )$metrics$width
  switch(unit,
    pt = w_pt,
    "in" = w_pt / 72,
    mm = w_pt / 72 * 25.4,
    cm = w_pt / 72 * 2.54
  )
}

#' @rdname rs_strwidth
#' @return `rs_strheight()`: the text height as a single number in `unit`.
#' @export
rs_strheight <- function(label, family = "", fontface = "plain",
                         fontsize = 12, cex = 1, unit = "in") {
  unit <- match.arg(unit, c("in", "pt", "mm", "cm"))
  face <- .rs_face(fontface)
  h_pt <- textshaping::shape_text(
    as.character(label)[1],
    family = family, italic = face$italic, weight = face$weight,
    size = fontsize * cex, res = 72
  )$metrics$height
  switch(unit,
    pt = h_pt,
    "in" = h_pt / 72,
    mm = h_pt / 72 * 25.4,
    cm = h_pt / 72 * 2.54
  )
}

# Shape `label` and emit a text node into `scene`. Shared by rs_text() and the
# compile(grob_text) method. `x`/`y` are unit objects; `col`/`alpha` tri-state.
.draw_text <- function(scene, label, x, y, hjust, vjust, rot,
                       family, fontface, fontsize, cex, col, alpha) {
  label <- as.character(label)[1]
  if (is.na(label) || !nzchar(label)) {
    return(invisible())
  }
  dpi <- scene$dpi()
  face <- .rs_face(fontface)
  sh <- textshaping::shape_text(label,
    family = family, italic = face$italic, weight = face$weight, size = fontsize * cex
  )
  g <- sh$shape
  if (nrow(g) == 0L) {
    return(invisible())
  }
  # shape_text reports points; convert to device pixels (em size likewise).
  scale <- dpi / 72
  cx <- .coord(x, "npc", 1)
  cy <- .coord(y, "npc", 1)
  scene$text(
    cx$value, cy$value, cx$code, cy$code, rot, hjust, vjust,
    sh$metrics$width * scale, sh$metrics$height * scale,
    as.integer(g$index), as.numeric(g$x_offset) * scale, as.numeric(g$y_offset) * scale,
    as.numeric(g$font_size) * scale, as.character(g$font_path), as.integer(g$font_index),
    .rs_col_inh(col), .rs_num_inh(alpha)
  )
  invisible()
}

# Map an R fontface to textshaping's italic/weight arguments.
.rs_face <- function(fontface) {
  f <- tolower(as.character(fontface)[1])
  list(
    italic = grepl("italic|oblique", f),
    weight = if (grepl("bold", f)) "bold" else "normal"
  )
}
