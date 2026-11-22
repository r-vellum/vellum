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
  format = c("gif", "apng", "svg", "frames"),
  fps = 25,
  gif_speed = 10,
  gif_dither = TRUE,
  frac_col = NULL,
  frac_size = NULL,
  frac_alpha = NULL,
  text_variants = NULL,
  text_frame = NULL
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
  `seg`. This is the schedule for **positional** geometry, and for every
  discrete attribute that snaps at the halfway point.

- path:

  Output path: an image file for `"gif"`/`"apng"`/`"svg"`, or a
  directory (created if needed) for `"frames"`.

- format:

  `"gif"` (looping animated GIF), `"apng"` (animated PNG), `"svg"` (a
  single animated SVG), or `"frames"` (one `frameNNNNN.png` per frame
  into `path`).

- fps:

  Frames per second (sets each frame's on-screen duration). Need not be
  whole: `12.5` or `0.5` (a two-second slideshow frame) are kept
  exactly. A GIF stores delays in whole centiseconds, so its rate is the
  nearest `100 / n` fps, and above 50 fps browsers play it slower, not
  faster (a warning says so).

- gif_speed:

  GIF only: the NeuQuant palette sample factor, `1` (best quality,
  slowest) to `30` (fastest). The default `10` samples a tenth of the
  pixels to build each frame's palette: with dithering on, the frames
  are visually indistinguishable from `1` on a plot (a mean error under
  0.2 of 255 per channel on a dense scatter), at about a quarter of the
  encode time. Use `1` for the last bit of palette fidelity. Ignored for
  `"apng"`/`"svg"`/`"frames"`.

- gif_dither:

  GIF only: apply Floyd–Steinberg dithering (default `TRUE`), which
  greatly reduces the banding a 256-colour palette leaves on gradients
  and antialiased edges. A frame that already fits in 256 colours is
  kept exact.

- frac_col, frac_size, frac_alpha:

  Optional per-aesthetic schedules, each a numeric vector the same
  length as `frac`, for the colour, size and opacity classes
  respectively. `NULL` (the default) uses `frac`, so one easing curve
  shapes the whole scene. Supplying a differently-eased vector lets each
  aesthetic travel on its own curve — position arriving on
  `cubic-in-out` while colour crossfades `linear`, say. See
  *Per-aesthetic easing* below.

- text_variants, text_frame:

  Optional per-frame text, for a label that changes on every frame
  rather than only at keyframes (a title showing the current time, say).
  `text_variants` is a list of scenes (anything with an
  [`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)
  method), each holding one or more **keyed** text grobs
  (`text_grob(key = )`); `text_frame` gives, per output frame, the
  1-based index of the variant that frame uses, or `0` (or `NA`) for
  none. In a frame that uses a variant, every keyed text node of the
  tweened frame whose key matches one of the variant's text grobs takes
  that grob's string and glyph layout (shaping, extent, font and size),
  while its position, rotation, justification and colour stay as the
  tween put them. So shape each distinct string once, with the same font
  and wrapping width as the node it replaces. `NULL` (the default) for
  neither.

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

Each GIF frame is quantised to its own palette and dithered on the
worker threads that rasterise it, so a GIF encodes in parallel like the
other formats; it is still several times slower than APNG (a 1200 x 800,
150-frame scatter: about 3 s against 2 s for APNG at the default
`gif_speed`, 13 s at `gif_speed = 1`).

## Choosing a format

`"svg"` emits every frame as vector markup, shown in turn by a CSS step
animation. It is resolution-independent, which no raster format is — the
same file is crisp in a slide, on a retina screen and in print.

Its size depends on scene complexity in a way the raster formats' does
not, because *every frame is emitted in full*. Measured on a 30-frame
scatter animation, gzipped (which is how a browser will fetch it):

|       |                        |        |
|-------|------------------------|--------|
| marks | animated SVG (gzipped) | GIF    |
| 20    | 20 KB                  | 61 KB  |
| 200   | 80 KB                  | 296 KB |
| 2000  | 720 KB                 | 124 KB |

So it wins clearly on line art — an explanatory animation of a few
moving marks, which is the common case — and loses on a dense scatter,
where a raster format is the right answer. Serve it gzipped (`.svgz`, or
any web server with compression on); uncompressed it is several times
larger again.

It also honours `prefers-reduced-motion`: a reader who has asked their
system not to animate gets one still frame. That is the last frame when
the schedule ends exactly on the final keyframe (a reveal, a time
series, a sequence that does not loop: the complete picture), and the
first frame otherwise (a loop).

Its CSS class and animation names carry the document's id prefix, so
several animated SVGs inlined into one HTML page play independently.

## Matching marks by identity

Marks are matched across keyframes by their **data keys** (a grob's
`keys`, the same keys interactivity uses), not by where they sit in the
node list. An element keyed `"k"` in one keyframe tweens into the
element keyed `"k"` in the next wherever that is drawn: in another node,
at another index, in another colour group's batch (a point that changes
group slides and recolours). So the order of rows, and which groups a
state happens to contain, do not matter. Keys are matched across the
whole scene, so a caller keeps them unique per layer (vellumplot
prefixes the layer) and stable across states.

What has no partner enters or leaves:

- keyed points, circles, rectangles (bars, tiles), hexagons, sectors and
  segments, and keyed lines, polygons, paths, rounded rectangles and
  text labels **fade** in or out on the alpha schedule;

- unkeyed nodes (axes, gridlines, legends, unkeyed marks) pair in order
  with the nodes of the same viewport, kind and role in the other
  keyframe. When that class has a different number of nodes in the two
  keyframes it cannot be matched, and its nodes **switch** whole at the
  midpoint (`frac >= 0.5`).

A matched line, polygon or path whose vertex count changes **morphs**:
both outlines are put on one common set of vertices by arc length (every
vertex of either, at its fraction of the way along its own outline), and
a ring is first turned to run the same way round and start near the
other's start. Each keeps all of its own vertices, so the morph starts
and ends on the keyframes exactly. A pair in mixed or different units,
with a stroke-width profile, a broken (non-finite) line, or paths with
different numbers of sub-paths, switches whole at the midpoint instead,
as does a matched pair of different kinds; a text label takes its string
and layout from the nearer keyframe while its position tweens.

Marks that overlap are drawn in the left keyframe's order up to the
midpoint and in the right keyframe's from there on, so a mark that moves
in front of another swaps over halfway through the move, along with the
other discrete switches, rather than popping at the next keyframe.

Two keyframes that do not share a viewport tree cannot be matched at
all: the frames show the left keyframe up to the midpoint and the right
one from there on (a cut, but every keyframe is shown).
[`vl_tween_pairing()`](https://r-vellum.github.io/vellum/reference/vl_tween_pairing.md)
reports all of this before rendering. Easing curves that overshoot
(`back`, `elastic`) may carry positions past their targets, but sizes,
radii and line widths stay at or above zero and opacity within `[0, 1]`.

## Per-aesthetic easing

`frac` and its three companions carry one eased fraction per **property
class**, so a single frame can interpolate different properties at
different points along their transitions. Every drawn property belongs
to exactly one class:

|  |  |
|----|----|
| schedule | drives |
| `frac` | x/y and all coordinate geometry, widths and heights, angles, path vertices, text rotation, dash phase — **and every discrete attribute's halfway snap** (`lty`, `lineend`, labels, a variant mismatch) |
| `frac_col` | `fill`, `col`, the stroke paint, and per-element colour vectors (hexagon and sector fills) |
| `frac_size` | `lwd`, marker size, circle and corner radius, hexagon extent, `linemitre` |
| `frac_alpha` | `alpha`, **including the enter/exit fade** — a keyed element appearing or leaving fades on this curve |

Two consequences worth knowing. Easing `alpha` retimes entrances and
exits, not just explicit opacity changes. And because a discrete
attribute flips when its fraction crosses `0.5`, and an eased curve
reaches `0.5` at a different *frame* than a linear one, `frac` decides
which frame those snaps land on.

Passing all four identical (the default) reproduces single-curve easing
exactly — the output is byte-identical to omitting them.

## See also

[`render()`](https://r-vellum.github.io/vellum/reference/vl_scene.md),
[`as_vellum_scene()`](https://r-vellum.github.io/vellum/reference/as_vellum_scene.md)

## Examples

``` r
if (FALSE) { # \dontrun{
grow <- lapply(c(0.1, 0.3, 0.2), function(r) {
  vl_scene(3, 2) |> draw(circle_grob(r = r, gp = vl_gpar(fill = "tomato")))
})
# 15 frames per move (fraction 0 up to, not including, 1 -- the next move
# starts on that keyframe), then 10 frames held on the last keyframe.
seg <- c(rep(1:2, each = 15), rep(2, 10))
frac <- c(rep((0:14) / 15, 2), rep(1, 10))
vl_render_animation(grow, seg, frac, tempfile(fileext = ".gif"))
} # }
```
