#' Measure text
#'
#' Returns the rendered width of a string for layout purposes, using the same
#' shaping (\pkg{textshaping}/HarfBuzz + \pkg{systemfonts}) the renderer uses, so
#' measurements match drawn text. Device-independent (does not need an open scene).
#'
#' @param label A single string to measure.
#' @param family Font family (e.g. `"sans"`, `"serif"`, `"mono"`, or a specific
#'   family name). `""` uses the system default.
#' @param fontface One of `"plain"`, `"bold"`, `"italic"`, `"bold.italic"`.
#' @param fontsize Font size in points.
#' @param cex Multiplier applied to `fontsize`.
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

# Shape and emit many labels that share one font (a vectorised text grob). All
# labels are shaped in ONE textshaping call (10x faster than per-label) and
# repeated strings are shaped once. `x`/`y` are unit vectors recycled to the label
# count; `rot` is per-label; `hjust`/`vjust`/`col`/`alpha`/font are shared.
.draw_text_batch <- function(scene, labels, x, y, hjust, vjust, rot,
                             family, fontface, fontsize, col, alpha) {
  labels <- as.character(labels)
  n <- length(labels)
  keep <- !is.na(labels) & nzchar(labels)
  if (!any(keep)) {
    return(invisible())
  }
  dpi <- scene$dpi()
  scale <- dpi / 72
  face <- .rs_face(fontface)
  uniq <- unique(labels[keep])
  sh <- textshaping::shape_text(uniq,
    family = family, italic = face$italic, weight = face$weight, size = fontsize
  )
  g <- sh$shape
  by_id <- split(seq_len(nrow(g)), g$metric_id) # glyph rows per unique label
  umap <- match(labels, uniq)
  # Drawn labels, with their glyph-row blocks; drop labels that shaped to nothing.
  drawn <- which(keep)
  rows <- lapply(umap[drawn], function(ui) {
    r <- by_id[[as.character(ui)]]
    if (is.null(r)) integer(0) else r
  })
  nper <- lengths(rows)
  ok <- nper > 0L
  drawn <- drawn[ok]
  if (length(drawn) == 0L) {
    return(invisible())
  }
  gi <- unlist(rows[ok], use.names = FALSE) # flat glyph-row indices, label order
  nper <- nper[ok]
  cx <- .coord(x, "npc", n)
  cy <- .coord(y, "npc", n)
  rot <- vctrs::vec_recycle(as.numeric(rot), n)
  ud <- umap[drawn]
  # One FFI call builds one text node per label from the flat glyph arrays.
  scene$texts(
    cx$value[drawn], cy$value[drawn], cx$code[drawn], cy$code[drawn], rot[drawn], hjust, vjust,
    sh$metrics$width[ud] * scale, sh$metrics$height[ud] * scale, as.integer(nper),
    as.integer(g$index[gi]), as.numeric(g$x_offset[gi]) * scale, as.numeric(g$y_offset[gi]) * scale,
    as.numeric(g$font_size[gi]) * scale, as.character(g$font_path[gi]), as.integer(g$font_index[gi]),
    labels[drawn], family, fontface, fontsize, .rs_col_inh(col), .rs_num_inh(alpha)
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
