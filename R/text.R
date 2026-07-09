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

# Line spacing as a multiple of the font size (baseline-to-baseline), matching
# grid's default `lineheight`.
.LINEHEIGHT <- 1.2

# Compose one (possibly multi-line) plain label into a single flat glyph set.
# Lines are split on "\n", shaped via the cache, and stacked baseline-to-baseline
# with the lines centred symmetrically about y = 0, so a single-line label gets a
# zero offset and is byte-for-byte identical to the pre-multi-line path. Returns
# the same shape as a `.shape_cached` entry (w/h/n + glyph arrays), in points.
.compose_plain <- function(label, family, italic, weight, size) {
  if (!grepl("\n", label, fixed = TRUE)) {
    return(.shape_cached(label, family, italic, weight, size)[[1]])
  }
  lines <- strsplit(label, "\n", fixed = TRUE)[[1]]
  if (!length(lines)) lines <- ""
  sh <- .shape_cached(lines, family, italic, weight, size)
  nl <- length(lines)
  lead <- size * .LINEHEIGHT
  idx <- integer(0); xo <- numeric(0); yo <- numeric(0)
  fs <- numeric(0); fp <- character(0); fi <- integer(0)
  wmax <- 0; hmax <- 0
  for (i in seq_len(nl)) {
    e <- sh[[i]]
    off <- ((nl - 1) / 2 - (i - 1)) * lead # line i, centred about 0 (+up)
    if (e$n > 0L) {
      idx <- c(idx, e$index); xo <- c(xo, e$xoff); yo <- c(yo, e$yoff + off)
      fs <- c(fs, e$fsize); fp <- c(fp, e$fpath); fi <- c(fi, e$findex)
    }
    wmax <- max(wmax, e$w); hmax <- max(hmax, e$h)
  }
  list(w = wmax, h = (nl - 1) * lead + hmax, n = length(idx),
       index = idx, xoff = xo, yoff = yo, fsize = fs, fpath = fp, findex = fi)
}

# Shape and emit many labels that share one font (a vectorised text grob). Unique
# strings are shaped once via the cache (PERF-7), then one FFI call builds one
# text node per label from the flat glyph arrays. `x`/`y` are unit vectors
# recycled to the label count; `rot` is per-label; the rest are shared. Labels may
# contain "\n" (multi-line); each unique label is composed once.
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
  shaped <- lapply(uniq, .compose_plain, family, face$italic, face$weight, fontsize)
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
    cx$value[drawn], cy$value[drawn], cx$code[drawn], cx$offset[drawn], cy$code[drawn], cy$offset[drawn],
    rot[drawn], hjust, vjust,
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
#' string. Embedded newlines (`\n`) start a new line (stacked baseline-to-baseline).
#'
#' `md()` is vectorised: a length-1 input returns a single `vellum_md_label`; a
#' longer vector returns a list of them (one per element), so a `vellumplot` mark can
#' carry a per-datum rich label.
#'
#' @param text A markup string (or a character vector for per-element labels).
#' @return A `vellum_md_label` (length-1 `text`) or a list of them (length > 1).
#' @examples
#' lab <- md("R^2^ = **0.91**")
#' labs <- md(c("*a*", "**b**")) # a list of two labels
#' @export
md <- function(text) {
  text <- as.character(text)
  if (length(text) == 0L) {
    return(list())
  }
  if (length(text) == 1L) {
    return(.md_one(text))
  }
  lapply(text, .md_one)
}

# Build one `vellum_md_label` from a single markup string, splitting on "\n" into
# lines whose run lists are joined by a break marker (`list(brk = TRUE)`).
.md_one <- function(text) {
  if (is.na(text)) text <- ""
  lines <- strsplit(text, "\n", fixed = TRUE)[[1]]
  if (!length(lines)) lines <- ""
  runs <- list()
  for (i in seq_along(lines)) {
    if (i > 1L) runs[[length(runs) + 1L]] <- list(brk = TRUE)
    runs <- c(runs, .md_parse(lines[i]))
  }
  plain <- paste0(vapply(runs, function(r) r$text %||% "\n", character(1)), collapse = "")
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
  # Split the flat run list into lines at the `brk` markers (single-line labels
  # yield one line and a zero line-offset, so their output is unchanged).
  lines <- list(); cur <- list()
  for (run in label@runs) {
    if (isTRUE(run$brk)) { lines[[length(lines) + 1L]] <- cur; cur <- list() }
    else cur[[length(cur) + 1L]] <- run
  }
  lines[[length(lines) + 1L]] <- cur
  nl <- length(lines)
  lead <- fontsize * .LINEHEIGHT

  gid <- integer(0); gx <- numeric(0); gy <- numeric(0)
  gsize <- numeric(0); gpath <- character(0); gface <- integer(0)
  cols <- character(0)
  wmax <- 0; top <- 0; bot <- 0
  for (li in seq_len(nl)) {
    loff <- ((nl - 1) / 2 - (li - 1)) * lead # line baseline, centred about 0 (+up)
    adv <- 0
    for (run in lines[[li]]) {
      if (!nzchar(run$text)) next
      face <- .rs_face(.md_run_face(fontface, run))
      rsize <- fontsize * run$size
      sh <- .shape_cached(run$text, family, face$italic, face$weight, rsize)[[1]]
      dyp <- run$dy * fontsize + loff
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
    wmax <- max(wmax, adv)
  }
  list(gid = gid, gx = gx, gy = gy, gsize = gsize, gpath = gpath, gface = gface,
       cols = cols, w = wmax, h = top - bot)
}

# Draw rich (markdown) labels at the `x`/`y` positions. `label` is either a single
# `vellum_md_label` (composed once and drawn at every position, the legend/title
# case) or a list of them (one per position, recycled — the per-datum mark_text
# case). Distinct labels are composed once (deduped by plain text). Mirrors
# `.draw_text_batch` but calls `texts_rich` with the per-glyph colour stream.
.draw_richtext_batch <- function(scene, label, x, y, hjust, vjust, rot,
                                 family, fontface, fontsize, col, alpha) {
  base_col <- if (is.null(col) || is.na(col)) "black" else col
  scale <- scene$dpi() / 72
  n <- vctrs::vec_size_common(x, y)
  if (n == 0L) {
    return(invisible())
  }
  cx <- .coord(x, "npc", n)
  cy <- .coord(y, "npc", n)
  rot <- vctrs::vec_recycle(as.numeric(rot), n)
  drawn <- which(!is.na(cx$value) & !is.na(cy$value))
  np <- length(drawn)
  if (np == 0L) {
    return(invisible())
  }
  # One label per drawn position: a single label replicates; a list recycles.
  labs <- if (S7::S7_inherits(label, vellum_label)) {
    rep(list(label), np)
  } else {
    m <- length(label)
    if (m == 0L) return(invisible())
    label[((drawn - 1L) %% m) + 1L]
  }
  keytxt <- vapply(labs, function(l) l@text, character(1))
  uk <- unique(keytxt)
  comp <- lapply(uk, function(t) .md_compose(labs[[match(t, keytxt)]], family, fontface, fontsize, base_col))
  names(comp) <- uk
  # Concatenate the per-position glyph sets into the flat FFI arrays; `gp$alpha`
  # folds into the per-glyph RGBA alpha channel (mirrors hexagon_grob's fill).
  gid <- integer(0); gx <- numeric(0); gy <- numeric(0); gsize <- numeric(0)
  gpath <- character(0); gface <- integer(0); gcol <- integer(0)
  nper <- integer(np); w <- numeric(np); h <- numeric(np)
  for (j in seq_len(np)) {
    g <- comp[[keytxt[j]]]
    ng <- length(g$gid)
    nper[j] <- ng; w[j] <- g$w * scale; h[j] <- g$h * scale
    if (ng > 0L) {
      gid <- c(gid, g$gid); gx <- c(gx, g$gx * scale); gy <- c(gy, g$gy * scale)
      gsize <- c(gsize, g$gsize * scale); gpath <- c(gpath, g$gpath); gface <- c(gface, g$gface)
      m <- grDevices::col2rgb(g$cols, alpha = TRUE)
      if (!is.null(alpha) && !is.na(alpha)) m[4L, ] <- round(m[4L, ] * alpha)
      gcol <- c(gcol, as.integer(m))
    }
  }
  scene$texts_rich(
    cx$value[drawn], cy$value[drawn], cx$code[drawn], cx$offset[drawn], cy$code[drawn], cy$offset[drawn],
    rot[drawn], hjust, vjust, w, h, as.integer(nper),
    gid, gx, gy, gsize, gpath, gface, gcol,
    keytxt, family, fontface, fontsize, .rs_col_inh(base_col), .rs_num_inh(alpha)
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
