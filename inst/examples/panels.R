# A worked vellum example: 2x2 small multiples via a layout + nested viewports,
# built with the S7 functional API.
#
# A row/column grid_layout on the root viewport, one clipped child viewport per
# cell (each with its own native scale), gpar inheritance for a shared line
# width, and a per-panel title.
#
# Run with:  Rscript inst/examples/panels.R  [output.png]

library(vellum)

xs <- seq(0, 2 * pi, length.out = 80)
series <- list(
  list(title = "sine", y = sin(xs), col = "steelblue"),
  list(title = "cosine", y = cos(xs), col = "firebrick"),
  list(title = "damped", y = sin(3 * xs) * exp(-xs / 4), col = "darkgreen"),
  list(title = "sawtooth", y = 2 * (xs / (2 * pi) - floor(xs / (2 * pi) + 0.5)), col = "purple")
)
cells <- list(c(1, 1), c(1, 2), c(2, 1), c(2, 2))

# shared style (lwd inherited by every panel line) + a 2x2 layout
s <- vl_scene(width = 7, height = 5, dpi = 150, bg = "white") |>
  push(vl_viewport(
    gp = vl_gpar(lwd = 2),
    layout = grid_layout(widths = vl_unit(c(1, 1), "null"), heights = vl_unit(c(1, 1), "null"))
  ))

for (i in seq_along(series)) {
  rc <- cells[[i]]
  d <- series[[i]]
  yr <- range(d$y)
  s <- s |>
    push(vl_viewport(row = rc[1], col = rc[2])) |> # cell
    push(vl_viewport(x = 0.5, y = 0.45, width = 0.86, height = 0.74,
                  xscale = range(xs), yscale = yr, clip = TRUE)) |>
    draw(rect_grob(gp = vl_gpar(fill = "grey97", col = NA))) |>
    draw(lines_grob(vl_unit(range(xs), "native"), vl_unit(c(0, 0), "native"),
                    gp = vl_gpar(col = "grey80", lwd = 1))) |>
    draw(lines_grob(vl_unit(xs, "native"), vl_unit(d$y, "native"), gp = vl_gpar(col = d$col))) |>
    pop() |>
    draw(rect_grob(x = 0.5, y = 0.45, width = 0.86, height = 0.74,
                   gp = vl_gpar(fill = NA, col = "grey60", lwd = 1))) |>
    draw(text_grob(d$title, x = 0.5, y = 0.9, just = c("centre", "top"),
                   gp = vl_gpar(fontface = "bold", fontsize = 13))) |>
    pop()
}

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else file.path(tempdir(), "vellum-panels.png")
render(s, out)
message("wrote ", out)
