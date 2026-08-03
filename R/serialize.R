#' @include api.R
NULL

# Scene serialization.
#
# The retained tree is already a tree of immutable S7 values whose properties are
# introspectable, so the serializer is generic rather than one method per grob
# type: record the class name and the properties, recurse. A grob added later
# serializes without touching this file.
#
# The format is a plain nested list -- R's own containers, no dependency -- so a
# caller can write it as RDS, hand it to jsonlite, or send it over a wire.

.SPEC_VERSION <- 1L

# Classes the reader is allowed to construct. Deserialising a scene means
# building R objects from a file, so the class name is looked up in a fixed table
# rather than resolved dynamically -- a spec cannot name an arbitrary function.
.spec_classes <- function() {
  list(
    gtree = gtree,
    vl_gpar = vl_gpar,
    class_viewport = class_viewport,
    class_grid_layout = class_grid_layout,
    style = style,
    vellum_md_label = vellum_md_label,
    grob_rect = grob_rect,
    grob_roundrect = grob_roundrect,
    grob_lines = grob_lines,
    grob_polygon = grob_polygon,
    grob_circle = grob_circle,
    grob_points = grob_points,
    grob_hexagon = grob_hexagon,
    grob_sector = grob_sector,
    grob_text = grob_text,
    grob_textpath = grob_textpath,
    grob_segments = grob_segments,
    grob_loop = grob_loop,
    grob_path = grob_path,
    grob_raster = grob_raster
  )
}

#' Convert a scene to and from a plain list
#'
#' `as_scene_spec()` turns a rendered-ready scene into a plain nested list of R
#' vectors, and `from_scene_spec()` rebuilds the scene from it. Together they
#' make a compiled scene a *value you can store or send*, rather than something
#' that only exists inside the session that built it.
#'
#' This is one level below `vellumplot`'s plot spec. A plot spec is portable and
#' re-renderable at any size; a scene spec is the *resolved* artifact — the grobs,
#' units and viewports as they will actually be drawn. They compose: keep the
#' plot spec to re-render, keep the scene spec to reproduce exactly this scene.
#'
#' The conversion is generic over the S7 property model rather than written per
#' grob type, so a grob added to vellum later serializes with no change here.
#'
#' @param scene A [vl_scene()], or anything with an [as_vellum_scene()] method.
#' @param spec A list from `as_scene_spec()`.
#' @return `as_scene_spec()`: a nested list, with a `version` element.
#'   `from_scene_spec()`: a `vellum_scene`.
#' @seealso [scene_write()], [scene_diff()], [scene_hash()]
#' @examples
#' s <- vl_scene(3, 2) |>
#'   draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "tomato", col = NA)))
#' spec <- as_scene_spec(s)
#' spec$version
#' identical(as_scene_spec(from_scene_spec(spec)), spec)
#' @export
as_scene_spec <- function(scene) {
  scene <- as_vellum_scene(scene)
  root <- .materialize(scene)
  list(
    version = .SPEC_VERSION,
    width = .spec_encode(scene@width),
    height = .spec_encode(scene@height),
    dpi = .spec_encode(scene@dpi),
    bg = scene@bg,
    title = scene@title,
    desc = scene@desc,
    root = .spec_encode(root)
  )
}

#' @rdname as_scene_spec
#' @export
from_scene_spec <- function(spec) {
  if (!is.list(spec) || is.null(spec$version)) {
    cli::cli_abort(
      "{.arg spec} does not look like a scene spec (no {.field version})."
    )
  }
  # A local, dot-free name: cli reads `{.SPEC_VERSION}` as an inline style.
  supported <- .SPEC_VERSION
  if (spec$version > supported) {
    cli::cli_abort(c(
      "This scene spec is version {spec$version}; this vellum reads up to {supported}.",
      i = "Upgrade vellum to read it."
    ))
  }
  # JSON has one number type and reads 120 back as an integer, so coerce the
  # numerics the S7 properties are typed on rather than failing validation.
  s <- vl_scene(
    width = .spec_decode(spec$width),
    height = .spec_decode(spec$height),
    dpi = as.double(.spec_decode(spec$dpi)),
    bg = spec$bg
  )
  if (!is.null(spec$title) || !is.null(spec$desc)) {
    s <- describe(s, title = spec$title, desc = spec$desc)
  }
  # Replace the (empty) built tree wholesale with the decoded one.
  .scene_with_root(s, .spec_decode(spec$root))
}

# --- encoding ----------------------------------------------------------------

.spec_encode <- function(x) {
  if (is.null(x)) {
    return(NULL)
  }
  if (is_unit(x)) {
    d <- vctrs::vec_data(x)
    return(list(
      `_t` = "unit",
      value = .spec_encode(d$value),
      unit = d$unit,
      offset = .spec_encode(d$offset)
    ))
  }
  if (S7::S7_inherits(x)) {
    cls <- attr(S7::S7_class(x), "name")
    props <- S7::props(x)
    # `bstate` is a live builder environment, not part of the value.
    props$bstate <- NULL
    # `nid` is a monotonic build-time counter for the render cache, not content.
    # Keeping it would make two identical scenes built separately serialize --
    # and therefore hash and diff -- differently, which is the opposite of what
    # a content fingerprint is for. It is regenerated on read.
    props$nid <- NULL
    return(c(list(`_t` = "s7", class = cls), lapply(props, .spec_encode)))
  }
  if (
    inherits(x, "vellum_gradient") ||
      inherits(x, "vellum_pattern") ||
      inherits(x, "vellum_mask") ||
      inherits(x, "vellum_shadow")
  ) {
    return(c(
      list(`_t` = "tagged", class = class(x)[1]),
      lapply(unclass(x), .spec_encode)
    ))
  }
  if (is.list(x)) {
    # Positional elements go in their own `items` array rather than alongside
    # `_t`: a JSON object with one named and several unnamed keys is not
    # representable, and jsonlite invents names for them on the way back.
    return(list(
      `_t` = "list",
      named = !is.null(names(x)),
      names = names(x) %||% character(),
      items = unname(lapply(x, .spec_encode))
    ))
  }
  if (is.function(x) || is.environment(x)) {
    cli::cli_abort(c(
      "A scene holding a function or environment cannot be serialized.",
      i = "Found a {.cls {class(x)[1]}}. Scene specs carry data, not code."
    ))
  }
  # Doubles are tagged so the JSON round-trip keeps them doubles. JSON has one
  # number type, so `120` reads back as an integer and S7 property validation
  # rejects it. RDS would not need this, but one encoding for both formats is
  # worth more than a smaller JSON file.
  if (is.double(x)) {
    return(list(`_t` = "dbl", v = x))
  }
  # Character too, for the same reason plus one more: JSON writes `NA` as null,
  # and a null read back into an untyped slot becomes a *logical* NA, silently
  # changing the type of an absent string.
  if (is.character(x)) {
    return(list(`_t` = "chr", v = x))
  }
  x
}

# --- decoding ----------------------------------------------------------------

.spec_decode <- function(x) {
  if (is.null(x) || !is.list(x) || is.null(x[["_t"]])) {
    return(x)
  }
  tag <- x[["_t"]]
  # Select by POSITION, not by name: list elements are unnamed, and `x[""]`
  # silently yields a NULL element rather than matching them.
  nm <- names(x)
  if (is.null(nm)) {
    nm <- rep("", length(x))
  }
  body <- x[!nm %in% c("_t", "class")]
  switch(
    tag,
    dbl = as.double(unlist(x$v)),
    chr = as.character(unlist(x$v)),
    unit = new_unit(
      as.double(.spec_decode(x$value)),
      as.integer(.spec_decode(x$unit)),
      as.double(.spec_decode(x$offset))
    ),
    list = {
      out <- lapply(x$items, .spec_decode)
      # Restore names only if the original had them: a `md()` label's runs are
      # named lists, and unnaming them rebuilds a different object.
      if (isTRUE(unlist(x$named))) {
        names(out) <- as.character(unlist(x$names))
      }
      out
    },
    tagged = {
      out <- lapply(body, .spec_decode)
      structure(out, class = x$class)
    },
    s7 = {
      ctor <- .spec_classes()[[x$class]]
      if (is.null(ctor)) {
        cli::cli_abort(c(
          "Unknown class in scene spec: {.val {x$class}}.",
          i = "It may come from a newer vellum, or the spec may be corrupt."
        ))
      }
      do.call(ctor, lapply(body, .spec_decode))
    },
    cli::cli_abort("Unknown spec node type {.val {tag}}.")
  )
}

# --- files -------------------------------------------------------------------

#' Write and read a scene
#'
#' Persist a scene so it can be rebuilt later, in another session, or in another
#' process. `.rds` is the default and needs nothing extra; `.json` produces a
#' portable text format and needs the jsonlite package.
#'
#' What this buys you: caching a built scene without re-running the code that
#' built it, sending one over a wire for a worker to render, and keeping a
#' reproducible intermediate between "the code" and "the pixels".
#'
#' @param scene A [vl_scene()], or anything with an [as_vellum_scene()] method.
#' @param path File path. The extension picks the format (`.rds` or `.json`).
#' @return `scene_write()`: `path`, invisibly. `scene_read()`: a `vellum_scene`.
#' @seealso [as_scene_spec()], [scene_diff()], [scene_hash()]
#' @examples
#' s <- vl_scene(2, 2) |> draw(circle_grob(gp = vl_gpar(fill = "steelblue")))
#' f <- tempfile(fileext = ".rds")
#' scene_write(s, f)
#' identical(as_scene_spec(scene_read(f)), as_scene_spec(s))
#' @export
scene_write <- function(scene, path) {
  spec <- as_scene_spec(scene)
  switch(.spec_format(path), rds = saveRDS(spec, path), json = {
    .spec_need_jsonlite()
    # `auto_unbox = FALSE` deliberately: unboxing turns a length-1 `NA` into a
    # bare `null`, which reads back as NULL and loses the value. Keeping every
    # vector an array costs some verbosity and round-trips NA correctly.
    writeLines(
      jsonlite::toJSON(
        spec,
        auto_unbox = FALSE,
        digits = NA,
        null = "null",
        na = "null"
      ),
      path
    )
  })
  invisible(path)
}

#' @rdname scene_write
#' @export
scene_read <- function(path) {
  if (!file.exists(path)) {
    cli::cli_abort("No such file: {.path {path}}.")
  }
  spec <- switch(.spec_format(path), rds = readRDS(path), json = {
    .spec_need_jsonlite()
    jsonlite::fromJSON(
      paste(readLines(path, warn = FALSE), collapse = "\n"),
      simplifyVector = TRUE,
      simplifyDataFrame = FALSE
    )
  })
  from_scene_spec(spec)
}

.spec_format <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (!ext %in% c("rds", "json")) {
    cli::cli_abort(
      "Unsupported scene format {.val {ext}}; use {.file .rds} or {.file .json}."
    )
  }
  ext
}

.spec_need_jsonlite <- function() {
  if (!requireNamespace("jsonlite", quietly = TRUE)) {
    cli::cli_abort(c(
      "Reading or writing a JSON scene needs the {.pkg jsonlite} package.",
      i = "Install it, or use {.file .rds}, which needs nothing."
    ))
  }
}

#' A content fingerprint for a scene
#'
#' A stable hash of everything that defines the scene — geometry, style, page
#' size, background. Two scenes that would render identically hash identically;
#' any change to what is drawn changes the hash.
#'
#' Useful for caching (has this scene changed since I last rendered it?) and for
#' asserting in tests that a refactor did not alter the scene.
#'
#' @param scene A [vl_scene()], or anything with an [as_vellum_scene()] method.
#' @return A length-1 character hash.
#' @seealso [scene_diff()] to see *what* changed, [as_scene_spec()].
#' @examples
#' a <- vl_scene(2, 2) |> draw(circle_grob(gp = vl_gpar(fill = "red")))
#' b <- vl_scene(2, 2) |> draw(circle_grob(gp = vl_gpar(fill = "blue")))
#' scene_hash(a) == scene_hash(a)
#' scene_hash(a) == scene_hash(b)
#' @export
scene_hash <- function(scene) {
  spec <- as_scene_spec(scene)
  # `serialize()` to a raw vector then md5 it: no dependency, and stable across
  # sessions for the plain lists and atomic vectors a spec is made of.
  con <- rawConnection(raw(0), "w")
  on.exit(close(con), add = TRUE)
  serialize(spec, con, version = 3, xdr = TRUE)
  f <- tempfile()
  on.exit(unlink(f), add = TRUE)
  writeBin(rawConnectionValue(con), f)
  unname(tools::md5sum(f))
}

#' What changed between two scenes
#'
#' Compares two scenes structurally and reports the differences in terms of the
#' scene — "the node `axis-x` moved", "3 marks changed fill" — rather than as a
#' pixel diff.
#'
#' This is a better basis for visual-regression testing than comparing rendered
#' images, for one specific reason: an image diff is sensitive to the font stack,
#' so the same code compared across two machines produces differences that swamp
#' the real change. A structural diff compares what was *asked for*, and is
#' unaffected.
#'
#' @param a,b Two scenes ([vl_scene()], or anything with an
#'   [as_vellum_scene()] method).
#' @param max_depth Stop descending after this many levels (guards a runaway
#'   report on deeply nested trees).
#' @return A data frame with columns `path` (where in the tree), `change`
#'   (`"added"`, `"removed"`, or `"changed"`), and `detail`. Empty when the two
#'   scenes are equivalent. Printing shows a readable summary.
#' @seealso [scene_hash()] for a yes/no answer, [as_scene_spec()].
#' @examples
#' a <- vl_scene(3, 2) |> draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "red")))
#' b <- vl_scene(3, 2) |> draw(circle_grob(r = 0.4, gp = vl_gpar(fill = "blue")))
#' scene_diff(a, b)
#' @export
scene_diff <- function(a, b, max_depth = 40L) {
  sa <- as_scene_spec(a)
  sb <- as_scene_spec(b)
  rows <- .diff_node(sa, sb, "", max_depth)
  out <- if (!length(rows)) {
    data.frame(
      path = character(),
      change = character(),
      detail = character(),
      stringsAsFactors = FALSE
    )
  } else {
    do.call(rbind, lapply(rows, as.data.frame, stringsAsFactors = FALSE))
  }
  row.names(out) <- NULL
  structure(out, class = c("vellum_diff", class(out)))
}

# Recursive structural comparison. Returns a list of row-lists.
.diff_node <- function(a, b, path, depth) {
  if (depth <= 0L) {
    return(list())
  }
  if (is.null(a) && is.null(b)) {
    return(list())
  }
  if (is.null(a)) {
    return(list(list(path = path, change = "added", detail = .diff_desc(b))))
  }
  if (is.null(b)) {
    return(list(list(path = path, change = "removed", detail = .diff_desc(a))))
  }
  # Units and tagged doubles are encoding detail, not structure: compare them
  # whole so the report says `r: 0.3npc -> 0.4npc` rather than `r$value$v`.
  if (.diff_is_leaf(a) || .diff_is_leaf(b)) {
    if (isTRUE(all.equal(a, b))) {
      return(list())
    }
    return(list(list(
      path = path,
      change = "changed",
      detail = sprintf("%s -> %s", .diff_leaf(a), .diff_leaf(b))
    )))
  }
  if (is.list(a) && is.list(b)) {
    # A different class at the same position is a replacement, not a field edit.
    if (!identical(a[["class"]], b[["class"]])) {
      return(list(list(
        path = path,
        change = "changed",
        detail = sprintf("%s -> %s", .diff_desc(a), .diff_desc(b))
      )))
    }
    # A `list` node holds unnamed children, so compare it by POSITION. Keying
    # off the tag rather than off the names matters: `x[[""]]` yields NULL, so a
    # name-based walk would silently find no differences at all.
    if (identical(a[["_t"]], "list")) {
      ea <- a$items
      eb <- b$items
      n <- max(length(ea), length(eb))
      return(
        unlist(
          lapply(seq_len(n), function(i) {
            .diff_node(
              if (i <= length(ea)) ea[[i]] else NULL,
              if (i <= length(eb)) eb[[i]] else NULL,
              sprintf("%s[%d]", path, i),
              depth - 1L
            )
          }),
          recursive = FALSE
        ) %||%
          list()
      )
    }
    keys <- setdiff(union(names(a), names(b)), c("_t", "class"))
    return(
      unlist(
        lapply(keys, function(k) {
          .diff_node(
            a[[k]],
            b[[k]],
            if (nzchar(path)) paste0(path, "$", k) else k,
            depth - 1L
          )
        }),
        recursive = FALSE
      ) %||%
        list()
    )
  }
  if (isTRUE(all.equal(a, b))) {
    return(list())
  }
  list(list(
    path = path,
    change = "changed",
    detail = sprintf("%s -> %s", .diff_val(a), .diff_val(b))
  ))
}

.diff_is_leaf <- function(x) {
  is.list(x) && !is.null(x[["_t"]]) && x[["_t"]] %in% c("unit", "dbl", "chr")
}

# Render a leaf spec node as the value a caller wrote, not as its encoding.
.diff_leaf <- function(x) {
  if (is.null(x)) {
    return("NULL")
  }
  if (!is.list(x)) {
    return(.diff_val(x))
  }
  switch(
    x[["_t"]],
    dbl = ,
    chr = .diff_val(unlist(x$v)),
    unit = .diff_val(format(.spec_decode(x))),
    .diff_val(x)
  )
}

# A short human label for a spec node.
.diff_desc <- function(x) {
  if (is.list(x) && !is.null(x[["class"]])) {
    nm <- x[["name"]]
    nm <- if (is.list(nm)) nm[["v"]] else nm
    if (!is.null(nm) && length(nm) && !is.na(nm[1]) && nzchar(nm[1])) {
      return(sprintf("%s '%s'", x[["class"]], nm[1]))
    }
    return(as.character(x[["class"]]))
  }
  .diff_val(x)
}

# A short label for a leaf value.
.diff_val <- function(x) {
  if (is.null(x)) {
    return("NULL")
  }
  v <- if (length(x) > 3L) c(format(utils::head(x, 3)), "...") else format(x)
  paste(v, collapse = ", ")
}

#' @export
print.vellum_diff <- function(x, ...) {
  if (!nrow(x)) {
    cli::cli_alert_success("The two scenes are structurally identical.")
    return(invisible(x))
  }
  cli::cli_text("{.strong {nrow(x)}} difference{?s}:")
  sym <- c(added = "+", removed = "-", changed = "~")
  cli::cli_bullets(stats::setNames(
    sprintf("%s %s: %s", sym[x$change], x$path, x$detail),
    rep("*", nrow(x))
  ))
  invisible(x)
}

#' Inset one scene inside another
#'
#' Places a whole scene inside a region of another one. Because a scene is a
#' retained tree with a known resolved size, this is a graft rather than a
#' re-render: the guest's grobs are spliced under a viewport of the host, and the
#' result is an ordinary scene you can keep building on, edit by name, or inset
#' again.
#'
#' This is the mechanism a composition layer needs — inset maps, small multiples
#' assembled from independently-built plots, a legend built separately and
#' dropped into a corner. The *policy* (should panel edges align across composed
#' plots? should axes be shared?) belongs above vellum, in a grammar; what the
#' engine provides is the ability to nest one scene in another at all.
#'
#' The guest's `npc` coordinates become relative to the region it is placed in,
#' so a guest built on a square page and inset into a wide region will stretch.
#' Match the aspect ratio, or build the guest at the aspect you want.
#'
#' @param host The scene to place into.
#' @param guest The scene to place. Its page size, background and dpi are *not*
#'   carried over — it becomes a region of the host, which owns those.
#' @param x,y,width,height The region, in the host's current coordinates.
#' @param name Optional name for the region's viewport, so the inset can later
#'   be found with [node_names()] and edited with [edit_node()].
#' @param ... Further arguments to [vl_viewport()] (`clip`, `angle`, `gp`,
#'   `mask`, `blur`, `shadow`, ...).
#' @return A `vellum_scene`.
#' @seealso [vl_viewport()], [as_scene_spec()]
#' @examples
#' main <- vl_scene(4, 3) |>
#'   draw(rect_grob(gp = vl_gpar(fill = "#eef2f6", col = NA)))
#' mini <- vl_scene(1, 1) |>
#'   draw(circle_grob(r = 0.4, gp = vl_gpar(fill = "tomato", col = NA)))
#' scene_inset(main, mini, x = 0.8, y = 0.75, width = 0.3, height = 0.35)
#' @export
scene_inset <- function(
  host,
  guest,
  x = 0.5,
  y = 0.5,
  width = 0.3,
  height = 0.3,
  name = NULL,
  ...
) {
  host <- as_vellum_scene(host)
  guest <- as_vellum_scene(guest)
  groot <- .materialize(guest)
  kids <- .node_children(groot)
  if (!length(kids)) {
    return(host)
  }
  out <- push(
    host,
    vl_viewport(x = x, y = y, width = width, height = height, name = name, ...)
  )
  # The guest's own root viewport is dropped: the region we just pushed takes
  # its place, which is exactly what "inset this scene here" means.
  for (k in kids) {
    out <- draw(out, k)
  }
  pop(out)
}
