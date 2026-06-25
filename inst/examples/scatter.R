# A worked rsplot example: a scatter plot of the base `cars` dataset with a
# fitted regression line, axes, tick labels, and titles.
#
# This is built on the M1 API: a single viewport with a native scale, plus the
# rect/lines/circle/text primitives. There is no axis/scale machinery yet
# (that's a higher layer), so the axes are drawn by hand here -- which doubles
# as a demonstration of mixing coordinate systems:
#
#   * the data (points + fit line) is drawn in "native" coordinates;
#   * the panel, axes, ticks, labels and titles are drawn in "npc"
#     coordinates, converting data positions to npc with nx()/ny(). Drawing at
#     npc values slightly outside [0, 1] places the axis furniture in the
#     margins around the panel.
#
# Run with:  Rscript inst/examples/scatter.R  [output.png]
# or source it after devtools::load_all(".").

library(rsplot)

# --- data -------------------------------------------------------------------
x <- cars$speed
y <- cars$dist
fit <- lm(y ~ x)

# Nice axis ranges and tick marks.
xticks <- pretty(x)
yticks <- pretty(y)
xr <- range(xticks)
yr <- range(yticks)

# native -> npc (within the panel viewport)
nx <- function(v) (v - xr[1]) / (xr[2] - xr[1])
ny <- function(v) (v - yr[1]) / (yr[2] - yr[1])

# --- scene + panel viewport -------------------------------------------------
# Margins (npc of the page) leave room for axes and titles.
m <- list(left = 0.13, right = 0.04, bottom = 0.14, top = 0.10)
vp_w <- 1 - m$left - m$right
vp_h <- 1 - m$bottom - m$top

s <- rs_scene(width = 6.5, height = 4.5, dpi = 150, bg = "white")
rs_viewport(
  s,
  x = m$left + vp_w / 2, y = m$bottom + vp_h / 2,
  width = vp_w, height = vp_h,
  xscale = xr, yscale = yr
)

# --- panel ------------------------------------------------------------------
rs_rect(s, x = 0.5, y = 0.5, width = 1, height = 1, fill = "grey97", col = "grey55")

# gridlines (npc, at the tick positions)
for (t in xticks) rs_lines(s, x = c(nx(t), nx(t)), y = c(0, 1), col = "grey88", lwd = 1)
for (t in yticks) rs_lines(s, x = c(0, 1), y = c(ny(t), ny(t)), col = "grey88", lwd = 1)

# --- data -------------------------------------------------------------------
# regression line in native coordinates. M1 has no clipping yet and native
# coordinates extrapolate past the viewport, so we clip the segment to the
# panel by hand: restrict it to where the fit stays within both scales.
b <- coef(fit)
x_at_y <- function(yv) (yv - b[1]) / b[2]
x_lo <- max(xr[1], x_at_y(yr[1]))
x_hi <- min(xr[2], x_at_y(yr[2]))
xline <- c(x_lo, x_hi)
yline <- b[1] + b[2] * xline
rs_lines(s, x = xline, y = yline, units = "native", col = "firebrick", lwd = 2.5)

# points (native); radius is a small fraction of the x range
r <- diff(xr) * 0.012
for (i in seq_along(x)) {
  rs_circle(s, x = x[i], y = y[i], r = r, units = "native",
            fill = "steelblue", col = "white", lwd = 1)
}

# --- axes (npc, drawn into the margins) -------------------------------------
tick <- 0.018 # tick length in npc
# x axis
rs_lines(s, x = c(0, 1), y = c(0, 0), col = "grey30", lwd = 1.2)
for (t in xticks) {
  rs_lines(s, x = c(nx(t), nx(t)), y = c(0, -tick), col = "grey30", lwd = 1.2)
  rs_text(s, t, x = nx(t), y = -tick - 0.02, hjust = 0.5, vjust = 1, fontsize = 11)
}
# y axis
rs_lines(s, x = c(0, 0), y = c(0, 1), col = "grey30", lwd = 1.2)
for (t in yticks) {
  rs_lines(s, x = c(0, -tick), y = c(ny(t), ny(t)), col = "grey30", lwd = 1.2)
  rs_text(s, t, x = -tick - 0.012, y = ny(t), hjust = 1, vjust = 0.5, fontsize = 11)
}

# --- titles -----------------------------------------------------------------
rs_text(s, "Stopping distance vs. speed", x = 0.5, y = 1.06,
        hjust = 0.5, vjust = 0.5, fontface = "bold", fontsize = 16)
rs_text(s, "Speed (mph)", x = 0.5, y = -0.13, hjust = 0.5, vjust = 1, fontsize = 13)
rs_text(s, "Stopping distance (ft)", x = -0.11, y = 0.5,
        hjust = 0.5, vjust = 0.5, rot = 90, fontsize = 13)

# --- render -----------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else file.path(tempdir(), "rsplot-cars.png")
rs_render(s, out)
message("wrote ", out)
