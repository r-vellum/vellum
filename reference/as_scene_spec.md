# Convert a scene to and from a plain list

`as_scene_spec()` turns a rendered-ready scene into a plain nested list
of R vectors, and `from_scene_spec()` rebuilds the scene from it.
Together they make a compiled scene a *value you can store or send*,
rather than something that only exists inside the session that built it.

## Usage

``` r
as_scene_spec(scene)

from_scene_spec(spec)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method.

- spec:

  A list from `as_scene_spec()`.

## Value

`as_scene_spec()`: a nested list, with a `version` element.
`from_scene_spec()`: a `vellum_scene`.

## Details

This is one level below `vellumplot`'s plot spec. A plot spec is
portable and re-renderable at any size; a scene spec is the *resolved*
artifact — the grobs, units and viewports as they will actually be
drawn. They compose: keep the plot spec to re-render, keep the scene
spec to reproduce exactly this scene.

The conversion is generic over the S7 property model rather than written
per grob type, so a grob added to vellum later serializes with no change
here.

## See also

[`scene_write()`](https://r-vellum.github.io/vellum/reference/scene_write.md),
[`scene_diff()`](https://r-vellum.github.io/vellum/reference/scene_diff.md),
[`scene_hash()`](https://r-vellum.github.io/vellum/reference/scene_hash.md)

## Examples

``` r
s <- vl_scene(3, 2) |>
  draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "tomato", col = NA)))
spec <- as_scene_spec(s)
spec$version
#> [1] 1
identical(as_scene_spec(from_scene_spec(spec)), spec)
#> [1] TRUE
```
