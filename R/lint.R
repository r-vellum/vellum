#' @include api.R
NULL

# Static analysis for a scene. Every rule reads the *resolved* geometry -- the
# same numbers the renderer draws with -- which is the whole reason this can
# exist here and not on top of grid: a grob's device box is not knowable until
# draw time there, so nothing above the engine can check it.

.lint_rules <- new.env(parent = emptyenv())

#' Register a lint rule
#'
#' Adds a rule to the registry [vl_lint()] runs. A package layered on vellum can
#' register rules of its own — vellum supplies the geometric ones (a mark drawn
#' off-canvas, text too small to read), a grammar layer can add semantic ones (a
#' scale with a single level, a legend with forty entries) — and both come back
#' from one `vl_lint()` call.
#'
#' @param name Short rule id, e.g. `"tiny_text"`. Re-registering replaces.
#' @param fn A function of `(scene, nodes, ctx)` returning a data frame of
#'   findings — build it with [vl_lint_finding()] — or `NULL` for "nothing
#'   found". A rule that fails is reported as a `rule_error` finding rather than
#'   aborting the lint.
#'
#'   `nodes` is the resolved per-node table, one row per drawn node in paint
#'   order:
#'   \describe{
#'     \item{`kind`, `name`, `id`, `label`}{what the node is, and what it was
#'       called. `label` is the string, for text nodes.}
#'     \item{`node`}{the paint index — later means drawn on top.}
#'     \item{`x0`, `y0`, `x1`, `y1`}{the device-px box, y-down. For a batched
#'       mark this is the union over every element, so reach for
#'       `ctx$elements()` when that distinction matters.}
#'     \item{`clip_x0`…`clip_y1`}{the innermost clip box, which is the whole
#'       page when the node is unclipped.}
#'     \item{`vp`, `vp_x0`…`vp_y1`}{the node's viewport: an id that nodes
#'       sharing a viewport share, and that viewport's own device-px extent.
#'       Not the same as the clip box — an unclipped viewport still has an
#'       extent, and a mark can leave it.}
#'     \item{`n`}{how many elements the node draws.}
#'     \item{`alpha`, `has_fill`, `has_col`}{the group alpha, and whether a fill
#'       and a stroke are present at all.}
#'     \item{`col`, `fill`}{stroke and fill colour as `0xRRGGBBAA` packed into a
#'       double (not an integer — the value overflows a signed 32-bit int once
#'       red reaches 128). Group alpha is already folded in.}
#'     \item{`fill_kind`}{`"none"`, `"solid"`, `"linear"`, `"radial"`,
#'       `"pattern"` or `"hatch"`. A gradient has no single colour, so a rule
#'       reasoning about colour must check this before reading `fill`.}
#'     \item{`lwd_px`}{stroke width in device pixels.}
#'     \item{`font_px`}{text size in device pixels; `0` for everything else.}
#'     \item{`notdef`}{how many characters of a text node shaped to glyph 0 —
#'       no font on this machine has them, and they will render as tofu boxes.}
#'   }
#'
#'   `ctx` carries:
#'   \describe{
#'     \item{`w`, `h`, `dpi`}{the page in device pixels, and its resolution.}
#'     \item{`min_text_px`, `min_text_pt`, `min_contrast`, `max_overplot`,
#'       `cvd`, `min_cvd_delta`}{the thresholds [vl_lint()] was called with.}
#'     \item{`pixel(x, y)`}{one composited RGBA pixel, as a length-4 vector.}
#'     \item{`region(x0, y0, x1, y1)`}{every composited pixel in a box, as a
#'       4-column RGBA matrix — cheaper and steadier than probing point by
#'       point, since a single probe can land on an incidental gridline.}
#'     \item{`elements()`}{the per-element table (`key`, `panel`, `name`,
#'       `kind`, `node`, box), which is what to use when a node is a batch: a
#'       scatter is one node whose box is the union over every point.}
#'   }
#'
#'   `pixel()`, `region()` and `elements()` are all lazy. Rendering the scene to
#'   look at it is the expensive part of linting, and most rules never need to.
#' @param description One line, shown by `vl_lint_rules()`.
#' @param kinds Node kinds the rule looks at, e.g. `"text"`. The rule is skipped
#'   when the scene contains none of them. `NULL` (default) means "any".
#' @param needs_pixels Whether the rule renders the scene. Reported by
#'   `vl_lint_rules()` so a caller can select the cheap rules for a tight loop.
#' @param tags Free-form labels for grouping rules, e.g. `"accessibility"`.
#' @return Invisibly, `name`.
#' @seealso [vl_lint()], [vl_lint_rules()]
#' @examples
#' vl_lint_rule("no_hexagons", function(scene, nodes, ctx) {
#'   hits <- nodes[nodes$kind == "hexagon", , drop = FALSE]
#'   if (!nrow(hits)) return(NULL)
#'   vl_lint_finding("no_hexagons", "note", hits, "hexagons are banned here")
#' }, "example rule", kinds = "hexagon")
#' @export
vl_lint_rule <- function(
  name,
  fn,
  description = "",
  kinds = NULL,
  needs_pixels = FALSE,
  tags = character()
) {
  if (!is.character(name) || length(name) != 1L) {
    cli::cli_abort("{.arg name} must be a single string.")
  }
  if (!is.function(fn)) {
    cli::cli_abort("{.arg fn} must be a function.")
  }
  if (!is.null(kinds) && !is.character(kinds)) {
    cli::cli_abort("{.arg kinds} must be a character vector or {.code NULL}.")
  }
  assign(
    name,
    list(
      fn = fn,
      description = description,
      kinds = kinds,
      needs_pixels = isTRUE(needs_pixels),
      tags = as.character(tags)
    ),
    envir = .lint_rules
  )
  invisible(name)
}

#' @rdname vl_lint_rule
#' @return `vl_lint_rules()`: a data frame of registered rules, with the
#'   `kinds` a rule looks at, whether it renders the scene, and its `tags`.
#' @export
vl_lint_rules <- function() {
  nm <- sort(ls(.lint_rules))
  meta <- lapply(nm, function(n) get(n, envir = .lint_rules))
  join <- function(field) {
    vapply(meta, function(m) paste(m[[field]], collapse = ", "), "")
  }
  data.frame(
    rule = nm,
    description = vapply(meta, function(m) m$description, ""),
    kinds = join("kinds"),
    needs_pixels = vapply(meta, function(m) isTRUE(m$needs_pixels), TRUE),
    tags = join("tags"),
    row.names = NULL,
    stringsAsFactors = FALSE
  )
}

#' Build a lint finding
#'
#' The return shape [vl_lint_rule()] functions must produce. Vectorised over
#' `nodes`, so a rule matches rows and describes them in one call.
#'
#' @param rule Rule id.
#' @param severity `"warning"` (likely a real defect) or `"note"`.
#' @param nodes The matching rows of the node table.
#' @param message One message, or one per row.
#' @return A data frame of findings, one row per node, with the node's
#'   device-px box carried through in `x0`/`y0`/`x1`/`y1` so a caller can point
#'   at the finding on the image. The box is `NA` when `nodes` has no geometry.
#' @export
vl_lint_finding <- function(
  rule,
  severity = c("warning", "note"),
  nodes,
  message
) {
  severity <- match.arg(severity)
  if (is.null(nodes) || !nrow(nodes)) {
    return(NULL)
  }
  # A rule may match rows of something other than the node table, so take the
  # box when it is there and say nothing when it is not.
  box <- function(nm) {
    if (is.null(nodes[[nm]])) NA_real_ else as.numeric(nodes[[nm]])
  }
  data.frame(
    rule = rule,
    severity = severity,
    node = ifelse(nzchar(nodes$name), nodes$name, nodes$kind),
    message = rep_len(message, nrow(nodes)),
    x0 = box("x0"),
    y0 = box("y0"),
    x1 = box("x1"),
    y1 = box("y1"),
    row.names = NULL,
    stringsAsFactors = FALSE
  )
}

# The canonical finding columns. Every rule's return value is coerced to exactly
# these before the results are stacked.
.lint_cols <- c("rule", "severity", "node", "message", "x0", "y0", "x1", "y1")

.lint_no_findings <- function() {
  data.frame(
    rule = character(),
    severity = character(),
    node = character(),
    message = character(),
    x0 = numeric(),
    y0 = numeric(),
    x1 = numeric(),
    y1 = numeric(),
    stringsAsFactors = FALSE
  )
}

# Coerce one rule's return value to `.lint_cols`. Rules built on
# `vl_lint_finding()` already comply; one that hand-builds a data frame may not,
# and `rbind()` needs every frame to agree on its columns.
.lint_normalize <- function(x, id) {
  if (is.null(x) || !nrow(x)) {
    return(NULL)
  }
  absent <- setdiff(c("rule", "severity", "node", "message"), names(x))
  if (length(absent)) {
    cli::cli_abort(c(
      "returned a data frame without the required column{?s} {.field {absent}}",
      i = "Build findings with {.fn vl_lint_finding}."
    ))
  }
  for (nm in c("x0", "y0", "x1", "y1")) {
    if (is.null(x[[nm]])) {
      x[[nm]] <- NA_real_
    }
  }
  x[, .lint_cols, drop = FALSE]
}

# Stack findings from one rule that reports at more than one severity. Drops the
# `NULL`s `vl_lint_finding()` returns for "nothing matched".
.lint_bind <- function(...) {
  parts <- Filter(function(x) !is.null(x) && nrow(x), list(...))
  if (!length(parts)) {
    return(NULL)
  }
  do.call(rbind, parts)
}

# Apply the caller's per-rule severity override. A rule declares the severity of
# each finding, which is the expressive place for it -- `truncated` reports cut
# text as a warning and a cut mark as a note -- so this reassigns rather than
# asks the rule again.
.lint_reseverity <- function(out, severity) {
  if (is.null(severity)) {
    return(out)
  }
  if (!is.character(severity) || is.null(names(severity))) {
    cli::cli_abort(
      "{.arg severity} must be a named character vector, e.g. \\
       {.code c(tiny_text = \"note\")}."
    )
  }
  bad <- setdiff(severity, c("warning", "note"))
  if (length(bad)) {
    cli::cli_abort(
      "Severity must be {.val warning} or {.val note}, not {.val {bad}}."
    )
  }
  for (r in names(severity)) {
    out$severity[out$rule == r] <- severity[[r]]
  }
  out
}

# Drop findings the caller has accepted. Suppression is by node rather than by
# rule -- `rules =` already selects rules -- because the usual case is one
# deliberate oddity in an otherwise clean figure, and without this a project can
# never reach a clean lint to assert on.
.lint_exclude <- function(out, exclude, nodes) {
  if (!length(exclude)) {
    return(out)
  }
  # A stale exclude list is worth hearing about: silently suppressing nothing
  # looks exactly like suppressing something.
  known <- unique(c(nodes$name, nodes$id, nodes$kind))
  unused <- setdiff(exclude, known)
  if (length(unused)) {
    cli::cli_warn(
      "{.arg exclude} matches nothing in this scene: {.val {unused}}."
    )
  }
  out[!out$node %in% exclude, , drop = FALSE]
}

# A rule that fails is reported, not fatal. The registry is open to downstream
# packages, so one broken rule must not cost the findings of every other rule --
# and an opaque `Error in get(id, ...)$fn(...)` does not say which rule broke.
.lint_rule_error <- function(id, e) {
  data.frame(
    rule = "rule_error",
    severity = "warning",
    node = id,
    message = paste0("the rule failed: ", conditionMessage(e)),
    x0 = NA_real_,
    y0 = NA_real_,
    x1 = NA_real_,
    y1 = NA_real_,
    stringsAsFactors = FALSE
  )
}

#' Check a scene for likely mistakes
#'
#' Static analysis for graphics. `vl_lint()` resolves the scene and inspects the
#' geometry the renderer would draw with, reporting the things people normally
#' find by squinting at the output: a mark that landed off-canvas, a label too
#' small to read, text that will not contrast with what is behind it, an element
#' that is invisible because nothing was ever going to paint it.
#'
#' This is possible because vellum resolves layout and text metrics *before*
#' drawing. A layer above grid cannot ask "how many pixels tall is this label",
#' because the answer does not exist until a device is open.
#'
#' The rule set is extensible — see [vl_lint_rule()].
#'
#' @param scene A [vl_scene()], or anything with an [as_vellum_scene()] method.
#' @param rules Rule ids to run; `NULL` (default) runs all registered rules.
#' @param exclude Node names (or ids, or kinds) whose findings to drop — the
#'   deliberate oddity you have already looked at and accepted. Suppression is by
#'   node because `rules` already selects rules, and without it a figure with one
#'   intentional off-canvas mark could never reach a clean lint to assert on. An
#'   entry matching nothing in the scene warns, since a stale exclude list looks
#'   exactly like a working one.
#' @param severity Named character vector overriding a rule's own severity, e.g.
#'   `c(tiny_text = "note")`. Useful when a project cares about a rule more, or
#'   less, than vellum does.
#' @param min_text_px Text shorter than this many device pixels is flagged as
#'   illegible. Default `7`.
#' @param min_text_pt Text smaller than this many points is flagged as
#'   illegible. Default `6`.
#'
#'   The two floors answer different questions and `tiny_text` fires on either.
#'   Device pixels decide whether the glyphs survive rasterisation, and points
#'   decide whether a human can read them — which is why a pixel floor alone is
#'   not enough: `font_px` scales with `dpi`, so a 4 pt label rendered at
#'   `dpi = 300` clears a 7 px floor comfortably while remaining illegible on
#'   paper.
#' @param min_contrast Minimum text-to-backdrop contrast ratio before
#'   `low_contrast` fires. Default `3` (WCAG AA for large text); WCAG AA for
#'   body text is `4.5`.
#' @param cvd Colour-vision deficiencies `cvd_collision` should check:
#'   `"deuteranopia"` (the default, and the most common form),
#'   `"protanopia"`, `"tritanopia"`, `"achromatopsia"` — which doubles as
#'   "will this survive a greyscale printer" — or `"none"` to switch the rule
#'   off. Simulated with the same matrices `render(cvd = )` draws with.
#' @param min_cvd_delta How close two colours may come, as an Oklab distance
#'   after simulation, before `cvd_collision` calls them the same colour.
#'   Default `0.06`. Two references for that number: ggplot2's default
#'   three-colour palette puts red and green `0.325` apart in normal vision and
#'   `0.048` apart under deuteranopia, while the closest pair in the CVD-safe
#'   Okabe-Ito palette stays at `0.075`.
#' @param max_overplot How many times an average pixel inside a batched mark's
#'   own extent may be painted before `overplotted` fires. Default `8`; a
#'   well-spread scatter sits below `1`, a few thousand points around `4`, and a
#'   dense cluster in the hundreds.
#' @return A data frame of findings, empty if the scene is clean: `rule`,
#'   `severity`, `node`, `message`, and the finding's device-px box
#'   (`x0`, `y0`, `x1`, `y1`, `NA` where a rule reported something with no
#'   geometry). Printing shows a grouped summary.
#'
#'   A rule that fails does not abort the lint: it is reported as a
#'   `rule_error` finding naming the rule, and the other rules still run.
#' @seealso [vl_lint_rule()], [scene_stats()], [why_size()]
#' @examples
#' # A label pushed off the page, and one too small to read.
#' s <- vl_scene(3, 2) |>
#'   draw(text_grob("off the edge", x = 1.6, y = 0.5)) |>
#'   draw(text_grob("tiny", x = 0.5, y = 0.2, gp = vl_gpar(fontsize = 2)))
#' vl_lint(s)
#' @export
vl_lint <- function(
  scene,
  rules = NULL,
  exclude = NULL,
  severity = NULL,
  min_text_px = 7,
  min_text_pt = 6,
  min_contrast = 3,
  max_overplot = 8,
  cvd = "deuteranopia",
  min_cvd_delta = 0.06
) {
  # Shares `render()`'s list of valid deficiencies, so the two cannot drift.
  cvd <- setdiff(cvd, "none")
  bad <- setdiff(cvd, .CVD_KINDS)
  if (length(bad)) {
    cli::cli_abort("Unknown {.arg cvd} value{?s}: {.val {bad}}.")
  }
  scene <- as_vellum_scene(scene)
  s <- .scene_to_backend(scene)
  nodes <- as.data.frame(s$lint_table(), stringsAsFactors = FALSE)
  d <- s$dim()
  # Everything that costs a render or a second backend call is behind a closure
  # and memoised: most rules never need pixels, and rasterising the scene to
  # look at it is the expensive part of linting.
  raster <- NULL
  pixels <- function() {
    if (is.null(raster)) {
      raster <<- s$rgba()
    }
    raster
  }
  elements <- NULL
  clampx <- function(x) pmax(1L, pmin(d[1], as.integer(round(x))))
  clampy <- function(y) pmax(1L, pmin(d[2], as.integer(round(y))))
  ctx <- list(
    w = d[1],
    h = d[2],
    dpi = scene@dpi,
    min_text_px = min_text_px,
    min_text_pt = min_text_pt,
    min_contrast = min_contrast,
    max_overplot = max_overplot,
    cvd = cvd,
    min_cvd_delta = min_cvd_delta,
    pixel = function(x, y) {
      px <- pixels()
      i <- ((clampy(y) - 1L) * d[1] + (clampx(x) - 1L)) * 4L
      px[i + 1:4]
    },
    # Every pixel in a box, as a 4-column RGBA matrix. A single probe can land
    # on an incidental gridline; a block cannot.
    region = function(x0, y0, x1, y1) {
      px <- pixels()
      xs <- seq.int(clampx(min(x0, x1)), clampx(max(x0, x1)))
      ys <- seq.int(clampy(min(y0, y1)), clampy(max(y0, y1)))
      i <- rep((ys - 1L) * d[1], each = length(xs)) + rep(xs - 1L, length(ys))
      matrix(
        px[rep(i * 4L, each = 4L) + seq_len(4L)],
        ncol = 4L,
        byrow = TRUE,
        dimnames = list(NULL, c("r", "g", "b", "a"))
      )
    },
    # Per-element geometry. A batched mark is ONE node whose box is the union
    # over every element, so this is the only honest view of a scatter.
    elements = function() {
      if (is.null(elements)) {
        elements <<- as.data.frame(
          s$element_table(),
          stringsAsFactors = FALSE
        )
      }
      elements
    }
  )
  ids <- if (is.null(rules)) ls(.lint_rules) else rules
  unknown <- setdiff(ids, ls(.lint_rules))
  if (length(unknown)) {
    cli::cli_abort("Unknown lint rule{?s}: {.val {unknown}}.")
  }
  out <- lapply(sort(ids), function(id) {
    rule <- get(id, envir = .lint_rules)
    # A rule that declares the kinds it reads is skipped when the scene has
    # none of them, which is both a saving and a statement of intent.
    if (!is.null(rule$kinds) && !any(nodes$kind %in% rule$kinds)) {
      return(NULL)
    }
    tryCatch(
      .lint_normalize(rule$fn(scene, nodes, ctx), id),
      error = function(e) .lint_rule_error(id, e)
    )
  })
  out <- do.call(rbind, out[!vapply(out, is.null, logical(1))])
  if (is.null(out)) {
    out <- .lint_no_findings()
  } else {
    out <- .lint_reseverity(out, severity)
    out <- .lint_exclude(out, exclude, nodes)
    # Warnings first, then by rule, so the important things are at the top.
    out <- out[order(out$severity != "warning", out$rule), , drop = FALSE]
    row.names(out) <- NULL
  }
  structure(out, class = c("vellum_lint", class(out)))
}

#' Fail on lint findings
#'
#' `vl_lint()` for a test suite or a CI job: run the rules and stop if anything
#' turns up. A figure that lints clean today stays that way, in the same spirit
#' as [font_pin()] and [scene_hash()] — with the difference that this one
#' catches defects rather than changes.
#'
#' @param scene A [vl_scene()], or anything with an [as_vellum_scene()] method.
#' @param ... Passed to [vl_lint()] — `rules`, `exclude`, the thresholds.
#' @param severity `"warning"` (default) fails only on warnings; `"note"` fails
#'   on anything at all.
#' @param on `"error"` (default) or `"warn"`.
#' @return Invisibly, the findings that triggered the failure — a zero-row frame
#'   when the scene is clean.
#' @seealso [vl_lint()], [vl_lint_overlay()] to see what was reported.
#' @examples
#' clean <- vl_scene(3, 2) |> draw(text_grob("fine", gp = vl_gpar(fontsize = 12)))
#' vl_lint_assert(clean)
#'
#' # In a test:
#' # test_that("the figure has no lint findings", vl_lint_assert(my_plot()))
#' @export
vl_lint_assert <- function(
  scene,
  ...,
  severity = c("warning", "note"),
  on = c("error", "warn")
) {
  severity <- match.arg(severity)
  on <- match.arg(on)
  found <- vl_lint(scene, ...)
  bad <- if (severity == "warning") {
    found[found$severity == "warning", , drop = FALSE]
  } else {
    found
  }
  if (nrow(bad)) {
    # Braces are doubled because a rule's message is data, not a glue template,
    # and a downstream rule is free to put a `{` in one.
    lines <- gsub(
      "\\{",
      "{{",
      sprintf("[%s] %s: %s", bad$rule, bad$node, bad$message)
    )
    lines <- gsub("\\}", "}}", lines)
    msg <- c(
      "Scene has {nrow(bad)} lint finding{?s}.",
      stats::setNames(lines, rep("*", length(lines)))
    )
    if (on == "error") {
      cli::cli_abort(msg)
    } else {
      cli::cli_warn(msg)
    }
  }
  invisible(bad)
}

#' Draw lint findings onto the scene
#'
#' Puts a box around every finding that has geometry, and labels it with the
#' rules that fired. For a graphics linter this is usually the fastest way to
#' understand a report: a message says a mark is clipped, an outline shows you
#' which one.
#'
#' Findings with no geometry (a `rule_error`, or a rule reporting something
#' scene-wide) have nothing to point at and are skipped.
#'
#' @param scene A [vl_scene()], or anything with an [as_vellum_scene()] method.
#' @param findings The result of [vl_lint()]. `NULL` (default) lints `scene`.
#' @param labels Whether to write the rule name beside each box.
#' @return A new scene: `scene` with the overlay drawn on top, at page level.
#' @seealso [vl_lint()], [vl_lint_assert()]
#' @examples
#' s <- vl_scene(3, 2) |>
#'   draw(text_grob("off the edge", x = 1.6, y = 0.5)) |>
#'   draw(text_grob("tiny", x = 0.5, y = 0.2, gp = vl_gpar(fontsize = 2)))
#' # display(vl_lint_overlay(s))
#' nrow(vl_lint(s)) > 0
#' @export
vl_lint_overlay <- function(scene, findings = NULL, labels = TRUE) {
  scene <- as_vellum_scene(scene)
  findings <- findings %||% vl_lint(scene)
  keep <- is.finite(findings$x0) &
    is.finite(findings$y0) &
    is.finite(findings$x1) &
    is.finite(findings$y1)
  f <- findings[keep, , drop = FALSE]
  if (!nrow(f)) {
    return(scene)
  }
  d <- .scene_to_backend(scene)$dim()
  w <- d[1]
  h <- d[2]
  # Findings often share a node -- a label can be both tiny and low-contrast --
  # so draw one box per distinct box and name every rule that landed on it.
  key <- paste(
    round(f$x0, 1),
    round(f$y0, 1),
    round(f$x1, 1),
    round(f$y1, 1),
    sep = "|"
  )
  pad <- 2
  grobs <- list()
  for (k in unique(key)) {
    rows <- f[key == k, , drop = FALSE]
    warn <- any(rows$severity == "warning")
    col <- if (warn) "#D62728" else "#FF7F0E"
    # Outward padding, so the box surrounds the mark instead of coinciding with
    # it -- and so a zero-size mark still gets something visible.
    x0 <- rows$x0[1] - pad
    y0 <- rows$y0[1] - pad
    x1 <- rows$x1[1] + pad
    y1 <- rows$y1[1] + pad
    grobs[[length(grobs) + 1L]] <- rect_grob(
      x = (x0 + x1) / 2 / w,
      # Device pixels run y-down and the page runs y-up.
      y = 1 - (y0 + y1) / 2 / h,
      width = (x1 - x0) / w,
      height = (y1 - y0) / h,
      gp = vl_gpar(fill = NA, col = col, lwd = 1.5),
      name = paste0("lint_box_", length(grobs) + 1L)
    )
    if (labels) {
      # Above the box, or below it when that would leave the page.
      above <- y0 - pad
      grobs[[length(grobs) + 1L]] <- text_grob(
        paste(unique(rows$rule), collapse = ", "),
        x = x0 / w,
        y = if (above > 12) 1 - above / h else 1 - (y1 + 12) / h,
        just = c("left", "bottom"),
        gp = vl_gpar(col = col, fontsize = 7),
        name = paste0("lint_label_", length(grobs) + 1L)
      )
    }
  }
  # Appended to the ROOT's children, not drawn through `draw()`: a scene left
  # inside a pushed viewport would otherwise put the overlay in that viewport's
  # coordinates, and these boxes are in page npc.
  root <- .materialize(scene)
  root@children <- c(root@children, grobs)
  .scene_with_root(scene, root)
}

#' @export
print.vellum_lint <- function(x, ...) {
  if (!nrow(x)) {
    cli::cli_alert_success("No lint findings.")
    return(invisible(x))
  }
  n_warn <- sum(x$severity == "warning")
  cli::cli_text("{.strong {nrow(x)}} lint finding{?s} ({n_warn} warning{?s}):")
  for (r in unique(x$rule)) {
    rows <- x[x$rule == r, , drop = FALSE]
    bullet <- if (rows$severity[1] == "warning") "x" else "i"
    cli::cli_bullets(stats::setNames(
      sprintf("[%s] %s: %s", r, rows$node, rows$message),
      rep(bullet, nrow(rows))
    ))
  }
  invisible(x)
}

# --- the built-in rules ------------------------------------------------------
# Registered in `.onLoad` (see zzz.R) so the registry survives a reload.

.register_builtin_lint_rules <- function() {
  vl_lint_rule(
    "offscreen",
    function(scene, nodes, ctx) {
      off <- nodes$x1 < 0 | nodes$y1 < 0 | nodes$x0 > ctx$w | nodes$y0 > ctx$h
      vl_lint_finding(
        "offscreen",
        "warning",
        nodes[off, , drop = FALSE],
        "drawn entirely outside the page - check the coordinates or the scale"
      )
    },
    "A mark lies completely off the canvas."
  )

  vl_lint_rule(
    "clipped_away",
    function(scene, nodes, ctx) {
      # Off-page is reported by `offscreen`; this is the subtler case of a mark
      # inside the page but outside its own viewport's clip.
      onpage <- !(nodes$x1 < 0 |
        nodes$y1 < 0 |
        nodes$x0 > ctx$w |
        nodes$y0 > ctx$h)
      gone <- onpage &
        (nodes$x1 < nodes$clip_x0 |
          nodes$y1 < nodes$clip_y0 |
          nodes$x0 > nodes$clip_x1 |
          nodes$y0 > nodes$clip_y1)
      vl_lint_finding(
        "clipped_away",
        "warning",
        nodes[gone, , drop = FALSE],
        "entirely outside its viewport's clip region, so nothing is drawn"
      )
    },
    "A mark is clipped out of existence by its viewport."
  )

  vl_lint_rule(
    "invisible",
    function(scene, nodes, ctx) {
      # Nothing will paint it: fully transparent, or neither a fill nor a stroke.
      # A fill can also be present but fully transparent in its own right --
      # `fill = "#FF000000"` sets a colour and then asks for none of it -- which
      # `has_fill` alone cannot see.
      opaque_fill <- nodes$has_fill == 1L &
        (nodes$fill_kind != "solid" | .lint_alpha(nodes$fill) > 0)
      blank <- nodes$alpha <= 0 | (!opaque_fill & nodes$has_col == 0L)
      vl_lint_finding(
        "invisible",
        "warning",
        nodes[blank, , drop = FALSE],
        "nothing will paint this - alpha is 0, or it has no opaque fill and no stroke"
      )
    },
    "An element has no fill, no stroke, or zero alpha."
  )

  vl_lint_rule(
    "degenerate",
    function(scene, nodes, ctx) {
      flat <- (nodes$x1 - nodes$x0) <= 0 &
        (nodes$y1 - nodes$y0) <= 0 &
        nodes$kind != "text"
      vl_lint_finding(
        "degenerate",
        "note",
        nodes[flat, , drop = FALSE],
        "zero width and height - it will not be visible"
      )
    },
    "An element resolves to zero size."
  )

  vl_lint_rule(
    "truncated",
    function(scene, nodes, ctx) {
      # `offscreen` and `clipped_away` both need the mark to be *entirely* gone.
      # This is the defect that actually ships: the axis label with its last two
      # characters cut off, the title chopped by the page edge. The visible
      # region is the node's clip intersected with the page -- `lint_table()`
      # reports the whole page as the clip when a node is unclipped, so the two
      # cases fall out of the same arithmetic.
      vx0 <- pmax(0, nodes$clip_x0)
      vy0 <- pmax(0, nodes$clip_y0)
      vx1 <- pmin(ctx$w, nodes$clip_x1)
      vy1 <- pmin(ctx$h, nodes$clip_y1)
      # A whole pixel of overhang before this is a defect. A mark filling its
      # viewport sits exactly on the boundary, stroke width is not in the box at
      # all, and text placed a hair from the page edge loses a fraction of a
      # descender row -- none of which is worth a finding.
      tol <- 1
      w <- nodes$x1 - nodes$x0
      h <- nodes$y1 - nodes$y0
      ow <- pmin(nodes$x1, vx1) - pmax(nodes$x0, vx0)
      oh <- pmin(nodes$y1, vy1) - pmax(nodes$y0, vy0)
      lost <- pmax(w - ow, h - oh)
      # The worst axis, not the area: a label losing half its width is half
      # unreadable whatever its height does.
      kept <- pmin(ifelse(w > 0, ow / w, 1), ifelse(h > 0, oh / h, 1))
      overlaps <- ow > 0 & oh > 0
      # A batched mark is one node whose box is the union over every element, so
      # a scatter always grazes its panel edge and a small loss says nothing
      # about any individual point. Only a union box that is mostly gone means
      # the batch itself landed wrong; the per-element view is `ctx$elements`.
      enough <- ifelse(nodes$n > 1L, kept < 0.5, lost > tol)
      cut <- overlaps & enough
      if (!any(cut)) {
        return(NULL)
      }
      hits <- nodes[cut, , drop = FALSE]
      kept <- kept[cut]
      offpage <- hits$x0 < -tol |
        hits$y0 < -tol |
        hits$x1 > ctx$w + tol |
        hits$y1 > ctx$h + tol
      msg <- sprintf(
        "%.0f px (%.0f%%) of it is cut off by %s",
        lost[cut],
        100 * (1 - kept),
        ifelse(offpage, "the page edge", "its viewport's clip")
      )
      # A cut label is unreadable; a cut mark is often a deliberate crop.
      istext <- hits$kind == "text"
      .lint_bind(
        vl_lint_finding(
          "truncated",
          "warning",
          hits[istext, , drop = FALSE],
          msg[istext]
        ),
        vl_lint_finding(
          "truncated",
          "note",
          hits[!istext, , drop = FALSE],
          msg[!istext]
        )
      )
    },
    "A mark is partly cut off by the page edge or by its viewport's clip."
  )

  vl_lint_rule(
    "subpixel",
    function(scene, nodes, ctx) {
      # An area mark thinner than a pixel does not survive rasterisation as
      # itself: it aliases into a faint smear whose weight changes with dpi.
      # Restricted to filled area kinds -- a horizontal segment legitimately has
      # a zero-height box, because its thickness comes from `lwd`, not geometry.
      area <- c("rect", "roundrect", "circle", "hexagon", "sector", "raster")
      w <- nodes$x1 - nodes$x0
      h <- nodes$y1 - nodes$y0
      thin <- nodes$kind %in%
        area &
        nodes$has_fill == 1L &
        pmin(w, h) < 1 &
        # `degenerate` owns the case where the mark has no extent at all.
        !(w <= 0 & h <= 0)
      hits <- nodes[thin, , drop = FALSE]
      if (!nrow(hits)) {
        return(NULL)
      }
      vl_lint_finding(
        "subpixel",
        "note",
        hits,
        sprintf(
          "%.2f x %.2f px - thinner than one pixel, so it renders as a smear",
          hits$x1 - hits$x0,
          hits$y1 - hits$y0
        )
      )
    },
    "An area mark is less than one pixel across."
  )

  vl_lint_rule(
    "blank_label",
    function(scene, nodes, ctx) {
      blank <- nodes$kind == "text" & !grepl("[^[:space:]]", nodes$label)
      vl_lint_finding(
        "blank_label",
        "note",
        nodes[blank, , drop = FALSE],
        "the label is empty or all whitespace, so this draws nothing"
      )
    },
    "A text mark has no visible characters.",
    kinds = "text"
  )

  vl_lint_rule(
    "duplicate_name",
    function(scene, nodes, ctx) {
      named <- nzchar(nodes$name)
      dup <- named & nodes$name %in% nodes$name[named & duplicated(nodes$name)]
      hits <- nodes[dup, , drop = FALSE]
      if (!nrow(hits)) {
        return(NULL)
      }
      # `get_node()` and `edit_node()` take the first match and say nothing, so
      # a duplicate name silently makes every later one unaddressable -- which
      # also means `vl_repel()` cannot move it.
      vl_lint_finding(
        "duplicate_name",
        "warning",
        hits,
        sprintf(
          "%d nodes share this name, and only the first can be addressed",
          as.integer(table(hits$name)[hits$name])
        )
      )
    },
    "Two nodes share a name, so only the first can be addressed."
  )

  vl_lint_rule(
    "double_draw",
    function(scene, nodes, ctx) {
      # Two nodes you cannot tell apart: same kind, same box, same paint. One of
      # them is doing nothing, and the usual cause is a `draw()` that ran twice.
      #
      # Drawing the same box twice is a legitimate idiom when the two differ --
      # a filled rect and then the same rect with `fill = NA` to put its border
      # on top -- so the key covers everything about the paint the node table can
      # see, down to the fill and stroke colours.
      paint <- nodes$has_fill == 1L | nodes$has_col == 1L
      key <- paste(
        nodes$kind,
        round(nodes$x0, 1),
        round(nodes$y0, 1),
        round(nodes$x1, 1),
        round(nodes$y1, 1),
        nodes$n,
        nodes$has_fill,
        nodes$has_col,
        nodes$alpha,
        nodes$col,
        nodes$fill,
        nodes$fill_kind,
        nodes$lwd_px,
        nodes$label,
        sep = "|"
      )
      dup <- paint & key %in% key[paint & duplicated(key)]
      vl_lint_finding(
        "double_draw",
        "note",
        nodes[dup, , drop = FALSE],
        "an identical mark is drawn in the same place, so one of them is wasted"
      )
    },
    "The same mark is drawn twice in the same place."
  )

  vl_lint_rule(
    "occluded",
    function(scene, nodes, ctx) {
      # An opaque mark completely covered by a later opaque one: ink that never
      # reaches the page, and usually a layer ordering mistake.
      #
      # The covering kinds are restricted to the marks that actually fill their
      # bounding box. A circle covers only ~79% of its box, so containment in a
      # circle's box says nothing -- reporting on it would be wrong, not merely
      # noisy.
      solid <- c("rect", "roundrect", "raster")
      covers <- which(
        nodes$kind %in% solid & nodes$has_fill == 1L & nodes$alpha >= 1
      )
      if (!length(covers)) {
        return(NULL)
      }
      painted <- (nodes$has_fill == 1L | nodes$has_col == 1L) & nodes$alpha > 0
      hidden <- rep(FALSE, nrow(nodes))
      by <- character(nrow(nodes))
      for (j in covers) {
        # Only what was painted *before* the cover, and never the cover itself.
        under <- painted &
          nodes$node < nodes$node[j] &
          nodes$x0 >= nodes$x0[j] &
          nodes$y0 >= nodes$y0[j] &
          nodes$x1 <= nodes$x1[j] &
          nodes$y1 <= nodes$y1[j]
        by[under & !hidden] <- if (nzchar(nodes$name[j])) {
          nodes$name[j]
        } else {
          nodes$kind[j]
        }
        hidden <- hidden | under
      }
      hits <- nodes[hidden, , drop = FALSE]
      if (!nrow(hits)) {
        return(NULL)
      }
      vl_lint_finding(
        "occluded",
        "note",
        hits,
        sprintf("completely covered by %s, drawn later", by[hidden])
      )
    },
    "An opaque mark is completely hidden behind a later one."
  )

  vl_lint_rule(
    "label_on_mark",
    function(scene, nodes, ctx) {
      # A label lying on top of the mark it annotates -- the thing `vl_repel()`
      # exists to fix. `label_overlap` compares text with text; this is text
      # against everything else.
      #
      # The condition is deliberately narrow, because text over a mark is
      # normally the whole point: every panel background has labels over it, and
      # a value label inside a bar is a style, not a defect. So the test is on
      # the fraction of the MARK that the label covers rather than on overlap
      # alone, which leaves a small label on a large mark alone and catches a
      # label swallowing the point it names. Batched nodes are out for the usual
      # reason -- their box is a union, so it is not any one element's extent.
      txt <- nodes[nodes$kind == "text" & nodes$n == 1L, , drop = FALSE]
      marks <- nodes[
        nodes$kind != "text" &
          nodes$n == 1L &
          (nodes$has_fill == 1L | nodes$has_col == 1L) &
          nodes$alpha > 0,
        ,
        drop = FALSE
      ]
      if (!nrow(txt) || !nrow(marks)) {
        return(NULL)
      }
      hit <- rep(FALSE, nrow(txt))
      hidden <- character(nrow(txt))
      area <- (marks$x1 - marks$x0) * (marks$y1 - marks$y0)
      for (i in seq_len(nrow(txt))) {
        ow <- pmin(txt$x1[i], marks$x1) - pmax(txt$x0[i], marks$x0)
        oh <- pmin(txt$y1[i], marks$y1) - pmax(txt$y0[i], marks$y0)
        frac <- ifelse(area > 0, pmax(0, ow) * pmax(0, oh) / area, 0)
        j <- which.max(frac)
        if (length(j) && frac[j] > 0.25) {
          hit[i] <- TRUE
          hidden[i] <- if (nzchar(marks$name[j])) {
            marks$name[j]
          } else {
            marks$kind[j]
          }
        }
      }
      hits <- txt[hit, , drop = FALSE]
      if (!nrow(hits)) {
        return(NULL)
      }
      vl_lint_finding(
        "label_on_mark",
        "note",
        hits,
        sprintf(
          "hides the %s it sits on - vl_repel() would move it clear",
          hidden[hit]
        )
      )
    },
    "A label covers most of the mark it sits on.",
    kinds = "text"
  )

  vl_lint_rule(
    "tiny_text",
    function(scene, nodes, ctx) {
      # Two floors, because `font_px` scales with dpi: a px floor alone stops
      # firing on a print-resolution render (4 pt at 300 dpi is 16.7 px, well
      # clear of a 7 px floor, and still unreadable on paper), and a pt floor
      # alone misses text that is physically fine but rasterises to mush.
      pt <- nodes$font_px * 72 / ctx$dpi
      txt <- nodes$kind == "text" &
        nodes$font_px > 0 &
        (nodes$font_px < ctx$min_text_px | pt < ctx$min_text_pt)
      hits <- nodes[txt, , drop = FALSE]
      if (!nrow(hits)) {
        return(NULL)
      }
      vl_lint_finding(
        "tiny_text",
        "warning",
        hits,
        ifelse(
          hits$font_px < ctx$min_text_px,
          sprintf(
            "%.1f px tall - below the %g px legibility floor",
            hits$font_px,
            ctx$min_text_px
          ),
          sprintf(
            "%.1f pt - below the %g pt legibility floor",
            hits$font_px * 72 / ctx$dpi,
            ctx$min_text_pt
          )
        )
      )
    },
    "Text is too small to read at the rendered size.",
    kinds = "text"
  )

  vl_lint_rule(
    "label_overlap",
    function(scene, nodes, ctx) {
      txt <- nodes[nodes$kind == "text", , drop = FALSE]
      if (nrow(txt) < 2L) {
        return(NULL)
      }
      hit <- rep(FALSE, nrow(txt))
      for (i in seq_len(nrow(txt) - 1L)) {
        for (j in seq(i + 1L, nrow(txt))) {
          if (
            txt$x0[i] < txt$x1[j] &&
              txt$x1[i] > txt$x0[j] &&
              txt$y0[i] < txt$y1[j] &&
              txt$y1[i] > txt$y0[j]
          ) {
            hit[i] <- TRUE
            hit[j] <- TRUE
          }
        }
      }
      vl_lint_finding(
        "label_overlap",
        "note",
        txt[hit, , drop = FALSE],
        "its box overlaps another label"
      )
    },
    "Two text labels overlap.",
    kinds = "text"
  )

  vl_lint_rule(
    "invisible_fill",
    function(scene, nodes, ctx) {
      # A mark filled in the page's own background colour. It is painted, it is
      # the right size and in the right place, and it cannot be seen -- so no
      # geometric rule will ever report it.
      bg <- .rs_col(scene@bg) %||% c(255L, 255L, 255L, 255L)
      solid <- nodes$fill_kind == "solid" & .lint_alpha(nodes$fill) > 0
      packed <- bg[1] * 2^24 + bg[2] * 2^16 + bg[3] * 2^8 + bg[4]
      # An outline saves it: a white-filled, black-stroked mark is a legitimate
      # and common thing to draw on a white page.
      same <- solid & nodes$fill == packed & nodes$has_col == 0L
      vl_lint_finding(
        "invisible_fill",
        "warning",
        nodes[same, , drop = FALSE],
        "filled in the page background colour, with no stroke to outline it"
      )
    },
    "A mark is filled in the background colour and has no outline."
  )

  vl_lint_rule(
    "hairline",
    function(scene, nodes, ctx) {
      # A stroke thinner than half a pixel. The raster backends render it as a
      # faint, dpi-dependent smudge and the vector backends as a crisp line, so
      # it is also a place where the outputs stop agreeing.
      thin <- nodes$has_col == 1L &
        nodes$kind != "text" &
        nodes$lwd_px > 0 &
        nodes$lwd_px < 0.5
      hits <- nodes[thin, , drop = FALSE]
      if (!nrow(hits)) {
        return(NULL)
      }
      vl_lint_finding(
        "hairline",
        "note",
        hits,
        sprintf(
          "stroked at %.2f px - too thin to render consistently",
          hits$lwd_px
        )
      )
    },
    "A stroke is thinner than half a device pixel."
  )

  vl_lint_rule(
    "bleed",
    function(scene, nodes, ctx) {
      # A mark drawn outside the viewport it was pushed into, where nothing
      # clips it. Sometimes deliberate -- an annotation reaching into the margin
      # -- so this is only a note, but it is also what a scale error looks like
      # before it grows big enough for `truncated` to notice.
      tol <- 1
      # A viewport as big as the page is the page: escaping it is not a thing.
      real_vp <- (nodes$vp_x1 - nodes$vp_x0) < ctx$w - tol |
        (nodes$vp_y1 - nodes$vp_y0) < ctx$h - tol
      # Nothing clips it: the effective clip is still the whole page.
      unclipped <- nodes$clip_x0 <= tol &
        nodes$clip_y0 <= tol &
        nodes$clip_x1 >= ctx$w - tol &
        nodes$clip_y1 >= ctx$h - tol
      out <- nodes$x0 < nodes$vp_x0 - tol |
        nodes$y0 < nodes$vp_y0 - tol |
        nodes$x1 > nodes$vp_x1 + tol |
        nodes$y1 > nodes$vp_y1 + tol
      vl_lint_finding(
        "bleed",
        "note",
        nodes[real_vp & unclipped & out, , drop = FALSE],
        "drawn outside its viewport, and nothing clips it"
      )
    },
    "A mark escapes its viewport, which does not clip."
  )

  vl_lint_rule(
    "overplotted",
    function(scene, nodes, ctx) {
      # How many times an average pixel inside a batch's own extent was painted.
      # Measured per node from the element boxes, so it names the layer to fix
      # rather than the scene, and needs no render: a count of marks says
      # nothing about whether they overlap, and overlap is the thing that
      # decides whether a scatter is readable or a blob.
      el <- ctx$elements()
      batches <- nodes[nodes$n > 1L, , drop = FALSE]
      if (!nrow(el) || !nrow(batches)) {
        return(NULL)
      }
      area <- (pmax(0, el$x1 - el$x0) * pmax(0, el$y1 - el$y0))
      per <- vapply(batches$node, function(i) sum(area[el$node == i]), 0)
      box <- (batches$x1 - batches$x0) * (batches$y1 - batches$y0)
      # Bounding boxes over-estimate for round marks (a circle fills ~79% of
      # its box), so this is an index, not a measurement -- the same caveat
      # `scene_stats()` carries.
      density <- ifelse(box > 0, per / box, 0)
      hits <- batches[density > ctx$max_overplot, , drop = FALSE]
      if (!nrow(hits)) {
        return(NULL)
      }
      vl_lint_finding(
        "overplotted",
        "note",
        hits,
        sprintf(
          "an average pixel here is painted ~%.0f times - consider datashade()",
          density[density > ctx$max_overplot]
        )
      )
    },
    "A batched mark overplots itself badly enough to hide its own density."
  )

  vl_lint_rule(
    "font_fallback",
    function(scene, nodes, ctx) {
      # Glyph 0 is `.notdef`: no font on this machine had the character, so the
      # renderer draws a tofu box. Nothing about the label string says so, which
      # is why this needs the shaped glyph stream to see it -- and why it is the
      # rule most worth having on a machine that is not the author's.
      hits <- nodes[nodes$kind == "text" & nodes$notdef > 0L, , drop = FALSE]
      if (!nrow(hits)) {
        return(NULL)
      }
      vl_lint_finding(
        "font_fallback",
        "warning",
        hits,
        sprintf(
          "%d character%s no font here can draw - they render as tofu boxes",
          hits$notdef,
          ifelse(hits$notdef == 1L, "", "s")
        )
      )
    },
    "A character has no glyph in any font on this machine.",
    kinds = "text",
    tags = "reproducibility"
  )

  vl_lint_rule(
    "cvd_collision",
    function(scene, nodes, ctx) {
      if (!length(ctx$cvd)) {
        return(NULL)
      }
      # Two colours a reader is meant to tell apart, that a colour-blind reader
      # cannot. Nobody catches this by looking, because the person looking can
      # see the difference -- which is exactly the kind of defect a linter with
      # the resolved paint in hand should be reporting.
      #
      # Only fully opaque authored colours. A translucent fill's perceived colour
      # is the composite with whatever is behind it, which is not the value in
      # this table, so claiming anything about it would be guesswork.
      opaque <- function(v) v[.lint_alpha(v) == 255]
      fills <- opaque(nodes$fill[nodes$fill_kind == "solid"])
      strokes <- opaque(nodes$col[nodes$has_col == 1L & nodes$kind != "text"])
      cols <- unique(c(fills, strokes))
      if (length(cols) < 2L) {
        return(NULL)
      }
      normal <- .lint_oklab_dist(cols, "")
      # Colours that were nearly the same to begin with are a palette problem,
      # not a CVD one, so only pairs that are clearly distinct in normal vision
      # can collide.
      distinct <- normal >= 2 * ctx$min_cvd_delta
      # A continuous ramp can collide with itself dozens of times over -- a
      # 40-step red-to-green diverging scale yields 57 pairs -- and 57 findings
      # about one palette is a way of saying nothing. Report the worst few, worst
      # meaning furthest apart in normal vision and closest after simulation, and
      # count the rest out loud rather than dropping them silently.
      cap <- 5L
      out <- NULL
      for (kind in ctx$cvd) {
        gone <- distinct & .lint_oklab_dist(cols, kind) < ctx$min_cvd_delta
        hits <- which(gone & upper.tri(gone), arr.ind = TRUE)
        if (!nrow(hits)) {
          next
        }
        hits <- hits[order(-normal[hits]), , drop = FALSE]
        extra <- max(0L, nrow(hits) - cap)
        for (k in seq_len(min(cap, nrow(hits)))) {
          a <- cols[hits[k, 1L]]
          b <- cols[hits[k, 2L]]
          # Report against the last node carrying either colour: the finding is
          # about a pair, and the later mark is the one drawn knowing the other.
          using <- which(
            nodes$fill %in%
              c(a, b) &
              nodes$fill_kind == "solid" |
              nodes$col %in% c(a, b) & nodes$has_col == 1L
          )
          out <- .lint_bind(
            out,
            vl_lint_finding(
              "cvd_collision",
              "warning",
              nodes[max(using), , drop = FALSE],
              sprintf(
                "%s and %s look the same under %s",
                .lint_hex(a),
                .lint_hex(b),
                kind
              )
            )
          )
        }
        if (extra > 0L) {
          out <- .lint_bind(
            out,
            vl_lint_finding(
              "cvd_collision",
              "warning",
              nodes[nrow(nodes), , drop = FALSE],
              sprintf(
                "%d further colour pair%s also collapse under %s",
                extra,
                if (extra == 1L) "" else "s",
                kind
              )
            )
          )
        }
      }
      out
    },
    "Two colours collapse into one under a colour-vision deficiency.",
    tags = "accessibility"
  )

  vl_lint_rule(
    "low_contrast",
    function(scene, nodes, ctx) {
      txt <- nodes[nodes$kind == "text" & nodes$has_col == 1L, , drop = FALSE]
      if (!nrow(txt)) {
        return(NULL)
      }
      ratios <- vapply(
        seq_len(nrow(txt)),
        function(i) {
          fg <- .lint_unpack_col(txt$col[i])
          # Sample the composited image just outside the label's box on all four
          # sides. That is the backdrop the label sits against; sampling under the
          # glyphs would read the glyphs themselves.
          pad <- 2
          pts <- list(
            c(txt$x0[i] - pad, (txt$y0[i] + txt$y1[i]) / 2),
            c(txt$x1[i] + pad, (txt$y0[i] + txt$y1[i]) / 2),
            c((txt$x0[i] + txt$x1[i]) / 2, txt$y0[i] - pad),
            c((txt$x0[i] + txt$x1[i]) / 2, txt$y1[i] + pad)
          )
          lums <- vapply(
            pts,
            function(p) .lint_luminance(ctx$pixel(p[1], p[2])[1:3]),
            0
          )
          # The SECOND-worst of the four sides. Taking the outright worst (`min`)
          # flagged any label a single 2 px probe happened to graze against a nearby
          # tick, gridline or axis rule -- so ordinary dark axis text on white read
          # as ~1:1 because one probe landed on the black axis line. Requiring at
          # least two low-contrast sides ignores that incidental adjacent ink while
          # still catching a label genuinely sitting on a low-contrast field (all
          # sides bad) or straddling a dark region (two sides bad).
          fgl <- .lint_luminance(fg[1:3])
          sort(vapply(lums, function(bl) .lint_contrast(fgl, bl), 0))[2L]
        },
        0
      )
      bad <- ratios < ctx$min_contrast
      hits <- txt[bad, , drop = FALSE]
      if (!nrow(hits)) {
        return(NULL)
      }
      vl_lint_finding(
        "low_contrast",
        "warning",
        hits,
        sprintf(
          "contrast %.1f:1 against its backdrop - below %g:1",
          ratios[bad],
          ctx$min_contrast
        )
      )
    },
    "Text contrast against its backdrop is below the WCAG threshold.",
    kinds = "text",
    needs_pixels = TRUE,
    tags = "accessibility"
  )
}

# 0xRRGGBBAA packed as a double -> c(r, g, b, a). A double, not an integer,
# because the value does not fit in a signed 32-bit int once red reaches 128.
.lint_unpack_col <- function(v) {
  v <- as.numeric(v)
  c(v %/% 2^24, (v %/% 2^16) %% 256, (v %/% 2^8) %% 256, v %% 256)
}

# The alpha channel alone, vectorised over a packed column.
.lint_alpha <- function(v) as.numeric(v) %% 256

# A packed colour as "#RRGGBB", for a message a human has to act on.
.lint_hex <- function(v) {
  c <- .lint_unpack_col(v)
  sprintf("#%02X%02X%02X", c[1], c[2], c[3])
}

# Pairwise perceptual distance between packed colours, as a full symmetric
# matrix, optionally as a viewer with `kind` would see them. Oklab is the space
# the gradient interpolator already uses, and the simulation reuses the render
# path's own matrices -- so this cannot drift from what `render(cvd = )` draws.
.lint_oklab_dist <- function(cols, kind) {
  lab <- matrix(rs_cvd_oklab(as.numeric(cols), kind), ncol = 3L, byrow = TRUE)
  as.matrix(stats::dist(lab))
}

# WCAG relative luminance from 0-255 sRGB.
.lint_luminance <- function(rgb) {
  cs <- rgb / 255
  lin <- ifelse(cs <= 0.03928, cs / 12.92, ((cs + 0.055) / 1.055)^2.4)
  sum(lin * c(0.2126, 0.7152, 0.0722))
}

# WCAG contrast ratio between two relative luminances.
.lint_contrast <- function(a, b) {
  (max(a, b) + 0.05) / (min(a, b) + 0.05)
}
