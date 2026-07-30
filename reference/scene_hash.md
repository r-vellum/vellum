# A content fingerprint for a scene

A stable hash of everything that defines the scene — geometry, style,
page size, background. Two scenes that would render identically hash
identically; any change to what is drawn changes the hash.

## Usage

``` r
scene_hash(scene)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method.

## Value

A length-1 character hash.

## Details

Useful for caching (has this scene changed since I last rendered it?)
and for asserting in tests that a refactor did not alter the scene.

## See also

[`scene_diff()`](https://r-vellum.github.io/vellum/reference/scene_diff.md)
to see *what* changed,
[`as_scene_spec()`](https://r-vellum.github.io/vellum/reference/as_scene_spec.md).

## Examples

``` r
a <- vl_scene(2, 2) |> draw(circle_grob(gp = vl_gpar(fill = "red")))
b <- vl_scene(2, 2) |> draw(circle_grob(gp = vl_gpar(fill = "blue")))
scene_hash(a) == scene_hash(a)
#> [1] TRUE
scene_hash(a) == scene_hash(b)
#> [1] FALSE
```
