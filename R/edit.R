# --- editing ----------------------------------------------------------------

#' Inspect and edit a scene by node name
#'
#' `node_names()` lists the names in a scene. `get_node()` returns the first node
#' with a given name. `edit_node()` returns a new scene with that node's
#' properties updated (copy-on-modify).
#'
#' @param scene A [vl_scene()] (or anything with an [as_vellum_scene()] method).
#' @param name A node name (set via the `name` argument of a grob/viewport).
#' @param ... Properties to set, e.g. `gp = vl_gpar(col = "red")`.
#' @return `node_names()`: character. `get_node()`: a node. `edit_node()`: a
#'   `vellum_scene`.
#' @export
node_names <- function(scene) {
  root <- .materialize(as_vellum_scene(scene))
  # Recurse returning each subtree's names, concatenated — avoids growing a
  # vector one element at a time via `<<-` (that is O(n^2) over the tree).
  walk <- function(node) {
    nm <- .node_name(node)
    c(
      if (!is.null(nm)) nm else character(0),
      unlist(lapply(.node_children(node), walk), use.names = FALSE)
    )
  }
  unlist(lapply(root@children, walk), use.names = FALSE) %||% character(0)
}

#' @rdname node_names
#' @export
get_node <- function(scene, name) {
  root <- .materialize(as_vellum_scene(scene))
  p <- .find_path(root, name)
  if (is.null(p)) {
    cli::cli_abort("No node named {.val {name}}.")
  }
  .get_at(root, p)
}

#' @rdname node_names
#' @export
edit_node <- function(scene, name, ...) {
  scene <- as_vellum_scene(scene)
  # Reuse the memoised materialised tree (same gtree objects, so unchanged
  # subtrees keep their `nid` across the edit -> repaint-boundary cache hits).
  root <- .materialize_cached(scene, .scene_cid(scene))
  p <- .find_path(root, name)
  if (is.null(p)) {
    cli::cli_abort("No node named {.val {name}}.")
  }
  # Return an immutable (materialised) scene; the builder env is untouched.
  .scene_with_root(
    scene,
    .modify_at(root, p, function(nd) S7::set_props(nd, ...))
  )
}

# Derive a scene value carrying a new tree, by *rebuilding* it rather than
# writing into it. Same reason as `.modify_at()`: `S7::set_props(scene, root =)`
# has to duplicate the old scene first, and duplicating it deep-copies the tree
# hanging off its `root` attribute — O(nodes), ~130ms on a 20k-grob scene, where
# constructing a fresh scene just stores the pointer. The id lives in `@cid` now
# that there is no `bstate` carrier.
.scene_with_root <- function(scene, root) {
  vellum_scene(
    width = attr(scene, "width", exact = TRUE),
    height = attr(scene, "height", exact = TRUE),
    dpi = attr(scene, "dpi", exact = TRUE),
    bg = attr(scene, "bg", exact = TRUE),
    root = root,
    bstate = NULL,
    cid = .new_scene_id(),
    title = attr(scene, "title", exact = TRUE),
    desc = attr(scene, "desc", exact = TRUE),
    a11y_prefix = attr(scene, "a11y_prefix", exact = TRUE)
  )
}

# Tree navigation over the immutable gtree. S7 stores properties as attributes,
# so these read them directly: `S7_inherits()` + `prop_names()` + `@` costs ~5us
# per node, which is the whole cost of a `.find_path()` walk over a large tree
# (~120ms at 20k nodes vs ~12ms here). Only a gtree carries `children`, and only
# a grob carries `name`, so the attribute read is the type test.
.node_children <- function(node) {
  attr(node, "children", exact = TRUE) %||% list()
}
.node_name <- function(node) attr(node, "name", exact = TRUE)

.get_at <- function(node, path) {
  if (length(path) == 0L) {
    return(node)
  }
  .get_at(node@children[[path[[1]]]], path[-1])
}
# Rebuild the gtrees on `path` around an edited node. Each is built *fresh* from
# its own properties rather than written into with `node@children[[i]] <- ...`:
# assigning a new list into an existing S7 object makes R duplicate that object,
# and duplicating it deep-copies the whole children list (every sibling grob).
# That made an edit O(siblings) — ~125ms on a 20k-grob parent — where
# constructing a new node just stores the pointer (~0.3ms, O(depth)). Every gtree
# property must be carried over here; `test-edit.R` fails if one is dropped.
# The re-stamped `nid` marks the subtree content as changed, so a cached repaint
# boundary on/above the edit invalidates while unchanged off-path siblings keep
# their `nid` (structural sharing) and stay cached.
.modify_at <- function(node, path, f) {
  if (length(path) == 0L) {
    return(.restamp_nid(f(node)))
  }
  i <- path[[1]]
  kids <- attr(node, "children", exact = TRUE)
  kids[[i]] <- .modify_at(kids[[i]], path[-1], f)
  gtree(
    name = attr(node, "name", exact = TRUE),
    gp = attr(node, "gp", exact = TRUE),
    vp = attr(node, "vp", exact = TRUE),
    id = attr(node, "id", exact = TRUE),
    role = attr(node, "role", exact = TRUE),
    keys = attr(node, "keys", exact = TRUE),
    meta = attr(node, "meta", exact = TRUE),
    children = kids,
    nid = .new_scene_id()
  )
}
.restamp_nid <- function(node) {
  if (S7::S7_inherits(node, gtree)) {
    node@nid <- .new_scene_id()
  }
  node
}
.find_path <- function(node, name) {
  if (identical(.node_name(node), name)) {
    return(integer(0))
  }
  ch <- .node_children(node)
  for (i in seq_along(ch)) {
    p <- .find_path(ch[[i]], name)
    if (!is.null(p)) return(c(i, p))
  }
  NULL
}
