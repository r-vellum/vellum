#' Marks-only display list (internal, for vellumwidget)
#'
#' Resolves every keyed mark in a scene to device-pixel geometry, a paint and
#' its key, packed as compact columnar tables. vellumwidget ships this to the
#' browser to draw and hit-test big plots (F-5 stage 1).
#'
#' **This is a private vellum to vellumwidget payload, not a public format.** Its
#' fields and encodings may change in any release, in step with vellumwidget.
#' Do not build on it.
#'
#' @section Format:
#' A list with `format = "vellum-display-list"`, `version` (1), the page
#' `width` and `height` in device px, the record count `n`, and:
#'
#' * `record`: one row per keyed primitive, in paint order. `kind` (0 point,
#'   1 rect, 2 path), `paint` (0-based row of `paints`), `key` (0-based index
#'   into `keys`), `flags` (bitfield, see below), `clip` (1-based row of
#'   `clips`, 0 = unclipped) and `panel` (1-based into `panels`: the innermost
#'   named panel the mark is drawn in, as in `scene_model()$elements$panel`;
#'   0 = none). The *i*-th record of a kind is the *i*-th row of
#'   that kind's table.
#' * `point`: `cx`, `cy`, `r` (device px) and `shape` (0 circle, else the
#'   [points_grob()] marker code: 1 square, 2 triangle, 3 diamond, 4 plus,
#'   5 cross, 6 triangle down, 7 star).
#' * `rect`: axis-aligned rectangles, top-left `x`, `y` and size `w`, `h`.
#' * `path`: polygons and polylines. `xy` holds interleaved vertices,
#'   `run_offset` the start of each run in vertices (one more entry than runs),
#'   `path_offset` the start of each path in runs (one more than paths),
#'   `closed` (1 = closed rings, 0 = open polylines) and `evenodd` (fill rule).
#'   Curves are flattened.
#' * `paints`: a data-frame-like list with `fill` and `stroke` (`"#rrggbbaa"`
#'   or `NA` for none), `stroke_width` (device px), `dash` (comma-separated
#'   device px, or `NA` for solid), `linecap` and `linejoin`.
#' * `clips`: rectangles `x0`, `y0`, `x1`, `y1` (device px).
#' * `keys`: the distinct keys in first-use order, as a character vector, or as
#'   an integer column (see below) when every key is a plain non-negative
#'   integer.
#' * `panels`: the names of the panels marks are drawn in.
#'
#' Every numeric column except those in `paints` and `clips` is a list
#' `list(type, n, ...)`. `type` is `"f32"`, `"u8"`, `"u16"` or `"u32"`, and `n`
#' is the length. The values come as exactly one of `data` (base64,
#' little-endian, typed), `const` (every value equal), `seq = c(start, step)`
#' (an arithmetic sequence) or `rle = list(values, lengths)` (runs of equal
#' values, used when there are few).
#'
#' @section What stage 1 does not reproduce:
#' Such marks are still listed, so they can be hit-tested, but `flags` marks
#' them and a client should fall back to its approximate path for them:
#' `1` a gradient, pattern or hatch paint (the paint's colour is `NA`); `2` a
#' clip that is not an axis-aligned rectangle (the clip is not listed); `4` a
#' mark inside a group with opacity, blend mode, mask or effect; `8` a text
#' label (the geometry is its box). Keyed marks that paint nothing (invisible
#' hover targets) and images do not appear at all.
#'
#' @param scene A [vl_scene()], or anything with an [as_vellum_scene()] method.
#' @param what Which marks to list. Only `"keyed"` for now.
#' @param panels `NULL` (the default) to list keyed marks wherever they are, or
#'   a character vector of panel names to list only those whose innermost named
#'   panel (`scene_model()$elements$panel`) is one of them, the same rule as
#'   `scene_png(layer = "keyed", panels = )`. vellumwidget passes its data
#'   panels, which leaves out a legend's keyed swatches.
#' @return The display list, as described in the *Format* section.
#' @keywords internal
#' @export
scene_display_list <- function(scene, what = "keyed", panels = NULL) {
  what <- match.arg(what)
  if (!is.null(panels) && (!is.character(panels) || anyNA(panels))) {
    cli::cli_abort(
      "{.arg panels} must be {.code NULL} or a character vector of panel names."
    )
  }
  scene <- as_vellum_scene(scene)
  s <- .scene_to_backend(scene)
  s$display_list_raw(panels)
}
