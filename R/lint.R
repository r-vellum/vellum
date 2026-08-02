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
#' @return A data frame of findings.
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
  data.frame(
    rule = rule,
    severity = severity,
    node = ifelse(nzchar(nodes$name), nodes$name, nodes$kind),
    message = rep_len(message, nrow(nodes)),
    row.names = NULL,
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
#' @param min_contrast Minimum text-to-backdrop contrast ratio before
#'   `low_contrast` fires. Default `3` (WCAG AA for large text); WCAG AA for
#'   body text is `4.5`.
#' @return A data frame of findings (`rule`, `severity`, `node`, `message`),
#'   empty if the scene is clean. Printing shows a grouped summary.
#' @seealso [vl_lint_rule()], [scene_stats()], [why_size()]
#' @examples
#' # A label pushed off the page, and one too small to read.
#' s <- vl_scene(3, 2) |>
#'   draw(text_grob("off the edge", x = 1.6, y = 0.5)) |>
#'   draw(text_grob("tiny", x = 0.5, y = 0.2, gp = vl_gpar(fontsize = 2)))
#' vl_lint(s)
#' @export
vl_lint <- function(scene, rules = NULL, min_text_px = 7, min_contrast = 3) {
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
    get(id, envir = .lint_rules)$fn(scene, nodes, ctx)
  })
  out <- do.call(rbind, out[!vapply(out, is.null, logical(1))])
  if (is.null(out)) {
    out <- data.frame(
      rule = character(),
      severity = character(),
      node = character(),
      message = character(),
      stringsAsFactors = FALSE
    )
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
    "tiny_text",
    function(scene, nodes, ctx) {
      txt <- nodes$kind == "text" &
        nodes$font_px > 0 &
        nodes$font_px < ctx$min_text_px
      hits <- nodes[txt, , drop = FALSE]
      if (!nrow(hits)) {
        return(NULL)
      }
      vl_lint_finding(
        "tiny_text",
        "warning",
        hits,
        sprintf(
          "%.1f px tall - below the %g px legibility floor",
          hits$font_px,
          ctx$min_text_px
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
