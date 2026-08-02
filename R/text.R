#' Measure text
#'
#' `vl_strwidth()` / `vl_strheight()` return the rendered width/height of each
#' string, using the same shaping (\pkg{textshaping}/HarfBuzz + \pkg{systemfonts})
#' the renderer uses, so measurements match drawn text. Device-independent (does
#' not need an open scene). Vectorised over `label`. (Named `vl_*` to avoid masking
#' `grDevices::strwidth()`.)
#'
#' @param label Character vector of strings to measure, or a rich label from
#'   [md()] (or a list of them). Rich labels are measured with the same run
#'   composition the renderer draws, so super/subscripts and bold runs are
#'   accounted for; `family`/`fontface`/`fontsize` then supply the *base* style
#'   the label's runs are relative to.
#' @param family Font family (e.g. `"sans"`, `"serif"`, `"mono"`, or a specific
#'   family name). `""` uses the system default.
#' @param fontface One of `"plain"`, `"bold"`, `"italic"`, `"bold.italic"`.
#' @param fontsize Font size in points.
#' @param cex Multiplier applied to `fontsize`.
#' @param features OpenType features as a named vector of four-character tags
#'   (e.g. `c(tnum = 1)`), matching [vl_gpar()]'s `features`. Measurement must
#'   use the same features as drawing, or reserved space will not match.
#' @param unit Output unit: one of `"in"`, `"pt"`, `"mm"`, `"cm"`.
#' @return A numeric vector (one per `label`) of widths/heights in `unit`.
#' @examples
#' vl_strwidth(c("short", "a longer label"), fontsize = 14)
#' @export
vl_strwidth <- function(
  label,
  family = "",
  fontface = "plain",
  fontsize = 12,
  cex = 1,
  unit = "in",
  features = NULL
) {
  .text_metric(label, family, fontface, fontsize, cex, unit, "width", features)
}

#' @rdname vl_strwidth
#' @export
vl_strheight <- function(
  label,
  family = "",
  fontface = "plain",
  fontsize = 12,
  cex = 1,
  unit = "in",
  features = NULL
) {
  .text_metric(label, family, fontface, fontsize, cex, unit, "height", features)
}

# Shared width/height measurement (vectorised over `label`); `which` is the
# `shape_text` metric column ("width"/"height"). `res = 72` => points.
.text_metric <- function(
  label,
  family,
  fontface,
  fontsize,
  cex,
  unit,
  which,
  features = NULL
) {
  unit <- match.arg(unit, c("in", "pt", "mm", "cm"))
  # Rich md() labels are measured through the same composition path the renderer
  # draws (`.md_extent_pt`), so reserved layout space matches drawn glyphs. A
  # single label or a list of them is accepted; family/fontface/fontsize give the
  # base style the label's runs are relative to.
  if (.is_md_labelish(label)) {
    labs <- if (S7::S7_inherits(label, vellum_label)) list(label) else label
    col <- if (which == "width") 1L else 2L
    pt <- vapply(
      labs,
      function(l) {
        .md_extent_pt(l, family, fontface, fontsize * cex, features)[col]
      },
      numeric(1)
    )
    return(.pt_to_unit(pt, unit))
  }
  label <- as.character(label)
  if (length(label) == 0L) {
    return(numeric(0))
  }
  face <- .rs_face(fontface)
  # Measurement must use the same features as drawing, or a `grobwidth`-sized
  # track reserves the wrong space for the glyphs that actually get drawn.
  pt <- textshaping::shape_text(
    label,
    family = family,
    italic = face$italic,
    weight = face$weight,
    size = fontsize * cex,
    res = 72,
    features = .as_font_feature(features)
  )$metrics[[which]]
  .pt_to_unit(pt, unit)
}

# TRUE for a single md() label or a non-empty list of them.
.is_md_labelish <- function(x) {
  S7::S7_inherits(x, vellum_label) ||
    (is.list(x) &&
      length(x) &&
      all(vapply(x, S7::S7_inherits, logical(1), vellum_label)))
}

# Convert points to an output unit (one of "pt"/"in"/"mm"/"cm").
.pt_to_unit <- function(pt, unit) {
  switch(
    unit,
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
.shape_cached <- function(uniq, family, italic, weight, size, features = NULL) {
  # The feature set is part of the font's identity for shaping: the same string
  # in the same font shapes to different glyphs under `smcp` or `onum`, so it
  # must be in the key, or a second grob would be served the first one's glyphs.
  keys <- paste(
    family,
    italic,
    weight,
    size,
    .feature_key(features),
    uniq,
    sep = ""
  )
  if (.shape_cache$.n > .SHAPE_CACHE_CAP) {
    # memory backstop: drop everything
    rm(
      list = setdiff(ls(.shape_cache, all.names = TRUE), ".n"),
      envir = .shape_cache
    )
    .shape_cache$.n <- 0L
  }
  hit <- vapply(
    keys,
    exists,
    logical(1),
    envir = .shape_cache,
    inherits = FALSE
  )
  miss <- which(!hit)
  if (length(miss)) {
    sh <- textshaping::shape_text(
      uniq[miss],
      family = family,
      italic = italic,
      weight = weight,
      size = size,
      features = .as_font_feature(features)
    )
    g <- sh$shape
    by_id <- split(seq_len(nrow(g)), g$metric_id) # glyph rows per shaped string
    for (j in seq_along(miss)) {
      r <- by_id[[as.character(j)]]
      entry <- if (is.null(r)) {
        list(w = sh$metrics$width[j], h = sh$metrics$height[j], n = 0L)
      } else {
        list(
          w = sh$metrics$width[j],
          h = sh$metrics$height[j],
          n = length(r),
          index = as.integer(g$index[r]),
          xoff = as.numeric(g$x_offset[r]),
          yoff = as.numeric(g$y_offset[r]),
          fsize = as.numeric(g$font_size[r]),
          fpath = as.character(g$font_path[r]),
          findex = as.integer(g$font_index[r])
        )
      }
      assign(keys[miss[j]], entry, envir = .shape_cache)
    }
    .shape_cache$.n <- .shape_cache$.n + length(miss)
  }
  lapply(keys, get, envir = .shape_cache, inherits = FALSE)
}

# A stable string for a feature set, for the shape-cache key. NULL and an empty
# set collapse to "" so a scene that asks for no features keys exactly as before.
.feature_key <- function(features) {
  if (is.null(features) || length(features) == 0L) {
    return("")
  }
  if (inherits(features, "font_feature")) {
    features <- unlist(features[[2]])
  }
  o <- order(names(features))
  paste0(names(features)[o], "=", features[o], collapse = ",")
}

# Convert our named-integer feature form to what `textshaping::shape_text()`
# wants. A `font_feature()` object the caller built themselves passes through.
.as_font_feature <- function(features) {
  if (is.null(features) || length(features) == 0L) {
    return(systemfonts::font_feature())
  }
  if (inherits(features, "font_feature")) {
    return(features)
  }
  do.call(systemfonts::font_feature, as.list(features))
}

# Line spacing as a multiple of the font size (baseline-to-baseline), matching
# grid's default `lineheight`.
.LINEHEIGHT <- 1.2

# Split a label into its lines, matching `strsplit()`'s handling of a trailing or
# lone separator (a label is never empty here — callers filter those out).
.label_lines <- function(label) {
  lines <- strsplit(label, "\n", fixed = TRUE)[[1]]
  if (!length(lines)) "" else lines
}

# Stack already-shaped lines baseline-to-baseline, centred symmetrically about
# y = 0, into one flat glyph set (points). `sh` is a list of `.shape_cached`
# entries, one per line, in order.
#
# `align` shifts each line horizontally within the block. The default "left"
# adds nothing at all, so an ordinary multi-line label is byte-for-byte what it
# was before alignment existed. `box_w`, when given, is the block width to align
# against (the wrap width), so a short line in a fixed-width box still aligns to
# the box edge rather than to the longest line.
.stack_lines <- function(sh, size, align = "left", box_w = NULL) {
  nl <- length(sh)
  lead <- size * .LINEHEIGHT
  idx <- integer(0)
  xo <- numeric(0)
  yo <- numeric(0)
  fs <- numeric(0)
  fp <- character(0)
  fi <- integer(0)
  wmax <- 0
  hmax <- 0
  for (i in seq_len(nl)) {
    wmax <- max(wmax, sh[[i]]$w)
    hmax <- max(hmax, sh[[i]]$h)
  }
  block <- box_w %||% wmax
  for (i in seq_len(nl)) {
    e <- sh[[i]]
    # Line i's baseline, measured UP from the block's LAST line -- not centred
    # about zero.
    #
    # The renderer places a glyph at `ay - (gy - vjust*h)`, where `h` is the
    # whole block's height. That term already accounts for the block's extent,
    # so pre-centring the per-line offsets about zero double-counts it: the top
    # line lands exactly where a single centred line would and every other line
    # stacks below it, hanging an `nl`-line block (nl-1)*lead/2 too low. Anchored
    # at the last line instead, all three vertical justifications come out right
    # -- bottom puts the final baseline where a single bottom-justified line
    # would sit, top does the same for the first, and centre puts the block's
    # mean baseline where a single centred line's is.
    off <- ((nl - 1) - (i - 1)) * lead
    dx <- switch(
      align,
      centre = ,
      center = (block - e$w) / 2,
      right = block - e$w,
      0
    )
    if (e$n > 0L) {
      idx <- c(idx, e$index)
      xo <- c(xo, e$xoff + dx)
      yo <- c(yo, e$yoff + off)
      fs <- c(fs, e$fsize)
      fp <- c(fp, e$fpath)
      fi <- c(fi, e$findex)
    }
  }
  list(
    w = block,
    h = (nl - 1) * lead + hmax,
    n = length(idx),
    index = idx,
    xoff = xo,
    yoff = yo,
    fsize = fs,
    fpath = fp,
    findex = fi
  )
}

# --- width-constrained text -------------------------------------------------

# Break `label` into lines no wider than `width` points, honouring any hard
# "\n" already in it.
#
# The break decision is made on the *shaped* width of each candidate line, not
# on a sum of per-word advances, so kerning and any active OpenType feature are
# accounted for and a line can never render wider than it measured. Candidates
# for one output line are shaped in a single batched call; they are short,
# repeat heavily across a figure, and go through the same cache as everything
# else.
#
# A word that cannot fit on a line of its own is placed anyway rather than being
# broken: hyphenation needs a dictionary, and a silently clipped label is worse
# than one that overflows visibly.
.wrap_label <- function(
  label,
  width,
  family,
  italic,
  weight,
  size,
  features = NULL
) {
  out <- character(0)
  for (para in .label_lines(label)) {
    words <- strsplit(para, "[ \t]+")[[1]]
    words <- words[nzchar(words)]
    if (!length(words)) {
      out <- c(out, "") # a blank line is a paragraph break, and must survive
      next
    }
    i <- 1L
    while (i <= length(words)) {
      j <- seq.int(i, length(words))
      cand <- vapply(
        j,
        function(k) paste(words[i:k], collapse = " "),
        character(1)
      )
      w <- vapply(
        .shape_cached(cand, family, italic, weight, size, features),
        `[[`,
        double(1),
        "w"
      )
      # Widths grow with each added word, so the fitting candidates are a prefix.
      ok <- which(w <= width)
      take <- if (length(ok)) max(ok) else 1L
      out <- c(out, cand[take])
      i <- i + take
    }
  }
  out
}

# Justify one line to exactly `width` by distributing the slack between its
# words. Words are shaped individually and re-placed, which drops kerning across
# the space -- there is essentially none, and the alternative is guessing which
# glyphs are spaces in an already-shaped run.
.justify_line <- function(
  line,
  width,
  family,
  italic,
  weight,
  size,
  features = NULL
) {
  words <- strsplit(line, " ", fixed = TRUE)[[1]]
  words <- words[nzchar(words)]
  if (length(words) < 2L) {
    return(NULL) # nothing to stretch; caller keeps the plain line
  }
  e <- .shape_cached(words, family, italic, weight, size, features)
  ww <- vapply(e, `[[`, double(1), "w")
  gap <- (width - sum(ww)) / (length(words) - 1)
  if (gap < 0) {
    return(NULL) # already over-full; stretching would only make it worse
  }
  at <- cumsum(c(0, ww[-length(ww)] + gap))
  keep <- vapply(e, `[[`, integer(1), "n") > 0L
  list(
    w = width,
    h = max(vapply(e, `[[`, double(1), "h")),
    n = sum(vapply(e[keep], `[[`, integer(1), "n")),
    index = unlist(lapply(e[keep], `[[`, "index"), use.names = FALSE),
    xoff = unlist(
      Map(function(g, d) g$xoff + d, e[keep], at[keep]),
      use.names = FALSE
    ),
    yoff = unlist(lapply(e[keep], `[[`, "yoff"), use.names = FALSE),
    fsize = unlist(lapply(e[keep], `[[`, "fsize"), use.names = FALSE),
    fpath = unlist(lapply(e[keep], `[[`, "fpath"), use.names = FALSE),
    findex = unlist(lapply(e[keep], `[[`, "findex"), use.names = FALSE)
  )
}

# Compose one label wrapped to `width` points. Returns a `.shape_cached`-shaped
# entry whose `w` is the box width, so justification against the anchor treats
# the block as a box of the requested width rather than as ragged lines.
.compose_wrapped <- function(
  label,
  width,
  align,
  family,
  italic,
  weight,
  size,
  features = NULL
) {
  lines <- .wrap_label(label, width, family, italic, weight, size, features)
  sh <- .shape_cached(lines, family, italic, weight, size, features)
  if (identical(align, "justify")) {
    # The last line of each paragraph stays ragged, as in any typesetter: a
    # two-word final line stretched to full width is the classic ugly artifact.
    last <- c(which(!nzchar(lines)) - 1L, length(lines))
    for (i in seq_along(lines)) {
      if (i %in% last) {
        next
      }
      j <- .justify_line(
        lines[i],
        width,
        family,
        italic,
        weight,
        size,
        features
      )
      if (!is.null(j)) sh[[i]] <- j
    }
    align <- "left" # words are already positioned absolutely
  }
  # `lines` rides along so the caller can send the backend the label it actually
  # drew (see `.draw_text_batch`).
  c(.stack_lines(sh, size, align = align, box_w = width), list(lines = lines))
}

# Largest font size in [`min`, `size`] at which `label` wrapped to `width` still
# fits `width` x `height` points. Bisection on a continuous size to 0.1 pt: the
# wrap depends on the size, so each probe re-wraps.
.fit_size <- function(
  label,
  width,
  height,
  align,
  family,
  italic,
  weight,
  size,
  min_size,
  features = NULL
) {
  fits <- function(s) {
    e <- .compose_wrapped(
      label,
      width,
      align,
      family,
      italic,
      weight,
      s,
      features
    )
    e$w <= width + 1e-6 && (is.null(height) || e$h <= height + 1e-6)
  }
  if (fits(size)) {
    return(size)
  }
  lo <- min_size
  hi <- size
  while (hi - lo > 0.1) {
    mid <- (lo + hi) / 2
    if (fits(mid)) lo <- mid else hi <- mid
  }
  lo
}

# Compose one (possibly multi-line) plain label into a single flat glyph set.
# A single-line label delegates straight to the cache, so it is byte-for-byte
# identical to the pre-multi-line path. Returns the same shape as a
# `.shape_cached` entry (w/h/n + glyph arrays), in points.
#
# Prefer `.compose_plain_batch()` when composing many labels: this one shapes a
# single label per call, which defeats `.shape_cached()`'s miss-batching.
.compose_plain <- function(
  label,
  family,
  italic,
  weight,
  size,
  features = NULL
) {
  if (!grepl("\n", label, fixed = TRUE)) {
    return(.shape_cached(label, family, italic, weight, size, features)[[1]])
  }
  .stack_lines(
    .shape_cached(.label_lines(label), family, italic, weight, size, features),
    size
  )
}

# Compose MANY plain labels, shaping every distinct line across ALL of them in a
# single `.shape_cached()` call.
#
# This is the batching PERF-1 introduced and commit e6d4d19 (multi-line text)
# inadvertently gave back: composing label-by-label sends one string per call to
# `.shape_cached()`, so its "shape the misses together" path never fires and every
# distinct label re-resolves its font through `systemfonts`. At 5000 distinct
# labels that cost ~4x (1.57 s vs 0.39 s) and made font resolution 56% of a cold
# render. Multi-line support is kept — the lines are simply pooled with every
# other label's before shaping, then re-stacked per label.
#
# Returns a list aligned with `labels`, each element a `.shape_cached`-shaped entry.
.compose_plain_batch <- function(
  labels,
  family,
  italic,
  weight,
  size,
  features = NULL
) {
  multi <- grepl("\n", labels, fixed = TRUE)
  # Common case: nothing to split, so each label is its own only line and the
  # cache call is exactly the pre-e6d4d19 one.
  if (!any(multi)) {
    return(.shape_cached(labels, family, italic, weight, size, features))
  }
  parts <- as.list(labels)
  parts[multi] <- lapply(labels[multi], .label_lines)
  # One shaping call for the union of every line of every label. Lines are looked
  # up by POSITION, not by name: a blank line ("a\n\nb") is the empty string, and
  # `x[""]` never matches a name, so a named lookup would silently drop it.
  need <- unique(unlist(parts, use.names = FALSE))
  sh <- .shape_cached(need, family, italic, weight, size, features)
  at <- lapply(parts, match, table = need)
  out <- vector("list", length(labels))
  out[!multi] <- sh[unlist(at[!multi], use.names = FALSE)]
  out[multi] <- lapply(at[multi], function(i) .stack_lines(sh[i], size))
  out
}

# Shape and emit many labels that share one font (a vectorised text grob). Unique
# strings are shaped once via the cache (PERF-7), then one FFI call builds one
# text node per label from the flat glyph arrays. `x`/`y` are unit vectors
# recycled to the label count; `rot` is per-label; the rest are shared. Labels may
# contain "\n" (multi-line); each unique label is composed once.
.draw_text_batch <- function(
  scene,
  labels,
  x,
  y,
  hjust,
  vjust,
  rot,
  family,
  fontface,
  fontsize,
  col,
  alpha,
  halo = NULL,
  features = NULL,
  wrap = NULL,
  keys = NULL
) {
  labels <- as.character(labels)
  n <- length(labels)
  keep <- !is.na(labels) & nzchar(labels)
  if (!any(keep)) {
    return(invisible())
  }
  scale <- scene$dpi() / 72
  face <- .rs_face(fontface)
  uniq <- unique(labels[keep])
  if (is.null(wrap)) {
    shaped <- .compose_plain_batch(
      uniq,
      family,
      face$italic,
      face$weight,
      fontsize,
      features
    )
  } else {
    # Auto-fit picks ONE size for the whole grob -- the smallest any label needs.
    # Per-label sizes would render fine (glyph sizes are per glyph) but a row of
    # labels at four different sizes is a defect, not a feature.
    if (!is.null(wrap$fit)) {
      fontsize <- min(vapply(
        uniq,
        .fit_size,
        double(1),
        width = wrap$width,
        height = wrap$height,
        align = wrap$align,
        family = family,
        italic = face$italic,
        weight = face$weight,
        size = fontsize,
        min_size = wrap$fit,
        features = features,
        USE.NAMES = FALSE
      ))
    }
    shaped <- lapply(
      uniq,
      .compose_wrapped,
      width = wrap$width,
      align = wrap$align,
      family = family,
      italic = face$italic,
      weight = face$weight,
      size = fontsize,
      features = features
    )
    # The label travelling to the backend is the *wrapped* one, with the chosen
    # breaks as newlines. It is metadata -- PDF `ToUnicode`, SVG native `<text>`
    # -- and it has to describe what was actually drawn: the SVG backend splits
    # it per line and matches the parts against the glyph baselines, so the
    # unwrapped string would not line up and would cost native text.
    wrapped_lab <- vapply(
      shaped,
      function(e) paste(e$lines, collapse = "\n"),
      character(1)
    )
    labels[keep] <- wrapped_lab[match(labels[keep], uniq)]
    uniq <- wrapped_lab
  }
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
    cx$value[drawn],
    cy$value[drawn],
    cx$code[drawn],
    cx$offset[drawn],
    cy$code[drawn],
    cy$offset[drawn],
    rot[drawn],
    hjust,
    vjust,
    vapply(ent, `[[`, double(1), "w") * scale,
    vapply(ent, `[[`, double(1), "h") * scale,
    as.integer(nper),
    unlist(lapply(ent, `[[`, "index"), use.names = FALSE),
    unlist(lapply(ent, `[[`, "xoff"), use.names = FALSE) * scale,
    unlist(lapply(ent, `[[`, "yoff"), use.names = FALSE) * scale,
    unlist(lapply(ent, `[[`, "fsize"), use.names = FALSE) * scale,
    unlist(lapply(ent, `[[`, "fpath"), use.names = FALSE),
    unlist(lapply(ent, `[[`, "findex"), use.names = FALSE),
    labels[drawn],
    family,
    fontface,
    fontsize,
    .rs_col_inh(col),
    .rs_num_inh(alpha),
    .rs_col_inh(halo$col),
    (halo$width %||% 0) * scale,
    if (is.null(keys)) character(0) else keys[drawn]
  )
  invisible()
}

# Shape one label and hand it to the backend with a baseline path. The glyph
# arrays are exactly what `.draw_text_batch()` builds for a single label; only
# the anchor differs, so on-path text inherits halos, features and every
# backend without any of them knowing about it.
#
# A newline is meaningless on a curve (there is no second baseline to stack
# onto), so the label is flattened to one line.
.draw_text_path <- function(
  scene,
  label,
  x,
  y,
  hjust,
  vjust,
  offset,
  family,
  fontface,
  fontsize,
  col,
  alpha,
  halo = NULL,
  features = NULL
) {
  label <- gsub("[\r\n]+", " ", as.character(label))
  if (is.na(label) || !nzchar(label)) {
    return(invisible())
  }
  scale <- scene$dpi() / 72
  face <- .rs_face(fontface)
  e <- .shape_cached(
    label,
    family,
    face$italic,
    face$weight,
    fontsize,
    features
  )[[1]]
  if (e$n == 0L) {
    return(invisible())
  }
  cx <- .coord(x, "npc", length(x))
  cy <- .coord(y, "npc", length(y))
  scene$text_path(
    cx$value,
    cy$value,
    cx$code,
    cx$offset,
    cy$code,
    cy$offset,
    offset,
    hjust,
    vjust,
    e$w * scale,
    e$h * scale,
    e$index,
    e$xoff * scale,
    e$yoff * scale,
    e$fsize * scale,
    e$fpath,
    e$findex,
    label,
    family,
    fontface,
    fontsize,
    .rs_col_inh(col),
    .rs_num_inh(alpha),
    .rs_col_inh(halo$col),
    (halo$width %||% 0) * scale
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
  if (is.na(text)) {
    text <- ""
  }
  lines <- strsplit(text, "\n", fixed = TRUE)[[1]]
  if (!length(lines)) {
    lines <- ""
  }
  runs <- list()
  for (i in seq_along(lines)) {
    if (i > 1L) {
      runs[[length(runs) + 1L]] <- list(brk = TRUE)
    }
    runs <- c(runs, .md_parse(lines[i]))
  }
  plain <- paste0(
    vapply(runs, function(r) r$text %||% "\n", character(1)),
    collapse = ""
  )
  vellum_md_label(runs = runs, text = plain)
}

# A run-style descriptor. `size` is a multiplier on the base fontsize; `dy` is a
# baseline shift in base-em (fraction of the base fontsize, +up); `col` is NA to
# inherit the base colour.
.md_style <- function(
  bold = FALSE,
  italic = FALSE,
  size = 1,
  dy = 0,
  col = NA_character_
) {
  list(bold = bold, italic = italic, size = size, dy = dy, col = col)
}
.md_run <- function(text, st) {
  list(
    text = text,
    bold = st$bold,
    italic = st$italic,
    size = st$size,
    dy = st$dy,
    col = st$col
  )
}

# First index >= `from` where the fixed substring `delim` occurs, or NA.
.md_find <- function(text, delim, from) {
  n <- nchar(text)
  if (from > n) {
    return(NA_integer_)
  }
  hay <- substr(text, from, n)
  p <- regexpr(delim, hay, fixed = TRUE)
  if (p[1] < 0) NA_integer_ else from + p[1] - 1L
}

# A `[inner]{colour}` span starting at `[` at index `i`. Returns list(inner, col,
# end) where `end` is the index of the closing `}`, or NULL if not a colour span.
.md_find_colspan <- function(text, i) {
  br <- .md_find(text, "]{", i + 1L)
  if (is.na(br)) {
    return(NULL)
  }
  brace <- .md_find(text, "}", br + 2L)
  if (is.na(brace)) {
    return(NULL)
  }
  list(
    inner = substr(text, i + 1L, br - 1L),
    col = substr(text, br + 2L, brace - 1L),
    end = brace
  )
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
    if (nzchar(buf)) {
      runs[[length(runs) + 1L]] <<- .md_run(buf, st)
    }
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
        runs <- c(
          runs,
          .md_parse_region(inner, utils::modifyList(st, list(bold = TRUE)))
        )
        i <- close + 2L
        next
      }
    }
    if (one == "*" || one == "_") {
      close <- .md_find(text, one, i + 1L)
      if (!is.na(close)) {
        emit()
        inner <- substr(text, i + 1L, close - 1L)
        runs <- c(
          runs,
          .md_parse_region(inner, utils::modifyList(st, list(italic = TRUE)))
        )
        i <- close + 1L
        next
      }
    }
    if (one == "^") {
      close <- .md_find(text, "^", i + 1L)
      if (!is.na(close)) {
        emit()
        inner <- substr(text, i + 1L, close - 1L)
        sub <- utils::modifyList(
          st,
          list(size = st$size * 0.7, dy = st$dy + 0.35 * st$size)
        )
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
        sub <- utils::modifyList(
          st,
          list(size = st$size * 0.7, dy = st$dy - 0.15 * st$size)
        )
        runs <- c(runs, .md_parse_region(inner, sub))
        i <- close + 1L
        next
      }
    }
    if (one == "[") {
      cs <- .md_find_colspan(text, i)
      if (!is.null(cs)) {
        emit()
        runs <- c(
          runs,
          .md_parse_region(cs$inner, utils::modifyList(st, list(col = cs$col)))
        )
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
  if (b && it) {
    "bold.italic"
  } else if (b) {
    "bold"
  } else if (it) {
    "italic"
  } else {
    "plain"
  }
}

# Shape every run of a markdown label and concatenate into one advance-accumulated
# glyph set. Returns flat per-glyph arrays (index/xoff/yoff/fsize/fpath/findex), a
# per-glyph colour character vector, and the composed extent (w, h). All lengths
# are in points (the caller scales by dpi/72 for drawing, or converts for
# measurement). `base_col` resolves a run's inherited colour.
.md_compose <- function(
  label,
  family,
  fontface,
  fontsize,
  base_col,
  features = NULL
) {
  # Split the flat run list into lines at the `brk` markers (single-line labels
  # yield one line and a zero line-offset, so their output is unchanged).
  lines <- list()
  cur <- list()
  for (run in label@runs) {
    if (isTRUE(run$brk)) {
      lines[[length(lines) + 1L]] <- cur
      cur <- list()
    } else {
      cur[[length(cur) + 1L]] <- run
    }
  }
  lines[[length(lines) + 1L]] <- cur
  nl <- length(lines)
  lead <- fontsize * .LINEHEIGHT

  gid <- integer(0)
  gx <- numeric(0)
  gy <- numeric(0)
  gsize <- numeric(0)
  gpath <- character(0)
  gface <- integer(0)
  cols <- character(0)
  wmax <- 0
  top <- 0
  bot <- 0
  for (li in seq_len(nl)) {
    loff <- ((nl - 1) / 2 - (li - 1)) * lead # line baseline, centred about 0 (+up)
    adv <- 0
    for (run in lines[[li]]) {
      if (!nzchar(run$text)) {
        next
      }
      face <- .rs_face(.md_run_face(fontface, run))
      rsize <- fontsize * run$size
      sh <- .shape_cached(
        run$text,
        family,
        face$italic,
        face$weight,
        rsize,
        features
      )[[1]]
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
  list(
    gid = gid,
    gx = gx,
    gy = gy,
    gsize = gsize,
    gpath = gpath,
    gface = gface,
    cols = cols,
    w = wmax,
    h = top - bot
  )
}

# Draw rich (markdown) labels at the `x`/`y` positions. `label` is either a single
# `vellum_md_label` (composed once and drawn at every position, the legend/title
# case) or a list of them (one per position, recycled — the per-datum mark_text
# case). Distinct labels are composed once (deduped by plain text). Mirrors
# `.draw_text_batch` but calls `texts_rich` with the per-glyph colour stream.
.draw_richtext_batch <- function(
  scene,
  label,
  x,
  y,
  hjust,
  vjust,
  rot,
  family,
  fontface,
  fontsize,
  col,
  alpha,
  halo = NULL,
  features = NULL,
  keys = NULL
) {
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
    if (m == 0L) {
      return(invisible())
    }
    label[((drawn - 1L) %% m) + 1L]
  }
  keytxt <- vapply(labs, function(l) l@text, character(1))
  uk <- unique(keytxt)
  comp <- lapply(uk, function(t) {
    .md_compose(
      labs[[match(t, keytxt)]],
      family,
      fontface,
      fontsize,
      base_col,
      features
    )
  })
  names(comp) <- uk
  # Concatenate the per-position glyph sets into the flat FFI arrays; `gp$alpha`
  # folds into the per-glyph RGBA alpha channel (mirrors hexagon_grob's fill).
  gid <- integer(0)
  gx <- numeric(0)
  gy <- numeric(0)
  gsize <- numeric(0)
  gpath <- character(0)
  gface <- integer(0)
  gcol <- integer(0)
  nper <- integer(np)
  w <- numeric(np)
  h <- numeric(np)
  for (j in seq_len(np)) {
    g <- comp[[keytxt[j]]]
    ng <- length(g$gid)
    nper[j] <- ng
    w[j] <- g$w * scale
    h[j] <- g$h * scale
    if (ng > 0L) {
      gid <- c(gid, g$gid)
      gx <- c(gx, g$gx * scale)
      gy <- c(gy, g$gy * scale)
      gsize <- c(gsize, g$gsize * scale)
      gpath <- c(gpath, g$gpath)
      gface <- c(gface, g$gface)
      m <- grDevices::col2rgb(g$cols, alpha = TRUE)
      if (!is.null(alpha) && !is.na(alpha)) {
        m[4L, ] <- round(m[4L, ] * alpha)
      }
      gcol <- c(gcol, as.integer(m))
    }
  }
  scene$texts_rich(
    cx$value[drawn],
    cy$value[drawn],
    cx$code[drawn],
    cx$offset[drawn],
    cy$code[drawn],
    cy$offset[drawn],
    rot[drawn],
    hjust,
    vjust,
    w,
    h,
    as.integer(nper),
    gid,
    gx,
    gy,
    gsize,
    gpath,
    gface,
    gcol,
    keytxt,
    family,
    fontface,
    fontsize,
    .rs_col_inh(base_col),
    .rs_num_inh(alpha),
    .rs_col_inh(halo$col),
    (halo$width %||% 0) * scale,
    if (is.null(keys)) character(0) else keys[drawn]
  )
  invisible()
}

# Composed extent of a rich label in points (w, h) — measurement path. Shares
# `.md_compose` with the draw path so reserved layout space matches drawn text.
.md_extent_pt <- function(label, family, fontface, fontsize, features = NULL) {
  g <- .md_compose(label, family, fontface, fontsize, "black", features)
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
    v <- list(
      italic = grepl("italic|oblique", f),
      weight = if (grepl("bold", f)) "bold" else "normal"
    )
    .face_cache[[f]] <- v
  }
  v
}
