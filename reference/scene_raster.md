# Read a rendered scene back as pixels

`scene_raster()` renders `scene` and returns its pixels as an integer
array with dimensions `c(channel, x, y)` — RGBA channels in `0:255`,
top-left origin, `y` increasing downward. This is the form most
convenient for probing or testing (e.g. `scene_raster(s)[1, x, y]` is
the red value at pixel `(x, y)`).

## Usage

``` r
scene_raster(scene, cvd = "none")
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  (or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method).

- cvd:

  Simulate a colour-vision deficiency: `"none"` (default),
  `"protanopia"` (red-blind), `"deuteranopia"` (green-blind, the common
  one that breaks red/green encodings), `"tritanopia"` (blue-blind), or
  `"achromatopsia"` (total, and a fair proxy for greyscale printing).
  The simulation is a post-pass over the finished raster using the
  Machado et al. (2009) matrices applied in linear light, so it turns an
  accessibility check into a one-line change instead of an
  export-and-upload round trip. **Raster output only** — a vector format
  has no pixels to transform, and
  [`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  warns if you ask for one.

## Value

`scene_raster()`: an integer array of dimension `c(4, width, height)`.
The [`as.raster()`](https://rdrr.io/r/grDevices/as.raster.html) method:
a `raster` (character matrix, `c(height, width)`).

## Details

An
[`grDevices::as.raster()`](https://rdrr.io/r/grDevices/as.raster.html)
method returns the same image as a `raster` object (a character matrix
of hex colours), drawable with
[`graphics::plot()`](https://rdrr.io/r/graphics/plot.default.html) or
[`grid::rasterGrob()`](https://rdrr.io/r/grid/grid.raster.html).

## Examples

``` r
s <- vl_scene(2, 1, bg = "white") |>
  draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "red", col = NA)))
dim(scene_raster(s)) # c(4, width_px, height_px)
#> [1]   4 192  96
```
