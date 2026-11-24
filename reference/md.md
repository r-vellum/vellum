# Rich-text labels (markdown subset)

`md()` builds a styled label from a small markdown/HTML-free subset, for
use as the `label` of
[`text_grob()`](https://r-vellum.github.io/vellum/reference/grob.md)
(and anywhere a label is measured with
[`grobwidth()`](https://r-vellum.github.io/vellum/reference/grobwidth.md)/[`grobheight()`](https://r-vellum.github.io/vellum/reference/grobwidth.md)).
The base font/size/colour come from `gp`; markup spans override per run.

## Usage

``` r
md(text)
```

## Arguments

- text:

  A markup string (or a character vector for per-element labels).

## Value

A `vellum_md_label` (length-1 `text`) or a list of them (length \> 1).

## Details

Supported markup:

- `**bold**`

- `*italic*` or `_italic_`

- `^sup^` (superscript) and `~sub~` (subscript)

- `[text]{#c00}` — a coloured span (any R colour: name or hex)

- `$...$` — inline math in
  [`tex()`](https://r-vellum.github.io/vellum/reference/tex.md)'s
  notation, typeset by the same engine and set on the line's baseline
  (`"electron mass $m_e$ in **kg**"`)

Math follows pandoc's rules for `$`, with a stricter close: the opening
`$` must be followed by a non-space, and the closing `$` preceded by a
non-space and not followed by a letter or a digit (pandoc only rules out
a digit). So prices stay prose: `"costs $5 to $10"`,
`"Revenue ($M) vs cost ($K)"` and `"(US$bn) and (US$m)"` have no math.
Write `\\$` for a literal dollar sign. Display math (`$$...$$`) is not
supported; `$$` is kept as literal text. Markup inside `$...$` is TeX,
not markdown; the formula takes its span's colour and size, and a tall
formula makes its line taller. Math that does not parse is an error
naming its position in the label.

Spans nest (e.g. `**a^2^**`). `md()` with no markup is equivalent to the
plain string. Embedded newlines (`\n`) start a new line (stacked
baseline-to-baseline).

`md()` is vectorised: a length-1 input returns a single
`vellum_md_label`; a longer vector returns a list of them (one per
element), so a `vellumplot` mark can carry a per-datum rich label.

## Examples

``` r
lab <- md("R^2^ = **0.91**")
labs <- md(c("*a*", "**b**")) # a list of two labels
md("kinetic energy $\\frac{1}{2}mv^2$ in **J**")
#> <vellum::vellum_md_label>
#>  @ runs: List of 4
#>  .. $ :List of 6
#>  ..  ..$ text  : chr "kinetic energy "
#>  ..  ..$ bold  : logi FALSE
#>  ..  ..$ italic: logi FALSE
#>  ..  ..$ size  : num 1
#>  ..  ..$ dy    : num 0
#>  ..  ..$ col   : chr NA
#>  .. $ :List of 7
#>  ..  ..$ text  : chr "$\\frac{1}{2}mv^2$"
#>  ..  ..$ bold  : logi FALSE
#>  ..  ..$ italic: logi FALSE
#>  ..  ..$ size  : num 1
#>  ..  ..$ dy    : num 0
#>  ..  ..$ col   : chr NA
#>  ..  ..$ math  : chr "\\frac{1}{2}mv^2"
#>  .. $ :List of 6
#>  ..  ..$ text  : chr " in "
#>  ..  ..$ bold  : logi FALSE
#>  ..  ..$ italic: logi FALSE
#>  ..  ..$ size  : num 1
#>  ..  ..$ dy    : num 0
#>  ..  ..$ col   : chr NA
#>  .. $ :List of 6
#>  ..  ..$ text  : chr "J"
#>  ..  ..$ bold  : logi TRUE
#>  ..  ..$ italic: logi FALSE
#>  ..  ..$ size  : num 1
#>  ..  ..$ dy    : num 0
#>  ..  ..$ col   : chr NA
#>  @ text: chr "kinetic energy $\\frac{1}{2}mv^2$ in J"
```
