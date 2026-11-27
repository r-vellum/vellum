#' @include scene-build.R
NULL

#' @rdname vl_scene
#' @param path Output file path; the format is taken from the extension (`.png`,
#'   `.svg`, `.pdf`, or `.pptx`). A `.pptx` is a one-slide PowerPoint file of
#'   editable shapes at the scene's size (see [as_dml()] for what that means,
#'   and [pptx_pages()] for several slides); it needs no other package.
#' @param text For SVG and PowerPoint output, how text is written: `"native"`
#'   (default) emits selectable, editable text referencing system fonts,
#'   `"outline"` emits glyph outlines (pixel-faithful, identical to the
#'   raster/PDF backends, but not selectable). Ignored for PNG/PDF.
#' @param debug If `TRUE`, overlay a layout-debug skeleton on the output: each
#'   viewport region (outlined and labelled by name), its layout track boundaries,
#'   and its clip region. Built from the resolved scene with [why_size()]; useful
#'   for understanding why elements land where they do. Default `FALSE`.
#' @param scale Resolution multiplier (default `1`). `scale = 2` renders at twice
#'   the device pixels while keeping the **same physical size** — the retina /
#'   `ggsave(scaling=)` idiom. It multiplies `dpi`, so absolute units (`mm`,
#'   `pt`, `in`) cover proportionally more pixels and nothing about the layout
#'   changes; text does not get relatively bigger or smaller. Only raster output
#'   gains anything: a PDF's page size in points and an SVG's physical size are
#'   unchanged by construction.
#' @param cvd Simulate a colour-vision deficiency: `"none"` (default),
#'   `"protanopia"` (red-blind), `"deuteranopia"` (green-blind, the common one
#'   that breaks red/green encodings), `"tritanopia"` (blue-blind), or
#'   `"achromatopsia"` (total, and a fair proxy for greyscale printing). The
#'   simulation is a post-pass over the finished raster using the Machado et al.
#'   (2009) matrices applied in linear light, so it turns an accessibility check
#'   into a one-line change instead of an export-and-upload round trip. **Raster
#'   output only** — a vector format has no pixels to transform, and `render()`
#'   warns if you ask for one.
#' @return `render()`: `path`, invisibly.
#' @export
render <- function(
  scene,
  path,
  text = c("native", "outline"),
  debug = FALSE,
  scale = 1,
  cvd = "none"
) {
  text <- match.arg(text)
  scene <- .apply_scale(as_vellum_scene(scene), scale)
  ext <- tolower(tools::file_ext(path))
  on.exit(.set_cvd("none"), add = TRUE)
  .set_cvd(cvd, format = ext)
  s <- .scene_to_backend(scene, debug = debug)
  warns <- switch(
    ext,
    png = s$render_png(path),
    svg = s$render_svg(path, identical(text, "outline")),
    pdf = s$render_pdf(path),
    pptx = .write_pptx(list(s), path, text, scene@title),
    cli::cli_abort(
      "Unsupported output format {.val {ext}}; use .png, .svg, .pdf, or .pptx."
    )
  )
  .emit_degrade_warnings(warns)
  invisible(path)
}

#' Render a scene to an SVG string
#'
#' Like [render()] with an `.svg` path, but returns the SVG document as a
#' character string instead of writing a file. This is the in-memory entry point
#' for hosting a scene interactively (an htmlwidget embeds the markup directly)
#' and for tests that assert on emitted attributes such as `data-key`.
#'
#' @section Split render:
#' `layer` renders part of the scene on the same page, with the same transforms
#' and clips, so the parts overlay pixel-exactly. `"keyed"` draws only the marks
#' that carry an interactivity key (`data_id`/`key`: the elements with a non-`NA`
#' `key` in [scene_model()]) on a transparent page; `"unkeyed"` draws everything
#' else (background, gridlines, axes, legends, unkeyed annotations). Groups,
#' clips and masks around a mark stay with it. A batch of elements counts as
#' keyed when any element carries a key.
#'
#' `panels` narrows the mark layer to keyed marks whose innermost named panel
#' (the `panel` column of `scene_model()$elements`) is listed, so keyed marks
#' elsewhere (e.g. a vellumplot legend's interactive swatches, in panel
#' `"legend"`) stay with the furniture. The two layers remain exact complements.
#'
#' Compositing the `"keyed"` layer over the `"unkeyed"` one reproduces the full
#' render, except where an unkeyed node is painted *above* a keyed mark (it ends
#' up underneath), or where a keyed mark's blend mode would mix with the
#' unkeyed backdrop (it blends against transparency instead). This is the
#' raster mode of vellumwidget: SVG furniture plus a PNG of the heavy mark layer.
#'
#' `"unkeyed_below"` and `"unkeyed_above"` split `"unkeyed"` by paint order, so
#' stacking `"unkeyed_below"`, `"keyed"`, `"unkeyed_above"` (bottom to top) also
#' gets an annotation or reference line drawn after the marks right. An unkeyed
#' element is *above* when a mark (an element of the `"keyed"` layer, so
#' `panels` applies) was painted before it inside its innermost named panel; a
#' mark in a nested panel counts for every panel around it, and an element
#' outside every named panel is above when any mark precedes it. Unkeyed
#' elements interleaved between two keyed batches are therefore above, and a
#' later facet's gridlines stay below that facet's own marks. With no marks at
#' all, everything is below. `"unkeyed_above"`, like `"keyed"`, has a
#' transparent page. The two halves together are exactly `"unkeyed"`.
#'
#' `"keyed_flagged"` draws only the marks of the `"keyed"` layer that
#' [scene_display_list()] (`version = 2`, same `panels`) flags as not drawable
#' from the list: marks under a mask, a blend mode or an effect, patterned or
#' repeating-gradient fills, gradient strokes and text. A hatched fill, on
#' a point marker too, is listed as exact geometry, so it is not drawn here
#' unless something else flags it (see
#' [scene_display_list()]). Whole
#' nodes are drawn (every record of a node with one flagged record), and an
#' opacity group holding a flagged mark goes in whole. The flagged marks fall
#' into *runs*: maximal stretches in paint order not interrupted by a mark the
#' list draws exactly, numbered from 1 in the list's `record$run` (its `runs`
#' field counts them). `run = k` draws only run `k`; `NULL` draws every run. A
#' host that draws the exact marks itself can composite run `k` at its place
#' in paint order and keep the overlap order right. The page is transparent.
#' A mark under a blend mode (display-list flag `32`) is drawn too, but blends
#' against transparency here rather than against the marks beneath it.
#'
#' @inheritParams render
#' @param layer Which part of the scene to draw: `"all"` (the default), only the
#'   `"keyed"` marks, everything `"unkeyed"`, the unkeyed elements painted
#'   before (`"unkeyed_below"`) or after (`"unkeyed_above"`) the marks, or only
#'   the keyed marks the display list flags (`"keyed_flagged"`). See the
#'   *Split render* section.
#' @param panels `NULL` (the default: every keyed mark is in the mark layer), or
#'   a character vector of panel names restricting the mark layer to keyed marks
#'   inside those panels. Ignored when `layer = "all"`.
#' @param run For `layer = "keyed_flagged"`: `NULL` (the default) for every
#'   flagged mark, or a positive integer, the one run of flagged marks to draw
#'   (see the *Split render* section). Ignored for the other layers.
#' @return A length-1 character vector: the SVG document.
#' @seealso [render()], [scene_png()], [scene_model()]
#' @export
scene_svg <- function(
  scene,
  text = c("native", "outline"),
  layer = c(
    "all",
    "unkeyed",
    "keyed",
    "unkeyed_below",
    "unkeyed_above",
    "keyed_flagged"
  ),
  panels = NULL,
  run = NULL
) {
  text <- match.arg(text)
  layer <- match.arg(layer)
  panels <- .check_panels(panels)
  run <- .check_run(run)
  scene <- as_vellum_scene(scene)
  s <- .scene_to_backend(scene)
  s$render_svg_string(
    identical(text, "outline"),
    .layer_code(layer),
    panels,
    run
  )
}

# `run` as the backend's code: 0 for every run (`NULL`), else the run number.
.check_run <- function(run, call = parent.frame()) {
  if (is.null(run)) {
    return(0L)
  }
  if (
    !is.numeric(run) ||
      length(run) != 1L ||
      is.na(run) ||
      run < 1 ||
      run != round(run)
  ) {
    cli::cli_abort(
      "{.arg run} must be {.code NULL} or a single positive whole number.",
      call = call
    )
  }
  as.integer(run)
}

.check_panels <- function(panels, call = parent.frame()) {
  if (is.null(panels)) {
    return(NULL)
  }
  if (!is.character(panels) || anyNA(panels)) {
    cli::cli_abort(
      "{.arg panels} must be {.code NULL} or a character vector of panel names.",
      call = call
    )
  }
  panels
}

# R<->Rust ABI for the split render (`Layer::from_code`).
.layer_code <- function(layer) {
  match(
    layer,
    c(
      "all",
      "unkeyed",
      "keyed",
      "unkeyed_below",
      "unkeyed_above",
      "keyed_flagged"
    )
  ) -
    1L
}

#' Render a scene to PNG or PDF bytes
#'
#' Like [render()] with a `.png` / `.pdf` path, but returns the encoded document
#' as a raw vector instead of writing a file. These are the in-memory entry
#' points for a host that needs the bytes rather than a path — embedding a
#' base64 data URI in an HTML widget, serving a plot from a web API, or writing
#' to a connection — without a temp-file round-trip.
#'
#' Together with [scene_svg()] (a string) and [scene_raster()] (pixels), every
#' output format vellum supports can now be produced without touching disk.
#'
#' Backend degradation warnings (see [render()]) are surfaced here too, so a PDF
#' that could not honour a pattern or mask reports it exactly as writing a file
#' would.
#'
#' @param scene A [vl_scene()], or anything with an [as_vellum_scene()] method.
#' @return A raw vector: the encoded PNG or PDF document.
#' @seealso [render()], [scene_svg()], [scene_raster()]
#' @examples
#' s <- vl_scene(2, 2) |> draw(circle_grob(gp = vl_gpar(fill = "steelblue")))
#' png_bytes <- scene_png(s)
#' length(png_bytes)
#' rawToChar(png_bytes[2:4]) # "PNG"
#' @inheritParams render
#' @inheritParams scene_svg
#' @param layer,panels,run For `scene_png()`: which part of the scene to draw,
#'   as for [scene_svg()] (see its *Split render* section). The `"keyed"` layer
#'   has a transparent background, ready to composite over the `"unkeyed"` one.
#' @export
scene_png <- function(
  scene,
  scale = 1,
  cvd = "none",
  layer = c(
    "all",
    "unkeyed",
    "keyed",
    "unkeyed_below",
    "unkeyed_above",
    "keyed_flagged"
  ),
  panels = NULL,
  run = NULL
) {
  layer <- match.arg(layer)
  panels <- .check_panels(panels)
  run <- .check_run(run)
  .scene_bytes(
    scene,
    "png",
    scale,
    cvd,
    layer = layer,
    panels = panels,
    run = run
  )
}

#' @rdname scene_png
#' @export
scene_pdf <- function(scene) {
  .scene_bytes(scene, "pdf")
}

# Shared body for `scene_png()`/`scene_pdf()`: render to bytes and surface the
# backend's degradation warnings the same way `render()` does.
.scene_bytes <- function(
  scene,
  kind,
  scale = 1,
  cvd = "none",
  layer = "all",
  panels = NULL,
  run = 0L
) {
  scene <- .apply_scale(as_vellum_scene(scene), scale)
  on.exit(.set_cvd("none"), add = TRUE)
  .set_cvd(cvd, format = kind)
  s <- .scene_to_backend(scene)
  res <- if (identical(kind, "png")) {
    s$render_png_raw(.layer_code(layer), panels, run)
  } else {
    s$render_pdf_raw()
  }
  .emit_degrade_warnings(res$warnings)
  res$bytes
}

# Apply a resolution multiplier by scaling `dpi` only. Physical size (width and
# height, held as absolute units) is untouched, so the layout solves identically
# and every unit keeps its meaning -- the render simply lands on a finer pixel
# grid. `dpi` is part of the render-cache key, so each scale caches separately.
# Valid `cvd` values; "none" disables. Kept here so `render()`, `scene_png()` and
# the error message can't drift apart.
.CVD_KINDS <- c(
  "none",
  "protanopia",
  "deuteranopia",
  "tritanopia",
  "achromatopsia"
)

# Push the CVD mode for the coming render (a thread-local on the Rust side, like
# the glyph-bitmap mode). Warns rather than errors for a vector target: asking for
# a simulation and silently getting an unsimulated file is the bad outcome, but so
# is refusing to render at all.
.set_cvd <- function(cvd, format = NULL) {
  if (length(cvd) != 1L || is.na(cvd) || !is.character(cvd)) {
    cli::cli_abort("{.arg cvd} must be one of {.or {.val {.CVD_KINDS}}}.")
  }
  cvd <- match.arg(cvd, .CVD_KINDS)
  if (!identical(cvd, "none") && !is.null(format) && !format %in% c("png")) {
    cli::cli_warn(c(
      "{.arg cvd} simulation applies to raster output only; {.val {format}} is unchanged.",
      i = "Render to {.file .png} (or use {.fn scene_raster}) to see the simulation."
    ))
    cvd <- "none"
  }
  rs_set_cvd_mode(if (identical(cvd, "none")) "" else cvd)
  invisible(cvd)
}

.apply_scale <- function(scene, scale) {
  if (length(scale) != 1L || is.na(scale) || !is.numeric(scale) || scale <= 0) {
    cli::cli_abort("{.arg scale} must be a single positive number.")
  }
  if (scale == 1) {
    return(scene)
  }
  S7::set_props(scene, dpi = scene@dpi * scale)
}

# Surface backend degradation warnings (e.g. a PDF pattern/mask that couldn't be
# honoured) as one R warning, unless the user has opted out. The successor-note
# principle: an unsupported feature should fail *visibly*, not silently degrade.
.emit_degrade_warnings <- function(warns) {
  if (length(warns) && isTRUE(getOption("vellum.warn_on_degrade", TRUE))) {
    msgs <- as.character(warns)
    names(msgs) <- rep("*", length(msgs))
    cli::cli_warn(c(
      "This render could not be fully reproduced on the target backend:",
      msgs,
      i = "Silence with {.code options(vellum.warn_on_degrade = FALSE)}."
    ))
  }
  invisible()
}

#' Read a rendered scene back as pixels
#'
#' `scene_raster()` renders `scene` and returns its pixels as an integer array
#' with dimensions `c(channel, x, y)` — RGBA channels in `0:255`, top-left origin,
#' `y` increasing downward. This is the form most convenient for probing or
#' testing (e.g. `scene_raster(s)[1, x, y]` is the red value at pixel `(x, y)`).
#'
#' An [grDevices::as.raster()] method returns the same image as a `raster` object
#' (a character matrix of hex colours), drawable with [graphics::plot()] or
#' [grid::rasterGrob()].
#'
#' @param scene A [vl_scene()] (or anything with an [as_vellum_scene()] method).
#' @inheritParams render
#' @return `scene_raster()`: an integer array of dimension `c(4, width, height)`.
#'   The `as.raster()` method: a `raster` (character matrix, `c(height, width)`).
#' @examples
#' s <- vl_scene(2, 1, bg = "white") |>
#'   draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "red", col = NA)))
#' dim(scene_raster(s)) # c(4, width_px, height_px)
#' @importFrom grDevices as.raster
#' @export
scene_raster <- function(scene, cvd = "none") {
  on.exit(.set_cvd("none"), add = TRUE)
  .set_cvd(cvd)
  s <- .scene_to_backend(as_vellum_scene(scene))
  d <- s$dim()
  array(s$rgba(), dim = c(4L, d[1], d[2]))
}

# as.raster() method for vellum_scene (documented in scene_raster() above).
# Registered at load via S7::methods_register(); no roxygen export needed (and a
# bare \usage would trip R CMD check, since `as.raster` is an existing generic).
#
# Build the raster via base as.raster() on a numeric [h, w, 4] array rather than
# hand-rolling a character matrix: a hand-built matrix is column-major, but a
# `raster` object's storage is what grid::grid.raster() reads (effectively
# row-major), so a hand-rolled one renders sheared. Let base as.raster() lay it
# out correctly. (Probe pixels with scene_raster(), not by indexing this object.)
S7::method(as.raster, vellum_scene) <- function(x, ...) {
  arr <- scene_raster(x) # [channel, x, y], 0:255
  grDevices::as.raster(aperm(arr, c(3, 2, 1)) / 255) # -> [y, x, channel] in 0..1
}

#' Display a scene in the active graphics device
#'
#' `display()` re-renders `scene` to fill the current graphics device and draws it
#' there. Interactively this is the RStudio / Positron **Plots** pane; inside a
#' knitr / Quarto chunk it becomes the chunk's figure (it draws to the chunk's
#' device). This is the seam any package built on vellum can call to *show* output
#' instead of writing a file: `scene` is coerced via [as_vellum_scene()], so it
#' also accepts e.g. a grammar's plot spec.
#'
#' To fill the window (no letterbox margins, like ggplot2) the scene is re-rendered
#' at the device's size and pixel density, so its relative (`npc`/`native`/layout)
#' content reflows to the window and absolute (`mm`/`in`/`pt`) content keeps its
#' physical size. It draws through a grid grob that re-rasterizes on every draw, so
#' **resizing the Plots pane re-renders the scene crisply** at the new size (round
#' markers stay round) rather than stretching one bitmap. Use `render()` to write
#' the scene at its *authored* width/height. Auto-printing a scene at the console
#' (or calling `plot()` on it) displays it.
#'
#' Inside a knitr / Quarto chunk the chunk's `dpi` option wins, so
#' `knitr::opts_chunk$set(dpi = 200)` yields a genuine 200-dpi figure even on
#' knitr's default `dev = "png"` device (which misreports its pixel density);
#' outside knitting the scene's authored [vl_scene()] `dpi` is honored unless the
#' live device reports a trustworthy higher density (e.g. a resized Plots pane).
#'
#' @param scene A [vl_scene()] or anything with an [as_vellum_scene()] method.
#' @param ... Unused.
#' @return The (coerced) scene, invisibly.
#' @examples
#' \dontrun{
#' vl_scene(4, 3) |>
#'   draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "tomato", col = NA))) |>
#'   display()
#' }
#' @export
display <- function(scene, ...) {
  scene <- as_vellum_scene(scene)
  # Draw into the active device interactively (the pane auto-opens on first plot)
  # or whenever a device is already open (an explicit png()/pdf(), or a knitr
  # chunk). Otherwise no-op, so sourced scripts / R CMD check don't spawn a stray
  # `Rplots.pdf`.
  if (!interactive() && grDevices::dev.cur() == 1L) {
    return(invisible(scene))
  }
  grid::grid.newpage()
  grid::grid.draw(.scene_grob(scene))
  invisible(scene)
}

# A grid grob that re-rasterizes the scene to the drawing region's *current* size
# on every draw. grid calls makeContent() on each draw — including Plots-pane
# resize, which replays the display list — so the scene is re-rendered crisply at
# the new size and aspect, instead of the engine stretching one fixed bitmap
# (which distorts circles and blurs on resize). This is the mechanism ggplot2 /
# gtable use to stay sharp on resize.
.scene_grob <- function(scene) {
  grid::gTree(scene = scene, cl = "vellum_scene_grob")
}

#' @exportS3Method grid::makeContent
makeContent.vellum_scene_grob <- function(x) {
  w_in <- grid::convertWidth(grid::unit(1, "npc"), "inches", valueOnly = TRUE)
  h_in <- grid::convertHeight(grid::unit(1, "npc"), "inches", valueOnly = TRUE)
  if (!is.finite(w_in) || w_in <= 0) {
    w_in <- .to_inches(x$scene@width)
  }
  if (!is.finite(h_in) || h_in <= 0) {
    h_in <- .to_inches(x$scene@height, "height")
  }
  # Pick the dpi to re-render at. Priority: (1) the knitr/Quarto chunk dpi the
  # user set and expects to win; (2) the live device's pixel density, but only
  # when it's trustworthy; (3) the scene's authored dpi. grDevices::png (knitr's
  # default device) hard-wires dev.size("px") to size_in * 72 and ignores its own
  # res=, so the ratio pins at 72 there regardless of the real resolution — treat
  # a ratio of 72 as "device misreports" and fall through to the authored dpi
  # rather than clamping the render to 72 and upscaling a soft bitmap.
  knit_dpi <- if (isTRUE(getOption("knitr.in.progress"))) {
    knitr::opts_current$get("dpi")
  } else {
    NULL
  }
  dev_dpi <- tryCatch(
    {
      d <- grDevices::dev.size("in")
      p <- grDevices::dev.size("px")
      r <- round(p[1] / d[1])
      if (r <= 72) NA_real_ else min(r, 300)
    },
    error = function(e) NA_real_
  )
  dpi <- knit_dpi %||% (if (is.na(dev_dpi)) x$scene@dpi else max(72, dev_dpi))
  # A YAML `dpi: 150` chunk option arrives as an integer; @dpi is <double>.
  dpi <- as.double(dpi)
  s2 <- S7::set_props(
    x$scene,
    width = vl_unit(w_in, "in"),
    height = vl_unit(h_in, "in"),
    dpi = dpi
  )
  grid::setChildren(
    x,
    grid::gList(
      grid::rasterGrob(
        as.raster(s2),
        width = grid::unit(1, "npc"),
        height = grid::unit(1, "npc"),
        interpolate = TRUE
      )
    )
  )
}

# Auto-print (type a scene at the console) and plot() both display it, like
# ggplot2's print method. Registered at load via S7::methods_register().
S7::method(print, vellum_scene) <- function(x, ...) {
  display(x)
  invisible(x)
}
S7::method(plot, vellum_scene) <- function(x, y, ...) {
  display(x)
  invisible(x)
}
# `method(print, cls) <- fn` is a *replacement call*, so R also binds the symbol
# on the left — `print` (and `plot`) — in this namespace, holding `base::print`
# unchanged. Harmless to call, but fatal to registration: `registerS3methods()`
# treats a generic whose name is a local object as a **local generic** and files
# every matching `S3method()` directive into vellum's own `.__S3MethodsTable__.`
# instead of base's, where dispatch never looks. That silently disabled all four
# `print.vellum_*` S3 methods (gradient/mask/pattern/why_size printed as raw
# lists). Dropping the accidental bindings restores the normal path; the S7
# methods above are registered by `S7::methods_register()` in `.onLoad()` and are
# unaffected. Guarded by `test-print-methods.R` — if a future
# `method(print, ...) <-` reintroduces the binding, that test fails.
rm(print, plot)

# --- object-identity render cache -------------------------------------------
# Keyed on the content-identity token (`.new_scene_id`), so a repeat render of an
# unchanged scene (multi-format export, `display()` redraw / resize-return-to-a-
# prior-size, animation replay) reuses the compiled backend `Scene` — while a
# single render pays only an O(1) key lookup, not the O(grobs) content hash the
# reverted FW4 cache computed on every call (DESIGN.md FW4). Two memos:
#   * `.render_cache`  key = (cid, w_in, h_in, dpi, bg)  -> compiled Scene (LRU)
#   * `.mtl_cache`     key = cid                          -> materialised gtree
# The materialise memo is device-independent, so a genuine resize (new size ->
# compiled-Scene miss) still skips the build->gtree walk. Both are transparent (a
# hit is byte-identical to a miss) and disabled by `options(vellum.cache=FALSE)`.
.render_cache <- new.env(parent = emptyenv())
.render_cache$.order <- character(0) # LRU access order, oldest first
.render_cache$.hits <- 0L
.render_cache$.misses <- 0L
.mtl_cache <- new.env(parent = emptyenv())
# Pick-compiled backends for `hit_test()` (see `.pick_backend()`), same LRU cap.
.pick_cache <- new.env(parent = emptyenv())
.pick_cache$.order <- character(0)
.mtl_count <- new.env(parent = emptyenv()) # `.materialize` call counter (tests)
.mtl_count$n <- 0L

.render_cache_cap <- function() {
  cap <- suppressWarnings(as.integer(getOption("vellum.cache_size", 8L)))
  if (is.na(cap) || cap < 1L) 8L else cap
}

.render_key <- function(cid, w_in, h_in, dpi, bg, title = NULL, desc = NULL) {
  paste0(
    cid,
    "|",
    w_in,
    "x",
    h_in,
    "@",
    dpi,
    "|",
    paste(bg, collapse = ","),
    "|a11y:",
    title %||% "",
    "|",
    desc %||% ""
  )
}

# LRU lookup: on a hit, promote the key to most-recent and count it.
.render_cache_get <- function(key) {
  hit <- .render_cache[[key]]
  if (!is.null(hit)) {
    .render_cache$.order <- c(setdiff(.render_cache$.order, key), key)
    .render_cache$.hits <- .render_cache$.hits + 1L
  }
  hit
}

# LRU insert: evict oldest until under cap, then store as most-recent.
.render_cache_put <- function(key, value) {
  cap <- .render_cache_cap()
  ord <- setdiff(.render_cache$.order, key)
  while (length(ord) >= cap) {
    old <- ord[[1L]]
    ord <- ord[-1L]
    if (exists(old, envir = .render_cache, inherits = FALSE)) {
      rm(list = old, envir = .render_cache)
    }
  }
  assign(key, value, envir = .render_cache)
  .render_cache$.order <- c(ord, key)
  .render_cache$.misses <- .render_cache$.misses + 1L
  invisible()
}

# Materialise the scene's tree, memoised on its content id (device-independent).
.materialize_cached <- function(scene, cid) {
  if (is.null(cid)) {
    return(.materialize(scene))
  }
  k <- as.character(cid)
  hit <- .mtl_cache[[k]]
  if (!is.null(hit)) {
    return(hit)
  }
  root <- .materialize(scene)
  if (length(ls(.mtl_cache)) > .render_cache_cap() * 2L) {
    # crude bound; refs are cheap
    rm(list = ls(.mtl_cache, all.names = TRUE), envir = .mtl_cache)
  }
  assign(k, root, envir = .mtl_cache)
  root
}

# Empty both memos and reset counters/LRU order, plus the Rust repaint-boundary
# sub-raster cache (FW4c).
.render_cache_reset <- function() {
  rm(list = ls(.render_cache, all.names = TRUE), envir = .render_cache)
  rm(list = ls(.mtl_cache, all.names = TRUE), envir = .mtl_cache)
  rm(list = ls(.pick_cache, all.names = TRUE), envir = .pick_cache)
  .pick_cache$.order <- character(0)
  .render_cache$.order <- character(0)
  .render_cache$.hits <- 0L
  .render_cache$.misses <- 0L
  rs_clear_subraster_cache()
  invisible()
}

#' Clear the render cache
#'
#' vellum memoises compiled scenes keyed on an object-identity token so repeat
#' renders of an unchanged scene (multi-format export, a `display()` resize back
#' to a prior size, or animation replaying a fixed set of frames) are cheap. The
#' cache is transparent — a cached render is byte-identical to an uncached one —
#' and bounded (`options(vellum.cache_size=)`, default 8), so you rarely need
#' this; it is provided to reclaim memory or to force a cold render in
#' benchmarks. Disable caching entirely with `options(vellum.cache = FALSE)`.
#'
#' @return `NULL`, invisibly.
#' @examples
#' vl_clear_render_cache()
#' @export
vl_clear_render_cache <- function() {
  .render_cache_reset()
  invisible(NULL)
}
