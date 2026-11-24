#' Math labels from R's plotmath notation
#'
#' `plotmath()` parses strings written in R's plotmath notation (see
#' [grDevices::plotmath]) and returns [tex()] labels, the way ggplot2's
#' `parse = TRUE` and `label_parsed()` parse theirs. [tex()] itself accepts
#' the unparsed form: a call, a symbol or an expression, as made by `quote()`,
#' `bquote()` or `expression()`:
#'
#' ```r
#' tex(quote(x[i]^2))
#' tex(expression(alpha + beta, sqrt(x, 3))) # a list of two labels
#' plotmath("hat(beta)[1] == 0.42")
#' ```
#'
#' The expression is translated to TeX (which becomes the label's source
#' text, so queries, alt text and tooltips show the TeX) and typeset by the
#' same engine.
#'
#' Supported: `x[i]` and `x^2`; `+ - / * ~` (`*` juxtaposes, `~` adds a
#' space); `== != < > <= >=`; `!x`; the `%op%` operators `%+-% %/% %*% %.%
#' %~~% %=~% %==% %prop% %~% %<->% %->% %<-% %up% %down% %<=>% %=>% %<=%
#' %dblup% %dbldown% %subset% %subseteq% %supset% %supseteq% %notsubset% %in%
#' %notin%`; `paste()`, `list()`; `sqrt(x)` and `sqrt(x, n)`; `frac()`,
#' `over()`, `atop()`; `hat() bar() tilde() dot() ring() widehat()
#' widetilde() underline() phantom()`; Greek letters by name (`alpha`,
#' `Omega`, and plotmath's `theta1 phi1 sigma1 omega1 Upsilon1`); `infinity
#' partialdiff nabla degree minute second cdots ldots ...` and `aleph`;
#' `sum() prod() integral() union() intersect()` with optional lower and upper
#' limits, and `lim() min() max() inf() sup()` with an optional lower one;
#' `group()` and `bgroup()` (growing) delimiters, including `lceil rceil
#' lfloor rfloor langle rangle`; `italic() bold() plain() bolditalic()`;
#' `displaystyle() textstyle() scriptstyle() scriptscriptstyle()`; strings
#' (set upright), numbers, `(x)` (drawn) and `{x}` (invisible grouping); and
#' function calls such as `f(x)` or `log(x)`.
#'
#' One deliberate difference from base R graphics: single-letter symbols are
#' set in math italic, the TeX convention, where base R sets them upright.
#' Use `plain()` for upright letters. Limits of `sum()`, `integral()`, `lim()`
#' and friends go above and below the operator, as in base R. Anything else
#' (`symbol()`, assignment, `if`, ...) is an error, not silently dropped.
#'
#' @param text A character vector of plotmath strings. Each string is parsed
#'   with [parse()] and its first expression is used; an empty string gives an
#'   empty label.
#' @param display As in [tex()].
#' @return A `vellum_tex_label` (length-1 `text`) or a list of them.
#' @seealso [tex()] for TeX notation, which covers more.
#' @examples
#' plotmath("alpha[i]^2 + beta")
#' plotmath(c("sqrt(x, 3)", "frac(1, n) * sum(x[i], i == 1, n)"))
#' tex(quote(hat(mu) == bar(x)))
#' k <- 3
#' tex(bquote(x^.(k)))
#' @export
plotmath <- function(text, display = FALSE) {
  text <- as.character(text)
  call <- environment()
  exprs <- lapply(text, function(s) {
    if (is.na(s)) {
      return("")
    }
    e <- tryCatch(
      parse(text = s, keep.source = FALSE),
      error = function(err) {
        cli::cli_abort(
          c(
            "Can't parse {.val {s}} as a plotmath expression.",
            x = conditionMessage(err)
          ),
          call = call,
          class = "vellum_plotmath_error"
        )
      }
    )
    if (length(e) == 0L) "" else e[[1]]
  })
  if (length(exprs) == 0L) {
    return(list())
  }
  out <- lapply(exprs, .plotmath_label, display = display, call = call)
  if (length(out) == 1L) out[[1]] else out
}

# One tex label from one plotmath expression (a call, symbol or constant).
.plotmath_label <- function(e, display, call) {
  src <- if (is.character(e) && length(e) == 1L && !nzchar(e)) {
    ""
  } else {
    .pm(e, "default", call)
  }
  .tex_one(src, display, call = call)
}

# --- translation tables --------------------------------------------------------

.PM_GREEK <- c(
  "alpha",
  "beta",
  "gamma",
  "delta",
  "epsilon",
  "zeta",
  "eta",
  "theta",
  "iota",
  "kappa",
  "lambda",
  "mu",
  "nu",
  "xi",
  "pi",
  "rho",
  "sigma",
  "tau",
  "upsilon",
  "phi",
  "chi",
  "psi",
  "omega",
  "Gamma",
  "Delta",
  "Theta",
  "Lambda",
  "Xi",
  "Pi",
  "Sigma",
  "Upsilon",
  "Phi",
  "Psi",
  "Omega"
)

# Names that are not TeX commands of the same name.
.PM_NAMES <- c(
  # Greek capitals that look like Latin ones, upright as in TeX
  Alpha = "\\mathrm{A}",
  Beta = "\\mathrm{B}",
  Epsilon = "\\mathrm{E}",
  Zeta = "\\mathrm{Z}",
  Eta = "\\mathrm{H}",
  Iota = "\\mathrm{I}",
  Kappa = "\\mathrm{K}",
  Mu = "\\mathrm{M}",
  Nu = "\\mathrm{N}",
  Omicron = "\\mathrm{O}",
  Rho = "\\mathrm{P}",
  Tau = "\\mathrm{T}",
  Chi = "\\mathrm{X}",
  omicron = "o",
  # plotmath's variant letters
  theta1 = "\\vartheta",
  vartheta = "\\vartheta",
  phi1 = "\\varphi",
  sigma1 = "\\varsigma",
  omega1 = "\\varpi",
  Upsilon1 = "\\Upsilon",
  epsilon1 = "\\varepsilon",
  infinity = "\\infty",
  partialdiff = "\\partial",
  nabla = "\\nabla",
  degree = "{}^{\\circ}",
  minute = "{}'",
  second = "{}''",
  cdots = "\\cdots",
  ldots = "\\ldots",
  "..." = "\\ldots",
  aleph = "\\aleph",
  lceil = "\\lceil",
  rceil = "\\rceil",
  lfloor = "\\lfloor",
  rfloor = "\\rfloor",
  langle = "\\langle",
  rangle = "\\rangle"
)

.PM_BINARY <- c(
  "+" = "+",
  "-" = "-",
  "/" = "/",
  "==" = "=",
  "!=" = "\\neq",
  "<" = "<",
  ">" = ">",
  "<=" = "\\leq",
  ">=" = "\\geq",
  "%+-%" = "\\pm",
  "%/%" = "\\div",
  "%*%" = "\\times",
  "%.%" = "\\cdot",
  "%~~%" = "\\approx",
  "%=~%" = "\\cong",
  "%==%" = "\\equiv",
  "%prop%" = "\\propto",
  "%~%" = "\\sim",
  "%<->%" = "\\leftrightarrow",
  "%->%" = "\\rightarrow",
  "%<-%" = "\\leftarrow",
  "%up%" = "\\uparrow",
  "%down%" = "\\downarrow",
  "%<=>%" = "\\Leftrightarrow",
  "%=>%" = "\\Rightarrow",
  "%<=%" = "\\Leftarrow",
  "%dblup%" = "\u21d1",
  "%dbldown%" = "\u21d3",
  "%subset%" = "\\subset",
  "%subseteq%" = "\\subseteq",
  "%supset%" = "\\supset",
  "%supseteq%" = "\\supseteq",
  "%notsubset%" = "\u2284",
  "%in%" = "\\in",
  "%notin%" = "\\notin"
)

.PM_ACCENT <- c(
  hat = "\\hat",
  tilde = "\\tilde",
  dot = "\\dot",
  ring = "\\mathring",
  widehat = "\\widehat",
  widetilde = "\\widetilde",
  underline = "\\underline",
  phantom = "\\phantom"
)

.PM_FONT <- c(
  italic = "\\mathit",
  bold = "\\mathbf",
  plain = "\\mathrm",
  bolditalic = "\\mathbfit"
)

.PM_TEXT <- c(
  default = "\\text",
  plain = "\\text",
  italic = "\\textit",
  bold = "\\textbf",
  bolditalic = "\\textbfit"
)

.PM_STYLE <- c(
  "displaystyle",
  "textstyle",
  "scriptstyle",
  "scriptscriptstyle"
)

# Big operators (lower and upper limits) and limit-like operators (a lower
# one only).
.PM_BIGOP <- c(
  sum = "\\sum",
  prod = "\\prod",
  integral = "\\int",
  union = "\\bigcup",
  intersect = "\\bigcap"
)
.PM_LIMOP <- c(
  lim = "\\lim",
  min = "\\min",
  max = "\\max",
  inf = "\\inf",
  sup = "\\sup"
)

# Function names TeX sets as upright operators.
.PM_FUNS <- c(
  "sin",
  "cos",
  "tan",
  "cot",
  "sec",
  "csc",
  "arcsin",
  "arccos",
  "arctan",
  "sinh",
  "cosh",
  "tanh",
  "log",
  "ln",
  "lg",
  "exp",
  "det",
  "dim",
  "gcd",
  "deg",
  "arg",
  "ker",
  "hom",
  "Pr"
)

.PM_DELIM <- c(
  "(" = "(",
  ")" = ")",
  "[" = "[",
  "]" = "]",
  "{" = "\\{",
  "}" = "\\}",
  "|" = "|",
  "||" = "\\|",
  "." = ".",
  lceil = "\\lceil",
  rceil = "\\rceil",
  lfloor = "\\lfloor",
  rfloor = "\\rfloor",
  langle = "\\langle",
  rangle = "\\rangle",
  "<" = "\\langle",
  ">" = "\\rangle"
)

# --- translation ---------------------------------------------------------------

# Translate one plotmath expression to TeX. `font` is the enclosing font call
# ("default" outside any), which decides how strings are set.
.pm <- function(e, font, call) {
  if (is.name(e)) {
    return(.pm_name(as.character(e)))
  }
  if (is.character(e) && length(e) == 1L) {
    return(paste0(.PM_TEXT[[font]], "{", .pm_escape(e), "}"))
  }
  if ((is.numeric(e) || is.logical(e)) && length(e) == 1L) {
    if (is.logical(e)) {
      return(paste0("\\text{", as.character(e), "}"))
    }
    if (e < 0) {
      return(paste0("-", .pm(-e, font, call)))
    }
    return(format(e, digits = 15, trim = TRUE))
  }
  if (!is.call(e)) {
    .pm_unsupported(e, call)
  }
  f <- e[[1]]
  args <- as.list(e)[-1]
  if (!is.name(f)) {
    # `plain(P)(X == x)`: a call used as the function name
    return(paste0(.pm(f, font, call), "(", .pm_list(args, font, call), ")"))
  }
  fn <- as.character(f)
  n <- length(args)
  a <- function(i) .pm(args[[i]], font, call)
  if (fn %in% names(.PM_BINARY)) {
    op <- .PM_BINARY[[fn]]
    if (n == 2L) {
      return(paste(a(1), op, a(2)))
    }
    if (n == 1L && fn %in% c("+", "-")) {
      return(paste0(op, a(1)))
    }
  }
  switch(
    fn,
    "*" = if (n == 2L) return(paste(a(1), a(2))),
    "~" = {
      if (n == 2L) {
        return(paste0(a(1), "\\ ", a(2)))
      }
      if (n == 1L) return(paste0("\\ ", a(1)))
    },
    "!" = if (n == 1L) return(paste("\\neg", a(1))),
    "(" = if (n == 1L) return(paste0("(", a(1), ")")),
    "{" = if (n == 1L) return(paste0("{", a(1), "}")),
    "[" = if (n >= 2L) {
      sub <- .pm_list(args[-1], font, call)
      return(paste0(.pm_base(a(1)), "_{", sub, "}"))
    },
    "^" = if (n == 2L) {
      b <- args[[1]]
      if (is.call(b) && identical(b[[1]], as.name("[")) && length(b) >= 3L) {
        # x[i]^2: one base with both scripts, as TeX's x_i^2
        sub <- .pm_list(as.list(b)[-(1:2)], font, call)
        return(paste0(
          .pm_base(.pm(b[[2]], font, call)),
          "_{",
          sub,
          "}^{",
          a(2),
          "}"
        ))
      }
      return(paste0(.pm_base(a(1)), "^{", a(2), "}"))
    },
    paste = return(paste(vapply(seq_len(n), a, ""), collapse = " ")),
    list = return(.pm_list(args, font, call)),
    sqrt = {
      if (n == 1L) {
        return(paste0("\\sqrt{", a(1), "}"))
      }
      if (n == 2L) return(paste0("\\sqrt[", a(2), "]{", a(1), "}"))
    },
    frac = ,
    over = if (n == 2L) return(paste0("\\frac{", a(1), "}{", a(2), "}")),
    atop = if (n == 2L) return(paste0("{", a(1), " \\atop ", a(2), "}")),
    bar = if (n == 1L) {
      x <- a(1)
      cmd <- if (.pm_atomic(x)) "\\bar" else "\\overline"
      return(paste0(cmd, "{", x, "}"))
    },
    group = ,
    bgroup = if (n == 3L) {
      l <- .pm_delim(args[[1]], call)
      r <- .pm_delim(args[[3]], call)
      if (fn == "bgroup") {
        return(paste0("\\left", l, " ", a(2), " \\right", r))
      }
      return(paste0(
        if (l == ".") "" else l,
        " ",
        a(2),
        " ",
        if (r == ".") "" else r
      ))
    }
  )
  if (fn %in% names(.PM_ACCENT) && n == 1L) {
    return(paste0(.PM_ACCENT[[fn]], "{", a(1), "}"))
  }
  if (fn %in% names(.PM_FONT) && n == 1L) {
    return(paste0(.PM_FONT[[fn]], "{", .pm(args[[1]], fn, call), "}"))
  }
  if (fn %in% .PM_STYLE && n == 1L) {
    return(paste0("{\\", fn, " ", a(1), "}"))
  }
  if (fn %in% names(.PM_BIGOP) && n >= 1L && n <= 3L) {
    lim <- paste0(
      .PM_BIGOP[[fn]],
      if (n >= 2L) "\\limits",
      if (n >= 2L) paste0("_{", a(2), "}"),
      if (n == 3L) paste0("^{", a(3), "}")
    )
    return(paste(lim, a(1)))
  }
  if (fn %in% names(.PM_LIMOP) && n >= 1L && n <= 2L) {
    lim <- paste0(
      .PM_LIMOP[[fn]],
      if (n == 2L) paste0("\\limits_{", a(2), "}")
    )
    return(paste(lim, a(1)))
  }
  if (fn %in% .PM_FUNS) {
    return(paste0("\\", fn, "(", .pm_list(args, font, call), ")"))
  }
  # `symbol()` selects base R's Adobe Symbol font, which has no TeX analogue.
  if (make.names(fn) == fn && fn != "symbol") {
    # a generic function call, f(x)
    return(paste0(.pm_name(fn), "(", .pm_list(args, font, call), ")"))
  }
  .pm_unsupported(e, call)
}

.pm_name <- function(x) {
  if (x %in% .PM_GREEK) {
    return(paste0("\\", x))
  }
  if (x %in% names(.PM_NAMES)) {
    return(.PM_NAMES[[x]])
  }
  if (!nzchar(x)) {
    return("")
  }
  gsub("_", "\\_", x, fixed = TRUE)
}

.pm_list <- function(args, font, call) {
  paste(vapply(args, .pm, "", font = font, call = call), collapse = ", ")
}

# A single symbol, or a one-argument command over one (`\\hat{\\beta}`,
# `\\mathrm{A}`), needs no braces as the base of a script, so it lays out as
# TeX's `\\hat\\beta_1` does; anything longer is grouped so the script
# attaches to all of it.
.pm_atomic <- function(x) {
  sym <- "(?:.|\\\\[A-Za-z]+)"
  grepl(paste0("^(?:", sym, "|\\\\[A-Za-z]+\\{", sym, "\\})$"), x, perl = TRUE)
}
.pm_base <- function(x) {
  if (.pm_atomic(x)) x else paste0("{", x, "}")
}

.pm_escape <- function(x) {
  gsub("([\\\\{}])", "\\\\\\1", x, perl = TRUE)
}

.pm_delim <- function(d, call) {
  key <- if (is.name(d)) {
    as.character(d)
  } else if (is.character(d)) {
    d
  } else {
    NA
  }
  if (identical(key, "")) {
    key <- "."
  }
  if (is.na(key) || !key %in% names(.PM_DELIM)) {
    cli::cli_abort(
      c(
        "Can't use {.code {deparse(d)}} as a plotmath delimiter.",
        i = "Use one of {.val {names(.PM_DELIM)}}, or {.val {\"\"}} for none."
      ),
      call = call,
      class = "vellum_plotmath_error"
    )
  }
  .PM_DELIM[[key]]
}

.pm_unsupported <- function(e, call) {
  cli::cli_abort(
    c(
      "Can't translate {.code {paste(deparse(e), collapse = ' ')}} from plotmath.",
      i = "See {.help vellum::plotmath} for the supported notation."
    ),
    call = call,
    class = "vellum_plotmath_error"
  )
}
