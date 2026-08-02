# Phase 15 -- making marks addressable, and hit-testing them honestly.
#
# Two things an interactive host needs from the engine: a way to say "this mark
# is that datum", and a way to ask "what is near this point" that is true of the
# mark's actual shape rather than of the box around it.

library(vellum)

# --- 1. every mark family can now carry a key --------------------------------
#
# A `key` is what makes a mark addressable: it becomes `data-key` in the SVG and
# a row in `scene_model()`, which is how a host maps a hover or a click back to
# the datum. Until now only points, rects, circles, hexagons, sectors and
# segments could carry one -- so a line, an area, a choropleth region or a data
# label could never be hovered, tooltipped, brushed or cross-filtered at all.

set.seed(2)
months <- seq_len(12)
value <- cumsum(rnorm(12, 2, 5)) + 20

plot <- vl_scene(6, 3.6, dpi = 150, bg = "white") |>
  push(vl_viewport(
    name = "panel",
    y = 0.46,
    width = 0.86,
    height = 0.7,
    xscale = c(1, 12),
    yscale = range(value) + c(-4, 4)
  )) |>
  draw(rect_grob(
    gp = vl_gpar(fill = "grey97", col = "grey85"),
    role = "presentation"
  )) |>
  # A whole series as one addressable thing -- hover the line, highlight the
  # series. This is the case that was impossible before.
  draw(lines_grob(
    vl_unit(months, "native"),
    vl_unit(value, "native"),
    gp = vl_gpar(col = "#2C6FA6", lwd = 2.5),
    key = "series-A",
    meta = list(list(series = "A", n = 12))
  )) |>
  # The points, keyed per datum, as they always could be.
  draw(points_grob(
    vl_unit(months, "native"),
    vl_unit(value, "native"),
    size = vl_unit(2.2, "mm"),
    gp = vl_gpar(fill = "#2C6FA6", col = "white", lwd = 1),
    key = paste0("pt-", months),
    meta = lapply(months, function(m) list(month = m, value = value[m]))
  )) |>
  # Data labels, keyed per label -- a vectorised text grob compiles to one node
  # per label, so each gets its own key.
  draw(text_grob(
    sprintf("%.0f", value),
    x = vl_unit(months, "native"),
    y = vl_unit(value + 3, "native"),
    gp = vl_gpar(fontsize = 7, col = "grey35"),
    key = paste0("lbl-", months)
  )) |>
  pop()

render(plot, "interactivity-keyed.png")
render(plot, "interactivity-keyed.svg")

el <- scene_model(plot)$elements
cat("addressable elements:", nrow(el), "\n")
print(table(el$mark))

# Note the asymmetry, which is deliberate. Batched marks (points, rects,
# segments, ...) always report a row so a plain scene still yields a geometry
# table -- the unkeyed panel background is in there with `key = NA`. The
# newly-keyable families (lines, polygons, paths, text) report a row ONLY when
# keyed, because a plot is full of unkeyed gridlines and axis labels that would
# otherwise become thousands of phantom elements.
cat("rows with no key:", sum(is.na(el$key)), "of", nrow(el), "\n")

# --- 2. hit-testing that respects the geometry -------------------------------
#
# `scene_model()` gives bounding boxes. For a round or upright mark that is
# fine. For anything diagonal or thin it is badly misleading: a line from one
# corner of a panel to the other has a bounding box covering the WHOLE panel.

demo <- vl_scene(4, 3, dpi = 150, bg = "white") |>
  draw(segments_grob(
    0.12,
    0.12,
    0.88,
    0.88,
    gp = vl_gpar(col = "#C0392B", lwd = 2),
    key = "diagonal"
  )) |>
  draw(points_grob(
    0.82,
    0.18,
    size = vl_unit(3, "mm"),
    gp = vl_gpar(fill = "#2C6FA6", col = NA),
    key = "corner"
  ))

probe <- c(0.82, 0.18) # right on the blue point

box <- scene_model(demo)$elements
d <- box[box$key == "diagonal", ]
px <- probe[1] * 600
py <- (1 - probe[2]) * 450
cat(sprintf(
  "\nprobe is inside the diagonal's bbox: %s\n",
  px > d$x0 && px < d$x1 && py > d$y0 && py < d$y1
))
cat("...but by true geometry:\n")
print(vl_nearest(demo, probe[1], probe[2], n = 2))

# The point wins, as it should. A box-based nearest would have reported the
# diagonal -- which is exactly why a host with only boxes has to *exclude* such
# marks from hover rather than rank them wrongly.

# A filled shape contains its interior, so clicking the middle of a region hits
# the region rather than its nearest edge.
region <- vl_scene(3, 3, dpi = 150, bg = "white") |>
  draw(polygon_grob(
    c(.2, .8, .5),
    c(.2, .2, .8),
    gp = vl_gpar(fill = "#F1C40F", col = "grey30"),
    key = "tri"
  ))
cat("\ninside the triangle:\n")
print(vl_nearest(region, 0.5, 0.4))

# --- 3. geometry for a client that cannot ask --------------------------------
#
# A browser cannot call back into R on every mouse move. `element_geometry()`
# hands over the true geometry once, so the client computes distances locally at
# whatever rate it likes -- an R-tree over boxes to shortlist candidates, then an
# exact test against these vertices to rank them.

g <- element_geometry(demo)
print(g)

# Two endpoints for the segment, one centre for the point -- not four box
# corners. That is the difference that lets a client hit-test a diagonal.

# The same, for the keyed line in the first plot: every vertex of the series.
gs <- element_geometry(plot)
cat("\nvertices per element:\n")
print(table(gs$key[gs$kind == "line"]))
