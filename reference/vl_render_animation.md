# Render a keyframe animation

Interpolate between a set of compiled keyframe scenes and encode the
in-between frames to an animated image, in one parallel, streaming pass
in the Rust backend. This is the low-level engine a grammar layer (e.g.
vellumplot's `animate()`) drives: the caller supplies the `K` keyframe
scenes and a per-frame *schedule* — for each output frame, which
adjacent keyframe pair to interpolate and the eased fraction between
them — and this renders and encodes every frame.

## Usage

``` r
vl_render_animation(
  keyframes,
  seg,
  frac,
  path,
  format = c("gif", "apng", "frames"),
  fps = 25,
  gif_speed = 1,
  gif_dither = TRUE
)
```

## Arguments

- keyframes:

  A list of at least two scenes (each a
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md)
  or anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method), all the same pixel size.

- seg:

  Integer vector, one entry per output frame: the **1-based** index of
  the frame's left keyframe (it is interpolated with keyframe
  `seg + 1`).

- frac:

  Numeric vector, one per output frame: the eased interpolation fraction
  in `[0, 1]` (0 = the left keyframe, 1 = the right one). Same length as
  `seg`.

- path:

  Output path: an image file for `"gif"`/`"apng"`, or a directory
  (created if needed) for `"frames"`.

- format:

  `"gif"` (looping animated GIF), `"apng"` (animated PNG), or `"frames"`
  (one `frameNNNNN.png` per frame into `path`).

- fps:

  Frames per second (sets each frame's on-screen duration).

- gif_speed:

  GIF only: the NeuQuant palette sample factor, `1` (best quality,
  slowest) to `30` (fastest). A plot's antialiased edges want the best
  palette, so the default is `1`. Ignored for `"apng"`/`"frames"`.

- gif_dither:

  GIF only: apply Floyd–Steinberg dithering (default `TRUE`), which
  greatly reduces the banding a 256-colour palette leaves on gradients
  and antialiased edges. A frame that already fits in 256 colours is
  kept exact.

## Value

`path`, invisibly.

## Details

The frames are tweened at the scene level: matching primitives
interpolate their geometry, their colours (perceptually, in Oklab), and
their bounded graphical parameters; discrete attributes snap. Nothing
retrains between frames — the keyframes are fixed at author time — so
this is non-reactive keyframe animation, not a live/reactive runtime.

GIF is limited to 256 colours per frame, so on a plot (smooth panels,
antialiased marks) it is inherently lossy — `gif_speed`/`gif_dither`
make it as clean as that palette allows. For a lossless result use
`format = "apng"`.

## See also

[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
[`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)

## Examples

``` r
if (FALSE) { # \dontrun{
grow <- lapply(c(0.1, 0.3, 0.2), function(r) {
  vl_scene(3, 2) |> draw(circle_grob(r = r, gp = vl_gpar(fill = "tomato")))
})
# 30 frames across the 3 keyframes, held on the last one.
seg <- rep(1:2, each = 15)
frac <- rep(seq(0, 1, length.out = 15), 2)
vl_render_animation(grow, seg, frac, tempfile(fileext = ".gif"))
} # }
```
