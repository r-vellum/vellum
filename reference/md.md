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
```
