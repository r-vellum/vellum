# Math labels from R's plotmath notation

`plotmath()` parses strings written in R's plotmath notation (see
[grDevices::plotmath](https://rdrr.io/r/grDevices/plotmath.html)) and
returns [`tex()`](https://r-vellum.github.io/vellum/reference/tex.md)
labels, the way ggplot2's `parse = TRUE` and
[`label_parsed()`](https://ggplot2.tidyverse.org/reference/labellers.html)
parse theirs.
[`tex()`](https://r-vellum.github.io/vellum/reference/tex.md) itself
accepts the unparsed form: a call, a symbol or an expression, as made by
[`quote()`](https://rdrr.io/r/base/substitute.html),
[`bquote()`](https://rdrr.io/r/base/bquote.html) or
[`expression()`](https://rdrr.io/r/base/expression.html):

## Usage

``` r
plotmath(text, display = FALSE)
```

## Arguments

- text:

  A character vector of plotmath strings. Each string is parsed with
  [`parse()`](https://rdrr.io/r/base/parse.html) and its first
  expression is used; an empty string gives an empty label.

- display:

  As in [`tex()`](https://r-vellum.github.io/vellum/reference/tex.md).

## Value

A `vellum_tex_label` (length-1 `text`) or a list of them.

## Details

    tex(quote(x[i]^2))
    tex(expression(alpha + beta, sqrt(x, 3))) # a list of two labels
    plotmath("hat(beta)[1] == 0.42")

The expression is translated to TeX (which becomes the label's source
text, so queries, alt text and tooltips show the TeX) and typeset by the
same engine.

Supported: `x[i]` and `x^2`; `+ - / * ~` (`*` juxtaposes, `~` adds a
space); `== != < > <= >=`; `!x`; the `%op%` operators
`%+-% %/% %*% %.% %~~% %=~% %==% %prop% %~% %<->% %->% %<-% %up% %down% %<=>% %=>% %<=% %dblup% %dbldown% %subset% %subseteq% %supset% %supseteq% %notsubset% %in% %notin%`;
[`paste()`](https://rdrr.io/r/base/paste.html),
[`list()`](https://rdrr.io/r/base/list.html); `sqrt(x)` and
`sqrt(x, n)`; `frac()`, `over()`, `atop()`;
`hat() bar() tilde() dot() ring() widehat() widetilde() underline() phantom()`;
Greek letters by name (`alpha`, `Omega`, and plotmath's
`theta1 phi1 sigma1 omega1 Upsilon1`);
`infinity partialdiff nabla degree minute second cdots ldots ...` and
`aleph`; `sum() prod() integral() union() intersect()` with optional
lower and upper limits, and `lim() min() max() inf() sup()` with an
optional lower one; `group()` and `bgroup()` (growing) delimiters,
including `lceil rceil lfloor rfloor langle rangle`;
`italic() bold() plain() bolditalic()`;
`displaystyle() textstyle() scriptstyle() scriptscriptstyle()`; strings
(set upright), numbers, `(x)` (drawn) and `{x}` (invisible grouping);
and function calls such as `f(x)` or `log(x)`.

One deliberate difference from base R graphics: single-letter symbols
are set in math italic, the TeX convention, where base R sets them
upright. Use `plain()` for upright letters. Longer names (`mpg`,
`Temperature`) are set upright as one word, as in base R. Functions
given the wrong number of arguments (`frac(a)`) are errors. Limits of
[`sum()`](https://rdrr.io/r/base/sum.html), `integral()`, `lim()` and
friends go above and below the operator, as in base R. Anything else
(`symbol()`, assignment, `if`, ...) is an error, not silently dropped.

## See also

[`tex()`](https://r-vellum.github.io/vellum/reference/tex.md) for TeX
notation, which covers more.

## Examples

``` r
plotmath("alpha[i]^2 + beta")
#> <vellum::vellum_tex_label>
#>  @ tex    : chr "\\alpha_{i}^{2} + \\beta"
#>  @ display: logi FALSE
#>  @ text   : chr "\\alpha_{i}^{2} + \\beta"
plotmath(c("sqrt(x, 3)", "frac(1, n) * sum(x[i], i == 1, n)"))
#> [[1]]
#> <vellum::vellum_tex_label>
#>  @ tex    : chr "\\sqrt[3]{x}"
#>  @ display: logi FALSE
#>  @ text   : chr "\\sqrt[3]{x}"
#> 
#> [[2]]
#> <vellum::vellum_tex_label>
#>  @ tex    : chr "\\frac{1}{n} \\sum\\limits_{i = 1}^{n} x_{i}"
#>  @ display: logi FALSE
#>  @ text   : chr "\\frac{1}{n} \\sum\\limits_{i = 1}^{n} x_{i}"
#> 
tex(quote(hat(mu) == bar(x)))
#> <vellum::vellum_tex_label>
#>  @ tex    : chr "\\hat{\\mu} = \\bar{x}"
#>  @ display: logi FALSE
#>  @ text   : chr "\\hat{\\mu} = \\bar{x}"
k <- 3
tex(bquote(x^.(k)))
#> <vellum::vellum_tex_label>
#>  @ tex    : chr "x^{3}"
#>  @ display: logi FALSE
#>  @ text   : chr "x^{3}"
```
