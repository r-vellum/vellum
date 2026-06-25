# A worked rsplot example: a scatter plot of the base `cars` dataset with a
# fitted regression line, axes, tick labels, and titles.
#
# Updated for M2 (viewports + clipping). The plot interior (panel background,
# gridlines, points, fitted line) is drawn into a CLIPPED child viewport, so the
# regression line is trimmed to the panel automatically — no manual clipping.
# Axes and titles are drawn in the unclipped parent so they can sit in the
# margins. The data uses "native" coordinates; axis furniture uses "npc"
# (there is no axis/scale machinery yet — that is a higher layer).
#
# Run with:  Rscript inst/examples/scatter.R  [output.png]

library(rsplot)

# --- data -------------------------------------------------------------------
x <- cars$speed
y <- cars$dist
fit <- lm(y ~ x)
b <- coef(fit)

xticks <- pretty(x)
yticks <- pretty(y)
xr <- range(xticks)
yr <- range(yticks)

nx <- function(v) (v - xr[1]) / (xr[2] - xr[1]) # native -> npc
ny <- function(v) (v - yr[1]) / (yr[2] - yr[1])

# --- scene + panel viewport -------------------------------------------------
m <- list(left = 0.13, right = 0.04, bottom = 0.14, top = 0.10)
vp_w <- 1 - m$left - m$right
vp_h <- 1 - m$bottom - m$top

s <- rs_scene(width = 6.5, height = 4.5, dpi = 150, bg = "white")
rs_push_viewport(
  s,
  x = m$left + vp_w / 2, y = m$bottom + vp_h / 2,
  width = vp_w, height = vp_h,
  xscale = xr, yscale = yr
)

# --- clipped interior -------------------------------------------------------
rs_push_viewport(s, clip = TRUE, xscale = xr, yscale = yr)
rs_rect(s, fill = "grey97", col = NA) # panel background
for (t in xticks) rs_lines(s, x = c(nx(t), nx(t)), y = c(0, 1), col = "grey88")
for (t in yticks) rs_lines(s, x = c(0, 1), y = c(ny(t), ny(t)), col = "grey88")

# regression line over the full x range; the clip trims it to the panel
rs_lines(s, x = xr, y = b[1] + b[2] * xr, units = "native", col = "firebrick", lwd = 2.5)

# points
r <- diff(xr) * 0.012
for (i in seq_along(x)) {
  rs_circle(s, x = x[i], y = y[i], r = r, units = "native",
            fill = "steelblue", col = "white", lwd = 1)
}
rs_pop_viewport(s) # back to the (unclipped) panel viewport

# --- axes (npc, into the margins) -------------------------------------------
rs_rect(s, fill = NA, col = "grey55") # crisp panel border (unclipped)
tick <- 0.018
rs_lines(s, x = c(0, 1), y = c(0, 0), col = "grey30", lwd = 1.2)
for (t in xticks) {
  rs_lines(s, x = c(nx(t), nx(t)), y = c(0, -tick), col = "grey30", lwd = 1.2)
  rs_text(s, t, x = nx(t), y = -tick - 0.02, hjust = 0.5, vjust = 1, fontsize = 11)
}
rs_lines(s, x = c(0, 0), y = c(0, 1), col = "grey30", lwd = 1.2)
for (t in yticks) {
  rs_lines(s, x = c(0, -tick), y = c(ny(t), ny(t)), col = "grey30", lwd = 1.2)
  rs_text(s, t, x = -tick - 0.012, y = ny(t), hjust = 1, vjust = 0.5, fontsize = 11)
}
rs_pop_viewport(s) # back to root

# --- titles -----------------------------------------------------------------
rs_text(s, "Stopping distance vs. speed", x = 0.5, y = 1.06 - 0.06,
        hjust = 0.5, vjust = 1, fontface = "bold", fontsize = 16)
rs_text(s, "Speed (mph)", x = 0.5, y = 0.02, hjust = 0.5, vjust = 0, fontsize = 13)
rs_text(s, "Stopping distance (ft)", x = 0.02, y = 0.5,
        hjust = 0.5, vjust = 1, rot = 90, fontsize = 13)

# --- render -----------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else file.path(tempdir(), "rsplot-cars.png")
rs_render(s, out)
message("wrote ", out)
