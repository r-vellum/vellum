# A worked rsplot example: 2x2 small multiples via a layout + nested viewports.
#
# Demonstrates M2: a row/column layout on the root viewport, one clipped child
# viewport per cell (each with its own native scale), gpar inheritance for a
# shared panel style, and a per-panel title drawn in the parent cell viewport.
#
# Run with:  Rscript inst/examples/panels.R  [output.png]

library(rsplot)

# four little series to plot
xs <- seq(0, 2 * pi, length.out = 80)
series <- list(
  list(title = "sine",        y = sin(xs),            col = "steelblue"),
  list(title = "cosine",      y = cos(xs),            col = "firebrick"),
  list(title = "damped",      y = sin(3 * xs) * exp(-xs / 4), col = "darkgreen"),
  list(title = "sawtooth",    y = 2 * (xs / (2 * pi) - floor(xs / (2 * pi) + 0.5)), col = "purple")
)

s <- rs_scene(width = 7, height = 5, dpi = 150, bg = "white")

# a shared light style inherited by every panel
rs_push_viewport(s, gp = rs_gpar(lwd = 2))
rs_layout(s, widths = c(1, 1), heights = c(1, 1))

cells <- list(c(1, 1), c(1, 2), c(2, 1), c(2, 2))
for (i in seq_along(series)) {
  rc <- cells[[i]]
  d <- series[[i]]
  yr <- range(d$y)

  # cell viewport (unclipped) with a small margin for the title
  rs_push_viewport(s, row = rc[1], col = rc[2])
  rs_push_viewport(s, x = 0.5, y = 0.45, width = 0.86, height = 0.74,
                   xscale = range(xs), yscale = yr, clip = TRUE)
  rs_rect(s, fill = "grey97", col = NA)
  rs_lines(s, x = c(min(xs), max(xs)), y = c(0, 0), units = "native", col = "grey80", lwd = 1)
  rs_lines(s, x = xs, y = d$y, units = "native", col = d$col) # lwd inherited (2)
  rs_pop_viewport(s)

  rs_rect(s, x = 0.5, y = 0.45, width = 0.86, height = 0.74, fill = NA, col = "grey60", lwd = 1)
  rs_text(s, d$title, x = 0.5, y = 0.9, hjust = 0.5, vjust = 1, fontface = "bold", fontsize = 13)
  rs_pop_viewport(s)
}
rs_pop_viewport(s)

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else file.path(tempdir(), "rsplot-panels.png")
rs_render(s, out)
message("wrote ", out)
