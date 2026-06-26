#' @include grob.R viewport.R gpar.R
NULL

# --- containers -------------------------------------------------------------

# A named subtree: its own viewport plus ordered children (grobs / gtrees).
gtree <- S7::new_class(
  "gtree", parent = grob, package = "vellum",
  properties = list(
    vp = S7::new_property(S7::class_any, default = NULL),
    children = S7::new_property(S7::class_list, default = list())
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
    bstate = S7::new_property(S7::class_any, default = NULL)
  )
)

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
  gtree(name = node$vp@name, vp = node$vp, children = children)
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
  list(build = build, open = open, ocount = ocount, gen = gen)
}

# The immutable root gtree for a scene's view (materialising the build tree if
# needed), honouring this scene's per-open-node child counts (`ocount`).
.materialize <- function(scene) {
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
#' @return `vl_scene()`, `push()`, `draw()`, `pop()`: a `vellum_scene`.
#' @examples
#' s <- vl_scene(width = 4, height = 3) |>
#'   push(viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
#'   draw(rect_grob(gp = gpar(fill = "grey95", col = "grey50"))) |>
#'   draw(lines_grob(x = unit(0:10, "native"), y = unit(0:10, "native"),
#'                   gp = gpar(col = "steelblue", lwd = 2)))
#' @export
vl_scene <- function(width = 6, height = 4, dpi = 96, bg = "white",
                     gp = gpar(), xscale = c(0, 1), yscale = c(0, 1), clip = FALSE) {
  root <- .bnode(vp = viewport(name = "root", gp = gp, xscale = xscale, yscale = yscale, clip = clip))
  vellum_scene(
    width = .as_size(width), height = .as_size(height), dpi = dpi, bg = bg,
    root = NULL, bstate = .bstate_new(root, list(root), 0L, 0)
  )
}

# Bump the ownership generation on `bs` (in place on the shared build node) and
# return the updated bstate list. The single per-op S7 write is `@bstate <-`.
.bstate_claim <- function(bs) {
  g <- bs$build$owner_gen + 1
  bs$build$owner_gen <- g
  bs$gen <- g
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
  scene <- .ensure_building(scene)
  bs <- scene@bstate
  k <- length(bs$open)
  keep <- max(1L, k - max(0L, as.integer(n))) # never pop the root; ignore n < 0
  bs$open <- bs$open[seq_len(keep)]
  bs$ocount <- bs$ocount[seq_len(keep)]
  scene@bstate <- .bstate_claim(bs)
  scene
}

#' @rdname vl_scene
#' @param path Output file path; the format is taken from the extension (`.png`,
#'   `.svg`, or `.pdf`).
#' @param text For SVG output, how text is written: `"native"` (default) emits
#'   selectable `<text>` referencing system fonts, `"outline"` emits glyph
#'   outlines (pixel-faithful, identical to the raster/PDF backends, but not
#'   selectable). Ignored for PNG/PDF.
#' @return `render()`: `path`, invisibly.
#' @export
render <- function(scene, path, text = c("native", "outline")) {
  text <- match.arg(text)
  s <- .scene_to_backend(scene)
  ext <- tolower(tools::file_ext(path))
  switch(ext,
    png = s$render_png(path),
    svg = s$render_svg(path, identical(text, "outline")),
    pdf = s$render_pdf(path),
    cli::cli_abort("Unsupported output format {.val {ext}}; use .png, .svg, or .pdf.")
  )
  invisible(path)
}

# Render-result cache (FW4). A vellum_scene is immutable (every push/draw/pop
# returns a new object), and the compiled backend `Scene` is logically immutable
# once built — only an internal pixmap cache mutates, and the vector backends read
# it without mutation. So a compiled Scene can be shared across repeated renders /
# inspections of the same content. We key on a content hash of the materialized
# tree (+ device fields): two structurally identical scenes share one compile and,
# via the backend's pixmap cache, one rasterization. A crude size cap bounds memory
# (each entry may hold one page-sized pixmap once rasterized).
.scene_cache <- new.env(parent = emptyenv())
.scene_cache$.n <- 0L
.SCENE_CACHE_CAP <- 32L

# Compile an immutable scene onto a backend `Scene`, reusing a cached compile when
# the same content was rendered before.
.scene_to_backend <- function(scene) {
  tree <- .materialize(scene)
  key <- rlang::hash(list(tree, scene@width, scene@height, scene@dpi, scene@bg))
  hit <- .scene_cache[[key]]
  if (!is.null(hit)) {
    return(hit)
  }
  if (.scene_cache$.n > .SCENE_CACHE_CAP) { # memory backstop: drop everything
    rm(list = setdiff(ls(.scene_cache, all.names = TRUE), ".n"), envir = .scene_cache)
    .scene_cache$.n <- 0L
  }
  s <- Scene$new(.to_inches(scene@width), .to_inches(scene@height), scene@dpi,
                 .rs_col(scene@bg) %||% c(255L, 255L, 255L, 0L))
  # Compile the root as a gtree so the root viewport's gp / scales / clip / layout
  # / mask all apply (it is pushed like any viewport), not just its layout.
  compile(tree, s)
  .scene_cache[[key]] <- s
  .scene_cache$.n <- .scene_cache$.n + 1L
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
    # One batched call (one shared gpar) instead of a per-element FFI loop.
    scene$rects(ex$value, ey$value, ew$value, eh$value,
                ex$code, ey$code, ew$code, eh$code, g$fill, g$col, g$lwd, g$alpha, g$stroke)
  })
}

S7::method(compile, grob_lines) <- function(node, scene) {
  .with_vp(node, scene, {
    ex <- .coord(node@x); ey <- .coord(node@y); g <- .gp4(node@gp, scene)
    a <- .encode_arrow(node@arrow)
    scene$lines(ex$value, ey$value, ex$code, ey$code, g$col, g$lwd, g$alpha, g$stroke,
                a$angle, a$len, a$ends, a$closed)
  })
}

S7::method(compile, grob_polygon) <- function(node, scene) {
  .with_vp(node, scene, {
    ex <- .coord(node@x); ey <- .coord(node@y); g <- .gp4(node@gp, scene)
    scene$polygon(ex$value, ey$value, ex$code, ey$code, g$fill, g$col, g$lwd, g$alpha, g$stroke)
  })
}

# circles and points compile identically (a batched circle draw); they differ
# only in where the radius comes from and its default unit (npc vs mm).
.compile_circles <- function(node, scene, radius, rdefault) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x, node@y, radius)
    ex <- .coord(node@x, "npc", n); ey <- .coord(node@y, "npc", n)
    er <- .coord(radius, rdefault, n)
    g <- .gp4(node@gp, scene)
    scene$circles(ex$value, ey$value, er$value, ex$code, ey$code, er$code,
                  g$fill, g$col, g$lwd, g$alpha, g$stroke)
  })
}

S7::method(compile, grob_circle) <- function(node, scene) {
  .compile_circles(node, scene, node@r, "npc")
}

S7::method(compile, grob_points) <- function(node, scene) {
  codes <- unname(.marker_codes[node@shape])
  if (all(codes == 0L)) {
    # All circles: the batched circle path (radius carries marker size, sprite
    # fast-path for dense clouds).
    .compile_circles(node, scene, node@size, "mm")
  } else {
    .with_vp(node, scene, {
      n <- vctrs::vec_size_common(node@x, node@y, node@size)
      ex <- .coord(node@x, "npc", n); ey <- .coord(node@y, "npc", n); es <- .coord(node@size, "mm", n)
      g <- .gp4(node@gp, scene)
      scene$markers(ex$value, ey$value, es$value, ex$code, ey$code, es$code,
                    vctrs::vec_recycle(as.integer(codes), n),
                    g$fill, g$col, g$lwd, g$alpha, g$stroke)
    })
  }
}

S7::method(compile, grob_segments) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x0, node@y0, node@x1, node@y1)
    e0x <- .coord(node@x0, "native", n); e0y <- .coord(node@y0, "native", n)
    e1x <- .coord(node@x1, "native", n); e1y <- .coord(node@y1, "native", n)
    g <- .gp4(node@gp, scene)
    a <- .encode_arrow(node@arrow)
    scene$segments(e0x$value, e0y$value, e1x$value, e1y$value,
                   e0x$code, e0y$code, e1x$code, e1y$code, g$col, g$lwd, g$alpha, g$stroke,
                   a$angle, a$len, a$ends, a$closed)
  })
}

S7::method(compile, grob_path) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x, node@y)
    ex <- .coord(node@x, "native", n); ey <- .coord(node@y, "native", n)
    g <- .gp4(node@gp, scene)
    scene$path(ex$value, ey$value, ex$code, ey$code, as.integer(node@nper),
               identical(node@rule, "evenodd"), g$fill, g$col, g$lwd, g$alpha, g$stroke)
  })
}

S7::method(compile, grob_raster) <- function(node, scene) {
  .with_vp(node, scene, {
    ex <- .coord(node@x, "npc", 1); ey <- .coord(node@y, "npc", 1)
    ew <- .coord(node@width, "npc", 1); eh <- .coord(node@height, "npc", 1)
    scene$image(node@rgba, node@iw, node@ih,
                ex$value, ey$value, ew$value, eh$value,
                ex$code, ey$code, ew$code, eh$code, isTRUE(node@interpolate))
  })
}

S7::method(compile, grob_text) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@label, node@x, node@y)
    if (n == 0L) return(invisible())
    lab <- vctrs::vec_recycle(node@label, n)
    x <- vctrs::vec_recycle(node@x, n); y <- vctrs::vec_recycle(node@y, n)
    rot <- vctrs::vec_recycle(node@rot, n)
    hv <- .just_to_hv(node@just)
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
  mask <- if (!is.null(node@vp)) node@vp@mask else NULL
  if (!is.null(mask)) {
    m <- .normalize_mask(mask)
    idx <- scene$mask_begin(m$code)        # route mask grobs into the mask
    for (g in m$grobs) compile(g, scene)
    scene$mask_end()
    scene$group_start(idx)                 # mask installed up front; content is isolated
    for (child in node@children) compile(child, scene)
    scene$group_end()
  } else {
    for (child in node@children) compile(child, scene)
  }
  scene$pop_viewport(1L)
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
  root <- .materialize(scene)
  p <- .find_path(root, name)
  if (is.null(p)) cli::cli_abort("No node named {.val {name}}.")
  # Return an immutable (materialised) scene; the builder env is untouched.
  scene@root <- .modify_at(root, p, function(nd) S7::set_props(nd, ...))
  scene@bstate <- NULL
  scene
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
    stop("a colour must be a single value, `NA` (none), or `NULL` (inherit)", call. = FALSE)
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
    stop("`lwd`/`alpha` must be a single number or `NULL` (inherit)", call. = FALSE)
  }
  if (is.na(x)) {
    return(NA_real_)
  }
  as.numeric(x)
}

# Optionally push a grob's own viewport, run `expr`, then pop.
.with_vp <- function(node, scene, expr) {
  has_vp <- !is.null(node@vp)
  if (has_vp) .push_vp(scene, node@vp)
  force(expr)
  if (has_vp) scene$pop_viewport(1L)
  invisible()
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
  scene$push_viewport(
    cx$value, cy$value, cw$value, ch$value, cx$code, cy$code, cw$code, ch$code,
    as.numeric(vp@xscale), as.numeric(vp@yscale), vp@angle, clip_flag,
    lrow, lcol, vp@rowspan, vp@colspan,
    .encode_paint(vp@gp@fill, scene), .rs_col_inh(vp@gp@col), .rs_num_inh(vp@gp@lwd), .rs_num_inh(vp@gp@alpha),
    .encode_stroke(vp@gp)
  )
  if (!is.null(clip_grob)) {
    cp <- .clip_path_of(clip_grob)
    scene$set_clip_path(cp$x, cp$y, cp$xcode, cp$ycode, cp$nper, cp$evenodd)
  }
  if (!is.null(vp@layout)) .set_layout(scene, vp@layout)
}

# Extract clip-path coordinates (in the viewport's coordinate system) from a
# polygon or path grob.
.clip_path_of <- function(g) {
  if (S7::S7_inherits(g, grob_path)) {
    ex <- .coord(g@x, "native"); ey <- .coord(g@y, "native")
    list(x = ex$value, y = ey$value, xcode = ex$code, ycode = ey$code,
         nper = as.integer(g@nper), evenodd = identical(g@rule, "evenodd"))
  } else if (S7::S7_inherits(g, grob_polygon)) {
    n <- vctrs::vec_size_common(g@x, g@y)
    ex <- .coord(g@x, "native", n); ey <- .coord(g@y, "native", n)
    list(x = ex$value, y = ey$value, xcode = ex$code, ycode = ey$code,
         nper = as.integer(n), evenodd = FALSE)
  } else {
    cli::cli_abort("A viewport {.arg clip} grob must be a {.fn polygon_grob} or {.fn path_grob}.")
  }
}

.set_layout <- function(scene, layout) {
  scene$set_layout(
    vctrs::field(layout@widths, "value"), .code_names(layout@widths),
    vctrs::field(layout@heights, "value"), .code_names(layout@heights)
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
  if (length(path) == 0L) return(f(node))
  i <- path[[1]]
  node@children[[i]] <- .modify_at(node@children[[i]], path[-1], f)
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
