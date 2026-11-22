# A worked vellum example: a keyframe animation. We build a handful of KEYFRAME
# scenes (fixed at author time), then let `vl_render_animation()` interpolate the
# in-between frames and encode them -- all in one parallel, streaming pass in the
# Rust backend. Geometry lerps, colours lerp perceptually in Oklab, and the frames
# are written to a looping GIF (or APNG / a PNG frame directory).
#
# This is non-reactive keyframe animation: nothing retrains between frames, the
# states are decided up front.
#
# Run with:  Rscript inst/examples/animation.R  [output.gif]

library(vellum)

# --- keyframes: a bubble that moves, grows, and shifts hue -------------------
keyframe <- function(x, r_mm, fill) {
  vl_scene(width = 4, height = 3, dpi = 150, bg = "white") |>
    push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1))) |>
    draw(rect_grob(gp = vl_gpar(fill = "grey97", col = NA))) |>
    draw(circle_grob(
      x = vl_unit(x, "native"),
      y = vl_unit(0.5, "native"),
      r = vl_unit(r_mm, "mm"),
      gp = vl_gpar(fill = fill, col = "white", lwd = 1.5)
    )) |>
    pop()
}

keys <- list(
  keyframe(0.15, 5, "#2c7fb8"),
  keyframe(0.50, 16, "#e6550d"),
  keyframe(0.85, 7, "#31a354")
)

# --- schedule: ease each segment, then hold on the last keyframe ------------
ease_in_out <- function(t) ifelse(t < 0.5, 2 * t * t, 1 - (-2 * t + 2)^2 / 2)

# Each move runs from its left keyframe (fraction 0) up to, but not including,
# its right one: the next move's first frame IS that keyframe, so repeating it
# at fraction 1 would show the same picture twice (a visible stutter).
per_seg <- 20
moves <- length(keys) - 1L
seg <- rep(seq_len(moves), each = per_seg)
frac <- rep(ease_in_out((seq_len(per_seg) - 1) / per_seg), moves)

# The hold: the last move at fraction 1 is the last keyframe, shown for `hold`
# frames. The GIF then loops, cutting back to the first keyframe.
hold <- 15
seg <- c(seg, rep(moves, hold))
frac <- c(frac, rep(1, hold))

# --- render + encode ---------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) {
  args[[1]]
} else {
  file.path(tempdir(), "vellum-bubble.gif")
}
vl_render_animation(keys, seg, frac, out, format = "gif", fps = 25)
message("wrote ", out)
