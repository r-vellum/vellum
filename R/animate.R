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
#' @param fps Frames per second (sets each frame's on-screen duration).
#' @param gif_speed GIF only: the NeuQuant palette sample factor, `1` (best
#'   quality, slowest) to `30` (fastest). A plot's antialiased edges want the best
#'   palette, so the default is `1`. Ignored for `"apng"`/`"frames"`.
#' @param gif_dither GIF only: apply Floyd–Steinberg dithering (default `TRUE`),
#'   which greatly reduces the banding a 256-colour palette leaves on gradients and
#'   antialiased edges. A frame that already fits in 256 colours is kept exact.
#' @return `path`, invisibly.
#' @details
#' GIF is limited to 256 colours per frame, so on a plot (smooth panels,
#' antialiased marks) it is inherently lossy — `gif_speed`/`gif_dither` make it as
#' clean as that palette allows. For a lossless result use `format = "apng"`.
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
#' not to animate gets the first frame, held.
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
#' # 30 frames across the 3 keyframes, held on the last one.
#' seg <- rep(1:2, each = 15)
#' frac <- rep(seq(0, 1, length.out = 15), 2)
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
  gif_speed = 1,
  gif_dither = TRUE,
  frac_col = NULL,
  frac_size = NULL,
  frac_alpha = NULL
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

  # Frame duration = 1 / fps seconds, passed as an exact numerator/denominator so
  # the encoders can round to their own time base (APNG: fraction of a second;
  # GIF: centiseconds). `seg` is 1-based here, 0-based across the FFI.
  gif_speed <- as.integer(gif_speed[[1L]])
  if (is.na(gif_speed) || gif_speed < 1L || gif_speed > 30L) {
    cli::cli_abort(
      "{.arg gif_speed} must be an integer in 1:30 (1 = best quality)."
    )
  }

  warns <- render_animation(
    backends,
    seg - 1L,
    frac,
    format,
    path,
    delay_num = 1L,
    delay_den = as.integer(round(fps)),
    gif_speed = gif_speed,
    gif_dither = isTRUE(gif_dither),
    frac_col = frac_col,
    frac_size = frac_size,
    frac_alpha = frac_alpha
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
