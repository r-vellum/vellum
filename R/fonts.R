# Phase 13 -- reproducible font resolution (I4).
#
# `DESIGN.md` §1 claims identical pixels on every OS and in CI. Everything vellum
# controls delivers that: layout, shaping and rasterisation are deterministic.
# What is *not* deterministic is the step before them -- turning a family name
# into a file. "sans" is Helvetica here, DejaVu Sans there, Arial somewhere else,
# and the pixels differ for a reason the claim does not cover.
#
# This is a correctness gap dressed as a feature, so the tools here are about
# making the gap visible and checkable rather than about pretending it away.

#' Which fonts a scene actually used
#'
#' Reports the font **files** a scene's text resolved to, read off the shaped
#' glyphs rather than re-resolved from family names — so it says what was used,
#' not what would be picked if asked again.
#'
#' @param scene A [vl_scene()] (or anything with an [as_vellum_scene()] method).
#' @return A data frame with `path`, `index` (the face within a font collection),
#'   `glyphs` (how many glyphs came from that face), `file` (the basename) and
#'   `exists`. Zero rows if the scene has no text.
#' @seealso [font_pin()] to record this and check it later.
#' @examples
#' s <- vl_scene(4, 2) |> draw(text_grob("hello", gp = vl_gpar(fontfamily = "serif")))
#' scene_fonts(s)
#' @export
scene_fonts <- function(scene) {
  scene <- as_vellum_scene(scene)
  ft <- as.data.frame(.scene_to_backend(scene)$font_table(), stringsAsFactors = FALSE)
  if (!nrow(ft)) {
    return(data.frame(path = character(0), index = integer(0), glyphs = integer(0),
                      file = character(0), exists = logical(0)))
  }
  ft$file <- basename(ft$path)
  ft$exists <- file.exists(ft$path)
  ft[order(-ft$glyphs, ft$path), , drop = FALSE]
}

#' Pin a scene's fonts, and check them later
#'
#' `font_pin()` records the fonts a scene resolved to. `font_check()` re-resolves
#' the same scene and reports what changed — a different file, a missing file, or
#' a family that now resolves somewhere else.
#'
#' @section Why this exists:
#' vellum's determinism claim is that the same scene renders to the same pixels
#' on every OS and in CI. Layout, shaping and rasterisation deliver that. Font
#' *resolution* does not, and cannot: `"sans"` is a different file on macOS,
#' Linux and Windows, and even the same family name can resolve to a different
#' version of the same font.
#'
#' So the claim holds only if the fonts are the same, and until now nothing
#' checked. A pin turns "identical pixels" from an assumption into an assertion:
#' record the manifest next to a reference image, and `font_check()` will say
#' whether a pixel difference is your change or the machine's font stack.
#'
#' @section What this does not do:
#' It does not *make* fonts reproducible — it cannot install a font, and vellum
#' deliberately resolves fonts through \pkg{systemfonts} so that it agrees with
#' the rest of the R graphics ecosystem. Bundling font files with a scene would
#' break that agreement and raises licensing questions vellum should not answer
#' for you. The honest tool is a check, not a substitute.
#'
#' The reliable fix, when you need it, is to register the exact file you mean
#' with `systemfonts::register_font()` and pin *that*.
#'
#' @param scene A [vl_scene()] (or anything with an [as_vellum_scene()] method).
#' @param pin A manifest from `font_pin()`.
#' @param on_mismatch `"warn"` (default), `"error"`, or `"ignore"` — what
#'   `font_check()` should do when the fonts have moved.
#' @return `font_pin()`: a `vellum_font_pin` object. `font_check()`: invisibly, a
#'   data frame of differences (zero rows when everything matches), with a
#'   `status` of `"changed"`, `"missing"` or `"new"`.
#' @examples
#' s <- vl_scene(4, 2) |> draw(text_grob("hello"))
#' pin <- font_pin(s)
#' pin
#' # In a test, next to a reference image:
#' nrow(font_check(s, pin)) == 0
#' @export
font_pin <- function(scene) {
  f <- scene_fonts(scene)
  structure(
    list(fonts = f[, c("path", "index", "glyphs")], created = Sys.time()),
    class = "vellum_font_pin"
  )
}

#' @rdname font_pin
#' @export
font_check <- function(scene, pin, on_mismatch = c("warn", "error", "ignore")) {
  on_mismatch <- match.arg(on_mismatch)
  if (!inherits(pin, "vellum_font_pin")) {
    cli::cli_abort("{.arg pin} must come from {.fn font_pin}.")
  }
  now <- scene_fonts(scene)
  was <- pin$fonts
  key <- function(d) paste(d$path, d$index, sep = "#")
  # Compare by face identity, not by count: the same face used for a different
  # number of glyphs is the same font, and is not what this is looking for.
  gone <- was[!(key(was) %in% key(now)), , drop = FALSE]
  new <- now[!(key(now) %in% key(was)), , drop = FALSE]
  out <- rbind(
    if (nrow(gone)) {
      data.frame(status = ifelse(file.exists(gone$path), "changed", "missing"),
                 path = gone$path, index = gone$index, stringsAsFactors = FALSE)
    },
    if (nrow(new)) {
      data.frame(status = "new", path = new$path, index = new$index,
                 stringsAsFactors = FALSE)
    }
  )
  if (is.null(out)) {
    out <- data.frame(status = character(0), path = character(0), index = integer(0))
  }
  if (nrow(out) && !identical(on_mismatch, "ignore")) {
    bullets <- stats::setNames(
      sprintf("%s: %s", out$status, out$path),
      rep("*", nrow(out))
    )
    msg <- c(
      "This scene's fonts do not match the pin.",
      bullets,
      i = "Rendered pixels will differ from the machine the pin was made on."
    )
    if (identical(on_mismatch, "error")) cli::cli_abort(msg) else cli::cli_warn(msg)
  }
  invisible(out)
}

#' @export
print.vellum_font_pin <- function(x, ...) {
  n <- nrow(x$fonts)
  cli::cli_text("{.cls vellum_font_pin}: {n} font face{?s}")
  if (n) {
    for (i in seq_len(n)) {
      cli::cli_bullets(c("*" = "{basename(x$fonts$path[i])} (face {x$fonts$index[i]}, {x$fonts$glyphs[i]} glyph{?s})"))
    }
  }
  invisible(x)
}
