# Phase 11 -- placement as an engine service.
#
# Repulsion, empty-region finding, hulls and buffers are all the same kind of
# thing: geometry over boxes and points that have already been resolved. None of
# it knows anything about data, which is exactly why it belongs below a plotting
# layer rather than inside one.

library(vellum)

set.seed(3)
n <- 26
x <- runif(n) * 0.9 + 0.05
y <- runif(n) * 0.85 + 0.08
lab <- paste0("station ", seq_len(n))

scatter <- function() {
  vl_scene(6, 3.4, dpi = 150, bg = "white") |>
    draw(points_grob(x, y, size = vl_unit(2, "mm"),
                     gp = vl_gpar(fill = "#C0392B", col = NA), name = "pts")) |>
    draw(text_grob(lab, x = x, y = y, gp = vl_gpar(fontsize = 8), name = "lab"))
}

# --- 1. repulsion ------------------------------------------------------------

render(scatter(), "labels-before.png")
render(vl_repel(scatter(), padding = 0.6), "labels-after.png")

# `vl_place()` is the same solve without applying it: one row per label, with
# the shift in millimetres and whether it ended up clear. Use it when you want
# to draw leader lines, or to decide that a label should be dropped instead of
# moved -- that call belongs to whoever knows what the labels mean, not here.
sol <- vl_place(scatter(), padding = 0.6)
cat(sum(!sol$resolved), "of", nrow(sol), "labels could not be placed cleanly\n")

# Leader lines are then a few lines of arithmetic, because the shift is a plain
# millimetre offset on top of the original anchor.
leaders <- scatter()
moved <- which(abs(sol$dx) + abs(sol$dy) > 1)
leaders <- leaders |>
  draw(segments_grob(
    x0 = vl_unit(x[moved], "npc"), y0 = vl_unit(y[moved], "npc"),
    x1 = vl_unit(x[moved], "npc") + vl_unit(sol$dx[moved], "mm"),
    y1 = vl_unit(y[moved], "npc") + vl_unit(sol$dy[moved], "mm"),
    gp = vl_gpar(col = "grey70", lwd = 0.6)
  ))
render(vl_repel(leaders, labels = "lab", padding = 0.6), "labels-leaders.png")

# It is viewport-agnostic. The solve happens in device pixels and the answer is
# applied as an absolute offset on top of whatever coordinate the label already
# had, so a label anchored in `native` inside a scaled panel moves by the same
# mechanism as one in `npc` on the page -- and every panel is solved at once.
set.seed(11)
two_panel <- vl_scene(7, 3, dpi = 150, bg = "white")
for (i in 1:2) {
  px <- runif(16) * 100
  py <- runif(16) * 0.01 # a wildly different scale on the other axis
  two_panel <- two_panel |>
    push(vl_viewport(name = paste0("p", i), x = c(0.25, 0.75)[i], width = 0.46,
                     xscale = c(0, 100), yscale = c(0, 0.01))) |>
    draw(rect_grob(gp = vl_gpar(fill = "grey97", col = "grey85"))) |>
    draw(points_grob(vl_unit(px, "native"), vl_unit(py, "native"),
                     size = vl_unit(1.6, "mm"),
                     gp = vl_gpar(fill = "#2C6FA6", col = NA))) |>
    draw(text_grob(paste0(c("a", "b")[i], seq_len(16)),
                   x = vl_unit(px, "native"), y = vl_unit(py, "native"),
                   gp = vl_gpar(fontsize = 7), name = paste0("lab", i))) |>
    pop()
}
render(vl_repel(two_panel, padding = 0.5), "labels-panels.png")

# --- 2. where is there room? -------------------------------------------------
#
# The same resolved geometry answers the other placement question: not "how do I
# move these apart" but "where can this one thing go". That is what automatic
# legend and annotation placement needs.

set.seed(9)
cloud <- vl_scene(5, 3.2, dpi = 150, bg = "white") |>
  draw(points_grob(rbeta(220, 2, 5), runif(220), size = vl_unit(1.6, "mm"),
                   gp = vl_gpar(fill = "#7FB2E5", col = NA), name = "pts"))

gap <- vl_empty_region(cloud, grid = 260)
# The region also comes back in millimetres, which is exactly the absolute
# measure Phase 10's wrapping wants -- so the annotation can be fitted to the
# gap that was just found, rather than to a width guessed in advance.
gap_mm <- vl_empty_region(cloud, grid = 260, unit = "mm")
legend <- cloud |>
  draw(rect_grob(x = mean(gap[c("x0", "x1")]), y = mean(gap[c("y0", "y1")]),
                 width = gap[["x1"]] - gap[["x0"]],
                 height = gap[["y1"]] - gap[["y0"]],
                 gp = vl_gpar(fill = "#FFFFFFCC", col = "grey60"))) |>
  draw(text_grob("placed in the emptiest rectangle, and fitted to it",
                 x = mean(gap[c("x0", "x1")]), y = mean(gap[c("y0", "y1")]),
                 align = "centre",
                 width = vl_unit((gap_mm[["x1"]] - gap_mm[["x0"]]) - 4, "mm"),
                 height = vl_unit((gap_mm[["y1"]] - gap_mm[["y0"]]) - 4, "mm"),
                 fit = TRUE, gp = vl_gpar(fontsize = 11, col = "grey30")))
render(legend, "labels-empty-region.png")

# Occupancy is rasterised onto a grid, so the answer is exact on that grid and
# conservative off it: boxes round outward, and the region never claims space
# that is in fact occupied.

# --- 3. hulls and buffers ----------------------------------------------------
#
# Outlining a group, and building the exclusion zone around it.

set.seed(21)
grp <- data.frame(
  x = c(rnorm(40, 0.32, 0.07), rnorm(40, 0.7, 0.06)),
  y = c(rnorm(40, 0.6, 0.09), rnorm(40, 0.38, 0.07)),
  g = rep(1:2, each = 40)
)

hulls <- vl_scene(5, 3.2, dpi = 150, bg = "white")
for (g in 1:2) {
  p <- grp[grp$g == g, ]
  h <- vl_hull(p$x, p$y, concavity = 4)
  b <- vl_buffer(h$x, h$y, 0.03)
  hulls <- hulls |>
    draw(polygon_grob(b$x, b$y, gp = vl_gpar(fill = c("#E8F0F9", "#FBEDE7")[g], col = NA))) |>
    draw(polygon_grob(h$x, h$y,
                      gp = vl_gpar(fill = NA, col = c("#2C6FA6", "#C0392B")[g],
                                   lwd = 1.2, lty = "dashed"))) |>
    draw(points_grob(p$x, p$y, size = vl_unit(1.5, "mm"),
                     gp = vl_gpar(fill = c("#2C6FA6", "#C0392B")[g], col = NA)))
}
render(hulls, "labels-hulls.png")

# `concavity` runs the other way from what the name suggests: LARGER is more
# convex. `Inf` is the convex hull, 8 follows the points loosely, 4 is a good
# tight outline, and below about 3 the boundary starts threading between
# interior points and crossing itself -- which is inherent to the method rather
# than a defect. Buffering a concave ring can self-cross for the same reason;
# repairing that is a boolean union, which is a Phase 12 operation.
