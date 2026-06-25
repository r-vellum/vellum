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

# A drawing scene: page size + background + a root gtree, plus the builder's
# focus (an integer path into the root's descendants).
vellum_scene <- S7::new_class(
  "vellum_scene", package = "vellum",
  properties = list(
    width  = S7::new_property(S7::new_S3_class("vellum_unit"), default = quote(unit(6, "in"))),
    height = S7::new_property(S7::new_S3_class("vellum_unit"), default = quote(unit(4, "in"))),
    dpi = S7::new_property(S7::class_double, default = 96),
    bg = S7::new_property(S7::class_any, default = "white"),
    root = S7::new_property(S7::class_any, default = NULL),
    focus = S7::new_property(S7::class_integer, default = integer(0))
  )
)

# --- scene construction + functional builder --------------------------------

#' Build and render a scene
#'
#' `vl_scene()` creates an empty scene. [push()] adds a viewport (and descends
#' into it), [draw()] adds a grob, [pop()] ascends. All return a new scene value
#' (the scene is immutable). [render()] compiles the scene and writes a PNG.
#'
#' @param width,height Page size ([unit()] or numeric inches).
#' @param dpi Resolution in dots per inch.
#' @param bg Background colour (or `NA` for transparent).
#' @return `vl_scene()`, `push()`, `draw()`, `pop()`: a `vellum_scene`.
#' @examples
#' s <- vl_scene(width = 4, height = 3) |>
#'   push(viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
#'   draw(rect_grob(gp = gpar(fill = "grey95", col = "grey50"))) |>
#'   draw(lines_grob(x = unit(0:10, "native"), y = unit(0:10, "native"),
#'                   gp = gpar(col = "steelblue", lwd = 2)))
#' @export
vl_scene <- function(width = 6, height = 4, dpi = 96, bg = "white") {
  vellum_scene(
    width = .as_size(width), height = .as_size(height), dpi = dpi, bg = bg,
    root = gtree(name = "root", vp = viewport(name = "root"), children = list()),
    focus = integer(0)
  )
}

#' @rdname vl_scene
#' @param scene A [vl_scene()].
#' @param vp A [viewport()].
#' @export
push <- function(scene, vp) {
  node <- gtree(name = vp@name, vp = vp, children = list())
  focus <- scene@focus
  here <- .get_at(scene@root, focus)
  new_idx <- length(here@children) + 1L
  scene@root <- .modify_at(scene@root, focus, function(nd) {
    nd@children <- c(nd@children, list(node))
    nd
  })
  scene@focus <- c(focus, new_idx)
  scene
}

#' @rdname vl_scene
#' @param grob A grob (see [grob]).
#' @export
draw <- function(scene, grob) {
  scene@root <- .modify_at(scene@root, scene@focus, function(nd) {
    nd@children <- c(nd@children, list(grob))
    nd
  })
  scene
}

#' @rdname vl_scene
#' @param n Number of viewport levels to ascend.
#' @export
pop <- function(scene, n = 1) {
  k <- length(scene@focus)
  scene@focus <- utils::head(scene@focus, max(0L, k - as.integer(n)))
  scene
}

#' @rdname vl_scene
#' @param path Output PNG file path.
#' @return `render()`: `path`, invisibly.
#' @export
render <- function(scene, path) {
  s <- .scene_to_backend(scene)
  ext <- tolower(tools::file_ext(path))
  switch(ext,
    png = s$render_png(path),
    svg = s$render_svg(path),
    pdf = s$render_pdf(path),
    cli::cli_abort("Unsupported output format {.val {ext}}; use .png, .svg, or .pdf.")
  )
  invisible(path)
}

# Compile an immutable scene onto a fresh backend `Scene` (write-only target).
.scene_to_backend <- function(scene) {
  s <- Scene$new(.to_inches(scene@width), .to_inches(scene@height), scene@dpi,
                 .rs_col(scene@bg) %||% c(255L, 255L, 255L, 0L))
  root <- scene@root
  if (!is.null(root@vp) && !is.null(root@vp@layout)) {
    .set_layout(s, root@vp@layout)
  }
  for (child in root@children) compile(child, s)
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
    scene$lines(ex$value, ey$value, ex$code, ey$code, g$col, g$lwd, g$alpha, g$stroke)
  })
}

S7::method(compile, grob_polygon) <- function(node, scene) {
  .with_vp(node, scene, {
    ex <- .coord(node@x); ey <- .coord(node@y); g <- .gp4(node@gp, scene)
    scene$polygon(ex$value, ey$value, ex$code, ey$code, g$fill, g$col, g$lwd, g$alpha, g$stroke)
  })
}

S7::method(compile, grob_circle) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x, node@y, node@r)
    ex <- .coord(node@x, "npc", n); ey <- .coord(node@y, "npc", n); er <- .coord(node@r, "npc", n)
    g <- .gp4(node@gp, scene)
    scene$circles(ex$value, ey$value, er$value, ex$code, ey$code, er$code,
                  g$fill, g$col, g$lwd, g$alpha, g$stroke)
  })
}

S7::method(compile, grob_points) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x, node@y, node@size)
    ex <- .coord(node@x, "npc", n); ey <- .coord(node@y, "npc", n); es <- .coord(node@size, "mm", n)
    g <- .gp4(node@gp, scene)
    # Points are circles whose radius carries the marker size; batched.
    scene$circles(ex$value, ey$value, es$value, ex$code, ey$code, es$code,
                  g$fill, g$col, g$lwd, g$alpha, g$stroke)
  })
}

S7::method(compile, grob_segments) <- function(node, scene) {
  .with_vp(node, scene, {
    n <- vctrs::vec_size_common(node@x0, node@y0, node@x1, node@y1)
    e0x <- .coord(node@x0, "native", n); e0y <- .coord(node@y0, "native", n)
    e1x <- .coord(node@x1, "native", n); e1y <- .coord(node@y1, "native", n)
    g <- .gp4(node@gp, scene)
    scene$segments(e0x$value, e0y$value, e1x$value, e1y$value,
                   e0x$code, e0y$code, e1x$code, e1y$code, g$col, g$lwd, g$alpha, g$stroke)
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
    hv <- .just_to_hv(node@just)
    .draw_text(scene, node@label, node@x, node@y, hv[1], hv[2], node@rot,
               node@gp@fontfamily %||% "", node@gp@fontface %||% "plain",
               node@gp@fontsize %||% 12, 1, node@gp@col %||% "black", node@gp@alpha)
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
    scene$group_start()                    # the masked content as an isolated layer
    for (child in node@children) compile(child, scene)
    scene$group_end(idx)
  } else {
    for (child in node@children) compile(child, scene)
  }
  scene$pop_viewport(1L)
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
  out <- character(0)
  walk <- function(node) {
    nm <- .node_name(node)
    if (!is.null(nm)) out[[length(out) + 1L]] <<- nm
    for (ch in .node_children(node)) walk(ch)
  }
  for (ch in scene@root@children) walk(ch)
  out
}

#' @rdname node_names
#' @export
get_node <- function(scene, name) {
  p <- .find_path(scene@root, name)
  if (is.null(p)) cli::cli_abort("No node named {.val {name}}.")
  .get_at(scene@root, p)
}

#' @rdname node_names
#' @export
edit_node <- function(scene, name, ...) {
  p <- .find_path(scene@root, name)
  if (is.null(p)) cli::cli_abort("No node named {.val {name}}.")
  scene@root <- .modify_at(scene@root, p, function(nd) S7::set_props(nd, ...))
  scene
}

# --- internal helpers -------------------------------------------------------

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
  scene$push_viewport(
    cx$value, cy$value, cw$value, ch$value, cx$code, cy$code, cw$code, ch$code,
    as.numeric(vp@xscale), as.numeric(vp@yscale), vp@angle, isTRUE(vp@clip),
    lrow, lcol, vp@rowspan, vp@colspan,
    .encode_paint(vp@gp@fill, scene), .rs_col_inh(vp@gp@col), .rs_num_inh(vp@gp@lwd), .rs_num_inh(vp@gp@alpha),
    .encode_stroke(vp@gp)
  )
  if (!is.null(vp@layout)) .set_layout(scene, vp@layout)
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
.just1 <- function(j, map) if (j %in% names(map)) unname(map[j]) else suppressWarnings(as.numeric(j))

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
