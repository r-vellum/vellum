# Which fonts a scene actually used

Reports the font **files** a scene's text resolved to, read off the
shaped glyphs rather than re-resolved from family names — so it says
what was used, not what would be picked if asked again.

## Usage

``` r
scene_fonts(scene)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  (or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method).

## Value

A data frame with `path`, `index` (the face within a font collection),
`glyphs` (how many glyphs came from that face), `file` (the basename)
and `exists`. Zero rows if the scene has no text.

## See also

[`font_pin()`](https://r-vellum.github.io/vellum/reference/font_pin.md)
to record this and check it later.

## Examples

``` r
s <- vl_scene(4, 2) |> draw(text_grob("hello", gp = vl_gpar(fontfamily = "serif")))
scene_fonts(s)
#>                                               path index glyphs            file
#> 1 /usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf     0      5 DejaVuSerif.ttf
#>   exists
#> 1   TRUE
```
