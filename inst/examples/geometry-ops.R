# Phase 12 -- geometry operations II: booleans, contours, SVG import.
#
# The thread connecting these three is that each produces *geometry*. A boolean
# result, a contour line and an imported icon are all ordinary paths, so they
# can be measured, filled with a gradient, stroked, hit-tested, simplified,
# exported as `<path>` data, and fed into each other.

library(vellum)

# --- 1. boolean path operations ----------------------------------------------

circ <- function(cx, cy, r = 0.3, n = 72) {
  t <- seq(0, 2 * pi, length.out = n + 1)[-(n + 1)]
  list(x = cx + r * cos(t), y = cy + r * sin(t))
}
a <- circ(0.42, 0.5)
b <- circ(0.58, 0.5)

ops <- vl_scene(8, 2, dpi = 150, bg = "white")
for (i in seq_along(o <- c("union", "intersect", "difference", "xor"))) {
  ops <- ops |>
    push(vl_viewport(x = (i - 0.5) / 4, width = 0.25)) |>
    draw(vl_path_op(a, b, o[i],
                    gp = vl_gpar(fill = "#7FB2E5", col = "#1B4F72", lwd = 1.5))) |>
    draw(polygon_grob(a$x, a$y, gp = vl_gpar(fill = NA, col = "grey75", lty = "dashed"))) |>
    draw(polygon_grob(b$x, b$y, gp = vl_gpar(fill = NA, col = "grey75", lty = "dashed"))) |>
    draw(text_grob(o[i], y = 0.08, gp = vl_gpar(fontsize = 9, col = "grey40"))) |>
    pop()
}
render(ops, "geometry-booleans.png")

# Why geometry rather than a render-time mask? vellum can already clip one shape
# by another, and for simply *showing* an intersection that is often enough. But
# a clip is not a shape: it cannot be measured, filled with its own gradient,
# stroked along its new boundary, or used as the operand of another boolean.
# A result that is a path can do all four.

venn <- vl_scene(4, 3, dpi = 150, bg = "white")
c1 <- circ(0.38, 0.58, 0.24)
c2 <- circ(0.62, 0.58, 0.24)
c3 <- circ(0.50, 0.36, 0.24)
# The centre cell of a three-set Venn: an intersection of intersections.
centre <- vl_path_op(vl_path_op(c1, c2, "intersect"), c3, "intersect")
for (cc in list(c1, c2, c3)) {
  venn <- draw(venn, polygon_grob(cc$x, cc$y,
                                  gp = vl_gpar(fill = "#2C6FA655", col = "#1B4F72")))
}
venn <- venn |>
  draw(S7::set_props(centre, gp = vl_gpar(
    fill = linear_gradient(c("#F1C40F", "#E67E22")), col = "grey20", lwd = 1
  ))) |>
  draw(text_grob("a cell you can fill", x = 0.5, y = 0.08,
                 gp = vl_gpar(fontsize = 9, col = "grey40")))
render(venn, "geometry-venn.png")

# Cutting holes. The result's rings are wound opposite one another, so the hole
# is a hole rather than a second solid island.
plate <- list(x = c(0.1, 0.9, 0.9, 0.1), y = c(0.2, 0.2, 0.8, 0.8))
holes <- plate
for (cx in c(0.3, 0.5, 0.7)) {
  holes <- vl_path_op(holes, circ(cx, 0.5, 0.08), "difference")
}
render(
  vl_scene(4, 2, dpi = 150, bg = "white") |>
    draw(S7::set_props(holes, gp = vl_gpar(fill = "#34495E", col = NA))),
  "geometry-holes.png"
)

# --- 2. contours from a grid -------------------------------------------------
#
# Marching squares over any matrix, chained into polylines. Loose segments would
# look the same under a solid stroke and be wrong for everything else: a dash
# pattern would restart in every grid cell, and nothing downstream could
# simplify, measure or close the line.

set.seed(7)
n <- 160
gx <- seq(-3, 3, length.out = n)
z <- outer(gx, gx, function(a, b) {
  exp(-((a - 1)^2 + (b - 0.6)^2) / 0.8) +
    0.8 * exp(-((a + 1.2)^2 + (b + 0.9)^2) / 1.4) +
    0.4 * exp(-((a - 0.4)^2 + (b + 1.6)^2) / 0.4)
})

levels <- seq(0.1, 0.9, by = 0.1)
cl <- vl_contour(z, levels = levels, xlim = c(-3, 3), ylim = c(-3, 3))
shade <- grDevices::colorRampPalette(c("#DCE7F5", "#1B4F72"))(length(levels))

# One grob per level: `lines_grob()` carries a single stroke colour, so a
# colour ramp across levels means one grob each. They batch fine.
contours <- vl_scene(4, 4, dpi = 150, bg = "white") |>
  push(vl_viewport(xscale = c(-3, 3), yscale = c(-3, 3)))
for (i in seq_along(levels)) {
  part <- cl[cl$level == levels[i], ]
  if (!nrow(part)) next
  contours <- draw(contours, contour_grob(part, gp = vl_gpar(col = shade[i], lwd = 1.4)))
}
render(pop(contours), "geometry-contours.png")

# Closed contours come back marked `closed`, so they can be *filled* as well as
# stroked -- which is what a filled density plot is.
ring <- cl[cl$level == 0.5 & cl$closed, ]
render(
  vl_scene(4, 4, dpi = 150, bg = "white") |>
    push(vl_viewport(xscale = c(-3, 3), yscale = c(-3, 3))) |>
    draw(path_grob(vl_unit(ring$x, "native"), vl_unit(ring$y, "native"), id = ring$id,
                   gp = vl_gpar(fill = "#7FB2E599", col = "#1B4F72"))) |>
    pop(),
  "geometry-contour-fill.png"
)

# Contours over a datashaded base -- the idiom the aggregate-then-shade design
# was built for. The grid is the same fixed-size intermediate either way.
set.seed(11)
N <- 200000
px <- c(rnorm(N / 2, -1, 0.7), rnorm(N / 2, 1.2, 0.5))
py <- c(rnorm(N / 2, 0.5, 0.6), rnorm(N / 2, -0.8, 0.9))
base <- datashade(px, py, width = 480, height = 480,
                  xlim = c(-4, 4), ylim = c(-4, 4))

# Re-aggregate at the same extent to get the counts the contours need.
dens <- outer(seq(-4, 4, length.out = 120), seq(-4, 4, length.out = 120),
              function(a, b) {
                0.5 * exp(-((a + 1)^2 / (2 * 0.7^2) + (b - 0.5)^2 / (2 * 0.6^2))) +
                  0.5 * exp(-((a - 1.2)^2 / (2 * 0.5^2) + (b + 0.8)^2 / (2 * 0.9^2)))
              })
iso <- vl_contour(dens, levels = c(0.1, 0.25, 0.45), xlim = c(-4, 4), ylim = c(-4, 4))

render(
  vl_scene(4, 4, dpi = 150, bg = "white") |>
    push(vl_viewport(xscale = c(-4, 4), yscale = c(-4, 4))) |>
    draw(base) |>
    draw(contour_grob(iso, gp = vl_gpar(col = "#F1C40F", lwd = 1.6))) |>
    pop(),
  "geometry-datashade-contours.png"
)

# --- 3. SVG path data as geometry --------------------------------------------
#
# Icon sets ship one `<path d="...">` per glyph, so `d` is the unit of exchange.
# Importing it as geometry rather than as a bitmap is what makes `shape = <svg>`
# markers crisp at any size.

ICONS <- list(
  star = "M12 2 L15 9 L22 9.3 L16.5 13.8 L18.5 21 L12 17 L5.5 21 L7.5 13.8 L2 9.3 L9 9 Z",
  # Arcs and relative commands, in the packed form minified icon files use.
  drop = "M12 2 C7 9 5 12 5 15 a7 7 0 0 0 14 0 c0-3-2-6-7-13 z",
  ring = paste("M12 2 a10 10 0 1 0 0.001 0 z",
               "M12 7 a5 5 0 1 1-0.001 0 z")
)

icons <- vl_scene(6, 2, dpi = 150, bg = "white")
for (i in seq_along(ICONS)) {
  icons <- icons |>
    draw(svg_grob(ICONS[[i]], x = (i - 0.5) / length(ICONS), y = 0.58,
                  size = vl_unit(16, "mm"),
                  gp = vl_gpar(fill = "#2C6FA6", col = "grey20", lwd = 0.8))) |>
    draw(text_grob(names(ICONS)[i], x = (i - 0.5) / length(ICONS), y = 0.12,
                   gp = vl_gpar(fontsize = 9, col = "grey40")))
}
render(icons, "geometry-icons.png")

# `ring` above is two subpaths, and `svg_grob()` draws with the even-odd rule,
# so the inner circle is a hole -- which is how icon sets express a ring.

# As markers. Because these are paths, they take a gradient fill and stay sharp
# at any size, which is what `mark_image()`'s raster-per-point cannot do.
set.seed(5)
k <- 14
mx <- seq(0.06, 0.94, length.out = k)
my <- 0.5 + 0.28 * sin(seq(0, 3 * pi, length.out = k))
markers <- vl_scene(6, 2, dpi = 150, bg = "white")
for (i in seq_len(k)) {
  markers <- draw(markers, svg_grob(
    ICONS$star, x = mx[i], y = my[i],
    size = vl_unit(4 + 5 * (i / k), "mm"),
    gp = vl_gpar(fill = linear_gradient(c("#F1C40F", "#C0392B")), col = NA)
  ))
}
render(markers, "geometry-svg-markers.png")

# And because the import is geometry, it composes with the booleans above:
# an icon can be cut by a shape.
star <- vl_svg_path(ICONS$star)
half <- vl_path_op(
  list(x = star$x, y = star$y, nper = nrow(star)),
  list(x = c(0, 24, 24, 0), y = c(0, 0, 11.5, 11.5)),
  "difference", rule = "evenodd"
)
sx <- as.numeric(vctrs::field(half@x, "value"))
sy <- as.numeric(vctrs::field(half@y, "value"))
render(
  vl_scene(3, 3, dpi = 150, bg = "white") |>
    push(vl_viewport(xscale = c(0, 24), yscale = c(24, 0))) |>
    draw(path_grob(vl_unit(sx, "native"), vl_unit(sy, "native"),
                   id = rep(seq_along(half@nper), half@nper),
                   gp = vl_gpar(fill = "#E67E22", col = "grey20"))) |>
    pop(),
  "geometry-icon-boolean.png"
)
