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

# --- rich (markdown) labels -------------------------------------------------

#' Rich-text labels (markdown subset)
#'
#' `md()` builds a styled label from a small markdown/HTML-free subset, for use as
#' the `label` of [text_grob()] (and anywhere a label is measured with
#' [grobwidth()]/[grobheight()]). The base font/size/colour come from `gp`; markup
#' spans override per run.
#'
#' Supported markup:
#' * `**bold**`
#' * `*italic*` or `_italic_`
#' * `^sup^` (superscript) and `~sub~` (subscript)
#' * `[text]{#c00}` — a coloured span (any R colour: name or hex)
#'
#' Spans nest (e.g. `**a^2^**`). `md()` with no markup is equivalent to the plain
#' string. Multi-line (`\n`) is not supported in this version (single line only).
#'
#' @param text A single markup string.
#' @return A `vellum_md_label` object.
#' @examples
#' lab <- md("R^2^ = **0.91**")
#' @export
md <- function(text) {
  text <- as.character(text)
  if (length(text) != 1L) {
    cli::cli_abort("{.fun md} expects a single string, not length {length(text)}.")
  }
  if (is.na(text)) text <- ""
  runs <- .md_parse(text)
  plain <- paste0(vapply(runs, `[[`, character(1), "text"), collapse = "")
  vellum_md_label(runs = runs, text = plain)
}

# A run-style descriptor. `size` is a multiplier on the base fontsize; `dy` is a
# baseline shift in base-em (fraction of the base fontsize, +up); `col` is NA to
# inherit the base colour.
.md_style <- function(bold = FALSE, italic = FALSE, size = 1, dy = 0, col = NA_character_) {
  list(bold = bold, italic = italic, size = size, dy = dy, col = col)
}
.md_run <- function(text, st) {
  list(text = text, bold = st$bold, italic = st$italic, size = st$size, dy = st$dy, col = st$col)
}

# First index >= `from` where the fixed substring `delim` occurs, or NA.
.md_find <- function(text, delim, from) {
  n <- nchar(text)
  if (from > n) return(NA_integer_)
  hay <- substr(text, from, n)
  p <- regexpr(delim, hay, fixed = TRUE)
  if (p[1] < 0) NA_integer_ else from + p[1] - 1L
}

# A `[inner]{colour}` span starting at `[` at index `i`. Returns list(inner, col,
# end) where `end` is the index of the closing `}`, or NULL if not a colour span.
.md_find_colspan <- function(text, i) {
  br <- .md_find(text, "]{", i + 1L)
  if (is.na(br)) return(NULL)
  brace <- .md_find(text, "}", br + 2L)
  if (is.na(brace)) return(NULL)
  list(inner = substr(text, i + 1L, br - 1L),
       col = substr(text, br + 2L, brace - 1L),
       end = brace)
}

# Parse a markup string into a flat list of styled runs. Recursive descent: each
# opening delimiter's matching close bounds an inner region parsed with the
# augmented style, so spans nest. Unmatched delimiters are treated as literals.
.md_parse <- function(text) {
  runs <- .md_parse_region(text, .md_style())
  runs <- Filter(function(r) nzchar(r$text), runs)
  if (length(runs) == 0L) list(.md_run("", .md_style())) else runs
}

.md_parse_region <- function(text, st) {
  runs <- list()
  buf <- ""
  n <- nchar(text)
  i <- 1L
  emit <- function() {
    if (nzchar(buf)) runs[[length(runs) + 1L]] <<- .md_run(buf, st)
    buf <<- ""
  }
  while (i <= n) {
    two <- substr(text, i, i + 1L)
    one <- substr(text, i, i)
    if (two == "**") {
      close <- .md_find(text, "**", i + 2L)
      if (!is.na(close)) {
        emit()
        inner <- substr(text, i + 2L, close - 1L)
        runs <- c(runs, .md_parse_region(inner, utils::modifyList(st, list(bold = TRUE))))
        i <- close + 2L
        next
      }
    }
    if (one == "*" || one == "_") {
      close <- .md_find(text, one, i + 1L)
      if (!is.na(close)) {
        emit()
        inner <- substr(text, i + 1L, close - 1L)
        runs <- c(runs, .md_parse_region(inner, utils::modifyList(st, list(italic = TRUE))))
        i <- close + 1L
        next
      }
    }
    if (one == "^") {
      close <- .md_find(text, "^", i + 1L)
      if (!is.na(close)) {
        emit()
        inner <- substr(text, i + 1L, close - 1L)
        sub <- utils::modifyList(st, list(size = st$size * 0.7, dy = st$dy + 0.35 * st$size))
        runs <- c(runs, .md_parse_region(inner, sub))
        i <- close + 1L
        next
      }
    }
    if (one == "~") {
      close <- .md_find(text, "~", i + 1L)
      if (!is.na(close)) {
        emit()
        inner <- substr(text, i + 1L, close - 1L)
        sub <- utils::modifyList(st, list(size = st$size * 0.7, dy = st$dy - 0.15 * st$size))
        runs <- c(runs, .md_parse_region(inner, sub))
        i <- close + 1L
        next
      }
    }
    if (one == "[") {
      cs <- .md_find_colspan(text, i)
      if (!is.null(cs)) {
        emit()
        runs <- c(runs, .md_parse_region(cs$inner, utils::modifyList(st, list(col = cs$col))))
        i <- cs$end + 1L
        next
      }
    }
    buf <- paste0(buf, one)
    i <- i + 1L
  }
  emit()
  runs
}

# Combine the base fontface with a run's bold/italic flags.
.md_run_face <- function(base, run) {
  base <- tolower(as.character(base)[1])
  b <- isTRUE(run$bold) || grepl("bold", base)
  it <- isTRUE(run$italic) || grepl("italic|oblique", base)
  if (b && it) "bold.italic" else if (b) "bold" else if (it) "italic" else "plain"
}

# Shape every run of a markdown label and concatenate into one advance-accumulated
# glyph set. Returns flat per-glyph arrays (index/xoff/yoff/fsize/fpath/findex), a
# per-glyph colour character vector, and the composed extent (w, h). All lengths
# are in points (the caller scales by dpi/72 for drawing, or converts for
# measurement). `base_col` resolves a run's inherited colour.
.md_compose <- function(label, family, fontface, fontsize, base_col) {
  gid <- integer(0); gx <- numeric(0); gy <- numeric(0)
  gsize <- numeric(0); gpath <- character(0); gface <- integer(0)
  cols <- character(0)
  adv <- 0
  top <- 0; bot <- 0
  for (run in label@runs) {
    if (!nzchar(run$text)) next
    face <- .rs_face(.md_run_face(fontface, run))
    rsize <- fontsize * run$size
    sh <- .shape_cached(run$text, family, face$italic, face$weight, rsize)[[1]]
    dyp <- run$dy * fontsize
    if (sh$n > 0L) {
      gid <- c(gid, sh$index)
      gx <- c(gx, sh$xoff + adv)
      gy <- c(gy, sh$yoff + dyp)
      gsize <- c(gsize, sh$fsize)
      gpath <- c(gpath, sh$fpath)
      gface <- c(gface, sh$findex)
      rc <- if (is.na(run$col)) base_col else run$col
      cols <- c(cols, rep(rc, sh$n))
    }
    adv <- adv + sh$w
    top <- max(top, dyp + sh$h)
    bot <- min(bot, dyp)
  }
  list(gid = gid, gx = gx, gy = gy, gsize = gsize, gpath = gpath, gface = gface,
       cols = cols, w = adv, h = top - bot)
}

# Draw a single rich (markdown) label at each of the `x`/`y` positions. The label
# is composed once into a glyph set with per-glyph colours; positions/rot recycle
# like the plain path. Mirrors `.draw_text_batch` but calls `texts_rich` with the
# per-glyph colour stream.
.draw_richtext_batch <- function(scene, label, x, y, hjust, vjust, rot,
                                 family, fontface, fontsize, col, alpha) {
  base_col <- if (is.null(col) || is.na(col)) "black" else col
  g <- .md_compose(label, family, fontface, fontsize, base_col)
  ng <- length(g$gid)
  if (ng == 0L) {
    return(invisible())
  }
  scale <- scene$dpi() / 72
  n <- vctrs::vec_size_common(x, y)
  cx <- .coord(x, "npc", n)
  cy <- .coord(y, "npc", n)
  rot <- vctrs::vec_recycle(as.numeric(rot), n)
  drawn <- which(!is.na(cx$value) & !is.na(cy$value))
  np <- length(drawn)
  if (np == 0L) {
    return(invisible())
  }
  # Per-glyph colour -> flat RGBA int stream (contiguous quads), with `gp$alpha`
  # folded into the alpha channel (mirrors hexagon_grob's per-element fill).
  m <- grDevices::col2rgb(g$cols, alpha = TRUE)
  if (!is.null(alpha) && !is.na(alpha)) m[4L, ] <- round(m[4L, ] * alpha)
  gcol1 <- as.integer(m)
  # Replicate the composed glyph set across the drawn positions.
  scene$texts_rich(
    cx$value[drawn], cy$value[drawn], cx$code[drawn], cy$code[drawn], rot[drawn], hjust, vjust,
    rep(g$w * scale, np), rep(g$h * scale, np), rep(ng, np),
    rep(g$gid, np),
    rep(g$gx * scale, np),
    rep(g$gy * scale, np),
    rep(g$gsize * scale, np),
    rep(g$gpath, np),
    rep(g$gface, np),
    rep(gcol1, np),
    rep(label@text, np), family, fontface, fontsize, .rs_col_inh(base_col), .rs_num_inh(alpha)
  )
  invisible()
}

# Composed extent of a rich label in points (w, h) — measurement path. Shares
# `.md_compose` with the draw path so reserved layout space matches drawn text.
.md_extent_pt <- function(label, family, fontface, fontsize) {
  g <- .md_compose(label, family, fontface, fontsize, "black")
  c(g$w, g$h)
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
