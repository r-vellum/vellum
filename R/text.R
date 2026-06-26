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

# PERF-7: a per-string shape cache. Shaping (and the font resolution inside it)
# is the dominant render-side cost for text-heavy plots, and the *same* strings
# recur across grobs (axis ticks, legend labels, facet strips). We memoise the
# shaped glyph run + metrics per (string, family, italic, weight, size), in POINT
# space (dpi-independent — the caller scales by dpi/72). Entries are immutable
# (shaping is deterministic), so the cache never needs invalidation; a crude size
# cap bounds memory.
.shape_cache <- new.env(parent = emptyenv())
.shape_cache$.n <- 0L
.SHAPE_CACHE_CAP <- 50000L

# Shape `uniq` strings, returning a list aligned with `uniq`. Each element is
# `list(w, h, n[, index, xoff, yoff, fsize, fpath, findex])` (the glyph fields are
# present only when n > 0). Cache-missing strings are shaped together in one call.
.shape_cached <- function(uniq, family, italic, weight, size) {
  keys <- paste(family, italic, weight, size, uniq, sep = "")
  if (.shape_cache$.n > .SHAPE_CACHE_CAP) { # memory backstop: drop everything
    rm(list = setdiff(ls(.shape_cache, all.names = TRUE), ".n"), envir = .shape_cache)
    .shape_cache$.n <- 0L
  }
  hit <- vapply(keys, exists, logical(1), envir = .shape_cache, inherits = FALSE)
  miss <- which(!hit)
  if (length(miss)) {
    sh <- textshaping::shape_text(uniq[miss],
      family = family, italic = italic, weight = weight, size = size
    )
    g <- sh$shape
    by_id <- split(seq_len(nrow(g)), g$metric_id) # glyph rows per shaped string
    for (j in seq_along(miss)) {
      r <- by_id[[as.character(j)]]
      entry <- if (is.null(r)) {
        list(w = sh$metrics$width[j], h = sh$metrics$height[j], n = 0L)
      } else {
        list(
          w = sh$metrics$width[j], h = sh$metrics$height[j], n = length(r),
          index = as.integer(g$index[r]), xoff = as.numeric(g$x_offset[r]),
          yoff = as.numeric(g$y_offset[r]), fsize = as.numeric(g$font_size[r]),
          fpath = as.character(g$font_path[r]), findex = as.integer(g$font_index[r])
        )
      }
      assign(keys[miss[j]], entry, envir = .shape_cache)
    }
    .shape_cache$.n <- .shape_cache$.n + length(miss)
  }
  lapply(keys, get, envir = .shape_cache, inherits = FALSE)
}

# Shape and emit many labels that share one font (a vectorised text grob). Unique
# strings are shaped once via the cache (PERF-7), then one FFI call builds one
# text node per label from the flat glyph arrays. `x`/`y` are unit vectors
# recycled to the label count; `rot` is per-label; the rest are shared.
.draw_text_batch <- function(scene, labels, x, y, hjust, vjust, rot,
                             family, fontface, fontsize, col, alpha) {
  labels <- as.character(labels)
  n <- length(labels)
  keep <- !is.na(labels) & nzchar(labels)
  if (!any(keep)) {
    return(invisible())
  }
  scale <- scene$dpi() / 72
  face <- .rs_face(fontface)
  uniq <- unique(labels[keep])
  shaped <- .shape_cached(uniq, family, face$italic, face$weight, fontsize)
  umap <- match(labels, uniq)
  # Drawn labels: those kept that shaped to >= 1 glyph (drops e.g. control chars).
  drawn <- which(keep)
  ui <- umap[drawn]
  nper <- vapply(shaped[ui], `[[`, integer(1), "n")
  ok <- nper > 0L
  drawn <- drawn[ok]
  ent <- shaped[ui[ok]] # cached entries for drawn labels, in draw order
  nper <- nper[ok]
  if (length(drawn) == 0L) {
    return(invisible())
  }
  cx <- .coord(x, "npc", n)
  cy <- .coord(y, "npc", n)
  rot <- vctrs::vec_recycle(as.numeric(rot), n)
  # One FFI call builds one text node per label from the flat glyph arrays.
  scene$texts(
    cx$value[drawn], cy$value[drawn], cx$code[drawn], cy$code[drawn], rot[drawn], hjust, vjust,
    vapply(ent, `[[`, double(1), "w") * scale, vapply(ent, `[[`, double(1), "h") * scale, as.integer(nper),
    unlist(lapply(ent, `[[`, "index"), use.names = FALSE),
    unlist(lapply(ent, `[[`, "xoff"), use.names = FALSE) * scale,
    unlist(lapply(ent, `[[`, "yoff"), use.names = FALSE) * scale,
    unlist(lapply(ent, `[[`, "fsize"), use.names = FALSE) * scale,
    unlist(lapply(ent, `[[`, "fpath"), use.names = FALSE),
    unlist(lapply(ent, `[[`, "findex"), use.names = FALSE),
    labels[drawn], family, fontface, fontsize, .rs_col_inh(col), .rs_num_inh(alpha)
  )
  invisible()
}

# Map an R fontface to textshaping's italic/weight arguments. Memoised: there are
# only a handful of distinct fontfaces but `.rs_face` is called once per text grob.
.face_cache <- new.env(parent = emptyenv())
.rs_face <- function(fontface) {
  f <- tolower(as.character(fontface)[1])
  if (is.na(f) || !nzchar(f)) {
    return(list(italic = FALSE, weight = "normal"))
  }
  v <- .face_cache[[f]]
  if (is.null(v)) {
    v <- list(italic = grepl("italic|oblique", f), weight = if (grepl("bold", f)) "bold" else "normal")
    .face_cache[[f]] <- v
  }
  v
}
