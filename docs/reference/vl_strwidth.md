# Measure text

`vl_strwidth()` / `vl_strheight()` return the rendered width/height of
each string, using the same shaping (textshaping/HarfBuzz + systemfonts)
the renderer uses, so measurements match drawn text. Device-independent
(does not need an open scene). Vectorised over `label`. (Named `vl_*` to
avoid masking `grDevices::strwidth()`.)

## Usage

``` r
vl_strwidth(
  label,
  family = "",
  fontface = "plain",
  fontsize = 12,
  cex = 1,
  unit = "in"
)

vl_strheight(
  label,
  family = "",
  fontface = "plain",
  fontsize = 12,
  cex = 1,
  unit = "in"
)
```

## Arguments

- label:

  Character vector of strings to measure.

- family:

  Font family (e.g. `"sans"`, `"serif"`, `"mono"`, or a specific family
  name). `""` uses the system default.

- fontface:

  One of `"plain"`, `"bold"`, `"italic"`, `"bold.italic"`.

- fontsize:

  Font size in points.

- cex:

  Multiplier applied to `fontsize`.

- unit:

  Output unit: one of `"in"`, `"pt"`, `"mm"`, `"cm"`.

## Value

A numeric vector (one per `label`) of widths/heights in `unit`.

## Examples

``` r
vl_strwidth(c("short", "a longer label"), fontsize = 14)
#> [1] 0.4320747 1.1668837
```
