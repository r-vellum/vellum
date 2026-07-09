# Clear the render cache

vellum memoises compiled scenes keyed on an object-identity token so
repeat renders of an unchanged scene (multi-format export, a
[`display()`](https://schochastics.github.io/vellum/reference/display.md)
resize back to a prior size, or animation replaying a fixed set of
frames) are cheap. The cache is transparent — a cached render is
byte-identical to an uncached one — and bounded
(`options(vellum.cache_size=)`, default 8), so you rarely need this; it
is provided to reclaim memory or to force a cold render in benchmarks.
Disable caching entirely with `options(vellum.cache = FALSE)`.

## Usage

``` r
vl_clear_render_cache()
```

## Value

`NULL`, invisibly.

## Examples

``` r
vl_clear_render_cache()
```
