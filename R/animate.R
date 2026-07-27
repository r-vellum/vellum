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
#'   as `seg`.
#' @param path Output path: an image file for `"gif"`/`"apng"`, or a directory
#'   (created if needed) for `"frames"`.
#' @param format `"gif"` (looping animated GIF), `"apng"` (animated PNG), or
#'   `"frames"` (one `frameNNNNN.png` per frame into `path`).
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
vl_render_animation <- function(keyframes, seg, frac,
                                path, format = c("gif", "apng", "frames"),
                                fps = 25, gif_speed = 1, gif_dither = TRUE) {
  format <- match.arg(format)
  if (!is.list(keyframes) || length(keyframes) < 2L) {
    cli::cli_abort("{.arg keyframes} must be a list of at least 2 scenes.")
  }
  seg <- vctrs::vec_cast(seg, integer())
  frac <- vctrs::vec_cast(frac, double())
  if (length(seg) != length(frac)) {
    cli::cli_abort("{.arg seg} and {.arg frac} must have the same length.")
  }
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

  backends <- lapply(keyframes, function(s) .scene_to_backend(as_vellum_scene(s)))

  # Frame duration = 1 / fps seconds, passed as an exact numerator/denominator so
  # the encoders can round to their own time base (APNG: fraction of a second;
  # GIF: centiseconds). `seg` is 1-based here, 0-based across the FFI.
  gif_speed <- as.integer(gif_speed[[1L]])
  if (is.na(gif_speed) || gif_speed < 1L || gif_speed > 30L) {
    cli::cli_abort("{.arg gif_speed} must be an integer in 1:30 (1 = best quality).")
  }

  warns <- render_animation(
    backends, seg - 1L, frac, format, path,
    delay_num = 1L, delay_den = as.integer(round(fps)),
    gif_speed = gif_speed, gif_dither = isTRUE(gif_dither)
  )
  .emit_degrade_warnings(warns)
  invisible(path)
}
