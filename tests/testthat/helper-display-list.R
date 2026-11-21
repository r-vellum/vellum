# Reference decoder for `scene_display_list()` (VR-14), used only by the tests.
# vellumwidget's JS decoder does the same in the browser.

# One encoded column -> an R vector.
.dl_col <- function(col) {
  n <- col$n
  if (!is.null(col$const)) {
    return(rep(col$const, n))
  }
  if (!is.null(col$seq)) {
    return(col$seq[1] + col$seq[2] * (seq_len(n) - 1))
  }
  if (!is.null(col$rle)) {
    return(rep(col$rle$values, col$rle$lengths))
  }
  raw <- jsonlite::base64_dec(col$data)
  if (!is.null(col$step)) {
    # A quantised geometry column (VR-18): lo + u * step.
    w <- switch(col$type, u8 = 1L, u16 = 2L, u24 = 3L)
    b <- matrix(as.integer(raw), nrow = w)
    u <- colSums(b * 256^(seq_len(w) - 1))
    return(col$lo + u * col$step)
  }
  switch(
    col$type,
    f32 = readBin(raw, "double", n, size = 4, endian = "little"),
    u8 = as.integer(raw),
    u16 = readBin(
      raw,
      "integer",
      n,
      size = 2,
      signed = FALSE,
      endian = "little"
    ),
    u32 = {
      v <- readBin(raw, "integer", n, size = 4, endian = "little")
      as.numeric(v) + ifelse(v < 0, 2^32, 0)
    }
  )
}

# The whole list -> one data frame row per record, with geometry: `cx, cy, r,
# shape` for points, `x, y, w, h` for rects, and `runs` (a list of 2-column
# matrices) plus `closed`/`evenodd` for paths.
# `given`: the `keys` argument the list was built with (VR-22), if any.
.dl_decode <- function(dl, given = NULL) {
  rec <- lapply(dl$record, .dl_col)
  keys <- if (is.list(dl$keys)) as.character(.dl_col(dl$keys)) else dl$keys
  if (!is.null(dl$keys_given)) {
    stopifnot(length(given) == dl$keys_given)
    keys <- c(given, keys)
  }
  n <- dl$n
  out <- data.frame(
    key = keys[rec$key + 1],
    kind = c("point", "rect", "path")[rec$kind + 1],
    flags = rec$flags,
    clip = rec$clip,
    panel = ifelse(rec$panel > 0, dl$panels[pmax(rec$panel, 1)], NA_character_),
    fill = dl$paints$fill[rec$paint + 1],
    stroke = dl$paints$stroke[rec$paint + 1],
    stroke_width = dl$paints$stroke_width[rec$paint + 1],
    dash = dl$paints$dash[rec$paint + 1],
    stringsAsFactors = FALSE
  )
  num <- rep(NA_real_, n)
  out[c("cx", "cy", "r", "shape", "x", "y", "w", "h")] <- list(num)
  out$closed <- rep(NA, n)
  out$evenodd <- rep(NA, n)
  out$runs <- vector("list", n)
  pt <- lapply(dl$point, .dl_col)
  i <- which(out$kind == "point")
  out$cx[i] <- pt$cx
  out$cy[i] <- pt$cy
  out$r[i] <- pt$r
  out$shape[i] <- pt$shape
  rc <- lapply(dl$rect, .dl_col)
  i <- which(out$kind == "rect")
  out$x[i] <- rc$x
  out$y[i] <- rc$y
  out$w[i] <- rc$w
  out$h[i] <- rc$h
  pa <- lapply(dl$path, .dl_col)
  i <- which(out$kind == "path")
  xy <- matrix(pa$xy, ncol = 2, byrow = TRUE)
  for (j in seq_along(i)) {
    runs <- seq(pa$path_offset[j] + 1, pa$path_offset[j + 1])
    out$runs[[i[j]]] <- lapply(runs, function(r) {
      xy[seq(pa$run_offset[r] + 1, pa$run_offset[r + 1]), , drop = FALSE]
    })
  }
  out$closed[i] <- pa$closed == 1
  out$evenodd[i] <- pa$evenodd == 1
  out
}
