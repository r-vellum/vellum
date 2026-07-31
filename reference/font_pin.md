# Pin a scene's fonts, and check them later

`font_pin()` records the fonts a scene resolved to. `font_check()`
re-resolves the same scene and reports what changed — a different file,
a missing file, or a family that now resolves somewhere else.

## Usage

``` r
font_pin(scene)

font_check(scene, pin, on_mismatch = c("warn", "error", "ignore"))
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  (or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method).

- pin:

  A manifest from `font_pin()`.

- on_mismatch:

  `"warn"` (default), `"error"`, or `"ignore"` — what `font_check()`
  should do when the fonts have moved.

## Value

`font_pin()`: a `vellum_font_pin` object. `font_check()`: invisibly, a
data frame of differences (zero rows when everything matches), with a
`status` of `"changed"`, `"missing"` or `"new"`.

## Why this exists

vellum's determinism claim is that the same scene renders to the same
pixels on every OS and in CI. Layout, shaping and rasterisation deliver
that. Font *resolution* does not, and cannot: `"sans"` is a different
file on macOS, Linux and Windows, and even the same family name can
resolve to a different version of the same font.

So the claim holds only if the fonts are the same, and until now nothing
checked. A pin turns "identical pixels" from an assumption into an
assertion: record the manifest next to a reference image, and
`font_check()` will say whether a pixel difference is your change or the
machine's font stack.

## What this does not do

It does not *make* fonts reproducible — it cannot install a font, and
vellum deliberately resolves fonts through systemfonts so that it agrees
with the rest of the R graphics ecosystem. Bundling font files with a
scene would break that agreement and raises licensing questions vellum
should not answer for you. The honest tool is a check, not a substitute.

The reliable fix, when you need it, is to register the exact file you
mean with
[`systemfonts::register_font()`](https://systemfonts.r-lib.org/reference/register_font.html)
and pin *that*.

## Examples

``` r
s <- vl_scene(4, 2) |> draw(text_grob("hello"))
pin <- font_pin(s)
pin
#> <vellum_font_pin>: 1 font face
#> • DejaVuSans.ttf (face 0, 5 glyphs)
# In a test, next to a reference image:
nrow(font_check(s, pin)) == 0
#> [1] TRUE
```
