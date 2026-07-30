# Write and read a scene

Persist a scene so it can be rebuilt later, in another session, or in
another process. `.rds` is the default and needs nothing extra; `.json`
produces a portable text format and needs the jsonlite package.

## Usage

``` r
scene_write(scene, path)

scene_read(path)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method.

- path:

  File path. The extension picks the format (`.rds` or `.json`).

## Value

`scene_write()`: `path`, invisibly. `scene_read()`: a `vellum_scene`.

## Details

What this buys you: caching a built scene without re-running the code
that built it, sending one over a wire for a worker to render, and
keeping a reproducible intermediate between "the code" and "the pixels".

## See also

[`as_scene_spec()`](https://r-vellum.github.io/vellum/reference/as_scene_spec.md),
[`scene_diff()`](https://r-vellum.github.io/vellum/reference/scene_diff.md),
[`scene_hash()`](https://r-vellum.github.io/vellum/reference/scene_hash.md)

## Examples

``` r
s <- vl_scene(2, 2) |> draw(circle_grob(gp = vl_gpar(fill = "steelblue")))
f <- tempfile(fileext = ".rds")
scene_write(s, f)
identical(as_scene_spec(scene_read(f)), as_scene_spec(s))
#> [1] TRUE
```
