#' @include gpar.R viewport.R
NULL

#' Graphical objects (grobs)
#'
#' Grobs are immutable value objects describing something to draw. Build them
#' with the constructors below, add them to a scene with [draw()], and render
#' with [render()]. Coordinates accept a [vl_unit()] vector or a bare numeric
#' (interpreted in the `default_units`).
#'
#' @section Units:
#' As in grid, a bare numeric position or size is interpreted in the
#' constructor's `default_units`, which is `"npc"` in **every** constructor: `0`
#' is the left/bottom edge of the viewport and `1` the right/top. To place
#' marks on a viewport's `xscale`/`yscale`, pass `default_units = "native"` or
#' wrap the values in `vl_unit(x, "native")`. A [vl_unit()] always keeps its
#' own unit, so one grob can mix units per element.
#'
#' A few arguments are absolute by nature and keep their own default whatever
#' `default_units` says: a bare `size` on [points_grob()], [hexagon_grob()] and
#' [loop_grob()], and `foot`, `start_cap`, `end_cap` and `offset`, are
#' millimetres; an arrow's `length` is inches.
#'
#' How a relative **length** resolves depends on what it measures:
#' * A `width` resolves against the viewport's width and a `height` against
#'   its height (rects, rasters, viewports, and the `width`/`height` of a
#'   hexagon -- so an `"npc"` or `"native"` hexagon follows the viewport's
#'   aspect, and can tile a non-square lattice).
#' * A radius is one length on both axes: circle and roundrect `r`, sector
#'   `r0`/`r1`, and a point or hexagon `size`. An `"npc"` radius is a fraction
#'   of the viewport's **shorter** side (grid's `"snpc"`), so circles stay
#'   round in a non-square viewport; a `"native"` radius is measured on the x
#'   scale.
#'
#' @name grob
#' @return A grob object.
NULL

# Abstract base: every grob carries a name, gpar, and an optional viewport.
# `id`/`role` are optional semantic metadata: a stable identifier and an ARIA
# role, emitted by the SVG backend as `data-vellum-id` / `role` for interactivity,
# accessibility, and testing. They are ignored by the raster and PDF backends.
#
# `keys`/`meta` are optional PER-ELEMENT metadata for batched grobs (interactivity
# foundation, see `_docs/DESIGN-INTERACTIVITY.md`). `keys` is a character vector,
# one data key per drawn element (recycled to the element count like `fill`),
# emitted by the SVG backend as `data-key` on each primitive — the join key a host
# uses to map a hover/click back to a datum. `meta` is a free-form per-element list
# (e.g. tooltip text / field values) that never crosses to the backend; it rides
# on the R scene and surfaces via [scene_model()]. Both default `NULL` (absent), so
# a scene without interactivity is byte-for-byte unchanged and pays nothing.
grob <- S7::new_class(
  "grob",
  package = "vellum",
  abstract = TRUE,
  properties = list(
    name = S7::new_property(S7::class_any, default = NULL),
    gp = S7::new_property(vl_gpar, default = quote(vl_gpar())),
    vp = S7::new_property(S7::class_any, default = NULL),
    id = S7::new_property(S7::class_any, default = NULL),
    role = S7::new_property(S7::class_any, default = NULL),
    keys = S7::new_property(S7::class_any, default = NULL),
    meta = S7::new_property(S7::class_any, default = NULL)
  )
)

# Recycle a per-element `key` vector to `n` (coerced to character); NULL -> NULL
# so an absent key emits no `data-key` and costs nothing. Only length 1 (one key
# for every element) or exactly `n` is accepted: anything else would be silently
# truncated or wrapped by `rep_len()`, pairing elements with the wrong data.
.recycle_keys <- function(key, n, call = parent.frame()) {
  if (is.null(key)) {
    return(NULL)
  }
  .check_elem_len(key, n, "key", call)
  rep_len(as.character(key), n)
}

# Recycle a per-element `meta` list to `n`. `meta` is a list of records (one per
# element); a length-1 list is recycled to every element. NULL -> NULL.
.recycle_meta <- function(meta, n, call = parent.frame()) {
  if (is.null(meta)) {
    return(NULL)
  }
  if (!is.list(meta)) {
    cli::cli_abort(
      "{.arg meta} must be a list, one entry (record) per element.",
      call = call
    )
  }
  .check_elem_len(meta, n, "meta", call)
  rep_len(meta, n)
}

.check_elem_len <- function(v, n, arg, call) {
  len <- length(v)
  if (len != 1L && len != n) {
    cli::cli_abort(
      c(
        "{.arg {arg}} must have length 1 or {n} (one per element), not {len}.",
        i = "This grob draws {n} element{?s}."
      ),
      call = call
    )
  }
}

# Element count of a batched grob: the common size of its per-element vectors
# under length-1 recycling (vctrs rules, so a zero-length vector gives n = 0).
# `vals` is a named list; NULLs (absent optional vectors) do not count. This is the single definition of "n" for a batch: the constructor
# recycles `key`/`meta` to it, `compile()` hands the backend that many elements,
# and `scene_model()` expects that many rows -- see `.batch_n()`.
.elem_n <- function(vals, call = parent.frame()) {
  vals <- vals[!vapply(vals, is.null, logical(1))]
  sizes <- vapply(vals, .vsize, integer(1))
  big <- unique(sizes[sizes != 1L])
  if (length(big) > 1L) {
    nms <- names(sizes)
    cli::cli_abort(
      c(
        "{.arg {nms}} must have compatible lengths.",
        i = "Each must be length 1 or a common length.",
        x = "{.arg {nms}} have lengths {sizes}."
      ),
      call = call
    )
  }
  if (length(big)) big else 1L
}

# The per-element properties of each batched grob class, in the order their
# constructor arguments appear. Per-element *style* vectors (hexagon/sector
# `fill`, segment `col`/`lwd`) are not listed: like a `gp` colour vector they
# cycle over the elements rather than define how many there are.
.batch_props <- list(
  grob_rect = c("x", "y", "width", "height"),
  grob_roundrect = c("x", "y", "width", "height", "r"),
  grob_circle = c("x", "y", "r"),
  grob_points = c("x", "y", "size", "shape"),
  grob_hexagon = c("x", "y", "size", "width", "height"),
  grob_sector = c("x", "y", "r0", "r1", "theta0", "theta1"),
  grob_segments = c(
    "x0",
    "y0",
    "x1",
    "y1",
    "start_cap",
    "end_cap",
    "offset"
  ),
  grob_loop = c("x", "y", "size", "foot", "angle", "width")
)

# Element count of a built batched grob (see `.elem_n()`). Text has its own rule
# (a rich label does not count towards n), so it goes through `.text_n()`.
.batch_n <- function(node, call = parent.frame()) {
  if (S7::S7_inherits(node, grob_text)) {
    return(.text_n(node@label, node@x, node@y, call = call))
  }
  props <- .batch_props[[attr(S7::S7_class(node), "name")]]
  if (is.null(props)) {
    cli::cli_abort(
      "Internal error: {.cls {class(node)[1]}} is not a batched grob.",
      .internal = TRUE
    )
  }
  vals <- lapply(props, function(p) S7::prop(node, p))
  names(vals) <- props
  .elem_n(vals, call = call)
}

grob_rect <- S7::new_class(
  "grob_rect",
  parent = grob,
  package = "vellum",
  properties = list(
    x = .unit_prop(),
    y = .unit_prop(),
    width = .unit_prop("vl_unit(1, \"npc\")"),
    height = .unit_prop("vl_unit(1, \"npc\")"),
    sketch = S7::new_property(S7::class_any, default = NULL)
  )
)
grob_roundrect <- S7::new_class(
  "grob_roundrect",
  parent = grob,
  package = "vellum",
  properties = list(
    x = .unit_prop(),
    y = .unit_prop(),
    width = .unit_prop("vl_unit(1, \"npc\")"),
    height = .unit_prop("vl_unit(1, \"npc\")"),
    r = .unit_prop("vl_unit(0.1, \"npc\")"),
    sketch = S7::new_property(S7::class_any, default = NULL)
  )
)
grob_lines <- S7::new_class(
  "grob_lines",
  parent = grob,
  package = "vellum",
  properties = list(
    x = .unit_prop(),
    y = .unit_prop(),
    arrow = S7::new_property(S7::class_any, default = NULL),
    start_cap = S7::new_property(S7::class_any, default = NULL),
    end_cap = S7::new_property(S7::class_any, default = NULL),
    offset = S7::new_property(S7::class_any, default = NULL),
    sketch = S7::new_property(S7::class_any, default = NULL),
    lwd_profile = S7::new_property(S7::class_any, default = NULL)
  )
)
grob_polygon <- S7::new_class(
  "grob_polygon",
  parent = grob,
  package = "vellum",
  properties = list(
    x = .unit_prop(),
    y = .unit_prop(),
    sketch = S7::new_property(S7::class_any, default = NULL)
  )
)
grob_circle <- S7::new_class(
  "grob_circle",
  parent = grob,
  package = "vellum",
  properties = list(
    x = .unit_prop(),
    y = .unit_prop(),
    r = .unit_prop("vl_unit(0.25, \"npc\")"),
    sketch = S7::new_property(S7::class_any, default = NULL)
  )
)
grob_points <- S7::new_class(
  "grob_points",
  parent = grob,
  package = "vellum",
  properties = list(
    x = .unit_prop(),
    y = .unit_prop(),
    size = .unit_prop("vl_unit(2, \"mm\")"),
    shape = S7::new_property(S7::class_character, default = "circle"),
    sketch = S7::new_property(S7::class_any, default = NULL)
  ),
  # Guard the shape here too (not only in points_grob): an unknown shape reaching
  # the compile method would otherwise map to NA and fail with a cryptic `if(NA)`.
  validator = function(self) {
    bad <- setdiff(unique(self@shape), names(.marker_codes))
    if (length(bad)) {
      sprintf("unknown point shape(s): %s", paste(bad, collapse = ", "))
    }
  }
)

grob_hexagon <- S7::new_class(
  "grob_hexagon",
  parent = grob,
  package = "vellum",
  properties = list(
    x = .unit_prop(),
    y = .unit_prop(),
    size = .unit_prop("vl_unit(2, \"mm\")"),
    width = S7::new_property(S7::class_any, default = NULL),
    height = S7::new_property(S7::class_any, default = NULL),
    fill = S7::new_property(S7::class_any, default = NULL),
    orientation = S7::new_property(S7::class_character, default = "flat")
  )
)

grob_sector <- S7::new_class(
  "grob_sector",
  parent = grob,
  package = "vellum",
  properties = list(
    x = .unit_prop(),
    y = .unit_prop(),
    r0 = .unit_prop("vl_unit(0, \"native\")"),
    r1 = .unit_prop("vl_unit(0.5, \"native\")"),
    theta0 = S7::new_property(S7::class_double, default = 0),
    theta1 = S7::new_property(S7::class_double, default = 0),
    fill = S7::new_property(S7::class_any, default = NULL),
    arrow = S7::new_property(S7::class_any, default = NULL),
    sketch = S7::new_property(S7::class_any, default = NULL)
  )
)

# Marker shape names -> backend codes (must match the `markers` arm in scene.rs).
.marker_codes <- c(
  circle = 0L,
  square = 1L,
  triangle = 2L,
  diamond = 3L,
  plus = 4L,
  cross = 5L,
  triangle_down = 6L,
  star = 7L
)
# Extension point for rich text labels (plotmath, markdown, ...). A concrete
# rich-label type subclasses this and adds a `.text_labels()` method that returns
# the strings to shape; until such a type exists only plain character labels are
# drawn. The seam keeps the grammar's text path from hard-coding `character`, so a
# future label kind plugs in here rather than in every geom (see DESIGN, the
# grammar-coupled items section).
vellum_label <- S7::new_class(
  "vellum_label",
  package = "vellum",
  abstract = TRUE
)

# A concrete rich label: a markdown-subset string parsed into styled runs (see
# `md()` and `.md_parse()` in text.R). `runs` is a list of run descriptors (text +
# per-run face/size/baseline/colour); `text` is the markup-stripped plain string,
# used by the `.text_labels()` seam and as a measurement fallback.
vellum_md_label <- S7::new_class(
  "vellum_md_label",
  parent = vellum_label,
  package = "vellum",
  properties = list(
    runs = S7::new_property(S7::class_list, default = list()),
    text = S7::new_property(S7::class_character, default = "")
  )
)

# The single place a label becomes the character vector the backend shapes.
.text_labels <- S7::new_generic("text_labels", "label")
S7::method(.text_labels, S7::class_character) <- function(label) label
S7::method(.text_labels, S7::class_any) <- function(label) as.character(label)
S7::method(.text_labels, vellum_md_label) <- function(label) label@text

# Is `label` rich (a single `vellum_label`, or a non-empty list of them -- one
# per datum)? Rich labels are drawn at every position, so they don't count
# towards the element count.
.is_rich_label <- function(label) {
  S7::S7_inherits(label, vellum_label) ||
    (is.list(label) &&
      length(label) > 0L &&
      all(vapply(
        label,
        function(l) S7::S7_inherits(l, vellum_label),
        logical(1)
      )))
}

# Element count of a text grob: the common length of `label`, `x` and `y` under
# length-1 recycling (rich labels recycle to the positions and so count only
# `x`/`y`). It matches what `compile()` hands the backend, one text node per
# element, so per-element `key`/`meta` recycle to the same n R-side.
.text_n <- function(label, x, y, call = parent.frame()) {
  vals <- list(x = x, y = y)
  if (!.is_rich_label(label)) {
    vals <- c(list(label = .text_labels(label)), vals)
  }
  .elem_n(vals, call = call)
}

grob_text <- S7::new_class(
  "grob_text",
  parent = grob,
  package = "vellum",
  properties = list(
    # A plain character vector, a single rich label, or a list of rich labels
    # (one per datum — the per-datum mark_text case).
    label = S7::new_property(S7::new_union(
      S7::class_character,
      vellum_label,
      S7::class_list
    )),
    x = .unit_prop(),
    y = .unit_prop(),
    just = S7::new_property(
      S7::class_character,
      default = c("centre", "centre")
    ),
    rot = S7::new_property(S7::class_double, default = 0),
    # Width-constrained text. `width`/`height` are absolute millimetres (see
    # `text_grob()`), NA when unset; `align` is line alignment within the box and
    # `fit` the floor for auto-fit sizing (NA = no auto-fit).
    width = S7::new_property(S7::class_double, default = NA_real_),
    height = S7::new_property(S7::class_double, default = NA_real_),
    align = S7::new_property(S7::class_character, default = "left"),
    fit = S7::new_property(S7::class_double, default = NA_real_)
  )
)
grob_textpath <- S7::new_class(
  "grob_textpath",
  parent = grob,
  package = "vellum",
  properties = list(
    label = S7::new_property(S7::class_character),
    x = .unit_prop(),
    y = .unit_prop(),
    just = S7::new_property(
      S7::class_character,
      default = c("centre", "centre")
    ),
    # Baseline shift perpendicular to the path, in points (+ = left of travel).
    offset = S7::new_property(S7::class_double, default = 0)
  )
)
grob_segments <- S7::new_class(
  "grob_segments",
  parent = grob,
  package = "vellum",
  properties = list(
    x0 = .unit_prop(),
    y0 = .unit_prop(),
    x1 = .unit_prop(),
    y1 = .unit_prop(),
    arrow = S7::new_property(S7::class_any, default = NULL),
    start_cap = S7::new_property(S7::class_any, default = NULL),
    end_cap = S7::new_property(S7::class_any, default = NULL),
    offset = S7::new_property(S7::class_any, default = NULL),
    sketch = S7::new_property(S7::class_any, default = NULL),
    ecol = S7::new_property(S7::class_any, default = NULL),
    elwd = S7::new_property(S7::class_any, default = NULL)
  )
)

grob_loop <- S7::new_class(
  "grob_loop",
  parent = grob,
  package = "vellum",
  properties = list(
    x = .unit_prop(),
    y = .unit_prop(),
    size = .unit_prop("vl_unit(4, \"mm\")"),
    foot = .unit_prop("vl_unit(0, \"mm\")"),
    angle = S7::new_property(S7::class_double, default = 0),
    width = S7::new_property(S7::class_double, default = 1),
    arrow = S7::new_property(S7::class_any, default = NULL)
  )
)
grob_path <- S7::new_class(
  "grob_path",
  parent = grob,
  package = "vellum",
  properties = list(
    x = .unit_prop(),
    y = .unit_prop(),
    nper = S7::new_property(S7::class_integer, default = integer(0)),
    rule = S7::new_property(S7::class_character, default = "winding"),
    sketch = S7::new_property(S7::class_any, default = NULL)
  )
)
grob_raster <- S7::new_class(
  "grob_raster",
  parent = grob,
  package = "vellum",
  properties = list(
    rgba = S7::new_property(S7::class_integer, default = integer(0)),
    iw = S7::new_property(S7::class_integer, default = 0L),
    ih = S7::new_property(S7::class_integer, default = 0L),
    x = .unit_prop(),
    y = .unit_prop(),
    width = .unit_prop("vl_unit(1, \"npc\")"),
    height = .unit_prop("vl_unit(1, \"npc\")"),
    interpolate = S7::new_property(S7::class_logical, default = TRUE)
  )
)
