#' Render a keyframe animation
#'
#' Interpolate between a set of compiled keyframe scenes and encode the in-between
#' frames to an animated image, in one parallel, streaming pass in the Rust
#' backend. This is the low-level engine a grammar layer (e.g. vellumplot's
#' `animate()`) drives: the caller supplies the `K` keyframe scenes and a
#' per-frame *schedule* — for each output frame, which adjacent keyframe pair to
#' interpolate and the eased fraction between them — and this renders and encodes
#' every frame.
#'
#' The frames are tweened at the scene level: matching primitives interpolate
#' their geometry, their colours (perceptually, in Oklab), and their bounded
#' graphical parameters; discrete attributes snap. Nothing retrains between frames
#' — the keyframes are fixed at author time — so this is non-reactive keyframe
#' animation, not a live/reactive runtime.
#'
#' @param keyframes A list of at least two scenes (each a [vl_scene()] or anything
#'   with an [as_vellum_scene()] method), all the same pixel size.
#' @param seg Integer vector, one entry per output frame: the **1-based** index of
#'   the frame's left keyframe (it is interpolated with keyframe `seg + 1`).
#' @param frac Numeric vector, one per output frame: the eased interpolation
#'   fraction in `[0, 1]` (0 = the left keyframe, 1 = the right one). Same length
#'   as `seg`. This is the schedule for **positional** geometry, and for every
#'   discrete attribute that snaps at the halfway point.
#' @param frac_col,frac_size,frac_alpha Optional per-aesthetic schedules, each a
#'   numeric vector the same length as `frac`, for the colour, size and opacity
#'   classes respectively. `NULL` (the default) uses `frac`, so one easing curve
#'   shapes the whole scene. Supplying a differently-eased vector lets each
#'   aesthetic travel on its own curve — position arriving on `cubic-in-out`
#'   while colour crossfades `linear`, say. See *Per-aesthetic easing* below.
#' @param path Output path: an image file for `"gif"`/`"apng"`/`"svg"`, or a
#'   directory (created if needed) for `"frames"`.
#' @param format `"gif"` (looping animated GIF), `"apng"` (animated PNG),
#'   `"svg"` (a single animated SVG), or `"frames"` (one `frameNNNNN.png` per
#'   frame into `path`).
#' @param fps Frames per second (sets each frame's on-screen duration). Need
#'   not be whole: `12.5` or `0.5` (a two-second slideshow frame) are kept
#'   exactly. A GIF stores delays in whole centiseconds, so its rate is the
#'   nearest `100 / n` fps, and above 50 fps browsers play it slower, not faster
#'   (a warning says so).
#' @param gif_speed GIF only: the NeuQuant palette sample factor, `1` (best
#'   quality, slowest) to `30` (fastest). The default `10` samples a tenth of the
#'   pixels to build each frame's palette: with dithering on, the frames are
#'   visually indistinguishable from `1` on a plot (a mean error under 0.2 of 255
#'   per channel on a dense scatter), at about a quarter of the encode time. Use
#'   `1` for the last bit of palette fidelity. Ignored for
#'   `"apng"`/`"svg"`/`"frames"`.
#' @param gif_dither GIF only: apply Floyd–Steinberg dithering (default `TRUE`),
#'   which greatly reduces the banding a 256-colour palette leaves on gradients and
#'   antialiased edges. A frame that already fits in 256 colours is kept exact.
#' @param text_variants,text_frame Optional per-frame text, for a label that
#'   changes on every frame rather than only at keyframes (a title showing the
#'   current time, say). `text_variants` is a list of scenes (anything with an
#'   [as_vellum_scene()] method), each holding one or more **keyed** text grobs
#'   (`text_grob(key = )`); `text_frame` gives, per output frame, the 1-based
#'   index of the variant that frame uses, or `0` (or `NA`) for none. In a frame
#'   that uses a variant, every keyed text node of the tweened frame whose key
#'   matches one of the variant's text grobs takes that grob's string and glyph
#'   layout (shaping, extent, font and size), while its position, rotation,
#'   justification and colour stay as the tween put them. So shape each
#'   distinct string once, with the same font and wrapping width as the node it
#'   replaces. `NULL` (the default) for neither.
#' @return `path`, invisibly.
#' @details
#' GIF is limited to 256 colours per frame, so on a plot (smooth panels,
#' antialiased marks) it is inherently lossy — `gif_speed`/`gif_dither` make it as
#' clean as that palette allows. For a lossless result use `format = "apng"`.
#'
#' Each GIF frame is quantised to its own palette and dithered on the worker
#' threads that rasterise it, so a GIF encodes in parallel like the other
#' formats; it is still several times slower than APNG (a 1200 x 800, 150-frame
#' scatter: about 3 s against 2 s for APNG at the default `gif_speed`, 13 s at
#' `gif_speed = 1`).
#'
#' # Choosing a format
#'
#' `"svg"` emits every frame as vector markup, shown in turn by a CSS step
#' animation. It is resolution-independent, which no raster format is — the same
#' file is crisp in a slide, on a retina screen and in print.
#'
#' Its size depends on scene complexity in a way the raster formats' does not,
#' because *every frame is emitted in full*. Measured on a 30-frame scatter
#' animation, gzipped (which is how a browser will fetch it):
#'
#' | marks | animated SVG (gzipped) | GIF |
#' |---|---|---|
#' | 20 | 20 KB | 61 KB |
#' | 200 | 80 KB | 296 KB |
#' | 2000 | 720 KB | 124 KB |
#'
#' So it wins clearly on line art — an explanatory animation of a few moving
#' marks, which is the common case — and loses on a dense scatter, where a raster
#' format is the right answer. Serve it gzipped (`.svgz`, or any web server with
#' compression on); uncompressed it is several times larger again.
#'
#' It also honours `prefers-reduced-motion`: a reader who has asked their system
#' not to animate gets one still frame. That is the last frame when the schedule
#' ends exactly on the final keyframe (a reveal, a time series, a sequence that
#' does not loop: the complete picture), and the first frame otherwise (a loop).
#'
#' Its CSS class and animation names carry the document's id prefix, so several
#' animated SVGs inlined into one HTML page play independently.
#'
#' # Matching marks by identity
#'
#' Marks are matched across keyframes by their **data keys** (a grob's `keys`,
#' the same keys interactivity uses), not by where they sit in the node list. An
#' element keyed `"k"` in one keyframe tweens into the element keyed `"k"` in the
#' next wherever that is drawn: in another node, at another index, in another
#' colour group's batch (a point that changes group slides and recolours). So the
#' order of rows, and which groups a state happens to contain, do not matter.
#' Keys are matched across the whole scene, so a caller keeps them unique per
#' layer (vellumplot prefixes the layer) and stable across states.
#'
#' What has no partner enters or leaves:
#'
#' * keyed points, circles, rectangles (bars, tiles), hexagons, sectors and
#'   segments, and keyed lines, polygons, paths, rounded rectangles and text
#'   labels **fade** in or out on the alpha schedule;
#' * unkeyed nodes (axes, gridlines, legends, unkeyed marks) pair in order with
#'   the nodes of the same viewport, kind and role in the other keyframe. When
#'   that class has a different number of nodes in the two keyframes it cannot
#'   be matched, and its nodes **switch** whole at the midpoint (`frac >= 0.5`).
#'
#' A matched line, polygon or path whose vertex count changes **morphs**: both
#' outlines are put on one common set of vertices by arc length (every vertex of
#' either, at its fraction of the way along its own outline), and a ring is
#' first turned to run the same way round and start near the other's start. Each
#' keeps all of its own vertices, so the morph starts and ends on the keyframes
#' exactly. A pair in mixed or different units, with a stroke-width profile, a
#' broken (non-finite) line, or paths with different numbers of sub-paths,
#' switches whole at the midpoint instead, as does a matched pair of different
#' kinds; a text label takes its string and layout from the nearer keyframe while
#' its position tweens.
#'
#' Marks that overlap are drawn in the left keyframe's order up to the midpoint
#' and in the right keyframe's from there on, so a mark that moves in front of
#' another swaps over halfway through the move, along with the other discrete
#' switches, rather than popping at the next keyframe.
#'
#' Two keyframes that do not share a viewport tree cannot be matched at all: the frames show the
#' left keyframe up to the midpoint and the right one from there on (a cut, but
#' every keyframe is shown). [vl_tween_pairing()] reports all of this before
#' rendering.
#' Easing curves that overshoot (`back`, `elastic`) may carry positions past
#' their targets, but sizes, radii and line widths stay at or above zero and
#' opacity within `[0, 1]`.
#'
#' # Per-aesthetic easing
#'
#' `frac` and its three companions carry one eased fraction per **property
#' class**, so a single frame can interpolate different properties at different
#' points along their transitions. Every drawn property belongs to exactly one
#' class:
#'
#' | schedule | drives |
#' |---|---|
#' | `frac` | x/y and all coordinate geometry, widths and heights, angles, path vertices, text rotation, dash phase — **and every discrete attribute's halfway snap** (`lty`, `lineend`, labels, a variant mismatch) |
#' | `frac_col` | `fill`, `col`, the stroke paint, and per-element colour vectors (hexagon and sector fills) |
#' | `frac_size` | `lwd`, marker size, circle and corner radius, hexagon extent, `linemitre` |
#' | `frac_alpha` | `alpha`, **including the enter/exit fade** — a keyed element appearing or leaving fades on this curve |
#'
#' Two consequences worth knowing. Easing `alpha` retimes entrances and exits,
#' not just explicit opacity changes. And because a discrete attribute flips when
#' its fraction crosses `0.5`, and an eased curve reaches `0.5` at a different
#' *frame* than a linear one, `frac` decides which frame those snaps land on.
#'
#' Passing all four identical (the default) reproduces single-curve easing
#' exactly — the output is byte-identical to omitting them.
#' @seealso [render()], [as_vellum_scene()]
#' @examples
#' \dontrun{
#' grow <- lapply(c(0.1, 0.3, 0.2), function(r) {
#'   vl_scene(3, 2) |> draw(circle_grob(r = r, gp = vl_gpar(fill = "tomato")))
#' })
#' # 15 frames per move (fraction 0 up to, not including, 1 -- the next move
#' # starts on that keyframe), then 10 frames held on the last keyframe.
#' seg <- c(rep(1:2, each = 15), rep(2, 10))
#' frac <- c(rep((0:14) / 15, 2), rep(1, 10))
#' vl_render_animation(grow, seg, frac, tempfile(fileext = ".gif"))
#' }
#' @export
vl_render_animation <- function(
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
) {
  format <- match.arg(format)
  if (!is.list(keyframes) || length(keyframes) < 2L) {
    cli::cli_abort("{.arg keyframes} must be a list of at least 2 scenes.")
  }
  seg <- vctrs::vec_cast(seg, integer())
  frac <- vctrs::vec_cast(frac, double())
  if (length(seg) != length(frac)) {
    cli::cli_abort("{.arg seg} and {.arg frac} must have the same length.")
  }
  # Each per-aesthetic schedule defaults to the positional one, so the common
  # single-curve case sends four identical vectors and tweens exactly as before.
  .frac_class <- function(x, arg) {
    if (is.null(x)) {
      return(frac)
    }
    x <- vctrs::vec_cast(x, double())
    if (length(x) != length(frac)) {
      cli::cli_abort(
        "{.arg {arg}} must have the same length as {.arg frac} ({length(frac)}), not {length(x)}."
      )
    }
    x
  }
  frac_col <- .frac_class(frac_col, "frac_col")
  frac_size <- .frac_class(frac_size, "frac_size")
  frac_alpha <- .frac_class(frac_alpha, "frac_alpha")
  if (length(seg) == 0L) {
    cli::cli_abort("No frames scheduled ({.arg seg} is empty).")
  }
  if (anyNA(seg) || min(seg) < 1L || max(seg) >= length(keyframes)) {
    cli::cli_abort(
      "{.arg seg} entries must be in 1:{length(keyframes) - 1L} (a 1-based left-keyframe index)."
    )
  }
  fps <- fps[[1L]]
  if (!is.finite(fps) || fps <= 0) {
    cli::cli_abort("{.arg fps} must be a positive number.")
  }

  backends <- lapply(keyframes, function(s) {
    .scene_to_backend(as_vellum_scene(s))
  })
  text <- .frame_text(text_variants, text_frame, length(seg))

  # Frame duration = 1 / fps seconds, passed as an exact numerator/denominator so
  # the encoders can round to their own time base (APNG: fraction of a second;
  # GIF: centiseconds). `seg` is 1-based here, 0-based across the FFI.
  gif_speed <- as.integer(gif_speed[[1L]])
  if (is.na(gif_speed) || gif_speed < 1L || gif_speed > 30L) {
    cli::cli_abort(
      "{.arg gif_speed} must be an integer in 1:30 (1 = best quality)."
    )
  }

  # A GIF stores its frame delay in whole centiseconds, and browsers replace a
  # delay of 0 or 1 cs with ~10 cs: above 50 fps the file plays far slower than
  # asked, not faster.
  if (identical(format, "gif") && fps > 50) {
    cli::cli_warn(c(
      "A GIF cannot play faster than 50 fps; {.arg fps} = {fps} will play much slower in most browsers.",
      i = "GIF frame delays are whole centiseconds, and browsers stretch a delay under 2 cs to about 10 cs.",
      i = "Use {.code fps <= 50}, or {.code format = \"apng\"}/{.code \"svg\"}."
    ))
  }
  delay <- .fps_delay(fps)

  warns <- render_animation(
    backends,
    seg - 1L,
    frac,
    format,
    path,
    delay_num = delay[[1L]],
    delay_den = delay[[2L]],
    gif_speed = gif_speed,
    gif_dither = isTRUE(gif_dither),
    frac_col = frac_col,
    frac_size = frac_size,
    frac_alpha = frac_alpha,
    text_variants = text$variants,
    text_frame = text$frame
  )
  .emit_degrade_warnings(warns)
  # An animated SVG emits every frame in full, so a dense scene times a long
  # schedule produces a very large file quietly -- 24 MB for 2000 marks over 30
  # frames, measured. That is easy to do by accident and hard to notice until
  # someone tries to load it, so say so.
  if (identical(format, "svg")) {
    mb <- file.size(path) / 1024^2
    if (is.finite(mb) && mb > 5) {
      cli::cli_warn(c(
        "The animated SVG is {round(mb, 1)} MB.",
        i = "Every frame is emitted in full, so size grows with scene complexity times frame count.",
        i = "Serve it gzipped, or use {.code format = \"gif\"}/{.code \"apng\"} for a dense scene."
      ))
    }
  }
  invisible(path)
}

#' Check how adjacent keyframes will tween
#'
#' [vl_render_animation()] matches marks across keyframes by their data keys
#' (see *Matching marks by identity* there). `vl_tween_pairing()` reports, before
#' anything is rendered, how each adjacent pair will tween -- what still switches
#' at the midpoint and how many marks enter or leave -- so a grammar layer can
#' warn its user.
#'
#' @param keyframes A list of at least two scenes, as for [vl_render_animation()].
#' @return A data frame with one row per adjacent pair: `from`, `to` (keyframe
#'   indices), `paired` (`FALSE` when the two keyframes do not share a viewport
#'   tree, so the frames cut at the midpoint), `nodes_from`, `nodes_to` (the
#'   node counts), `snapped` (the nodes that switch whole at the midpoint: a
#'   matched line or path whose vertex count changes and cannot be morphed, a
#'   matched pair of different kinds, or an unkeyed node with no counterpart),
#'   and `exited`,
#'   `entered` (keyed elements with no partner, which fade out or in). The last
#'   three are `NA` for a pair that does not pair.
#' @seealso [vl_render_animation()]
#' @examples
#' a <- vl_scene(2, 2) |> draw(circle_grob(r = 0.2))
#' b <- a |> draw(rect_grob(width = 0.2, height = 0.2))
#' vl_tween_pairing(list(a, a, b))
#' @export
vl_tween_pairing <- function(keyframes) {
  if (!is.list(keyframes) || length(keyframes) < 2L) {
    cli::cli_abort("{.arg keyframes} must be a list of at least 2 scenes.")
  }
  backends <- lapply(keyframes, function(s) {
    .scene_to_backend(as_vellum_scene(s))
  })
  p <- tween_pairing(backends)
  m <- length(p$paired)
  data.frame(
    from = seq_len(m),
    to = seq_len(m) + 1L,
    paired = p$paired,
    nodes_from = p$nodes_a,
    nodes_to = p$nodes_b,
    snapped = p$snapped,
    exited = p$exited,
    entered = p$entered
  )
}

# The frame duration 1 / fps seconds as an exact (or, for an irrational-looking
# fps, the closest) fraction `c(num, den)` with both terms in 1:65535 -- the
# range an APNG frame delay holds. 12.5 fps is 2/25 s, 0.4 fps is 5/2 s, 29.97
# fps is 100/2997 s: none of them is rounded to a whole fps.
.fps_delay <- function(fps, max_term = 65535L) {
  x <- 1 / fps
  # Continued-fraction convergents of x, kept while both terms fit.
  h <- c(0, 1) # numerators h[k-2], h[k-1]
  k <- c(1, 0) # denominators
  # Fallback for an fps beyond what the terms can express: the nearest bound.
  best <- if (x >= 1) {
    c(min(round(x), max_term), 1)
  } else {
    c(1, min(round(1 / x), max_term))
  }
  r <- x
  for (i in seq_len(40L)) {
    a <- floor(r)
    hn <- a * h[2L] + h[1L]
    kn <- a * k[2L] + k[1L]
    if (hn > max_term || kn > max_term) {
      break
    }
    if (hn >= 1) {
      best <- c(hn, kn)
    }
    h <- c(h[2L], hn)
    k <- c(k[2L], kn)
    frac <- r - a
    if (frac < 1e-12 || abs(hn / kn - x) <= 1e-12 * x) {
      break
    }
    r <- 1 / frac
  }
  as.integer(best)
}

# Validate the per-frame text of `vl_render_animation()`: the variant scenes as
# backends and the per-frame 1-based variant index (0 = none); an empty index
# when there is no per-frame text.
.frame_text <- function(variants, frame, n) {
  if (is.null(variants) && is.null(frame)) {
    return(list(variants = list(), frame = integer(0)))
  }
  if (is.null(variants) || is.null(frame)) {
    cli::cli_abort(
      "Supply both {.arg text_variants} and {.arg text_frame}, or neither."
    )
  }
  if (!is.list(variants)) {
    cli::cli_abort("{.arg text_variants} must be a list of scenes.")
  }
  frame <- vctrs::vec_cast(frame, integer())
  frame[is.na(frame)] <- 0L
  if (length(frame) != n) {
    cli::cli_abort(
      "{.arg text_frame} must have one entry per frame ({n}), not {length(frame)}."
    )
  }
  if (any(frame < 0L | frame > length(variants))) {
    cli::cli_abort(
      "{.arg text_frame} entries must be in 0:{length(variants)} (0 = no variant)."
    )
  }
  list(
    variants = lapply(variants, function(s) {
      .scene_to_backend(as_vellum_scene(s))
    }),
    frame = frame
  )
}

# One tweened frame between scenes `a` and `b` at fraction `frac`, as a backend
# scene to query (`$element_table()`, `$pixel()`): a mid-transition frame
# without rendering a whole animation (tests, debugging).
.tween_frame <- function(a, b, frac) {
  frac <- as.double(frac)
  tween_frame(
    .scene_to_backend(as_vellum_scene(a)),
    .scene_to_backend(as_vellum_scene(b)),
    frac,
    frac,
    frac,
    frac,
    NULL
  )
}

#' Render one frame of a keyframe animation
#'
#' `vl_render_frame()` draws the single frame that [vl_render_animation()]
#' would draw for one schedule entry -- keyframe pair `seg` at fraction `frac`
#' -- and writes it as a still image: a poster for an animation, a thumbnail,
#' or the frame to put in print. The marks are matched and tweened exactly as
#' in the animation (see *Matching marks by identity* in
#' [vl_render_animation()]), and a per-frame text variant is swapped in the
#' same way.
#'
#' @inheritParams vl_render_animation
#' @param seg The 1-based index of the left keyframe of the pair (a single
#'   integer in `1:(length(keyframes) - 1)`).
#' @param frac The positional fraction between keyframe `seg` and `seg + 1`
#'   (a single number; `0` is keyframe `seg`, `1` is keyframe `seg + 1`).
#' @param frac_col,frac_size,frac_alpha The fractions of the other property
#'   classes; default `frac`.
#' @param path Output file path; the format is taken from the extension
#'   (`.png`, `.svg` or `.pdf`), as for [render()].
#' @param text_variant A scene whose keyed text replaces the frame's text with
#'   the same keys (one entry of `text_variants` in [vl_render_animation()]),
#'   or `NULL`.
#' @inheritParams vl_scene
#' @return `path`, invisibly.
#' @seealso [vl_render_animation()], [render()]
#' @examples
#' a <- vl_scene(2, 2) |> draw(circle_grob(r = 0.1, gp = vl_gpar(fill = "tomato")))
#' b <- vl_scene(2, 2) |> draw(circle_grob(r = 0.4, gp = vl_gpar(fill = "tomato")))
#' vl_render_frame(list(a, b), 1, 0.5, tempfile(fileext = ".png"))
#' @export
vl_render_frame <- function(
  keyframes,
  seg,
  frac,
  path,
  frac_col = frac,
  frac_size = frac,
  frac_alpha = frac,
  text_variant = NULL,
  text = c("native", "outline"),
  scale = 1
) {
  text <- match.arg(text)
  if (!is.list(keyframes) || length(keyframes) < 2L) {
    cli::cli_abort("{.arg keyframes} must be a list of at least 2 scenes.")
  }
  one <- function(x, arg, cast) {
    x <- vctrs::vec_cast(x, cast, x_arg = arg)
    if (length(x) != 1L || is.na(x)) {
      cli::cli_abort("{.arg {arg}} must be a single number.")
    }
    x
  }
  seg <- one(seg, "seg", integer())
  if (seg < 1L || seg >= length(keyframes)) {
    cli::cli_abort(
      "{.arg seg} must be in 1:{length(keyframes) - 1L} (a 1-based left-keyframe index)."
    )
  }
  frac <- one(frac, "frac", double())
  frac_col <- one(frac_col, "frac_col", double())
  frac_size <- one(frac_size, "frac_size", double())
  frac_alpha <- one(frac_alpha, "frac_alpha", double())
  ext <- tolower(tools::file_ext(path))
  if (!ext %in% c("png", "svg", "pdf")) {
    cli::cli_abort(
      "Unsupported output format {.val {ext}}; use .png, .svg, or .pdf."
    )
  }
  backend <- function(s) .scene_to_backend(.apply_scale(as_vellum_scene(s), scale))
  s <- tween_frame(
    backend(keyframes[[seg]]),
    backend(keyframes[[seg + 1L]]),
    frac,
    frac_col,
    frac_size,
    frac_alpha,
    if (is.null(text_variant)) NULL else backend(text_variant)
  )
  warns <- switch(
    ext,
    png = s$render_png(path),
    svg = s$render_svg(path, identical(text, "outline")),
    pdf = s$render_pdf(path)
  )
  .emit_degrade_warnings(warns)
  invisible(path)
}
