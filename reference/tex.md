# Math labels (a TeX subset)

`tex()` builds a label from TeX math notation, for use anywhere an
[`md()`](https://r-vellum.github.io/vellum/reference/md.md) label goes:
the `label` of
[`text_grob()`](https://r-vellum.github.io/vellum/reference/grob.md),
[`vl_strwidth()`](https://r-vellum.github.io/vellum/reference/vl_strwidth.md)
and
[`grobwidth()`](https://r-vellum.github.io/vellum/reference/grobwidth.md),
and the titles, guides and text marks of vellumplot. vellum typesets it
itself (no LaTeX installation, no web engine), with the sizes, shifts
and glyph variants the font's OpenType `MATH` table specifies, so a
formula renders the same in PNG, SVG and PDF and measures exactly what
it draws.

## Usage

``` r
tex(x, display = FALSE)
```

## Arguments

- x:

  A TeX math string, without `$` delimiters (or a character vector, for
  one label per element).

- display:

  `TRUE` sets the formula in TeX's display style (big operators larger,
  limits above and below, fractions full size); the default is inline
  text style.

## Value

A `vellum_tex_label` (length-1 `x`) or a list of them.

## Details

The formula is set in a math font, not in the label's `fontfamily`; the
size comes from the grob's `fontsize` and every part takes the label's
colour. The default font is STIX Two Math, bundled with vellum (SIL Open
Font License, see `system.file("COPYRIGHTS", package = "vellum")`). Pick
another with `options(vellum.math_font = )`: a family name known to
systemfonts (`"Latin Modern Math"`, `"Cambria Math"`, `"Fira Math"`) or
a path to a font file. The font must have a `MATH` table.

Supported notation:

- letters (set in math italic), digits, `+ - = < > ( ) [ ] , ; :`

- superscripts and subscripts, `x^2`, `x_i`, `x_i^2`, `x^{a_b}`, and
  primes `f'`

- `\frac{a}{b}`, `\dfrac`, `\tfrac`, `\binom{n}{k}`, `\sqrt{x}`,
  `\sqrt[n]{x}`

- Greek letters `\alpha` ... `\omega`, `\Gamma` ... `\Omega`,
  `\varepsilon`, `\varphi`, `\vartheta`, ...

- operators and relations with TeX's spacing:
  `\pm \mp \times \div \cdot \leq \geq \neq \approx \sim \equiv \propto \in \subset \cup \cap \to \Rightarrow \mapsto \infty \partial \nabla \forall \exists \ldots \cdots`
  and more

- big operators `\sum \prod \int \oint` and operator names
  `\lim \max \min \sup \inf \log \exp \sin \cos \tan \ln` (limits go
  above and below in display style; `\limits` / `\nolimits` override)

- growing delimiters `\left( ... \right)`, with
  `[ ] \{ \} | \| \langle \rangle` and the empty `\left.`; fixed sizes
  `\big \Big \bigg \Bigg` (and their `l`/`r`/`m` forms)

- alphabets `\mathrm \mathbf \mathit \mathsf \mathtt \mathcal \mathbb`,
  and upright `\text{...}`

- accents
  `\hat \bar \tilde \vec \dot \ddot \widehat \overline \underline`

- spacing `\, \: \; \! \quad \qquad ~`, and `\displaystyle` etc.

Scripts are placed with the font's italic correction and math kerning
(cut-ins), as LuaTeX does. A label's box is baseline-stable: it is the
line box a plain or \[md()\] label of the same `fontfamily` and
`fontsize` gets, grown only where the formula reaches past it, so
formulas set side by side share a baseline.

A command outside this subset is an error, not silently dropped, and so
is nesting more than 100 levels deep. Characters the math font has no
glyph for are drawn as its empty box, with a warning.

\[ \]: R:%20 \[ \]: R:%20 \[md()\]: R:md()

## See also

[`md()`](https://r-vellum.github.io/vellum/reference/md.md) for styled
prose.

## Examples

``` r
lab <- tex("E = mc^2")
s <- vl_scene(3, 1.2) |>
  draw(text_grob(
    tex("\\sum_{i=1}^n x_i^2", display = TRUE),
    gp = vl_gpar(fontsize = 16)
  ))
vl_strwidth(tex("\\frac{a}{b}"), fontsize = 12, unit = "pt")
#> [1] 7.9956
```
