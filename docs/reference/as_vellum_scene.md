# Coerce an object to a vellum scene

The extensible seam a higher-level package (e.g. a grammar layer)
implements to compile its own plot object into a
[`vl_scene()`](https://schochastics.github.io/vellum/reference/vl_scene.md).
[`render()`](https://schochastics.github.io/vellum/reference/vl_scene.md)
coerces its input through this generic, so `render(x, path)` works for
any `x` that has an `as_vellum_scene()` method. An identity method for
`vellum_scene` is provided.

## Usage

``` r
as_vellum_scene(x, ...)
```

## Arguments

- x:

  An object to coerce: a `vellum_scene`, or a type a downstream package
  has taught to compile by defining an `as_vellum_scene()` method.

- ...:

  Passed on to methods.

## Value

A `vellum_scene`.

## Details

This is the stable *compiler-backend* entry point: downstream packages
should target `as_vellum_scene()` (and the exported grob/viewport/unit
constructors) rather than vellum's internal `compile()` /
`.scene_to_backend()` helpers.

## Examples

``` r
sc <- vl_scene()
identical(as_vellum_scene(sc), sc) # the identity method returns its input
#> [1] TRUE
```
