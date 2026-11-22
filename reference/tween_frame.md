# The tweened scene of one frame between keyframes `a` and `b`, at fraction `frac` (position) and `frac_col` / `frac_size` / `frac_alpha` (the other property classes), with the keyed text of `text_variant` (a compiled scene, or `NULL`) swapped in – exactly the frame `render_animation` would draw for that schedule entry. For rendering one frame on its own (`vl_render_frame()`) and for inspecting a mid-transition frame (`$element_table()`, `$pixel()`).

The tweened scene of one frame between keyframes `a` and `b`, at
fraction `frac` (position) and `frac_col` / `frac_size` / `frac_alpha`
(the other property classes), with the keyed text of `text_variant` (a
compiled scene, or `NULL`) swapped in – exactly the frame
`render_animation` would draw for that schedule entry. For rendering one
frame on its own
([`vl_render_frame()`](https://r-vellum.github.io/vellum/reference/vl_render_frame.md))
and for inspecting a mid-transition frame (`$element_table()`,
`$pixel()`).

## Usage

``` r
tween_frame(a, b, frac, frac_col, frac_size, frac_alpha, text_variant)
```
