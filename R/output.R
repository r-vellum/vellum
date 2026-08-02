# Phase 14 -- output reach: animated SVG, multi-page PDF, parallel batch render.

#' Write several scenes as the pages of one PDF
#'
#' `render()` writes one page. This writes a document: a report's worth of
#' figures, one facet per page, an animation as a contact sheet.
#'
#' Pages may differ in size — each carries its own page box — so a landscape
#' figure can sit between two portrait ones.
#'
#' Tagging follows each page's own metadata, exactly as it does for a
#' single-page render (see `vignette("accessible-output")`): the pages are drawn
#' by the same code, so a document cannot drift from a single-page file.
#'
#' @param scenes A list of scenes (each a [vl_scene()] or anything with an
#'   [as_vellum_scene()] method).
#' @param path Output file. `NULL` returns the bytes instead.
#' @return `path` invisibly, or a raw vector when `path` is `NULL`.
#' @seealso [render()] for a single page.
#' @examples
#' pages <- lapply(c("tomato", "steelblue", "seagreen"), function(col) {
#'   vl_scene(4, 3, dpi = 96, bg = "white") |>
#'     draw(circle_grob(r = 0.3, gp = vl_gpar(fill = col)))
#' })
#' f <- tempfile(fileext = ".pdf")
#' pdf_pages(pages, f)
#' file.size(f) > 0
#' @export
pdf_pages <- function(scenes, path = NULL) {
  if (!is.list(scenes) || !length(scenes)) {
    cli::cli_abort("{.arg scenes} must be a non-empty list of scenes.")
  }
  backends <- lapply(scenes, function(s) .scene_to_backend(as_vellum_scene(s)))
  if (is.null(path)) {
    r <- rs_pdf_pages_raw(backends)
    .emit_degrade_warnings(r$warnings)
    return(as.raw(r$bytes))
  }
  .emit_degrade_warnings(rs_pdf_pages(backends, path))
  invisible(path)
}

#' Render many scenes in parallel
#'
#' Renders a list of independent scenes across cores. This is
#' embarrassingly parallel — one whole scene per worker, nothing shared — which
#' is why it exists while *tiling a single raster* across threads does not:
#' that needs synchronised access to one pixmap and is declined in
#' `PERFORMANCE.md`.
#'
#' The saving is real when the scenes are substantial and there are several of
#' them. For a handful of small figures the process/thread overhead dominates and
#' a plain `lapply(scenes, render)` is as fast; this reports enough to tell.
#'
#' @param scenes A named or unnamed list of scenes.
#' @param paths Output paths, one per scene. The format of each comes from its
#'   extension, exactly as in [render()]. When `scenes` is named and `paths` is a
#'   single directory, files are named after the list.
#' @param workers Number of parallel workers. Defaults to one per available core,
#'   capped at the number of scenes.
#' @param ... Passed to [render()] for every scene.
#' @return The paths written, invisibly.
#' @seealso [render()], [pdf_pages()]
#' @examples
#' scenes <- list(
#'   a = vl_scene(3, 2, dpi = 96) |> draw(circle_grob(gp = vl_gpar(fill = "tomato"))),
#'   b = vl_scene(3, 2, dpi = 96) |> draw(rect_grob(gp = vl_gpar(fill = "steelblue")))
#' )
#' render_all(scenes, file.path(tempdir(), c("a.png", "b.png")))
#' @export
render_all <- function(scenes, paths, workers = NULL, ...) {
  if (!is.list(scenes) || !length(scenes)) {
    cli::cli_abort("{.arg scenes} must be a non-empty list of scenes.")
  }
  # A single directory plus named scenes is the common case for "a report's
  # worth of figures", and spelling out the paths for it is busywork.
  if (length(paths) == 1L && length(scenes) > 1L && dir.exists(paths)) {
    nm <- names(scenes)
    if (is.null(nm) || !all(nzchar(nm))) {
      cli::cli_abort(c(
        "{.arg paths} is a directory, so {.arg scenes} must be named.",
        i = "Names become file names; otherwise give one path per scene."
      ))
    }
    paths <- file.path(paths, paste0(nm, ".png"))
  }
  if (length(paths) != length(scenes)) {
    cli::cli_abort(
      "{.arg paths} must have one entry per scene ({length(scenes)})."
    )
  }
  n <- length(scenes)
  workers <- as.integer(workers %||% min(n, .cores()))
  # Below two workers there is nothing to parallelise, and the setup cost is
  # pure loss -- so do not pay it.
  if (workers < 2L || n < 2L) {
    for (i in seq_len(n)) {
      render(as_vellum_scene(scenes[[i]]), paths[[i]], ...)
    }
    return(invisible(paths))
  }
  if (!requireNamespace("parallel", quietly = TRUE)) {
    for (i in seq_len(n)) {
      render(as_vellum_scene(scenes[[i]]), paths[[i]], ...)
    }
    return(invisible(paths))
  }
  # Fork where it is available (cheap: no re-loading the package, no copying the
  # scenes), otherwise fall back to sequential. A socket cluster would have to
  # serialise every scene to the workers, which for the big scenes that make
  # this worth doing costs more than it saves.
  if (.Platform$OS.type == "unix") {
    parallel::mclapply(
      seq_len(n),
      function(i) {
        render(as_vellum_scene(scenes[[i]]), paths[[i]], ...)
      },
      mc.cores = workers
    )
  } else {
    for (i in seq_len(n)) {
      render(as_vellum_scene(scenes[[i]]), paths[[i]], ...)
    }
  }
  invisible(paths)
}

# Available cores, conservatively.
#
# Three things to respect, in order:
#
#  * `_R_CHECK_LIMIT_CORES_`, which `R CMD check` sets. `parallel::mclapply()`
#    *errors* if more than two processes are spawned under it, so a package that
#    ignores this makes `R CMD check` fail for anyone using it -- and on CRAN.
#  * `options(mc.cores)`, the user's explicit answer to this question.
#  * `detectCores(logical = FALSE)` otherwise, since hyperthreads do not help a
#    render and over-subscribing is a slowdown.
.cores <- function() {
  chk <- Sys.getenv("_R_CHECK_LIMIT_CORES_", "")
  if (nzchar(chk) && !identical(tolower(chk), "false")) {
    return(2L)
  }
  opt <- getOption("mc.cores")
  if (!is.null(opt) && is.finite(opt) && opt >= 1) {
    return(as.integer(opt))
  }
  n <- tryCatch(parallel::detectCores(logical = FALSE), error = function(e) 1L)
  if (!is.finite(n) || n < 1L) 1L else as.integer(n)
}
