# Inspecting a scene: linting, coverage, profiling

A vellum scene is not only something you render. Because layout and text
metrics are resolved **before** anything is drawn, a finished scene can
be asked questions — where will this land, how big will that text be,
what is expensive — and answer them exactly, without opening a device.

This article covers the three tools built on that:
[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)
finds likely mistakes,
[`scene_stats()`](https://r-vellum.github.io/vellum/reference/scene_stats.md)
measures coverage and crowding, and
[`profile_render()`](https://r-vellum.github.io/vellum/reference/profile_render.md)
says where the time goes.

## Why this can exist here

In grid, a grob’s size and position are not knowable until draw time:
text has no measurable width before a device is open, `native` units
need a viewport, and `null` units need a layout context. Anything
wanting to check “is this label readable at the rendered size” would
have to re-implement the geometry and hope it stays in step with the
renderer.

vellum resolves all of it up front, and every tool below reads *the same
resolved numbers the renderer draws with*. That is the whole trick.

## `vl_lint()`: static analysis for graphics

Here is a plot with four defects planted in it. Each is the kind of
thing you normally discover by exporting the figure and squinting at it.

``` r

bad <- vl_scene(5, 3, dpi = 96) |>
  push(vl_viewport(name = "panel", y = 0.55, width = 0.85, height = 0.7,
                   xscale = c(0, 1), yscale = c(0, 1), clip = TRUE)) |>
  draw(rect_grob(gp = vl_gpar(fill = "grey96", col = "grey70"))) |>
  draw(points_grob(runif(120), runif(120), size = vl_unit(1.6, "mm"),
                   gp = vl_gpar(fill = "#7FB2E5", col = NA), name = "cloud")) |>
  # 1. outside the panel's clip: silently never drawn
  draw(points_grob(2.4, 0.5, size = vl_unit(3, "mm"),
                   gp = vl_gpar(fill = "tomato", col = NA), name = "stray_point")) |>
  # 2. too small to read
  draw(text_grob("n = 120", x = 0.06, y = 0.93, just = c("left", "top"),
                 gp = vl_gpar(fontsize = 2.5), name = "n_label")) |>
  # 3. will not contrast with the panel behind it
  draw(text_grob("watermark", gp = vl_gpar(fontsize = 22, col = "#F2F2F2"),
                 name = "watermark")) |>
  # 4. nothing will ever paint it
  draw(rect_grob(x = 0.8, y = 0.2, width = 0.2, height = 0.1,
                 gp = vl_gpar(fill = NA, col = NA), name = "empty_box")) |>
  pop()

vl_lint(bad)
#> 4 lint findings (4 warnings):
#> ✖ [invisible] empty_box: nothing will paint this - alpha is 0, or both fill and
#>   col are absent
#> ✖ [low_contrast] watermark: contrast 1.3:1 against its backdrop - below 3:1
#> ✖ [offscreen] stray_point: drawn entirely outside the page - check the
#>   coordinates or the scale
#> ✖ [tiny_text] n_label: 3.3 px tall - below the 7 px legibility floor
```

Every finding names the grob, so you can go straight to it. Nothing here
needed you to look at the picture.

The rules that ship:

``` r

vl_lint_rules()
#>            rule                                                     description
#> 1  clipped_away             A mark is clipped out of existence by its viewport.
#> 2    degenerate                               An element resolves to zero size.
#> 3     invisible               An element has no fill, no stroke, or zero alpha.
#> 4 label_overlap                                        Two text labels overlap.
#> 5  low_contrast Text contrast against its backdrop is below the WCAG threshold.
#> 6     offscreen                          A mark lies completely off the canvas.
#> 7     tiny_text                 Text is too small to read at the rendered size.
```

Two are worth explaining.

`tiny_text` measures in **device pixels at the size you are actually
rendering**, not in points. A 6 pt label is fine in a print figure and
illegible in a thumbnail, and the same scene rendered at two sizes
should — correctly — lint differently. Adjust the floor with
`min_text_px`.

`low_contrast` samples the **rendered image** just outside each label’s
box, on four sides, and takes the worst. So it measures the backdrop the
label really sits on, including any marks that happen to be behind it,
rather than assuming the page colour:

``` r

faint <- vl_scene(4, 1.2, dpi = 96, bg = "white") |>
  draw(text_grob("hard to read", gp = vl_gpar(fontsize = 22, col = "#DDDDDD")))
vl_lint(faint)
#> 1 lint finding (1 warning):
#> ✖ [low_contrast] text: contrast 1.7:1 against its backdrop - below 3:1

# Same text colour, dark page: now it is fine, and the linter agrees.
vl_lint(vl_scene(4, 1.2, dpi = 96, bg = "grey15") |>
  draw(text_grob("easy to read", gp = vl_gpar(fontsize = 22, col = "#DDDDDD"))))
#> ✔ No lint findings.
```

### Adding your own rules

The rule set is a registry, which is the point: vellum knows about
geometry, but it knows nothing about *your* semantics. A package layered
on top can add rules that do, and both come back from one
[`vl_lint()`](https://r-vellum.github.io/vellum/reference/vl_lint.md)
call.

A rule is a function of `(scene, nodes, ctx)`. `nodes` is the resolved
per-node table — device-px box, clip box, kind, name, element count,
alpha, whether a fill or stroke is present, font size in px, colour,
label — and `ctx` carries the page size, dpi, thresholds, and a
`pixel(x, y)` sampler.

``` r

vl_lint_rule(
  "wide_marks",
  function(scene, nodes, ctx) {
    wide <- nodes[(nodes$x1 - nodes$x0) > 0.8 * ctx$w, , drop = FALSE]
    vl_lint_finding("wide_marks", "note", wide, "spans almost the whole page")
  },
  description = "A mark spans nearly the full page width."
)

vl_lint(bad, rules = c("wide_marks", "tiny_text"))
#> 3 lint findings (1 warning):
#> ✖ [tiny_text] n_label: 3.3 px tall - below the 7 px legibility floor
#> ℹ [wide_marks] rect: spans almost the whole page
#> ℹ [wide_marks] cloud: spans almost the whole page
```

Register from your package’s `.onLoad()` and your users get your rules
for free.

## `scene_stats()`: how crowded is this, really?

A mark count tells you nothing about whether the marks land on top of
each other.
[`scene_stats()`](https://r-vellum.github.io/vellum/reference/scene_stats.md)
measures what actually reached the canvas:

``` r

cloud <- function(n, sd = NA) {
  xy <- if (is.na(sd)) list(runif(n), runif(n)) else list(rnorm(n, .5, sd), rnorm(n, .5, sd))
  vl_scene(4, 3, dpi = 96) |>
    draw(points_grob(xy[[1]], xy[[2]], gp = vl_gpar(fill = "steelblue", col = NA)))
}

round(rbind(
  scattered = scene_stats(cloud(2000)),
  clustered = scene_stats(cloud(2000, sd = 0.03))
), 3)
#>           elements   ink colours overplot
#> scattered     2000 0.971     233    4.256
#> clustered     2000 0.045      59   91.004
```

Identical element counts; wildly different plots. `overplot` estimates
how many times an average inked pixel was painted over — `1` means no
overlap — and it is the honest trigger for reaching for
[`datashade()`](https://r-vellum.github.io/vellum/reference/datashade.md).
Thirty thousand well-separated points are fine; eight thousand piled up
are not, and only this number knows the difference.

It is computed from bounding boxes, so treat it as an index rather than
a measurement: a circle fills about 79% of its box, and text and unkeyed
lines/polygons contribute to `ink` but not to `overplot`.

## `profile_render()`: where the time goes

``` r

heavy <- vl_scene(6, 4, dpi = 96) |>
  draw(points_grob(runif(20000), runif(20000), name = "points")) |>
  draw(segments_grob(runif(2000), runif(2000), runif(2000), runif(2000), name = "edges")) |>
  draw(text_grob(format(1:200), x = runif(200), y = runif(200),
                 gp = vl_gpar(fontsize = 8), name = "labels"))

profile_render(heavy, reps = 1)
#> Phases (median of the timed reps):
#> • build 0.001 s (constructing the R value)
#> • compile 0.023 s (R -> Rust replay, incl. text shaping)
#> • raster 0.185 s (drawing)
#> 
#> Slowest marks (raster time):
#> • circle points 20000 elem 0.1176 s 76.5%
#> • segments edges 2000 elem 0.0333 s 21.7%
#> • text labels 200 elem 0.0027 s 1.8%
```

**Read the phase split first.** A render is three phases: *build*
(constructing the R value), *compile* (the R→Rust replay, including text
shaping), and *raster* (drawing). If compile dominates — which it does
on scenes made of many small grobs, where the cost is S7 validation and
grob construction — then the backend is not your problem and tuning it
will not help.
[`profile_render()`](https://r-vellum.github.io/vellum/reference/profile_render.md)
says so explicitly when that happens.

The per-mark table covers raster time, aggregated by mark rather than by
node: a vectorised
[`text_grob()`](https://r-vellum.github.io/vellum/reference/grob.md) of
200 labels compiles to 200 nodes, and 200 rows of almost nothing is
noise rather than a profile.

Timing is armed only for that call, so ordinary renders pay nothing for
it.

## Putting it in a test

All three return plain data frames, so they drop straight into a test
suite. A lint check is a reasonable thing to assert in CI:

``` r

test_that("the figure has no lint findings", {
  expect_equal(nrow(vl_lint(my_plot())), 0L)
})
```

## Where to go next

- [`vignette("render-quality")`](https://r-vellum.github.io/vellum/articles/render-quality.md):
  colour-vision simulation, crisp gridlines, and group effects — the
  other half of “will this actually read”.
- [`vignette("retained-mode")`](https://r-vellum.github.io/vellum/articles/retained-mode.md):
  [`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md),
  [`hit_test()`](https://r-vellum.github.io/vellum/reference/hit_test.md),
  and editing nodes by name.
