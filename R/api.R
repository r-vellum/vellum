#' @include grob.R viewport.R gpar.R
NULL

# --- containers -------------------------------------------------------------

# A named subtree: its own viewport plus ordered children (grobs / gtrees).
# `nid` is a per-subtree content-identity token (see `.new_scene_id`) used by the
# repaint-boundary sub-raster cache (FW4c): it is stamped at materialisation and
# re-stamped for every node on an `edit_node` path, so an unchanged subtree keeps
# its `nid` across an edit (structural sharing) while a changed one gets a fresh
# one. `NULL` -> the subtree is not sub-raster-cacheable.
gtree <- S7::new_class(
  "gtree", parent = grob, package = "vellum",
  properties = list(
    vp = S7::new_property(S7::class_any, default = NULL),
    children = S7::new_property(S7::class_list, default = list()),
    nid = S7::new_property(S7::class_any, default = NULL)
  )
)

# A drawing scene: page size + background + the scene tree. While building, the
# tree is held in a fast mutable form (`build` = a root "build node", `open` = the
# stack of open ancestors); it is materialised to an immutable `root` gtree lazily
# (at render/edit/query). Exactly one of `build`/`root` is non-NULL.
#
# The build tree is mutated in place for O(1) appends, but each scene value must
# still behave as immutable (the pipe may branch: `b <- push(...); x <- draw(b);
# y <- draw(b)`). All the per-value builder state lives in one list property,
# `bstate = list(build, open, ocount, gen)`, so a mutating op is a single S7
# property write (S7 `@<-` validation is the hot-path cost). `build` (the root
# build node) is shared by reference across scene values for O(1) appends;
# `open`/`ocount`/`gen` are the cheap per-value bits.
#
# Ownership is tracked with a generation token: a scene owns its build tree iff
# `bstate$gen == build$owner_gen`. Exactly one scene (the latest mutation) owns
# it; mutating any other (stale) scene first forks an independent copy of its own
# view (copy-on-write). `ocount` records, per open-stack node, how many children
# belong to *this* scene's view — appends only grow the child dict, so a stale
# scene's view is the recorded prefix of each open node. Exactly one of
# `bstate`/`root` is non-NULL.
vellum_scene <- S7::new_class(
  "vellum_scene", package = "vellum",
  properties = list(
    width  = S7::new_property(S7::new_S3_class("vellum_unit"), default = quote(unit(6, "in"))),
    height = S7::new_property(S7::new_S3_class("vellum_unit"), default = quote(unit(4, "in"))),
    dpi = S7::new_property(S7::class_double, default = 96),
    bg = S7::new_property(S7::class_any, default = "white"),
    root = S7::new_property(S7::class_any, default = NULL),
    bstate = S7::new_property(S7::class_any, default = NULL),
    # Content-identity token for the render cache (see `.new_scene_id`). Lives in
    # `bstate$cid` while building; here only once materialised (by `edit_node`).
    # `NULL` -> the scene is not cacheable (foreign-built / raw `set_props`).
    cid = S7::new_property(S7::class_any, default = NULL),
    # Accessibility: an accessible name (`title`) and long description (`desc`).
    # When set, the SVG backend emits `role="img"` + `<title>`/`<desc>` and the PDF
    # backend tags the page as a Figure with Alt text. `a11y_prefix` uniquifies the
    # SVG title/desc ids across a page. `NULL`/`""` -> no a11y markup (unchanged).
    title = S7::new_property(S7::class_any, default = NULL),
    desc = S7::new_property(S7::class_any, default = NULL),
    a11y_prefix = S7::new_property(S7::class_any, default = NULL)
  )
)

# A per-scene id prefix so `aria-labelledby` title/desc ids don't collide when
# several vellum SVGs share one HTML page. Stable for a given scene object
# (stored once at construction), unique across scenes (monotonic counter).
.new_a11y_prefix <- function() paste0("vl", .new_scene_id())

# --- content-identity token (object-identity render cache) -------------------
# A strictly-monotonic per-content-version id, stamped into the *content carrier*
# (the build-state list, or the scene's `cid` property once materialised) at
# every content mutation, so it changes whenever the drawn content changes but
# survives a device-only edit (a `display()` resize's
# `set_props(width=, height=, dpi=)`). The render cache keys on it in O(1) — a
# scalar read, not the O(grobs) tree hash that sank the reverted FW4 cache. A
# double counter is exact to 2^53, far beyond any session's mutation count.
.id_counter <- new.env(parent = emptyenv())
.id_counter$n <- 0
.new_scene_id <- function() {
  n <- .id_counter$n + 1
  .id_counter$n <- n
  n
}

# --- mutable build tree (O(1) append) ---------------------------------------
# A "build node" is an environment with the viewport plus a child dictionary
# (hashed env keyed "1","2",… + a counter), so appending a child is amortised
# O(1) — versus copying an immutable children list on every draw (O(n^2) total).

.bnode <- function(vp = NULL) {
  e <- new.env(parent = emptyenv())
  e$vp <- vp
  e$kids <- new.env(parent = emptyenv())
  e$n <- 0L
  e$is_bnode <- TRUE
  e
}
.is_bnode <- function(x) is.environment(x) && isTRUE(x$is_bnode)
.bnode_kid <- function(node, i) get(as.character(i), envir = node$kids)
.bnode_add <- function(node, child) {
  node$n <- node$n + 1L
  assign(as.character(node$n), child, envir = node$kids)
  invisible()
}
# Index (1-based) of `child` among `parent`'s first `lim` children, by identity.
.bnode_index_of <- function(parent, child, lim) {
  for (j in seq_len(lim)) if (identical(.bnode_kid(parent, j), child)) return(j)
  NA_integer_
}

# Materialise a build node into an immutable gtree. `depth` is the node's index
# on the open path (NA once off it): an open-path node is capped to its view
# count `ocount[depth]` (a stale scene sees a prefix); off-path subtrees are
# fully frozen (all children).
.bnode_to_gtree <- function(node, open, ocount, depth) {
  on_path <- !is.na(depth)
  cap <- if (on_path) ocount[[depth]] else node$n
  nextnode <- if (on_path && depth < length(open)) open[[depth + 1L]] else NULL
  children <- lapply(seq_len(cap), function(i) {
    ch <- .bnode_kid(node, i)
    if (!.is_bnode(ch)) {
      return(ch)
    }
    nd <- if (!is.null(nextnode) && identical(ch, nextnode)) depth + 1L else NA_integer_
    .bnode_to_gtree(ch, open, ocount, nd)
  })
  # Stamp a per-subtree identity token (FW4c). Memoised with the tree by
  # `.materialize_cached`, so it is stable across renders at a fixed scene cid.
  gtree(name = node$vp@name, vp = node$vp, children = children, nid = .new_scene_id())
}
# Reopen an immutable gtree into a build tree (for drawing after edit/render).
.gtree_to_bnode <- function(g) {
  node <- .bnode(vp = g@vp)
  for (ch in g@children) .bnode_add(node, if (S7::S7_inherits(ch, gtree)) .gtree_to_bnode(ch) else ch)
  node
}

# A fresh build-state list: a root build node, its open stack, the per-node view
# counts, and the ownership generation. `owner_gen` is stamped on the build node.
.bstate_new <- function(build, open, ocount, gen) {
  build$owner_gen <- gen
  list(build = build, open = open, ocount = ocount, gen = gen, cid = .new_scene_id())
}

# The immutable root gtree for a scene's view (materialising the build tree if
# needed), honouring this scene's per-open-node child counts (`ocount`).
.materialize <- function(scene) {
  .mtl_count$n <- .mtl_count$n + 1L # instrumentation: build->gtree walks (see tests)
  if (!is.null(scene@root)) {
    return(scene@root)
  }
  bs <- scene@bstate
  if (is.null(bs)) {
    return(gtree(name = "root", vp = viewport(name = "root"), children = list()))
  }
  .bnode_to_gtree(bs$build, bs$open, bs$ocount, 1L)
}

# Fork an independent copy of a stale scene's *own view* (copy-on-write), so the
# subsequent in-place mutation can't corrupt scenes that branched earlier. Owner
# scenes (the common linear-pipe case) never reach here.
.fork <- function(scene) {
  bs <- scene@bstate
  idx <- vapply(
    seq_len(length(bs$open) - 1L),
    function(i) .bnode_index_of(bs$open[[i]], bs$open[[i + 1L]], bs$ocount[[i]]),
    integer(1)
  )
  root <- .gtree_to_bnode(.materialize(scene)) # deep copy of this scene's view
  open <- vector("list", length(idx) + 1L)
  open[[1L]] <- root
  for (j in seq_along(idx)) open[[j + 1L]] <- .bnode_kid(open[[j]], idx[[j]])
  scene@root <- NULL
  scene@bstate <- .bstate_new(root, open, vapply(open, function(b) b$n, integer(1)), 0)
  scene
}

# Put the scene into building mode and guarantee it owns its build tree (forking
# a stale handle first). All mutating ops (push/draw/pop) go through this; it
# returns a scene whose `@bstate` is present and owned.
.ensure_building <- function(scene) {
  bs <- scene@bstate
  if (is.null(bs)) { # materialised -> reopen a fresh, owned build tree
    br <- .gtree_to_bnode(.materialize(scene))
    scene@root <- NULL
    scene@bstate <- .bstate_new(br, list(br), br$n, 0)
    return(scene)
  }
  if (identical(bs$gen, bs$build$owner_gen)) scene else .fork(scene)
}

# --- scene construction + functional builder --------------------------------

#' Build and render a scene
#'
#' `vl_scene()` creates an empty scene. [push()] adds a viewport (and descends
#' into it), [draw()] adds a grob, [pop()] ascends. The builder is a linear pipe;
#' a *rendered or edited* scene is an immutable value ([edit_node()] copies on
#' modify). [render()] compiles the scene and writes the output.
#'
#' @param width,height Page size ([unit()] or numeric inches).
#' @param dpi Resolution in dots per inch.
#' @param bg Background colour (or `NA` for transparent).
#' @param gp Page-level graphical parameters ([gpar()]) carried by the root
#'   viewport; inherited by everything drawn (e.g. a default `col`/`fontsize`).
#' @param xscale,yscale Native coordinate range of the root viewport, so
#'   `"native"` units work at the page level without an explicit [push()].
#' @param clip Clip drawing to the page rectangle?
#' @param title,desc Accessibility: an accessible **name** (a short title) and a
#'   longer **description** (alt text) for the scene. When either is set, the SVG
#'   backend emits `role="img"` + `<title>`/`<desc>` (referenced by
#'   `aria-labelledby`) and the PDF backend tags the page as a Figure with the
#'   description as Alt text. `NULL` (default) emits no accessibility markup, so
#'   output is unchanged. See [describe()] to set them on an existing scene.
#' @return `vl_scene()`, `push()`, `draw()`, `pop()`: a `vellum_scene`.
#' @examples
#' s <- vl_scene(width = 4, height = 3) |>
#'   push(viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
#'   draw(rect_grob(gp = gpar(fill = "grey95", col = "grey50"))) |>
#'   draw(lines_grob(x = unit(0:10, "native"), y = unit(0:10, "native"),
#'                   gp = gpar(col = "steelblue", lwd = 2)))
#' @export
vl_scene <- function(width = 6, height = 4, dpi = 96, bg = "white",
                     gp = gpar(), xscale = c(0, 1), yscale = c(0, 1), clip = FALSE,
                     title = NULL, desc = NULL) {
  root <- .bnode(vp = viewport(name = "root", gp = gp, xscale = xscale, yscale = yscale, clip = clip))
  vellum_scene(
    width = .as_size(width), height = .as_size(height), dpi = dpi, bg = bg,
    root = NULL, bstate = .bstate_new(root, list(root), 0L, 0),
    title = title, desc = desc, a11y_prefix = .new_a11y_prefix()
  )
}

#' Set a scene's accessibility name and description
#'
#' Attach (or replace) an accessible **name** (`title`) and long **description**
#' (`desc`, the alt text) on an existing scene. The SVG backend then emits
#' `role="img"` + `<title>`/`<desc>`, and the PDF backend tags the page as a
#' Figure with the description as Alt text — meeting WCAG 1.1.1 (text
#' alternative). Equivalent to passing `title`/`desc` to [vl_scene()].
#'
#' @param scene A [vl_scene()].
#' @param title An accessible name (short), or `NULL` to leave unset.
#' @param desc A long description / alt text, or `NULL` to leave unset.
#' @return The scene, with the accessibility fields set (a new value).
#' @examples
#' vl_scene(2, 2) |>
#'   draw(points_grob(c(0.3, 0.7), 0.5, gp = gpar(fill = "red"))) |>
#'   describe(title = "Two red dots", desc = "Two red points on a white field.")
#' @export
describe <- function(scene, title = NULL, desc = NULL) {
  scene <- as_vellum_scene(scene)
  # A new content-identity so the render cache recompiles with the new metadata.
  S7::set_props(scene, title = title, desc = desc,
                a11y_prefix = scene@a11y_prefix %||% .new_a11y_prefix(),
                cid = .new_scene_id())
}

# Bump the ownership generation on `bs` (in place on the shared build node) and
# return the updated bstate list. The single per-op S7 write is `@bstate <-`.
.bstate_claim <- function(bs) {
  g <- bs$build$owner_gen + 1
  bs$build$owner_gen <- g
  bs$gen <- g
  bs$cid <- .new_scene_id() # content changed -> new identity for the render cache
  bs
}

#' @rdname vl_scene
#' @param scene A [vl_scene()].
#' @param vp A [viewport()].
#' @export
push <- function(scene, vp) {
  scene <- .ensure_building(scene)
  bs <- scene@bstate
  k <- length(bs$open)
  cur <- bs$open[[k]]
  node <- .bnode(vp = vp)
  .bnode_add(cur, node)
  bs$ocount[k] <- cur$n # parent now has this child in our view
  bs$open <- c(bs$open, list(node))
  bs$ocount <- c(bs$ocount, 0L)
  scene@bstate <- .bstate_claim(bs)
  scene
}

#' @rdname vl_scene
#' @param grob A grob (see [grob]).
#' @export
draw <- function(scene, grob) {
  scene <- .ensure_building(scene)
  bs <- scene@bstate
  k <- length(bs$open)
  cur <- bs$open[[k]]
  .bnode_add(cur, grob) # O(1) env append
  bs$ocount[k] <- cur$n
  scene@bstate <- .bstate_claim(bs)
  scene
}

#' @rdname vl_scene
#' @param n Number of viewport levels to ascend.
#' @export
pop <- function(scene, n = 1) {
  .check_count(n, "n")
  scene <- .ensure_building(scene)
  bs <- scene@bstate
  k <- length(bs$open)
  keep <- max(1L, k - max(0L, as.integer(n))) # never pop the root; ignore n < 0
  bs$open <- bs$open[seq_len(keep)]
  bs$ocount <- bs$ocount[seq_len(keep)]
  scene@bstate <- .bstate_claim(bs)
  scene
}

# A count argument must be a single finite number (NA/NaN/Inf, non-scalar, or
# non-numeric error with a named message). Negative values are tolerated by the
# caller (clamped) — this only rejects the cases that would fail cryptically
# downstream (e.g. `seq_len(NA)`). Mirrors `.check_cell`'s style.
.check_count <- function(n, arg) {
  if (!is.numeric(n) || length(n) != 1L || !is.finite(n)) {
    cli::cli_abort("{.arg {arg}} must be a single finite number.")
  }
  invisible(n)
}

#' Coerce an object to a vellum scene
#'
#' The extensible seam a higher-level package (e.g. a grammar layer) implements to
#' compile its own plot object into a [vl_scene()]. [render()] coerces its input
#' through this generic, so `render(x, path)` works for any `x` that has an
#' `as_vellum_scene()` method. An identity method for `vellum_scene` is provided.
#'
#' This is the stable *compiler-backend* entry point: downstream packages should
#' target `as_vellum_scene()` (and the exported grob/viewport/unit constructors)
#' rather than vellum's internal `compile()` / `.scene_to_backend()` helpers.
#'
#' @param x An object to coerce: a `vellum_scene`, or a type a downstream package
#'   has taught to compile by defining an `as_vellum_scene()` method.
#' @param ... Passed on to methods.
#' @return A `vellum_scene`.
#' @examples
#' sc <- vl_scene()
#' identical(as_vellum_scene(sc), sc) # the identity method returns its input
#' @export
as_vellum_scene <- S7::new_generic("as_vellum_scene", "x")

S7::method(as_vellum_scene, vellum_scene) <- function(x, ...) x

#' @rdname vl_scene
#' @param path Output file path; the format is taken from the extension (`.png`,
#'   `.svg`, or `.pdf`).
#' @param text For SVG output, how text is written: `"native"` (default) emits
#'   selectable `<text>` referencing system fonts, `"outline"` emits glyph
#'   outlines (pixel-faithful, identical to the raster/PDF backends, but not
#'   selectable). Ignored for PNG/PDF.
#' @param debug If `TRUE`, overlay a layout-debug skeleton on the output: each
#'   viewport region (outlined and labelled by name), its layout track boundaries,
#'   and its clip region. Built from the resolved scene with [why_size()]; useful
#'   for understanding why elements land where they do. Default `FALSE`.
#' @return `render()`: `path`, invisibly.
#' @export
render <- function(scene, path, text = c("native", "outline"), debug = FALSE) {
  text <- match.arg(text)
  scene <- as_vellum_scene(scene)
  s <- .scene_to_backend(scene, debug = debug)
  ext <- tolower(tools::file_ext(path))
  warns <- switch(ext,
    png = s$render_png(path),
    svg = s$render_svg(path, identical(text, "outline")),
    pdf = s$render_pdf(path),
    cli::cli_abort("Unsupported output format {.val {ext}}; use .png, .svg, or .pdf.")
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
#' @inheritParams render
#' @return A length-1 character vector: the SVG document.
#' @seealso [render()], [scene_model()]
#' @export
scene_svg <- function(scene, text = c("native", "outline")) {
  text <- match.arg(text)
  scene <- as_vellum_scene(scene)
  s <- .scene_to_backend(scene)
  s$render_svg_string(identical(text, "outline"))
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
#' @return `scene_raster()`: an integer array of dimension `c(4, width, height)`.
#'   The `as.raster()` method: a `raster` (character matrix, `c(height, width)`).
#' @examples
#' s <- vl_scene(2, 1, bg = "white") |>
#'   draw(circle_grob(r = 0.3, gp = gpar(fill = "red", col = NA)))
#' dim(scene_raster(s)) # c(4, width_px, height_px)
#' @importFrom grDevices as.raster
#' @export
scene_raster <- function(scene) {
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
#'   draw(circle_grob(r = 0.3, gp = gpar(fill = "tomato", col = NA))) |>
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
  if (!is.finite(w_in) || w_in <= 0) w_in <- .to_inches(x$scene@width)
  if (!is.finite(h_in) || h_in <= 0) h_in <- .to_inches(x$scene@height)
  # Pick the dpi to re-render at. Priority: (1) the knitr/Quarto chunk dpi the
  # user set and expects to win; (2) the live device's pixel density, but only
  # when it's trustworthy; (3) the scene's authored dpi. grDevices::png (knitr's
  # default device) hard-wires dev.size("px") to size_in * 72 and ignores its own
  # res=, so the ratio pins at 72 there regardless of the real resolution — treat
  # a ratio of 72 as "device misreports" and fall through to the authored dpi
  # rather than clamping the render to 72 and upscaling a soft bitmap.
  knit_dpi <- if (isTRUE(getOption("knitr.in.progress")))
    knitr::opts_current$get("dpi") else NULL
  dev_dpi <- tryCatch({
    d <- grDevices::dev.size("in")
    p <- grDevices::dev.size("px")
    r <- round(p[1] / d[1])
    if (r <= 72) NA_real_ else min(r, 300)
  }, error = function(e) NA_real_)
  dpi <- knit_dpi %||% (if (is.na(dev_dpi)) x$scene@dpi else max(72, dev_dpi))
  s2 <- S7::set_props(x$scene, width = unit(w_in, "in"), height = unit(h_in, "in"), dpi = dpi)
  grid::setChildren(x, grid::gList(
    grid::rasterGrob(as.raster(s2), width = grid::unit(1, "npc"),
                     height = grid::unit(1, "npc"), interpolate = TRUE)
  ))
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
.mtl_count <- new.env(parent = emptyenv()) # `.materialize` call counter (tests)
.mtl_count$n <- 0L

.render_cache_cap <- function() {
  cap <- suppressWarnings(as.integer(getOption("vellum.cache_size", 8L)))
  if (is.na(cap) || cap < 1L) 8L else cap
}

.render_key <- function(cid, w_in, h_in, dpi, bg, title = NULL, desc = NULL) {
  paste0(cid, "|", w_in, "x", h_in, "@", dpi, "|", paste(bg, collapse = ","),
         "|a11y:", title %||% "", "|", desc %||% "")
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
    if (exists(old, envir = .render_cache, inherits = FALSE)) rm(list = old, envir = .render_cache)
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
  if (length(ls(.mtl_cache)) > .render_cache_cap() * 2L) { # crude bound; refs are cheap
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

# Compile an immutable scene onto a fresh backend `Scene`, memoised on the
# scene's object-identity token. A single render costs one O(1) key lookup + one
# compile; a repeat of the same content at the same device size reuses the
# compiled Scene (and, via the Scene's own lazy pixmap memo, its rasterisation).
# The scene's content-identity token, or NULL if it is not cacheable. Requires
# the "exactly one of bstate/root" invariant to hold — a scene with both set (or
# neither) has been mutated outside the builder API (a raw `set_props(root=)`), so
# it is untrustworthy: NULL, render it fresh rather than risk a stale hit.
.scene_cid <- function(scene) {
  if (!is.null(scene@bstate) && is.null(scene@root)) {
    scene@bstate$cid
  } else if (is.null(scene@bstate) && !is.null(scene@root)) {
    scene@cid
  } else {
    NULL
  }
}

# Map `options(vellum.glyph_bitmap)` to the Rust mode code (0 off / 1 auto / 2 on).
.glyph_bitmap_code <- function() {
  switch(as.character(getOption("vellum.glyph_bitmap", "auto")),
    off = 0L, on = 2L, auto = 1L, 1L)
}

.scene_to_backend <- function(scene, debug = FALSE) {
  # Push the glyph-bitmap mode for this render (a thread-local read by the raster
  # backend when it rasterises). Cheap, so set it every call. A cached raster is
  # returned as-is without re-reading the mode; that is fine because the mode is a
  # perf-only fast path with output identical to the vector text path.
  rs_set_glyph_bitmap_mode(.glyph_bitmap_code())
  cid <- .scene_cid(scene)
  # Bypass for debug overlays, when disabled, or when the scene carries no id
  # (foreign-built / raw `set_props`) — compute fresh rather than risk a stale
  # hit. Absent id => never cached (fail-safe), so it can only under-hit.
  if (debug || is.null(cid) || !isTRUE(getOption("vellum.cache", TRUE))) {
    return(.compile_backend(scene, debug = debug, cid = NULL))
  }
  key <- .render_key(cid, .to_inches(scene@width), .to_inches(scene@height),
                     scene@dpi, .rs_col(scene@bg) %||% c(255L, 255L, 255L, 0L),
                     scene@title, scene@desc)
  hit <- .render_cache_get(key)
  if (!is.null(hit)) {
    return(hit)
  }
  s <- .compile_backend(scene, cid = cid)
  .render_cache_put(key, s)
  s
}

.compile_backend <- function(scene, debug = FALSE, cid = NULL) {
  s <- Scene$new(.to_inches(scene@width), .to_inches(scene@height), scene@dpi,
                 .rs_col(scene@bg) %||% c(255L, 255L, 255L, 0L))
  # Scene-level accessibility (name/description), emitted by the SVG/PDF backends.
  if (!is.null(scene@title) || !is.null(scene@desc)) {
    s$set_a11y(scene@title %||% "", scene@desc %||% "", scene@a11y_prefix %||% "vl")
  }
  # Compile the root as a gtree so the root viewport's gp / scales / clip / layout
  # / mask all apply (it is pushed like any viewport), not just its layout.
  root <- .materialize_cached(scene, cid)
  if (debug) {
    # Capture the id<->name map for each pushed viewport (via `.push_vp`), then
    # draw the layout-debug overlay on top of the compiled content.
    reg <- new.env(parent = emptyenv())
    reg$items <- list()
    old <- .debug_state$reg
    .debug_state$reg <- reg
    on.exit(.debug_state$reg <- old, add = TRUE)
    compile(root, s)
    .debug_state$reg <- old
    .draw_debug_overlay(s, reg$items)
  } else {
    compile(root, s)
  }
  s
}

# --- compile (tree -> imperative Scene calls) -------------------------------

compile <- S7::new_generic("compile", "node", function(node, scene) {
  S7::S7_dispatch()
})

S7::method(compile, grob_rect) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x, node@y, node@width, node@height)
    ex <- .coord(node@x, "npc", n); ey <- .coord(node@y, "npc", n)
    ew <- .coord(node@width, "npc", n); eh <- .coord(node@height, "npc", n)
    g <- .gp4(node@gp, scene)
    sk <- .encode_sketch(node@sketch)
    # One batched call (one shared gpar) instead of a per-element FFI loop.
    scene$rects(ex$value, ey$value, ew$value, eh$value,
                ex$code, ex$offset, ey$code, ey$offset, ew$code, ew$offset, eh$code, eh$offset,
                g$fill, g$col, g$lwd, g$alpha, g$stroke,
                sk$roughness, sk$bowing, sk$fill_style, sk$fill_weight, sk$hachure_angle,
                sk$hachure_gap, sk$curve_tightness, sk$disable_multi, sk$preserve, sk$seed,
                .keys_vec(node, n))
  })
}

S7::method(compile, grob_roundrect) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x, node@y, node@width, node@height, node@r)
    ex <- .coord(node@x, "npc", n); ey <- .coord(node@y, "npc", n)
    ew <- .coord(node@width, "npc", n); eh <- .coord(node@height, "npc", n)
    er <- .coord(node@r, "npc", n)
    g <- .gp4(node@gp, scene)
    sk <- .encode_sketch(node@sketch)
    # Rounded rects are typically few (keys/labels); one FFI call each, shared gpar.
    for (i in seq_len(n)) {
      scene$roundrect(ex$value[i], ey$value[i], ew$value[i], eh$value[i], er$value[i],
                      ex$code[i], ex$offset[i], ey$code[i], ey$offset[i], ew$code[i], ew$offset[i],
                      eh$code[i], eh$offset[i], er$code[i], er$offset[i],
                      g$fill, g$col, g$lwd, g$alpha, g$stroke,
                      sk$roughness, sk$bowing, sk$fill_style, sk$fill_weight, sk$hachure_angle,
                      sk$hachure_gap, sk$curve_tightness, sk$disable_multi, sk$preserve, sk$seed)
    }
  })
}

S7::method(compile, grob_lines) <- function(node, scene) {
  .with_vp(node, scene, {
    ex <- .coord(node@x); ey <- .coord(node@y); g <- .gp4(node@gp, scene)
    a <- .encode_arrow(node@arrow)
    sc <- .encode_cap(node@start_cap); ec <- .encode_cap(node@end_cap)
    of <- .encode_cap(node@offset)
    sk <- .encode_sketch(node@sketch)
    scene$lines(ex$value, ey$value, ex$code, ex$offset, ey$code, ey$offset,
                sc$value, ec$value, sc$code, ec$code, of$value, of$code,
                g$col, g$lwd, g$alpha, g$stroke,
                a$angle, a$len, a$ends, a$closed,
                sk$roughness, sk$bowing, sk$fill_style, sk$fill_weight, sk$hachure_angle,
                sk$hachure_gap, sk$curve_tightness, sk$disable_multi, sk$preserve, sk$seed,
                .key1(node))
  })
}

S7::method(compile, grob_polygon) <- function(node, scene) {
  .with_vp(node, scene, {
    ex <- .coord(node@x); ey <- .coord(node@y); g <- .gp4(node@gp, scene)
    sk <- .encode_sketch(node@sketch)
    scene$polygon(ex$value, ey$value, ex$code, ex$offset, ey$code, ey$offset, g$fill, g$col, g$lwd, g$alpha, g$stroke,
                  sk$roughness, sk$bowing, sk$fill_style, sk$fill_weight, sk$hachure_angle,
                  sk$hachure_gap, sk$curve_tightness, sk$disable_multi, sk$preserve, sk$seed,
                  .key1(node))
  })
}

# circles and points compile identically (a batched circle draw); they differ
# only in where the radius comes from and its default unit (npc vs mm).
.compile_circles <- function(node, scene, radius, rdefault, sketch = NULL) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x, node@y, radius)
    ex <- .coord(node@x, "npc", n); ey <- .coord(node@y, "npc", n)
    er <- .coord(radius, rdefault, n)
    g <- .gp4(node@gp, scene)
    sk <- .encode_sketch(sketch)
    scene$circles(ex$value, ey$value, er$value, ex$code, ex$offset, ey$code, ey$offset, er$code, er$offset,
                  g$fill, g$col, g$lwd, g$alpha, g$stroke,
                  sk$roughness, sk$bowing, sk$fill_style, sk$fill_weight, sk$hachure_angle,
                  sk$hachure_gap, sk$curve_tightness, sk$disable_multi, sk$preserve, sk$seed,
                  .keys_vec(node, n))
  })
}

S7::method(compile, grob_circle) <- function(node, scene) {
  .compile_circles(node, scene, node@r, "npc", node@sketch)
}

S7::method(compile, grob_points) <- function(node, scene) {
  codes <- unname(.marker_codes[node@shape])
  if (all(codes == 0L)) {
    # All circles: the batched circle path (radius carries marker size, sprite
    # fast-path for dense clouds).
    .compile_circles(node, scene, node@size, "mm", node@sketch)
  } else {
    .with_vp(node, scene, {
      n <- vctrs::vec_size_common(node@x, node@y, node@size)
      ex <- .coord(node@x, "npc", n); ey <- .coord(node@y, "npc", n); es <- .coord(node@size, "mm", n)
      g <- .gp4(node@gp, scene)
      sk <- .encode_sketch(node@sketch)
      scene$markers(ex$value, ey$value, es$value, ex$code, ex$offset, ey$code, ey$offset, es$code, es$offset,
                    vctrs::vec_recycle(as.integer(codes), n),
                    g$fill, g$col, g$lwd, g$alpha, g$stroke,
                    sk$roughness, sk$bowing, sk$fill_style, sk$fill_weight, sk$hachure_angle,
                    sk$hachure_gap, sk$curve_tightness, sk$disable_multi, sk$preserve, sk$seed,
                    .keys_vec(node, n))
    })
  }
}

S7::method(compile, grob_hexagon) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x, node@y, node@size)
    ex <- .coord(node@x, "npc", n); ey <- .coord(node@y, "npc", n)
    es <- .coord(node@size, "mm", n)
    # Non-regular geometry: per-axis full width/height (override `size`). Empty
    # streams signal the regular size-driven path to the Rust side.
    if (!is.null(node@width)) {
      ew <- .coord(node@width, "native", n); eh <- .coord(node@height, "native", n)
    } else {
      ew <- list(value = numeric(0), code = integer(0), offset = numeric(0))
      eh <- list(value = numeric(0), code = integer(0), offset = numeric(0))
    }
    # Per-hex fill: the binned-count colour mesh. Falls back to gp$fill, then
    # transparent. col2rgb(alpha=TRUE) flattens column-major -> per-hex RGBA
    # contiguous (chunks of 4 on the Rust side). Fold the uniform gp$alpha into
    # the per-hex fill alpha (the fill bypasses the shared-gpar resolve).
    cols <- node@fill
    if (is.null(cols)) cols <- node@gp@fill
    if (is.null(cols)) cols <- NA
    cols <- rep_len(cols, n)
    cols[is.na(cols)] <- "transparent"
    m <- grDevices::col2rgb(cols, alpha = TRUE)
    a <- node@gp@alpha
    if (!is.null(a) && !is.na(a)) m[4L, ] <- round(m[4L, ] * a)
    frgba <- as.integer(m)
    g <- .gp4(node@gp, scene)
    scene$hexagons(ex$value, ey$value, es$value, ew$value, eh$value,
                   ex$code, ex$offset, ey$code, ey$offset, es$code, es$offset,
                   ew$code, ew$offset, eh$code, eh$offset,
                   frgba, identical(node@orientation, "flat"),
                   g$col, g$lwd, g$alpha, g$stroke,
                   .keys_vec(node, n))
  })
}

S7::method(compile, grob_sector) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x, node@y, node@r0, node@r1)
    ex <- .coord(node@x, "npc", n); ey <- .coord(node@y, "npc", n)
    er0 <- .coord(node@r0, "native", n); er1 <- .coord(node@r1, "native", n)
    th0 <- vctrs::vec_recycle(as.numeric(node@theta0), n)
    th1 <- vctrs::vec_recycle(as.numeric(node@theta1), n)
    # Per-sector fill (like hexagons): explicit `fill`, else gp$fill, else none.
    # col2rgb(alpha=TRUE) -> contiguous RGBA quads; fold the uniform gp$alpha in.
    cols <- node@fill
    if (is.null(cols)) cols <- node@gp@fill
    if (is.null(cols)) cols <- NA
    cols <- rep_len(cols, n)
    cols[is.na(cols)] <- "transparent"
    m <- grDevices::col2rgb(cols, alpha = TRUE)
    a <- node@gp@alpha
    if (!is.null(a) && !is.na(a)) m[4L, ] <- round(m[4L, ] * a)
    frgba <- as.integer(m)
    g <- .gp4(node@gp, scene)
    a <- .encode_arrow(node@arrow)
    sk <- .encode_sketch(node@sketch)
    scene$sectors(ex$value, ey$value, er0$value, er1$value, th0, th1,
                  ex$code, ex$offset, ey$code, ey$offset, er0$code, er0$offset, er1$code, er1$offset, frgba,
                  g$col, g$lwd, g$alpha, g$stroke,
                  a$angle, a$len, a$ends, a$closed,
                  sk$roughness, sk$bowing, sk$fill_style, sk$fill_weight, sk$hachure_angle,
                  sk$hachure_gap, sk$curve_tightness, sk$disable_multi, sk$preserve, sk$seed,
                  .keys_vec(node, n))
  })
}

S7::method(compile, grob_loop) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x, node@y, node@size, node@foot)
    ex <- .coord(node@x, "npc", n); ey <- .coord(node@y, "npc", n)
    es <- .coord(node@size, "mm", n); ef <- .coord(node@foot, "mm", n)
    ang <- vctrs::vec_recycle(as.numeric(node@angle), n)
    wid <- vctrs::vec_recycle(as.numeric(node@width), n)
    g <- .gp4(node@gp, scene)
    a <- .encode_arrow(node@arrow)
    scene$add_loop(ex$value, ey$value, es$value, ef$value, ang, wid,
                   ex$code, ex$offset, ey$code, ey$offset, es$code, es$offset, ef$code, ef$offset,
                   g$col, g$lwd, g$alpha, g$stroke,
                   a$angle, a$len, a$ends, a$closed)
  })
}

S7::method(compile, grob_segments) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x0, node@y0, node@x1, node@y1)
    e0x <- .coord(node@x0, "native", n); e0y <- .coord(node@y0, "native", n)
    e1x <- .coord(node@x1, "native", n); e1y <- .coord(node@y1, "native", n)
    g <- .gp4(node@gp, scene)
    a <- .encode_arrow(node@arrow)
    sc <- .encode_cap(node@start_cap); ec <- .encode_cap(node@end_cap)
    of <- .encode_cap(node@offset)
    sk <- .encode_sketch(node@sketch)
    scene$segments(e0x$value, e0y$value, e1x$value, e1y$value,
                   e0x$code, e0x$offset, e0y$code, e0y$offset, e1x$code, e1x$offset, e1y$code, e1y$offset,
                   sc$value, ec$value, sc$code, ec$code, of$value, of$code,
                   g$col, g$lwd, g$alpha, g$stroke,
                   a$angle, a$len, a$ends, a$closed,
                   sk$roughness, sk$bowing, sk$fill_style, sk$fill_weight, sk$hachure_angle,
                   sk$hachure_gap, sk$curve_tightness, sk$disable_multi, sk$preserve, sk$seed,
                   .keys_vec(node, n))
  })
}

S7::method(compile, grob_path) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x, node@y)
    ex <- .coord(node@x, "native", n); ey <- .coord(node@y, "native", n)
    g <- .gp4(node@gp, scene)
    sk <- .encode_sketch(node@sketch)
    scene$path(ex$value, ey$value, ex$code, ex$offset, ey$code, ey$offset, as.integer(node@nper),
               identical(node@rule, "evenodd"), g$fill, g$col, g$lwd, g$alpha, g$stroke,
               sk$roughness, sk$bowing, sk$fill_style, sk$fill_weight, sk$hachure_angle,
               sk$hachure_gap, sk$curve_tightness, sk$disable_multi, sk$preserve, sk$seed,
               .key1(node))
  })
}

S7::method(compile, grob_raster) <- function(node, scene) {
  .with_vp(node, scene, {
    ex <- .coord(node@x, "npc", 1); ey <- .coord(node@y, "npc", 1)
    ew <- .coord(node@width, "npc", 1); eh <- .coord(node@height, "npc", 1)
    scene$image(node@rgba, node@iw, node@ih,
                ex$value, ey$value, ew$value, eh$value,
                ex$code, ex$offset, ey$code, ey$offset, ew$code, ew$offset, eh$code, eh$offset,
                isTRUE(node@interpolate))
  })
}

S7::method(compile, grob_text) <- function(node, scene) {
  .with_vp(node, scene, {
    hv <- .just_to_hv(node@just)
    # Rich (markdown) labels take the multi-run path: one styled label composed
    # into per-glyph colour/size/baseline, drawn at each position. Plain character
    # labels keep the fast single-style batch path unchanged.
    # Rich labels take the multi-run path: a single `vellum_label` (composed once,
    # drawn at every position) or a list of them (one per datum). Plain character
    # labels keep the fast single-style batch path.
    rich <- S7::S7_inherits(node@label, vellum_label) ||
      (is.list(node@label) && length(node@label) > 0L &&
         all(vapply(node@label, function(l) S7::S7_inherits(l, vellum_label), logical(1))))
    if (rich) {
      n <- vctrs::vec_size_common(node@x, node@y)
      if (n == 0L) return(invisible())
      x <- vctrs::vec_recycle(node@x, n); y <- vctrs::vec_recycle(node@y, n)
      rot <- vctrs::vec_recycle(node@rot, n)
      .draw_richtext_batch(scene, node@label, x, y, hv[1], hv[2], rot,
                           node@gp@fontfamily %||% "", node@gp@fontface %||% "plain",
                           node@gp@fontsize %||% 12, node@gp@col, node@gp@alpha)
      return(invisible())
    }
    labels <- .text_labels(node@label) # seam: rich labels -> strings (plain = identity)
    n <- vctrs::vec_size_common(labels, node@x, node@y)
    if (n == 0L) return(invisible())
    lab <- vctrs::vec_recycle(labels, n)
    x <- vctrs::vec_recycle(node@x, n); y <- vctrs::vec_recycle(node@y, n)
    rot <- vctrs::vec_recycle(node@rot, n)
    # One shaping pass for all labels (repeats shaped once); see .draw_text_batch.
    # `col` is passed through as-is (NULL = inherit the viewport's gp$col, like
    # every other primitive; the root default is black, so plain text stays black).
    .draw_text_batch(scene, lab, x, y, hv[1], hv[2], rot,
                     node@gp@fontfamily %||% "", node@gp@fontface %||% "plain",
                     node@gp@fontsize %||% 12, node@gp@col, node@gp@alpha)
  })
}

S7::method(compile, gtree) <- function(node, scene) {
  .push_vp(scene, node@vp)
  # A named viewport becomes an addressable `<g data-vellum-panel>` in the SVG
  # (a host targets it for pan/zoom); costs nothing on other backends or when
  # unnamed. Bracket the whole subtree, outside any mask/opacity group.
  panel <- .panel_name(node@vp)
  if (!is.null(panel)) scene$begin_panel(panel)
  mask <- if (!is.null(node@vp)) node@vp@mask else NULL
  alpha <- if (!is.null(node@vp)) node@vp@alpha else NULL
  blend <- if (!is.null(node@vp)) node@vp@blend else NULL
  blend_code <- if (is.null(blend)) 0L else .blend_codes[[blend]]
  # Repaint boundary (FW4c): bracket the subtree so the raster backend can cache
  # its sub-raster, keyed on the subtree `nid`. Requires a normal blend (a blend
  # composites against the live backdrop, which a captured transparent layer
  # lacks) and a known nid (a cacheable scene). Ignored by SVG/PDF (they render
  # the subtree as vector). The bracket is outermost, so it captures whatever the
  # subtree draws, including its own mask/opacity group compositing below.
  cached <- !is.null(node@vp) && isTRUE(node@vp@cache) && blend_code == 0L && !is.null(node@nid)
  if (cached) scene$subraster_start(node@nid)
  # A group (isolated layer) is needed for a mask, a sub-1 group opacity, and/or a
  # non-normal blend mode.
  if (!is.null(mask) || (!is.null(alpha) && alpha < 1) || blend_code != 0L) {
    idx <- -1L
    if (!is.null(mask)) {
      m <- .normalize_mask(mask)
      idx <- scene$mask_begin(m$code)      # route mask grobs into the mask
      for (g in m$grobs) compile(g, scene)
      scene$mask_end()
    }
    # mask + opacity + blend installed up front; content drawn into an isolated layer
    scene$group_start(idx, alpha %||% 1, blend_code)
    for (child in node@children) compile(child, scene)
    scene$group_end()
  } else {
    for (child in node@children) compile(child, scene)
  }
  if (cached) scene$subraster_end()
  if (!is.null(panel)) scene$end_panel()
  scene$pop_viewport(1L)
}

# The panel name of a viewport for `data-vellum-panel` emission: its non-empty
# `name`, else NULL (no panel group). NULL vp / unnamed vp -> NULL (no-op). The
# reserved auto-name "root" (the scene's implicit top viewport) is excluded, so a
# plain scene emits no panel group and stays byte-for-byte unchanged; only
# explicitly named viewports (e.g. a grammar's "panel-1-1") become panels.
.panel_name <- function(vp) {
  if (is.null(vp)) return(NULL)
  nm <- vp@name
  if (is.null(nm) || length(nm) == 0L || is.na(nm[[1]]) || !nzchar(nm[[1]])) return(NULL)
  nm <- as.character(nm[[1]])
  if (identical(nm, "root")) return(NULL)
  nm
}

# --- hit-testing ------------------------------------------------------------

#' Hit-test a scene
#'
#' Find the topmost node drawn under a point — the picking primitive the retained
#' scene graph enables (base grid offers only `grid.locator()`). The scene is
#' compiled into a colour pick-buffer (each grob drawn in a colour encoding its
#' id, respecting clipping and paint order), so the result is geometry-, clip- and
#' overlap-exact. Markers and text are matched by their bounding box; lines and
#' segments by a small pick band.
#'
#' @param scene A [vl_scene()].
#' @param x,y Query point, in `units`: `"npc"` (default; the page, `0..1` with y
#'   up) or `"px"` (device pixels, top-left origin, y down).
#' @param units `"npc"` or `"px"`.
#' @return The hit node's `name` (character); `NA_character_` if the topmost grob
#'   there is unnamed; or `NULL` if nothing is drawn at the point.
#' @export
hit_test <- function(scene, x, y, units = c("npc", "px")) {
  units <- match.arg(units)
  s <- Scene$new(.to_inches(scene@width), .to_inches(scene@height), scene@dpi,
                 .rs_col(scene@bg) %||% c(255L, 255L, 255L, 0L))
  reg <- new.env(parent = emptyenv())
  reg$n <- 0L
  reg$names <- list()
  .compile_pick(s, .materialize(scene), reg)
  d <- s$dim()
  if (units == "npc") {
    px <- x * d[1]
    py <- (1 - y) * d[2] # npc y is up; device y is down
  } else {
    px <- x
    py <- y
  }
  id <- s$hit_test(as.integer(round(px)), as.integer(round(py)))
  if (id < 0L) {
    return(NULL)
  }
  reg$names[[id + 1L]] # name, or NA_character_ for an unnamed grob
}

# Compile for picking: like the render compile, but assign each leaf grob a
# sequential pick id (paint order) and record its name, so hit_test can map the
# pick-buffer colour back to a node. Masks are ignored (content is drawn plainly).
.compile_pick <- function(scene, node, reg) {
  if (S7::S7_inherits(node, gtree)) {
    .push_vp(scene, node@vp)
    for (ch in node@children) .compile_pick(scene, ch, reg)
    scene$pop_viewport(1L)
  } else {
    id <- reg$n
    reg$n <- id + 1L
    reg$names[[id + 1L]] <- .node_name(node) %||% NA_character_
    scene$set_pick(id)
    compile(node, scene)
  }
}

# --- editing ----------------------------------------------------------------

#' Inspect and edit a scene by node name
#'
#' `node_names()` lists the names in a scene. `get_node()` returns the first node
#' with a given name. `edit_node()` returns a new scene with that node's
#' properties updated (copy-on-modify).
#'
#' @param scene A [vl_scene()].
#' @param name A node name (set via the `name` argument of a grob/viewport).
#' @param ... Properties to set, e.g. `gp = gpar(col = "red")`.
#' @return `node_names()`: character. `get_node()`: a node. `edit_node()`: a
#'   `vellum_scene`.
#' @export
node_names <- function(scene) {
  root <- .materialize(scene)
  # Recurse returning each subtree's names, concatenated — avoids growing a
  # vector one element at a time via `<<-` (that is O(n^2) over the tree).
  walk <- function(node) {
    nm <- .node_name(node)
    c(if (!is.null(nm)) nm else character(0), unlist(lapply(.node_children(node), walk), use.names = FALSE))
  }
  unlist(lapply(root@children, walk), use.names = FALSE) %||% character(0)
}

#' @rdname node_names
#' @export
get_node <- function(scene, name) {
  root <- .materialize(scene)
  p <- .find_path(root, name)
  if (is.null(p)) cli::cli_abort("No node named {.val {name}}.")
  .get_at(root, p)
}

#' @rdname node_names
#' @export
edit_node <- function(scene, name, ...) {
  # Reuse the memoised materialised tree (same gtree objects, so unchanged
  # subtrees keep their `nid` across the edit -> repaint-boundary cache hits).
  root <- .materialize_cached(scene, .scene_cid(scene))
  p <- .find_path(root, name)
  if (is.null(p)) cli::cli_abort("No node named {.val {name}}.")
  # Return an immutable (materialised) scene; the builder env is untouched. The
  # id lives in `@cid` now that there is no `bstate` carrier (one write).
  S7::set_props(scene,
    root = .modify_at(root, p, function(nd) S7::set_props(nd, ...)),
    bstate = NULL, cid = .new_scene_id())
}

# --- internal helpers -------------------------------------------------------

`%||%` <- function(a, b) if (is.null(a)) b else a

# Backend value encoders: turn R colours / numbers into the form the Rust side
# expects. Shared by the compile path, paint.R, and text.R.

# PERF-7: colour parsing memo. `col2rgb` is called once per drawn grob's col/fill;
# a plot with many same-coloured elements re-parses the same string repeatedly.
# Memoise the (deterministic) parse, keyed by type + value so an integer palette
# index and a same-looking string never collide.
.col_cache <- new.env(parent = emptyenv())
.col2rgba <- function(x) {
  key <- paste0(typeof(x), as.character(x))
  v <- .col_cache[[key]]
  if (is.null(v)) {
    v <- as.integer(grDevices::col2rgb(x, alpha = TRUE)[, 1L])
    .col_cache[[key]] <- v
  }
  v
}

# Concrete colour -> length-4 integer RGBA, or NULL ("no paint" / transparent).
.rs_col <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x)) {
    return(NULL)
  }
  .col2rgba(x)
}

# Tri-state colour encoding for the backend:
#   NULL  -> NULL        (inherit)
#   NA    -> integer(0)  (explicit "no paint")
#   colour-> int[4]      (set)
.rs_col_inh <- function(x) {
  if (is.null(x)) {
    return(NULL)
  }
  if (length(x) != 1L) {
    cli::cli_abort("A colour must be a single value, {.code NA} (none), or {.code NULL} (inherit).")
  }
  if (is.na(x)) {
    return(integer(0))
  }
  .col2rgba(x)
}

# Tri-state numeric encoding: NULL/NA -> NA_real_ (inherit); else the value.
.rs_num_inh <- function(x) {
  if (is.null(x)) {
    return(NA_real_)
  }
  if (length(x) != 1L) {
    cli::cli_abort("{.arg lwd}/{.arg alpha} must be a single number or {.code NULL} (inherit).")
  }
  if (is.na(x)) {
    return(NA_real_)
  }
  as.numeric(x)
}

# Optionally push a grob's own viewport, run `expr`, then pop. Also attaches the
# grob's semantic metadata (id/role/name) to the primitives `expr` emits, so the
# SVG backend can tag them; cleared afterwards so it never leaks to a later node.
.with_vp <- function(node, scene, expr) {
  .set_meta(scene, node)
  has_vp <- !is.null(node@vp)
  panel <- if (has_vp) .panel_name(node@vp) else NULL
  if (has_vp) .push_vp(scene, node@vp)
  if (!is.null(panel)) scene$begin_panel(panel)
  force(expr)
  if (!is.null(panel)) scene$end_panel()
  if (has_vp) scene$pop_viewport(1L)
  scene$set_meta("", "", "")
  invisible()
}

# Push a grob's id/role/name as the metadata for its upcoming primitives.
.set_meta <- function(scene, node) {
  id <- if ("id" %in% S7::prop_names(node)) node@id else NULL
  role <- if ("role" %in% S7::prop_names(node)) node@role else NULL
  scene$set_meta(.meta_str(id), .meta_str(role), .meta_str(.node_name(node)))
}

# A single metadata string for the backend: "" when absent/NA (= no attribute);
# a length->1 value takes its first element (grob-level identity for now).
.meta_str <- function(x) {
  if (is.null(x) || length(x) == 0L) return("")
  x <- x[[1L]]
  if (is.na(x)) "" else as.character(x)
}

# Per-element data keys for a batched grob, aligned to its `n` elements. Returns
# `character(0)` when the grob carries no keys (the backend then emits no
# `data-key`, so a non-interactive scene is byte-for-byte unchanged); otherwise a
# length-`n` character vector with "" for NA/absent entries (no attribute emitted
# for those elements).
.keys_vec <- function(node, n) {
  k <- if ("keys" %in% S7::prop_names(node)) node@keys else NULL
  if (is.null(k)) return(character(0))
  k <- as.character(k)
  k[is.na(k)] <- ""
  rep_len(k, n)
}

# The single data key of a single-element shape grob (path/lines/polygon):
# "" when absent (the backend then emits no `data-key`). Takes the first key.
.key1 <- function(node) {
  k <- if ("keys" %in% S7::prop_names(node)) node@keys else NULL
  if (is.null(k) || length(k) == 0L) return("")
  k <- as.character(k[[1L]])
  if (is.na(k)) "" else k
}

# Encode a gpar's drawing fields for the backend. `fill` may be a colour, a
# gradient, or a pattern (see .encode_paint; patterns need `scene`); `stroke`
# bundles lty/lineend/linejoin/linemitre (or NULL = inherit all).
.gp4 <- function(gp, scene = NULL) {
  list(fill = .encode_paint(gp@fill, scene), col = .rs_col_inh(gp@col),
       lwd = .rs_num_inh(gp@lwd), alpha = .rs_num_inh(gp@alpha),
       stroke = .encode_stroke(gp))
}

.push_vp <- function(scene, vp) {
  cx <- .coord(vp@x, "npc", 1); cy <- .coord(vp@y, "npc", 1)
  cw <- .coord(vp@width, "npc", 1); ch <- .coord(vp@height, "npc", 1)
  lrow <- if (is.null(vp@row)) -1L else as.integer(vp@row) - 1L
  lcol <- if (is.null(vp@col)) -1L else as.integer(vp@col) - 1L
  # clip may be TRUE/FALSE (rect) or a path-like grob (arbitrary clip path).
  clip_grob <- if (S7::S7_inherits(vp@clip, grob)) vp@clip else NULL
  clip_flag <- if (is.null(clip_grob)) isTRUE(vp@clip) else TRUE
  vid <- scene$push_viewport(
    cx$value, cy$value, cw$value, ch$value,
    cx$code, cx$offset, cy$code, cy$offset, cw$code, cw$offset, ch$code, ch$offset,
    as.numeric(vp@xscale), as.numeric(vp@yscale), vp@angle, clip_flag,
    lrow, lcol, vp@rowspan, vp@colspan,
    .encode_paint(vp@gp@fill, scene), .rs_col_inh(vp@gp@col), .rs_num_inh(vp@gp@lwd), .rs_num_inh(vp@gp@alpha),
    .encode_stroke(vp@gp)
  )
  # Debug capture: record this viewport's backend id, name, and node for the
  # layout-debug overlay / why_size() (only active during a debug render).
  if (!is.null(.debug_state$reg)) {
    reg <- .debug_state$reg
    reg$items[[length(reg$items) + 1L]] <- list(id = vid, name = vp@name, vp = vp)
  }
  if (!is.null(clip_grob)) {
    cp <- .clip_path_of(clip_grob)
    scene$set_clip_path(cp$x, cp$y, cp$xcode, cp$xoff, cp$ycode, cp$yoff, cp$nper, cp$evenodd)
  }
  if (!is.null(vp@layout)) .set_layout(scene, vp@layout)
}

# Extract clip-path coordinates (in the viewport's coordinate system) from a
# polygon or path grob.
.clip_path_of <- function(g) {
  if (S7::S7_inherits(g, grob_path)) {
    ex <- .coord(g@x, "native"); ey <- .coord(g@y, "native")
    list(x = ex$value, y = ey$value, xcode = ex$code, xoff = ex$offset,
         ycode = ey$code, yoff = ey$offset,
         nper = as.integer(g@nper), evenodd = identical(g@rule, "evenodd"))
  } else if (S7::S7_inherits(g, grob_polygon)) {
    n <- vctrs::vec_size_common(g@x, g@y)
    ex <- .coord(g@x, "native", n); ey <- .coord(g@y, "native", n)
    list(x = ex$value, y = ey$value, xcode = ex$code, xoff = ex$offset,
         ycode = ey$code, yoff = ey$offset,
         nper = as.integer(n), evenodd = FALSE)
  } else {
    cli::cli_abort("A viewport {.arg clip} grob must be a {.fn polygon_grob} or {.fn path_grob}.")
  }
}

.set_layout <- function(scene, layout) {
  scene$set_layout(
    vctrs::field(layout@widths, "value"), .code_names(layout@widths),
    vctrs::field(layout@heights, "value"), .code_names(layout@heights),
    isTRUE(layout@respect)
  )
}

.code_names <- function(u) {
  names(.unit_codes)[match(vctrs::field(u, "unit"), .unit_codes)]
}

.as_size <- function(x) if (is_unit(x)) x else unit(x, "in")

.to_inches <- function(u) {
  v <- vctrs::field(u, "value")[1]
  switch(as.character(vctrs::field(u, "unit")[1]),
    "2" = v / 25.4, # mm
    "3" = v,        # in
    "4" = v / 72,   # pt
    cli::cli_abort("Page size must be an absolute unit (in/mm/pt).")
  )
}

.just_to_hv <- function(just) {
  hmap <- c(left = 0, centre = 0.5, center = 0.5, right = 1)
  vmap <- c(bottom = 0, centre = 0.5, center = 0.5, top = 1)
  # A single vertical-only name ("top"/"bottom") sets vjust and centres h; a single
  # horizontal-only name sets hjust and centres v (grid's single-`just` semantics).
  if (length(just) == 1L && is.character(just)) {
    if (just %in% c("top", "bottom")) {
      return(c(0.5, .just1(just, vmap)))
    }
    if (just %in% c("left", "right")) {
      return(c(.just1(just, hmap), 0.5))
    }
  }
  h <- .just1(just[1], hmap)
  v <- if (length(just) > 1) .just1(just[2], vmap) else 0.5
  c(h, v)
}
.just1 <- function(j, map) {
  if (j %in% names(map)) {
    return(unname(map[j]))
  }
  v <- suppressWarnings(as.numeric(j))
  if (is.na(v)) {
    cli::cli_abort("Invalid {.arg just} value {.val {j}}; use {.or {names(map)}} or a number in [0, 1].")
  }
  v
}

# Tree navigation over the immutable gtree.
.node_children <- function(node) if (S7::S7_inherits(node, gtree)) node@children else list()
.node_name <- function(node) {
  if (S7::S7_inherits(node, grob) && "name" %in% S7::prop_names(node)) node@name else NULL
}

.get_at <- function(node, path) {
  if (length(path) == 0L) return(node)
  .get_at(node@children[[path[[1]]]], path[-1])
}
.modify_at <- function(node, path, f) {
  if (length(path) == 0L) return(.restamp_nid(f(node)))
  i <- path[[1]]
  node@children[[i]] <- .modify_at(node@children[[i]], path[-1], f)
  # Re-stamp every rebuilt gtree on the path (its subtree content changed), so a
  # cached repaint boundary on/above the edit invalidates while unchanged
  # off-path siblings keep their `nid` (structural sharing) and stay cached.
  .restamp_nid(node)
}
.restamp_nid <- function(node) {
  if (S7::S7_inherits(node, gtree)) node@nid <- .new_scene_id()
  node
}
.find_path <- function(node, name) {
  if (identical(.node_name(node), name)) return(integer(0))
  ch <- .node_children(node)
  for (i in seq_along(ch)) {
    p <- .find_path(ch[[i]], name)
    if (!is.null(p)) return(c(i, p))
  }
  NULL
}
