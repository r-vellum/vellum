# Render one frame of a keyframe animation

`vl_render_frame()` draws the single frame that
[`vl_render_animation()`](https://r-vellum.github.io/vellum/reference/vl_render_animation.md)
would draw for one schedule entry – keyframe pair `seg` at fraction
`frac` – and writes it as a still image: a poster for an animation, a
thumbnail, or the frame to put in print. The marks are matched and
tweened exactly as in the animation (see *Matching marks by identity* in
[`vl_render_animation()`](https://r-vellum.github.io/vellum/reference/vl_render_animation.md)),
and a per-frame text variant is swapped in the same way.

## Usage

``` r
vl_render_frame(
  keyframes,
  seg,
  frac,
  path,
  frac_col = frac,
  frac_size = frac,
  frac_alpha = frac,
  text_variant = NULL,
  text = c("native", "outline"),
  scale = 1
)
```

## Arguments

- keyframes:

  A list of at least two scenes (each a
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method), all the same pixel size.

- seg:

  The 1-based index of the left keyframe of the pair (a single integer
  in `1:(length(keyframes) - 1)`).

- frac:

  The positional fraction between keyframe `seg` and `seg + 1` (a single
  number; `0` is keyframe `seg`, `1` is keyframe `seg + 1`).

- path:

  Output file path; the format is taken from the extension (`.png`,
  `.svg` or `.pdf`), as for
  [`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md).

- frac_col, frac_size, frac_alpha:

  The fractions of the other property classes; default `frac`.

- text_variant:

  A scene whose keyed text replaces the frame's text with the same keys
  (one entry of `text_variants` in
  [`vl_render_animation()`](https://r-vellum.github.io/vellum/reference/vl_render_animation.md)),
  or `NULL`.

- text:

  For SVG output, how text is written: `"native"` (default) emits
  selectable `<text>` referencing system fonts, `"outline"` emits glyph
  outlines (pixel-faithful, identical to the raster/PDF backends, but
  not selectable). Ignored for PNG/PDF.

- scale:

  Resolution multiplier (default `1`). `scale = 2` renders at twice the
  device pixels while keeping the **same physical size** — the retina /
  `ggsave(scaling=)` idiom. It multiplies `dpi`, so absolute units
  (`mm`, `pt`, `in`) cover proportionally more pixels and nothing about
  the layout changes; text does not get relatively bigger or smaller.
  Only raster output gains anything: a PDF's page size in points and an
  SVG's physical size are unchanged by construction.

## Value

`path`, invisibly.

## See also

[`vl_render_animation()`](https://r-vellum.github.io/vellum/reference/vl_render_animation.md),
[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)

## Examples

``` r
a <- vl_scene(2, 2) |> draw(circle_grob(r = 0.1, gp = vl_gpar(fill = "tomato")))
b <- vl_scene(2, 2) |> draw(circle_grob(r = 0.4, gp = vl_gpar(fill = "tomato")))
vl_render_frame(list(a, b), 1, 0.5, tempfile(fileext = ".png"))
```
