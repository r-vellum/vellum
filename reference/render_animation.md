# Render a keyframe animation to `path`.

- `keyframes` — a list of compiled `Scene` external pointers (the `K`
  states).

- `seg` — per frame, the 0-based index of the frame's **left** keyframe
  (the right one is `seg + 1`).

- `frac` — per frame, the eased interpolation fraction in `[0, 1]`.

- `format` — `"frames"` (a PNG per frame into directory `path`),
  `"apng"` (a single animated PNG at `path`), or `"gif"` (a looping
  animated GIF).

- `delay_num`/`delay_den` — per-frame delay as a fraction of a second
  (e.g. `1`/`25` for 25 fps); rounded to centiseconds for GIF.

- `gif_speed` — GIF only: NeuQuant palette sample factor, 1 (best) to 30
  (fastest). Ignored by the other formats.

- `gif_dither` — GIF only: apply Floyd–Steinberg dithering.

## Usage

``` r
render_animation(
  keyframes,
  seg,
  frac,
  format,
  path,
  delay_num,
  delay_den,
  gif_speed,
  gif_dither
)
```

## Details

Returns any renderer degradation warnings (currently none for the raster
path).
