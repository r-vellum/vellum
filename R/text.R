#' Measure text
#'
#' `vl_strwidth()` / `vl_strheight()` return the rendered width/height of each
#' string, using the same shaping (\pkg{textshaping}/HarfBuzz + \pkg{systemfonts})
#' the renderer uses, so measurements match drawn text. Device-independent (does
#' not need an open scene). Vectorised over `label`. (Named `vl_*` to avoid masking
#' `grDevices::strwidth()`.)
#'
#' @param label Character vector of strings to measure.
#' @param family Font family (e.g. `"sans"`, `"serif"`, `"mono"`, or a specific
#'   family name). `""` uses the system default.
#' @param fontface One of `"plain"`, `"bold"`, `"italic"`, `"bold.italic"`.
#' @param fontsize Font size in points.
#' @param cex Multiplier applied to `fontsize`.
#' @param unit Output unit: one of `"in"`, `"pt"`, `"mm"`, `"cm"`.
#' @return A numeric vector (one per `label`) of widths/heights in `unit`.
#' @examples
#' vl_strwidth(c("short", "a longer label"), fontsize = 14)
#' @export
vl_strwidth <- function(label, family = "", fontface = "plain",
                        fontsize = 12, cex = 1, unit = "in") {
  .text_metric(label, family, fontface, fontsize, cex, unit, "width")
}

#' @rdname vl_strwidth
#' @export
vl_strheight <- function(label, family = "", fontface = "plain",
                         fontsize = 12, cex = 1, unit = "in") {
  .text_metric(label, family, fontface, fontsize, cex, unit, "height")
}

# Shared width/height measurement (vectorised over `label`); `which` is the
# `shape_text` metric column ("width"/"height"). `res = 72` => points.
.text_metric <- function(label, family, fontface, fontsize, cex, unit, which) {
  unit <- match.arg(unit, c("in", "pt", "mm", "cm"))
  label <- as.character(label)
  if (length(label) == 0L) {
    return(numeric(0))
  }
  face <- .rs_face(fontface)
  pt <- textshaping::shape_text(
    label,
    family = family, italic = face$italic, weight = face$weight,
    size = fontsize * cex, res = 72
  )$metrics[[which]]
  switch(unit,
    pt = pt,
    "in" = pt / 72,
    mm = pt / 72 * 25.4,
    cm = pt / 72 * 2.54
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
