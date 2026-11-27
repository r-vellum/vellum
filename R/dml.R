# PowerPoint (DrawingML) output: the scene as editable Office shapes.

# The DrawingML fragment for a scene: one `<p:grpSp>` whose child coordinates
# are absolute slide EMU, offset by `left`/`top` (inches). Rasters are written
# as PNG files into `media_dir` and referenced by path, which is what officer
# expects of `ph_with(<xml_document>)` (it copies them into the package when the
# deck is saved). `media_dir = ""` leaves placeholder names instead, for tests.
# Returns `list(xml, files, warnings)`; warnings are not emitted here.
.dml_fragment <- function(
  scene,
  left = 0,
  top = 0,
  text = c("native", "outline"),
  media_dir = ""
) {
  text <- match.arg(text)
  scene <- as_vellum_scene(scene)
  s <- .scene_to_backend(scene)
  s$render_dml(
    as.numeric(left) * 914400,
    as.numeric(top) * 914400,
    identical(text, "outline"),
    media_dir
  )
}

#' Editable PowerPoint output via officer
#'
#' Put a scene on a PowerPoint slide as **editable shapes**: every mark is a
#' DrawingML freeform (or a preset rectangle or ellipse), every label a real
#' text box whose words can be retyped, and each panel a named group that can
#' be ungrouped, recoloured or moved in PowerPoint.
#'
#' With the officer package installed, a scene goes straight into
#' [officer::ph_with()]; `as_dml()` wraps anything else [as_vellum_scene()]
#' can compile (a vellumplot plot, say) so it can go there too:
#'
#' ```r
#' doc <- officer::read_pptx()
#' doc <- officer::add_slide(doc, layout = "Title and Content")
#' doc <- officer::ph_with(doc, scene, location = officer::ph_location_type("body"))
#' doc <- officer::ph_with(doc, as_dml(plot), location = officer::ph_location_fullsize())
#' print(doc, target = "deck.pptx")
#' ```
#'
#' To write a deck without officer, give [render()] a `.pptx` path (one slide)
#' or use [pptx_pages()] (several).
#'
#' @section Size:
#' By default the scene is laid out again at the size of the location
#' (`resize = TRUE`), exactly as [render()] would at that size, so text keeps
#' its point size and nothing is stretched. `resize = FALSE` keeps the scene's
#' own size, anchored at the location's top-left corner.
#'
#' @section Text and fonts:
#' Each label names the font vellum measured it with. PowerPoint uses that font
#' when the machine opening the deck has it and substitutes another when it does
#' not; the box is anchored so a wider substitute grows away from the label's
#' anchor (right-aligned tick labels stay right-aligned) rather than drifting.
#' Fonts are not embedded. `text = "outline"` writes glyph outlines instead:
#' identical everywhere, but no longer editable as text. An `md()` label is
#' one text run per styled span (bold, italic, colour; a superscript or
#' subscript as a raised or lowered run). `tex()` labels, `md()` labels with
#' inline math, halos and text set on a path are always outlines, as in SVG.
#'
#' @section What cannot be expressed:
#' DrawingML has no clipping, blend modes, masks or group opacity.
#'
#' * Clipped geometry is cut in advance: fills to the visible area, strokes
#'   along their centreline (a round or square cap at a cut end reaches half a
#'   line width past the edge), pictures cropped. Native text cannot be cut: a
#'   label crossing a clip edge is drawn whole, with a warning (outlined text is
#'   cut exactly).
#' * Group opacity over shapes that do not overlap is folded into their
#'   colours, which is exactly what the group composites to.
#' * Blend modes, masks, blur and shadow effects, and group opacity over
#'   overlapping shapes are drawn as a picture of the region they cover, with
#'   a warning: the slide looks right, but that part is not editable.
#' * Linear and radial gradients are native gradient fills, patterns a tiled
#'   picture fill. A radial gradient's focal point moves to its centre (with a
#'   warning). Rasters become pictures.
#'
#' LibreOffice is not a reliable preview for these: it drops gradients with
#' translucent stops and the transparency of tiled pattern pictures, and places
#' an off-centre radial gradient differently.
#'
#' For charts whose *data* stays editable in PowerPoint, see the mschart
#' package; this writes the drawing, not the data.
#'
#' @param x A [vl_scene()], or anything with an [as_vellum_scene()] method.
#' @param text `"native"` (default) for editable text runs, `"outline"` for
#'   glyph outlines.
#' @param resize Re-solve the layout at the location's size (default `TRUE`).
#' @return `as_dml()`: a `vellum_dml` object, for [officer::ph_with()].
#' @seealso [render()] and [pptx_pages()] to write a `.pptx` without officer.
#' @examplesIf requireNamespace("officer", quietly = TRUE)
#' sc <- vl_scene(6, 4, dpi = 96, bg = "white") |>
#'   draw(rect_grob(width = 0.5, height = 0.5, gp = vl_gpar(fill = "tomato"))) |>
#'   draw(text_grob("editable", gp = vl_gpar(fontsize = 24)))
#' doc <- officer::read_pptx()
#' doc <- officer::add_slide(doc, layout = "Blank", master = "Office Theme")
#' doc <- officer::ph_with(doc, as_dml(sc),
#'   location = officer::ph_location(left = 1, top = 1, width = 6, height = 4)
#' )
#' f <- tempfile(fileext = ".pptx")
#' print(doc, target = f)
#' @export
as_dml <- function(x, text = c("native", "outline"), resize = TRUE) {
  text <- match.arg(text)
  if (!is.logical(resize) || length(resize) != 1L || is.na(resize)) {
    cli::cli_abort("{.arg resize} must be {.code TRUE} or {.code FALSE}.")
  }
  structure(
    list(scene = as_vellum_scene(x), text = text, resize = resize),
    class = "vellum_dml"
  )
}

#' @export
print.vellum_dml <- function(x, ...) {
  s <- x$scene
  cat(sprintf(
    "<vellum_dml> %g x %g in scene, text = \"%s\"%s\n",
    .to_inches(s@width),
    .to_inches(s@height, "height"),
    x$text,
    if (x$resize) ", resized to its location" else ""
  ))
  invisible(x)
}

# officer::ph_with() methods, registered when officer loads (delayed S3
# registration, so officer stays in Suggests). S7 objects dispatch S3 on their
# class vector, whose first entry is "vellum::vellum_scene".
#' @rawNamespace S3method(officer::ph_with, vellum_dml, .ph_with_dml)
#' @rawNamespace S3method(officer::ph_with, "vellum::vellum_scene", .ph_with_scene)
NULL

.ph_with_dml <- function(x, value, location, ...) {
  .ph_with_vellum(x, value$scene, location, value$text, value$resize)
}

.ph_with_scene <- function(
  x,
  value,
  location,
  text = c("native", "outline"),
  resize = TRUE,
  ...
) {
  .ph_with_vellum(x, value, location, match.arg(text), resize)
}

.ph_with_vellum <- function(x, scene, location, text, resize) {
  if (!requireNamespace("xml2", quietly = TRUE)) {
    cli::cli_abort("PowerPoint output needs the {.pkg xml2} package.")
  }
  loc <- officer::fortify_location(location, doc = x)
  if (isTRUE(resize)) {
    scene <- S7::set_props(
      scene,
      width = vl_unit(loc$width, "in"),
      height = vl_unit(loc$height, "in")
    )
  }
  fr <- .dml_fragment(
    scene,
    left = loc$left,
    top = loc$top,
    text = text,
    media_dir = .dml_media_dir()
  )
  .emit_degrade_warnings(fr$warnings)
  officer::ph_with(x, xml2::as_xml_document(fr$xml), location = location)
}

# Where rasters wait until officer copies them into the deck. officer reads the
# files when the deck is *saved* (`print()`), which can be long after
# `ph_with()` returns, so they live for the session (in its temp directory)
# rather than being cleaned up on exit. Files are content-named, so adding the
# same image twice reuses one file.
.dml_media_dir <- function() {
  d <- file.path(tempdir(), "vellum-dml-media")
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  d
}

#' Write several scenes as the slides of one PowerPoint file
#'
#' [render()] with a `.pptx` path writes one slide; this writes a deck, one
#' slide per scene, without officer. The shapes are the same editable ones
#' [as_dml()] puts on an officer slide.
#'
#' A presentation has a single slide size, so the deck takes the largest
#' scene's width and height (at least 1 inch, at most 56) and centres any
#' smaller scene on its slide. The file is byte-for-byte reproducible: it
#' carries no timestamps, user name or software version.
#'
#' @inheritParams pdf_pages
#' @param text `"native"` (default) for editable text, `"outline"` for glyph
#'   outlines.
#' @param title The presentation's title property. `NULL` (default) uses the
#'   first scene's `title`.
#' @return `path` invisibly, or a raw vector when `path` is `NULL`.
#' @seealso [render()] for a single slide, [as_dml()] for officer decks.
#' @examples
#' slides <- lapply(c("tomato", "steelblue"), function(col) {
#'   vl_scene(6, 4, dpi = 96, bg = "white") |>
#'     draw(rect_grob(width = 0.5, height = 0.5, gp = vl_gpar(fill = col))) |>
#'     draw(text_grob(col, gp = vl_gpar(fontsize = 24)))
#' })
#' f <- tempfile(fileext = ".pptx")
#' pptx_pages(slides, f)
#' file.size(f) > 0
#' @export
pptx_pages <- function(
  scenes,
  path = NULL,
  text = c("native", "outline"),
  title = NULL
) {
  text <- match.arg(text)
  .check_string(title, "title")
  if (!is.list(scenes) || !length(scenes)) {
    cli::cli_abort("{.arg scenes} must be a non-empty list of scenes.")
  }
  backends <- lapply(scenes, function(s) .scene_to_backend(as_vellum_scene(s)))
  r <- .pptx_bytes(backends, text, title)
  .emit_degrade_warnings(r$warnings)
  if (is.null(path)) {
    return(r$bytes)
  }
  writeBin(r$bytes, path)
  invisible(path)
}

# Compiled scenes as .pptx bytes: list(warnings, bytes). An empty or missing
# title falls back to the first scene's.
.pptx_bytes <- function(backends, text, title = NULL) {
  if (!is.character(title) || length(title) != 1L || is.na(title)) {
    title <- ""
  }
  rs_pptx_pages(backends, identical(text, "outline"), title)
}

# Write compiled scenes as a .pptx; returns the degradation warnings.
.write_pptx <- function(backends, path, text, title = NULL) {
  r <- .pptx_bytes(backends, text, title)
  writeBin(r$bytes, path)
  r$warnings
}
