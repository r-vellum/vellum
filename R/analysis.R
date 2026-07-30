#' @include api.R
NULL

#' Where a scene spends its render time
#'
#' Attributes render cost to the individual marks that caused it, and splits the
#' three phases a render goes through: **build** (constructing the R value),
#' **compile** (the R→Rust replay, including text shaping), and **raster**
#' (drawing). Turns "this plot is slow" into a specific answer.
#'
#' Read the phase split first. Compile time is R-side — S7 property validation,
#' grob construction, unit records — and on scenes with many small grobs it
#' routinely dominates, in which case no amount of backend tuning will help. The
#' per-node table only accounts for raster time.
#'
#' Timing is armed only for this call, so ordinary renders pay nothing for it.
#'
#' @param scene A [vl_scene()], or anything with an [as_vellum_scene()] method.
#' @param reps Number of render repetitions to time; the median is reported.
#' @return A data frame ordered by cost, with columns `kind`, `name`, `n`
#'   (elements), `seconds` and `pct` (share of raster time). Rows are aggregated
#'   per mark — a vectorised `text_grob()` of 200 labels compiles to 200 nodes
#'   but reports as one row — so the table reads as "which of my marks is
#'   expensive". The phase split is attached as the `"phases"` attribute and
#'   shown when printed.
#' @seealso [vl_lint()], [scene_stats()]
#' @examples
#' set.seed(1)
#' s <- vl_scene(4, 3) |>
#'   draw(points_grob(runif(2000), runif(2000))) |>
#'   draw(text_grob("title", y = 0.95, gp = vl_gpar(fontsize = 16)))
#' profile_render(s)
#' @export
profile_render <- function(scene, reps = 3) {
  scene <- as_vellum_scene(scene)
  if (length(reps) != 1L || is.na(reps) || reps < 1) {
    cli::cli_abort("{.arg reps} must be a positive whole number.")
  }
  f <- tempfile(fileext = ".png")
  on.exit(unlink(f), add = TRUE)

  # Phase split. `.scene_to_backend()` is build+compile; the render call is
  # raster. The cache is cleared each rep so every phase is actually paid.
  build <- compile <- raster <- numeric(reps)
  for (i in seq_len(reps)) {
    vl_clear_render_cache()
    build[i] <- system.time(root <- .materialize(scene))[["elapsed"]]
    vl_clear_render_cache()
    compile[i] <- system.time(s <- .scene_to_backend(scene))[["elapsed"]]
    raster[i] <- system.time(s$render_png(f))[["elapsed"]]
  }

  # Per-node raster times, on a fresh backend with profiling armed.
  vl_clear_render_cache()
  s <- .scene_to_backend(scene)
  idx <- as.data.frame(s$node_index(), stringsAsFactors = FALSE)
  rs_set_profiling(TRUE)
  on.exit(rs_set_profiling(FALSE), add = TRUE)
  invisible(rs_take_node_times()) # discard anything left from an earlier call
  times <- numeric(0)
  for (i in seq_len(reps)) {
    s$render_png(f)
    t <- rs_take_node_times()
    if (!length(times)) times <- numeric(nrow(idx))
    if (length(t)) times[seq_along(t)] <- times[seq_along(t)] + t
    # The pixmap memo would make later reps free, so drop it.
    s <- .scene_to_backend(scene)
    vl_clear_render_cache()
  }
  rs_set_profiling(FALSE)
  if (!length(times)) times <- numeric(nrow(idx))
  times <- times / reps

  keep <- nzchar(idx$kind)
  raw <- data.frame(
    kind = idx$kind[keep], name = idx$name[keep], n = idx$n[keep],
    seconds = times[keep], stringsAsFactors = FALSE
  )
  # Aggregate by mark, not by node. A vectorised `text_grob()` of 200 labels
  # compiles to 200 nodes, and 200 rows of ~0 s is noise, not a profile -- what
  # the caller wants is "the labels cost this much, together".
  key <- paste(raw$kind, raw$name, sep = "\r")
  out <- data.frame(
    kind = tapply(raw$kind, key, `[`, 1L),
    name = tapply(raw$name, key, `[`, 1L),
    n = as.integer(tapply(raw$n, key, sum)),
    seconds = as.numeric(tapply(raw$seconds, key, sum)),
    stringsAsFactors = FALSE
  )
  total <- sum(out$seconds)
  out$pct <- if (total > 0) 100 * out$seconds / total else 0
  out <- out[order(-out$seconds), , drop = FALSE]
  row.names(out) <- NULL
  attr(out, "phases") <- c(
    build = stats::median(build),
    compile = stats::median(compile),
    raster = stats::median(raster)
  )
  structure(out, class = c("vellum_profile", class(out)))
}

#' @export
print.vellum_profile <- function(x, ...) {
  ph <- attr(x, "phases")
  cli::cli_text("{.strong Phases} (median of the timed reps):")
  cli::cli_bullets(c(
    "*" = sprintf("build    %7.3f s  (constructing the R value)", ph[["build"]]),
    "*" = sprintf("compile  %7.3f s  (R -> Rust replay, incl. text shaping)", ph[["compile"]]),
    "*" = sprintf("raster   %7.3f s  (drawing)", ph[["raster"]])
  ))
  if (ph[["compile"]] > ph[["raster"]]) {
    cli::cli_alert_info(
      "Compile dominates: the cost is R-side (grob construction, S7 validation), not drawing."
    )
  }
  n <- min(10L, nrow(x))
  if (n) {
    cli::cli_text("")
    cli::cli_text("{.strong Slowest marks} (raster time):")
    top <- x[seq_len(n), , drop = FALSE]
    cli::cli_bullets(stats::setNames(
      sprintf("%-10s %-14s %7d elem  %7.4f s  %4.1f%%",
              top$kind, ifelse(nzchar(top$name), top$name, "-"), top$n, top$seconds, top$pct),
      rep("*", n)
    ))
  }
  invisible(x)
}

#' Ink and overplotting statistics for a scene
#'
#' How much of the canvas a scene actually covers, and how hard it is working to
#' do it. `overplot` is the honest signal for "should this be
#' [datashade()]-ed?": a count of marks says nothing about whether they overlap,
#' whereas thirty thousand well-separated points are fine and eight thousand
#' piled on top of each other are not.
#'
#' @param scene A [vl_scene()], or anything with an [as_vellum_scene()] method.
#' @return A one-row data frame:
#'   \describe{
#'     \item{`elements`}{total drawn elements.}
#'     \item{`ink`}{fraction of canvas pixels differing from the background.}
#'     \item{`colours`}{distinct colours in the rendered image.}
#'     \item{`overplot`}{summed element-box area divided by inked area — an
#'       estimate of how many times an average inked pixel was drawn over. `1`
#'       means no overlap. It is computed from bounding boxes, so it
#'       over-estimates for non-rectangular marks (a circle fills ~79% of its
#'       box); treat it as an index, not a measurement. Marks the element table
#'       does not cover — text, and unkeyed lines/polygons/paths — contribute to
#'       `ink` but not to `overplot`.}
#'   }
#' @seealso [vl_lint()], [profile_render()], [datashade()]
#' @examples
#' set.seed(1)
#' sparse <- vl_scene(4, 3) |> draw(points_grob(runif(200), runif(200)))
#' dense <- vl_scene(4, 3) |> draw(points_grob(rnorm(20000, 0.5, 0.05),
#'                                             rnorm(20000, 0.5, 0.05)))
#' rbind(sparse = scene_stats(sparse), dense = scene_stats(dense))
#' @export
scene_stats <- function(scene) {
  scene <- as_vellum_scene(scene)
  s <- .scene_to_backend(scene)
  d <- s$dim()
  # Per-ELEMENT boxes, not per-node: a node's box is the union over its batch, so
  # a dense cluster would look like one small rectangle and overplotting would
  # come out backwards.
  el <- as.data.frame(s$element_table(), stringsAsFactors = FALSE)
  px <- s$rgba()
  npix <- d[1] * d[2]
  # Pack RGBA into one integer per pixel: cheaper to compare and to count
  # distinct values than four parallel vectors.
  i <- seq_len(npix)
  packed <- px[(i - 1) * 4 + 1] * 2^24 + px[(i - 1) * 4 + 2] * 2^16 +
    px[(i - 1) * 4 + 3] * 2^8 + px[(i - 1) * 4 + 4]
  bg <- .rs_col(scene@bg) %||% c(255L, 255L, 255L, 255L)
  bg_packed <- bg[1] * 2^24 + bg[2] * 2^16 + bg[3] * 2^8 + bg[4]
  inked <- sum(packed != bg_packed)
  area <- sum(pmax(0, el$x1 - el$x0) * pmax(0, el$y1 - el$y0))
  data.frame(
    elements = nrow(el),
    ink = inked / npix,
    colours = length(unique(packed)),
    overplot = if (inked > 0) area / inked else 0,
    row.names = NULL
  )
}
