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
#' A list with `format = "vellum-display-list"`, `version` (1 or 2), the page
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
#'   integer. With the `keys` argument, only the keys it lacks (see below).
#' * `keys_given`: only with the `keys` argument, its length. `record$key` then
#'   indexes `c(<the keys argument>, keys)`: a key found in the argument is its
#'   first position there, and the rest follow in first-use order. A client
#'   that already has the keys (vellumwidget's element table) ships them once.
#' * `panels`: the names of the panels marks are drawn in.
#'
#' Every numeric column except those in `paints` and `clips` is a list
#' `list(type, n, ...)`. `type` is `"f32"`, `"u8"`, `"u16"` or `"u32"`, and `n`
#' is the length. The values come as exactly one of `data` (base64,
#' little-endian, typed), `const` (every value equal), `seq = c(start, step)`
#' (an arithmetic sequence) or `rle = list(values, lengths)` (runs of equal
#' values, used when there are few).
#'
#' @section Version 2:
#' `version = 2` lists three more cases exactly, which version 1 flags, and
#' adds the tables they need. A reader that knows only version 1 must not be
#' handed a version-2 list: their records are no longer flagged.
#'
#' * Gradient fills: linear and radial gradients with `pad` extension.
#'   `paints$fill_gradient` is the 1-based row of `gradients` (0 = none; then
#'   `fill` is `NA`). `gradients` has `type` (`"linear"` or `"radial"`), the
#'   geometry in the shape's local px (linear: `x1, y1` to `x2, y2`; radial:
#'   the focal circle `x1, y1, r1` at offset 0 to the outer circle `x2, y2, r2`
#'   at offset 1), the transform placing it in device px as `a`, `b`, `c`,
#'   `d`, `e`, `f` (the SVG / canvas `matrix(a, b, c, d, e, f)`), and its stops:
#'   gradient *i*'s are rows `stop_offset[i] + 1` to `stop_offset[i + 1]` of
#'   `stop_pos` (0 to 1) and `stop_color` (`"#rrggbbaa"`).
#' * Path clips: a clip by a path or a rotated rectangle. `clips` gains
#'   `path_start` and `path_n`: a clip's paths are shapes `path_start + 1` to
#'   `path_start + path_n` of `clip_paths` (0 = the rect alone), and a record is
#'   clipped to the rect and to each of them. Its rect is then also bounded by
#'   the paths' boxes. `clip_paths` is a path table like `path`: `xy`,
#'   `run_offset`, `path_offset` (one shape per entry) and `evenodd`.
#' * Opacity groups: a group whose only effect is an opacity below 1.
#'   `record$group` is the 1-based row of `groups` (the innermost such group
#'   the record is drawn in, 0 = none). `groups` has `alpha` and `parent`
#'   (1-based, 0 = top level). A client draws a group's records into their own
#'   layer and composites it at `alpha`.
#'
#' Masks, blend modes, blur and shadow effects, hatches, patterns, repeating or
#' reflecting gradients and gradient strokes stay flagged.
#'
#' * Flagged runs (VW-30): `record$run` is the run of flagged marks a record
#'   belongs to (1-based, 0 = none) and `runs` their count. A run is a stretch
#'   of flagged marks in paint order that no exactly drawn mark interrupts;
#'   every record of a node with a flagged record, and of an opacity group
#'   holding one, is in it. `scene_png(layer = "keyed_flagged", run = k)`
#'   draws run `k`, so a client can draw the exact records itself and
#'   composite each run's raster where the run starts.
#' * Blend modes in runs (VW-32): `run_blend` gives, per run, how its raster
#'   composites onto what is beneath it: `"normal"`, or a CSS `mix-blend-mode`
#'   keyword (`"multiply"`, `"screen"`, ...) when the run is exactly the marks
#'   of one group with that blend mode drawn onto the page, directly or
#'   inside groups with no opacity, mask, blend or effect, which isolate
#'   nothing (a *blend root*; a run ends where the blend root changes).
#'   Rendered on its own, such a run's raster is its marks unblended, and
#'   compositing it with that mode reproduces the blend. A blend nested inside
#'   a mask, an effect or an opacity group happens within that group's raster,
#'   so its run is `"normal"`. `""` would mark a run that cannot be composited
#'   from its raster; current lists have none.
#'
#' @section What stage 1 does not reproduce:
#' Such marks are still listed, so they can be hit-tested, but `flags` marks
#' them and a client should fall back to its approximate path for them:
#' `1` a gradient, pattern or hatch paint (the paint's colour is `NA`); `2` a
#' clip that is not an axis-aligned rectangle (the clip is not listed); `4` a
#' mark inside a group with opacity, blend mode, mask or effect; `8` a text
#' label (the geometry is its box); `16` pick-only: a keyed mark that paints
#' nothing (an invisible hover target such as a `fill = NA` rect, circle,
#' marker or polygon). Its geometry is listed and its paint has `fill` and
#' `stroke` `NA`, so a client hit-tests it but draws nothing; `32` inside a
#' group with a blend mode (with `4`): the mark mixes with what is painted
#' beneath it, so its run's raster reproduces it only when composited with
#' the run's `run_blend` mode. Images do not appear at all.
#'
#' @param scene A [vl_scene()], or anything with an [as_vellum_scene()] method.
#' @param what Which marks to list. Only `"keyed"` for now.
#' @param panels `NULL` (the default) to list keyed marks wherever they are, or
#'   a character vector of panel names to list only those whose innermost named
#'   panel (`scene_model()$elements$panel`) is one of them, the same rule as
#'   `scene_png(layer = "keyed", panels = )`. vellumwidget passes its data
#'   panels, which leaves out a legend's keyed swatches.
#' @param version The format version, `1` (the default) or `2` (see the
#'   *Version 2* section).
#' @param keys `NULL` (the default), or a character vector of keys for
#'   `record$key` to index, so the list need not repeat them (VR-22). Keys
#'   it lacks are listed in `keys` as usual, after it; `NA` matches nothing.
#' @return The display list, as described in the *Format* section.
#' @keywords internal
#' @export
scene_display_list <- function(
  scene,
  what = "keyed",
  panels = NULL,
  version = 1L,
  keys = NULL
) {
  what <- match.arg(what)
  if (!is.numeric(version) || length(version) != 1L || !version %in% c(1, 2)) {
    cli::cli_abort("{.arg version} must be 1 or 2.")
  }
  if (!is.null(panels) && (!is.character(panels) || anyNA(panels))) {
    cli::cli_abort(
      "{.arg panels} must be {.code NULL} or a character vector of panel names."
    )
  }
  if (!is.null(keys) && !is.character(keys)) {
    cli::cli_abort("{.arg keys} must be {.code NULL} or a character vector.")
  }
  scene <- as_vellum_scene(scene)
  s <- .scene_to_backend(scene)
  s$display_list_raw(panels, as.integer(version), keys)
}
