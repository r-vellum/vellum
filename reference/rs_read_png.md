# Decode a PNG file to straight (un-premultiplied) RGBA.

Returns `c(width, height, r, g, b, a, r, g, b, a, ...)` – the two
dimensions followed by the pixels in row-major order, top-left first.
The `png` crate is already vendored for the encode path, so this needs
no new dependency and no R-side image package.

## Usage

``` r
rs_read_png(path)
```

## Arguments

- path:

  Path to a PNG file.
