# A worked vellum example: a scatter plot of the base `cars` dataset with a
# fitted regression line, axes, tick labels, and titles -- built with the S7
# functional API (vl_scene |> push |> draw ... |> render).
#
# The plot interior (panel, gridlines, points, fitted line) is drawn into a
# CLIPPED child viewport, so the regression line is trimmed to the panel
# automatically. Axes and titles are drawn in the unclipped parent so they can
# sit in the margins. Data uses "native" units; axis furniture uses "npc".
#
# Run with:  Rscript inst/examples/scatter.R  [output.png]

library(vellum)

# --- data -------------------------------------------------------------------
x <- cars$speed
y <- cars$dist
b <- coef(lm(y ~ x))

xticks <- pretty(x)
yticks <- pretty(y)
xr <- range(xticks)
yr <- range(yticks)
nx <- function(v) (v - xr[1]) / (xr[2] - xr[1]) # native -> npc
ny <- function(v) (v - yr[1]) / (yr[2] - yr[1])

m <- list(left = 0.13, right = 0.04, bottom = 0.14, top = 0.10)
vp_w <- 1 - m$left - m$right
vp_h <- 1 - m$bottom - m$top

# --- panel viewport ---------------------------------------------------------
s <- vl_scene(width = 6.5, height = 4.5, dpi = 150, bg = "white") |>
  push(vl_viewport(
    x = m$left + vp_w / 2, y = m$bottom + vp_h / 2,
    width = vp_w, height = vp_h, xscale = xr, yscale = yr
  ))

# --- clipped interior -------------------------------------------------------
s <- s |>
  push(vl_viewport(xscale = xr, yscale = yr, clip = TRUE)) |>
  draw(rect_grob(gp = vl_gpar(fill = "grey97", col = NA)))
for (t in xticks) {
  s <- draw(s, lines_grob(vl_unit(c(nx(t), nx(t)), "npc"), vl_unit(c(0, 1), "npc"),
                          gp = vl_gpar(col = "grey88")))
}
for (t in yticks) {
  s <- draw(s, lines_grob(vl_unit(c(0, 1), "npc"), vl_unit(c(ny(t), ny(t)), "npc"),
                          gp = vl_gpar(col = "grey88")))
}
s <- s |>
  draw(lines_grob(vl_unit(xr, "native"), vl_unit(b[1] + b[2] * xr, "native"),
                  gp = vl_gpar(col = "firebrick", lwd = 2.5))) |>
  draw(circle_grob(vl_unit(x, "native"), vl_unit(y, "native"), r = vl_unit(2, "mm"),
                   gp = vl_gpar(fill = "steelblue", col = "white", lwd = 1))) |>
  pop()

# --- axes (npc, into the margins) -------------------------------------------
tick <- 0.018
s <- s |>
  draw(rect_grob(gp = vl_gpar(fill = NA, col = "grey55"))) |>
  draw(lines_grob(vl_unit(c(0, 1), "npc"), vl_unit(c(0, 0), "npc"), gp = vl_gpar(col = "grey30", lwd = 1.2)))
for (t in xticks) {
  s <- draw(s, lines_grob(vl_unit(c(nx(t), nx(t)), "npc"), vl_unit(c(0, -tick), "npc"),
                          gp = vl_gpar(col = "grey30", lwd = 1.2)))
  s <- draw(s, text_grob(t, x = vl_unit(nx(t), "npc"), y = vl_unit(-tick - 0.02, "npc"),
                         just = c("centre", "top"), gp = vl_gpar(fontsize = 11)))
}
s <- draw(s, lines_grob(vl_unit(c(0, 0), "npc"), vl_unit(c(0, 1), "npc"), gp = vl_gpar(col = "grey30", lwd = 1.2)))
for (t in yticks) {
  s <- draw(s, lines_grob(vl_unit(c(0, -tick), "npc"), vl_unit(c(ny(t), ny(t)), "npc"),
                          gp = vl_gpar(col = "grey30", lwd = 1.2)))
  s <- draw(s, text_grob(t, x = vl_unit(-tick - 0.012, "npc"), y = vl_unit(ny(t), "npc"),
                         just = c("right", "centre"), gp = vl_gpar(fontsize = 11)))
}
s <- pop(s) # back to root

# --- titles -----------------------------------------------------------------
s <- s |>
  draw(text_grob("Stopping distance vs. speed", x = 0.5, y = 1.0,
                 just = c("centre", "top"), gp = vl_gpar(fontface = "bold", fontsize = 16))) |>
  draw(text_grob("Speed (mph)", x = 0.5, y = 0.02,
                 just = c("centre", "bottom"), gp = vl_gpar(fontsize = 13))) |>
  draw(text_grob("Stopping distance (ft)", x = 0.02, y = 0.5, rot = 90,
                 just = c("centre", "top"), gp = vl_gpar(fontsize = 13)))

# --- render -----------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else file.path(tempdir(), "vellum-cars.png")
render(s, out)
message("wrote ", out)
