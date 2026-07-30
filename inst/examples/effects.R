# A worked vellum example: group effects and render quality.
#
#   * `vl_viewport(blur =, shadow = vl_shadow(...))` -- blur and drop shadow as
#     GROUP effects: everything in the viewport blurs, or casts one shadow,
#     together. Raster convolves; SVG emits native filter primitives and stays
#     vector; PDF has no filter model and says so.
#   * `vl_gpar(crisp = TRUE)` -- snap axis-parallel strokes to the pixel grid, so
#     gridlines are one solid row rather than two grey ones.
#   * `vl_gpar(antialias = FALSE)` -- hard pixel edges.
#
# Run with:  Rscript inst/examples/effects.R  [output.png|.svg|.pdf]

library(vellum)

out <- commandArgs(trailingOnly = TRUE)
out <- if (length(out)) out[[1]] else "effects.png"

cap <- function(txt, x, y = 0.06) {
  text_grob(txt, x = x, y = y, gp = vl_gpar(fontsize = 9, col = "grey35"))
}
card <- function(scene, x, ...) {
  scene |>
    push(vl_viewport(x = x, y = 0.62, width = 0.2, height = 0.5, ...)) |>
    draw(roundrect_grob(r = 0.12, gp = vl_gpar(fill = "steelblue", col = NA))) |>
    draw(text_grob("Aa", gp = vl_gpar(fontsize = 26, col = "white"))) |>
    pop()
}

scene <- vl_scene(7, 3.4, dpi = 150, bg = "grey97")
scene <- card(scene, 0.14)
scene <- card(scene, 0.38, shadow = vl_shadow(dx = 3, dy = 4, blur = 5))
scene <- card(scene, 0.62, blur = 3)
scene <- card(scene, 0.86, shadow = vl_shadow(dx = 0, dy = 0, blur = 9, col = "#1F77B4"))

scene <- scene |>
  draw(cap("plain", 0.14, 0.30)) |>
  draw(cap("shadow", 0.38, 0.30)) |>
  draw(cap("blur", 0.62, 0.30)) |>
  draw(cap("glow (shadow, no offset)", 0.86, 0.30))

# --- crisp gridlines ---------------------------------------------------------
# The same rules drawn twice: default, then snapped to the pixel grid. At screen
# resolution the difference between one solid row and two grey ones is obvious.
ys <- seq(0.12, 0.88, length.out = 5) + 0.0013 # deliberately off-grid
rules <- function(scene, x0, x1, ...) {
  scene |>
    push(vl_viewport(x = (x0 + x1) / 2, y = 0.16, width = x1 - x0, height = 0.18)) |>
    draw(rect_grob(gp = vl_gpar(fill = "white", col = "grey80"))) |>
    draw(segments_grob(0.02, ys, 0.98, ys,
                       gp = vl_gpar(col = "grey15", lwd = 1, ...))) |>
    pop()
}
scene <- rules(scene, 0.06, 0.46)
scene <- rules(scene, 0.54, 0.94, crisp = TRUE)
scene <- scene |>
  draw(cap("gridlines: default", 0.26)) |>
  draw(cap("gridlines: crisp = TRUE", 0.74))

render(scene, out)
cat(sprintf("wrote %s\n", out))

# Blur and shadow are group effects, so overlapping shapes inside one viewport
# cast a single shadow rather than each shadowing the others.
if (identical(tolower(tools::file_ext(out)), "png")) {
  grp <- vl_scene(3, 1.6, dpi = 150, bg = "grey97") |>
    push(vl_viewport(width = 0.7, height = 0.7, shadow = vl_shadow(dx = 3, dy = 3, blur = 4))) |>
    draw(circle_grob(x = 0.35, r = 0.28, gp = vl_gpar(fill = "tomato", col = NA))) |>
    draw(circle_grob(x = 0.65, r = 0.28, gp = vl_gpar(fill = "seagreen", col = NA))) |>
    pop()
  f2 <- sub("\\.png$", "-group.png", out)
  render(grp, f2)
  cat(sprintf("wrote %s  (two circles, one shared shadow)\n", f2))
}
