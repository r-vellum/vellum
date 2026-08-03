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
#' @param fn A function of `(scene, nodes, ctx)` returning a data frame with
#'   columns `rule`, `severity` (`"warning"`/`"note"`), `node`, `message` — or
#'   `NULL` for "nothing found". `nodes` is the resolved per-node table
#'   (device-px `x0`/`y0`/`x1`/`y1`, clip box, `kind`, `name`, `n`, `alpha`,
#'   `has_fill`, `has_col`, `font_px`, `col`, `label`); `ctx` carries the page
#'   size (`w`, `h`), `dpi`, and a `pixel(x, y)` sampler over the rendered image.
#' @param description One line, shown by `vl_lint_rules()`.
#' @return Invisibly, `name`.
#' @seealso [vl_lint()], [vl_lint_rules()]
#' @examples
#' vl_lint_rule("no_hexagons", function(scene, nodes, ctx) {
#'   hits <- nodes[nodes$kind == "hexagon", , drop = FALSE]
#'   if (!nrow(hits)) return(NULL)
#'   vl_lint_finding("no_hexagons", "note", hits, "hexagons are banned here")
#' }, "example rule")
#' @export
vl_lint_rule <- function(name, fn, description = "") {
  if (!is.character(name) || length(name) != 1L) {
    cli::cli_abort("{.arg name} must be a single string.")
  }
  if (!is.function(fn)) {
    cli::cli_abort("{.arg fn} must be a function.")
  }
  assign(name, list(fn = fn, description = description), envir = .lint_rules)
  invisible(name)
}

#' @rdname vl_lint_rule
#' @return `vl_lint_rules()`: a data frame of registered rules.
#' @export
vl_lint_rules <- function() {
  nm <- sort(ls(.lint_rules))
  data.frame(
    rule = nm,
    description = vapply(
      nm,
      function(n) get(n, envir = .lint_rules)$description,
      ""
    ),
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
  min_text_px = 7,
  min_text_pt = 6,
  min_contrast = 3
) {
  scene <- as_vellum_scene(scene)
  s <- .scene_to_backend(scene)
  nodes <- as.data.frame(s$lint_table(), stringsAsFactors = FALSE)
  d <- s$dim()
  raster <- NULL
  ctx <- list(
    w = d[1],
    h = d[2],
    dpi = scene@dpi,
    min_text_px = min_text_px,
    min_text_pt = min_text_pt,
    min_contrast = min_contrast,
    # Sampled lazily: most rules never need pixels, and rendering to look at
    # them is the expensive part of linting.
    pixel = function(x, y) {
      if (is.null(raster)) {
        raster <<- s$rgba()
      }
      x <- max(1L, min(d[1], as.integer(round(x))))
      y <- max(1L, min(d[2], as.integer(round(y))))
      i <- ((y - 1L) * d[1] + (x - 1L)) * 4L
      raster[i + 1:4]
    }
  )
  ids <- if (is.null(rules)) ls(.lint_rules) else rules
  unknown <- setdiff(ids, ls(.lint_rules))
  if (length(unknown)) {
    cli::cli_abort("Unknown lint rule{?s}: {.val {unknown}}.")
  }
  out <- lapply(sort(ids), function(id) {
    tryCatch(
      .lint_normalize(get(id, envir = .lint_rules)$fn(scene, nodes, ctx), id),
      error = function(e) .lint_rule_error(id, e)
    )
  })
  out <- do.call(rbind, out[!vapply(out, is.null, logical(1))])
  if (is.null(out)) {
    out <- .lint_no_findings()
  } else {
    # Warnings first, then by rule, so the important things are at the top.
    out <- out[order(out$severity != "warning", out$rule), , drop = FALSE]
    row.names(out) <- NULL
  }
  structure(out, class = c("vellum_lint", class(out)))
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
      blank <- nodes$alpha <= 0 | (nodes$has_fill == 0L & nodes$has_col == 0L)
      vl_lint_finding(
        "invisible",
        "warning",
        nodes[blank, , drop = FALSE],
        "nothing will paint this - alpha is 0, or both fill and col are absent"
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
    "A text mark has no visible characters."
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
      # on top -- so the key covers everything about the paint that the node
      # table can see. It cannot yet see the fill colour, so two same-box rects
      # in different fills are reported here; the earlier one is invisible in
      # any case, which is what `occluded` would say about it.
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
    "A label covers most of the mark it sits on."
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
    "Text is too small to read at the rendered size."
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
    "Two text labels overlap."
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
    "Text contrast against its backdrop is below the WCAG threshold."
  )
}

# 0xRRGGBBAA packed int -> c(r, g, b, a).
.lint_unpack_col <- function(v) {
  v <- as.numeric(v)
  c(v %/% 2^24, (v %/% 2^16) %% 256, (v %/% 2^8) %% 256, v %% 256)
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
