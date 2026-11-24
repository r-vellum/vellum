#' Math labels (a TeX subset)
#'
#' `tex()` builds a label from TeX math notation, for use anywhere an [md()]
#' label goes: the `label` of [text_grob()], [vl_strwidth()] and
#' [grobwidth()], and the titles, guides and text marks of \pkg{vellumplot}.
#' vellum typesets it itself (no LaTeX installation, no web engine), with the
#' sizes, shifts and glyph variants the font's OpenType `MATH` table
#' specifies, so a formula renders the same in PNG, SVG and PDF and measures
#' exactly what it draws.
#'
#' The formula is set in a math font, not in the label's `fontfamily`; the
#' size comes from the grob's `fontsize` and every part takes the label's
#' colour. The default font is STIX Two Math, bundled with vellum (SIL Open
#' Font License, see `system.file("COPYRIGHTS", package = "vellum")`). Pick
#' another with `options(vellum.math_font = )`: a family name known to
#' \pkg{systemfonts} (`"Latin Modern Math"`, `"Cambria Math"`, `"Fira Math"`)
#' or a path to a font file. The font must have a `MATH` table.
#'
#' Supported notation:
#' * letters (set in math italic), digits, `+ - = < > ( ) [ ] , ; :`
#' * superscripts and subscripts, `x^2`, `x_i`, `x_i^2`, `x^{a_b}`, and primes
#'   `f'`
#' * `\frac{a}{b}`, `\dfrac`, `\tfrac`, `\binom{n}{k}`, `\sqrt{x}`,
#'   `\sqrt[n]{x}`
#' * Greek letters `\alpha` ... `\omega`, `\Gamma` ... `\Omega`, `\varepsilon`,
#'   `\varphi`, `\vartheta`, ...
#' * operators and relations with TeX's spacing: `\pm \mp \times \div \cdot
#'   \leq \geq \neq \approx \sim \equiv \propto \in \subset \cup \cap \to
#'   \Rightarrow \mapsto \infty \partial \nabla \forall \exists \ldots \cdots`
#'   and more
#' * big operators `\sum \prod \int \oint` and operator names `\lim \max \min
#'   \sup \inf \log \exp \sin \cos \tan \ln` (limits go above and below in
#'   display style; `\limits` / `\nolimits` override)
#' * growing delimiters `\left( ... \right)`, with `[ ] \{ \} | \| \langle
#'   \rangle` and the empty `\left.`
#' * alphabets `\mathrm \mathbf \mathit \mathsf \mathtt \mathcal \mathbb`, and
#'   upright `\text{...}`
#' * accents `\hat \bar \tilde \vec \dot \ddot \widehat \overline \underline`
#' * spacing `\, \: \; \! \quad \qquad ~`, and `\displaystyle` etc.
#'
#' A command outside this subset is an error, not silently dropped.
#'
#' @param x A TeX math string, without `$` delimiters (or a character vector,
#'   for one label per element).
#' @param display `TRUE` sets the formula in TeX's display style (big
#'   operators larger, limits above and below, fractions full size); the
#'   default is inline text style.
#' @return A `vellum_tex_label` (length-1 `x`) or a list of them.
#' @seealso [md()] for styled prose.
#' @examples
#' lab <- tex("E = mc^2")
#' s <- vl_scene(3, 1.2) |>
#'   draw(text_grob(
#'     tex("\\sum_{i=1}^n x_i^2", display = TRUE),
#'     gp = vl_gpar(fontsize = 16)
#'   ))
#' vl_strwidth(tex("\\frac{a}{b}"), fontsize = 12, unit = "pt")
#' @export
tex <- function(x, display = FALSE) {
  x <- as.character(x)
  if (!is.logical(display) || length(display) != 1L || is.na(display)) {
    cli::cli_abort("{.arg display} must be {.code TRUE} or {.code FALSE}.")
  }
  if (length(x) == 0L) {
    return(list())
  }
  if (length(x) == 1L) {
    return(.tex_one(x, display, call = environment()))
  }
  lapply(x, .tex_one, display = display, call = environment())
}

.tex_one <- function(x, display, call) {
  if (is.na(x)) {
    x <- ""
  }
  bad <- rs_math_check(x)
  if (!is.null(bad)) {
    .tex_parse_error(x, bad, call)
  }
  vellum_tex_label(tex = x, display = display, text = x)
}

# A parse error as a cli error that names the problem, its position, and the
# formula.
.tex_parse_error <- function(x, bad, call) {
  cli::cli_abort(
    c(
      "Can't parse the {.fn tex} formula.",
      x = if (bad$position > nchar(x)) {
        "{bad$message} at the end of the formula."
      } else {
        "{bad$message} at position {bad$position}."
      },
      i = "In {.code {x}}."
    ),
    call = call,
    class = "vellum_tex_error"
  )
}

# --- math font -----------------------------------------------------------------

.math_font_cache <- new.env(parent = emptyenv())

# The math font as list(path, index): `getOption("vellum.math_font")` (a
# systemfonts family or a file path) or the bundled STIX Two Math. Checked once
# per option value for an OpenType MATH table.
.math_font <- function(call = parent.frame()) {
  opt <- getOption("vellum.math_font")
  key <- if (is.null(opt)) ".bundled" else paste0("opt:", opt, collapse = "\r")
  hit <- .math_font_cache[[key]]
  if (!is.null(hit)) {
    return(hit)
  }
  if (is.null(opt)) {
    path <- system.file("fonts", "STIXTwoMath-Regular.otf", package = "vellum")
    index <- 0L
  } else {
    if (!is.character(opt) || length(opt) != 1L || is.na(opt) || !nzchar(opt)) {
      cli::cli_abort(
        "{.code options(vellum.math_font)} must be a single font family name or file path.",
        call = call
      )
    }
    if (file.exists(opt)) {
      path <- normalizePath(opt)
      index <- 0L
    } else {
      m <- systemfonts::match_fonts(opt)
      path <- m$path[1]
      index <- m$index[1]
    }
  }
  why <- rs_math_font_check(path, as.integer(index))
  if (nzchar(why)) {
    cli::cli_abort(
      c(
        "{.code options(vellum.math_font)} must name a math font.",
        x = "{.val {opt}} resolves to {.file {path}}: {why}.",
        i = paste(
          "Use a font with an OpenType MATH table (STIX Two Math, Latin",
          "Modern Math, Cambria Math, Fira Math), or unset the option for",
          "the bundled STIX Two Math."
        )
      ),
      call = call,
      class = "vellum_math_font_error"
    )
  }
  res <- list(path = path, index = as.integer(index))
  assign(key, res, envir = .math_font_cache)
  res
}

# --- composition -----------------------------------------------------------------

# Lay out a tex label with the math engine and return it in `.md_compose()`'s
# form: per-glyph arrays in points with y up from the label box's bottom, so a
# tex label draws and measures through exactly the plumbing an md label uses.
# The engine works baseline-relative; lifting everything by the ink depth puts
# the box bottom at 0, so the box (w x h) is the drawn ink, vertically. Rules
# (fraction bars, radical overbars) come back as rx/ry/rw/rh with a colour each.
S7::method(.label_compose, vellum_tex_label) <- function(
  label,
  family,
  fontface,
  fontsize,
  base_col,
  features = NULL
) {
  .check_font_size(fontsize)
  f <- .math_font()
  m <- rs_math_layout(label@tex, f$path, f$index, fontsize, label@display)
  if (is.null(m$gid)) {
    cli::cli_abort("Can't typeset {.code {label@tex}}: {m$message}.")
  }
  lift <- m$depth
  n <- length(m$gid)
  list(
    gid = m$gid,
    gx = m$gx,
    gy = m$gy + lift,
    gsize = m$gsize,
    gpath = rep(f$path, n),
    gface = rep(f$index, n),
    cols = rep(base_col, n),
    w = m$width,
    h = m$ascent + m$depth,
    rx = m$rx,
    ry = m$ry + lift,
    rw = m$rw,
    rh = m$rh,
    rcols = rep(base_col, length(m$rx)),
    # One character per glyph, so PDF text extraction maps each glyph to the
    # character it came from.
    text = m$text,
    baseline = lift
  )
}

# Forget resolved math fonts (tests; a font installed mid-session).
.math_font_reset <- function() {
  rm(list = ls(.math_font_cache, all.names = TRUE), envir = .math_font_cache)
  invisible()
}
