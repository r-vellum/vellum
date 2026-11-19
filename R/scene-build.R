#' @include grob-class.R viewport.R gpar.R
NULL

# --- containers -------------------------------------------------------------

# A named subtree: its own viewport plus ordered children (grobs / gtrees).
# `nid` is a per-subtree content-identity token (see `.new_scene_id`) used by the
# repaint-boundary sub-raster cache (FW4c): it is stamped at materialisation and
# re-stamped for every node on an `edit_node` path, so an unchanged subtree keeps
# its `nid` across an edit (structural sharing) while a changed one gets a fresh
# one. `NULL` -> the subtree is not sub-raster-cacheable.
gtree <- S7::new_class(
  "gtree",
  parent = grob,
  package = "vellum",
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
  "vellum_scene",
  package = "vellum",
  properties = list(
    width = S7::new_property(
      S7::new_S3_class("vellum_unit"),
      default = quote(vl_unit(6, "in"))
    ),
    height = S7::new_property(
      S7::new_S3_class("vellum_unit"),
      default = quote(vl_unit(4, "in"))
    ),
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
  for (j in seq_len(lim)) {
    if (identical(.bnode_kid(parent, j), child)) return(j)
  }
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
  # One `mget()` beats `cap` R-level `get()`s (~35ms vs ~8ms at 20k children).
  children <- if (cap) {
    mget(as.character(seq_len(cap)), envir = node$kids)
  } else {
    list()
  }
  names(children) <- NULL
  for (i in seq_len(cap)) {
    ch <- children[[i]]
    if (.is_bnode(ch)) {
      nd <- if (!is.null(nextnode) && identical(ch, nextnode)) {
        depth + 1L
      } else {
        NA_integer_
      }
      children[[i]] <- .bnode_to_gtree(ch, open, ocount, nd)
    }
  }
  # Stamp a per-subtree identity token (FW4c). Memoised with the tree by
  # `.materialize_cached`, so it is stable across renders at a fixed scene cid.
  gtree(
    name = node$vp@name,
    vp = node$vp,
    children = children,
    nid = .new_scene_id()
  )
}
# Reopen an immutable gtree into a build tree (for drawing after edit/render).
# One `list2env()` beats a `.bnode_add()` per child, and the recursion test is an
# attribute read rather than `S7_inherits()` (~3us/child, which was most of the
# cost): ~110ms -> ~12ms at 20k children. Only a gtree carries `children`.
.gtree_to_bnode <- function(g) {
  node <- .bnode(vp = attr(g, "vp", exact = TRUE))
  ch <- attr(g, "children", exact = TRUE)
  n <- length(ch)
  if (n) {
    for (i in seq_len(n)) {
      if (!is.null(attr(ch[[i]], "children", exact = TRUE))) {
        ch[[i]] <- .gtree_to_bnode(ch[[i]])
      }
    }
    names(ch) <- as.character(seq_len(n))
    node$kids <- list2env(
      ch,
      envir = new.env(parent = emptyenv(), hash = TRUE, size = n)
    )
    node$n <- n
  }
  node
}

# A fresh build-state list: a root build node, its open stack, the per-node view
# counts, and the ownership generation. `owner_gen` is stamped on the build node.
.bstate_new <- function(build, open, ocount, gen) {
  build$owner_gen <- gen
  list(
    build = build,
    open = open,
    ocount = ocount,
    gen = gen,
    cid = .new_scene_id()
  )
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
    return(gtree(
      name = "root",
      vp = vl_viewport(name = "root"),
      children = list()
    ))
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
    function(i) {
      .bnode_index_of(bs$open[[i]], bs$open[[i + 1L]], bs$ocount[[i]])
    },
    integer(1)
  )
  root <- .gtree_to_bnode(.materialize(scene)) # deep copy of this scene's view
  open <- vector("list", length(idx) + 1L)
  open[[1L]] <- root
  for (j in seq_along(idx)) {
    open[[j + 1L]] <- .bnode_kid(open[[j]], idx[[j]])
  }
  scene@root <- NULL
  scene@bstate <- .bstate_new(
    root,
    open,
    vapply(open, function(b) b$n, integer(1)),
    0
  )
  scene
}

# Put the scene into building mode and guarantee it owns its build tree (forking
# a stale handle first). All mutating ops (push/draw/pop) go through this; it
# returns a scene whose `@bstate` is present and owned.
.ensure_building <- function(scene) {
  bs <- scene@bstate
  if (is.null(bs)) {
    # materialised -> reopen a fresh, owned build tree
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
#' @param width,height Page size ([vl_unit()] or numeric inches).
#' @param dpi Resolution in dots per inch.
#' @param bg Background colour (or `NA` for transparent).
#' @param gp Page-level graphical parameters ([vl_gpar()]) carried by the root
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
#'   push(vl_viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
#'   draw(rect_grob(gp = vl_gpar(fill = "grey95", col = "grey50"))) |>
#'   draw(lines_grob(x = vl_unit(0:10, "native"), y = vl_unit(0:10, "native"),
#'                   gp = vl_gpar(col = "steelblue", lwd = 2)))
#' @export
vl_scene <- function(
  width = 6,
  height = 4,
  dpi = 96,
  bg = "white",
  gp = vl_gpar(),
  xscale = c(0, 1),
  yscale = c(0, 1),
  clip = FALSE,
  title = NULL,
  desc = NULL
) {
  root <- .bnode(
    vp = vl_viewport(
      name = "root",
      gp = gp,
      xscale = xscale,
      yscale = yscale,
      clip = clip
    )
  )
  vellum_scene(
    width = .as_size(width),
    height = .as_size(height),
    dpi = dpi,
    bg = bg,
    root = NULL,
    bstate = .bstate_new(root, list(root), 0L, 0),
    title = title,
    desc = desc,
    a11y_prefix = .new_a11y_prefix()
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
#'   draw(points_grob(c(0.3, 0.7), 0.5, gp = vl_gpar(fill = "red"))) |>
#'   describe(title = "Two red dots", desc = "Two red points on a white field.")
#' @export
describe <- function(scene, title = NULL, desc = NULL) {
  scene <- as_vellum_scene(scene)
  # A new content-identity so the render cache recompiles with the new metadata.
  S7::set_props(
    scene,
    title = title,
    desc = desc,
    a11y_prefix = scene@a11y_prefix %||% .new_a11y_prefix(),
    cid = .new_scene_id()
  )
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
#' @param vp A [vl_viewport()].
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
  # A plain list of grobs draws as if each had been passed in turn. Several
  # constructors naturally produce one grob per piece -- `contour_grob()` returns
  # one polyline per contour -- and without this the list is appended as a single
  # child that nothing can compile, which fails later and further away.
  # (`S7_inherits(x)` with no class asks "is this any S7 object" — naming the
  # `grob` class here would resolve to this function's argument.)
  if (is.list(grob) && !S7::S7_inherits(grob)) {
    for (g in grob) {
      .bnode_add(cur, g)
    }
  } else {
    .bnode_add(cur, grob) # O(1) env append
  }
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
