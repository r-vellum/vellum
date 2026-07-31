# Where a scene spends its render time

Attributes render cost to the individual marks that caused it, and
splits the three phases a render goes through: **build** (constructing
the R value), **compile** (the R→Rust replay, including text shaping),
and **raster** (drawing). Turns "this plot is slow" into a specific
answer.

## Usage

``` r
profile_render(scene, reps = 3)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method.

- reps:

  Number of render repetitions to time; the median is reported.

## Value

A data frame ordered by cost, with columns `kind`, `name`, `n`
(elements), `seconds` and `pct` (share of raster time). Rows are
aggregated per mark — a vectorised
[`text_grob()`](https://r-vellum.github.io/vellum/reference/grob.md) of
200 labels compiles to 200 nodes but reports as one row — so the table
reads as "which of my marks is expensive". The phase split is attached
as the `"phases"` attribute and shown when printed.

## Details

Read the phase split first. Compile time is R-side — S7 property
validation, grob construction, unit records — and on scenes with many
small grobs it routinely dominates, in which case no amount of backend
tuning will help. The per-node table only accounts for raster time.

Timing is armed only for this call, so ordinary renders pay nothing for
it.

## See also

[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md),
[`scene_stats()`](https://r-vellum.github.io/vellum/reference/scene_stats.md)

## Examples

``` r
set.seed(1)
s <- vl_scene(4, 3) |>
  draw(points_grob(runif(2000), runif(2000))) |>
  draw(text_grob("title", y = 0.95, gp = vl_gpar(fontsize = 16)))
profile_render(s)
#> Phases (median of the timed reps):
#> • build 0.000 s (constructing the R value)
#> • compile 0.002 s (R -> Rust replay, incl. text shaping)
#> • raster 0.038 s (drawing)
#> 
#> Slowest marks (raster time):
#> • circle - 2000 elem 0.0079 s 99.6%
#> • text - 1 elem 0.0000 s 0.4%
```
