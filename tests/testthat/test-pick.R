# Phase 15: element keys on every mark family, and true-geometry hit-testing.

# --- keys on the mark families that could not carry them ----------------------

test_that("lines, polygons, paths, roundrects and text can carry a key", {
  s <- vl_scene(5, 3, dpi = 96, bg = "white") |>
    draw(lines_grob(c(.1, .9), c(.2, .8), name = "ln", key = "line-1")) |>
    draw(polygon_grob(c(.1, .3, .2), c(.6, .6, .9), name = "pg", key = "poly-1")) |>
    draw(path_grob(c(.5, .7, .6), c(.1, .1, .4), name = "pt", key = "path-1")) |>
    draw(roundrect_grob(x = .8, y = .5, width = .15, height = .2, name = "rr",
                        key = "rr-1")) |>
    draw(text_grob("hello", x = .5, y = .95, name = "tx", key = "text-1"))
  el <- scene_model(s)$elements
  expect_setequal(el$key, c("line-1", "poly-1", "path-1", "rr-1", "text-1"))
  expect_setequal(el$mark, c("line", "polygon", "path", "roundrect", "text"))
  # Every one has a real box, not a degenerate one.
  expect_true(all(el$x1 > el$x0))
  expect_true(all(el$y1 > el$y0))
})

test_that("keyed marks reach the SVG as data-key", {
  s <- vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(lines_grob(c(.1, .9), c(.5, .5), key = "ln")) |>
    draw(text_grob("hi", x = .5, y = .8, key = "tx"))
  svg <- scene_svg(s)
  expect_true(grepl('data-key="ln"', svg, fixed = TRUE))
  expect_true(grepl('data-key="tx"', svg, fixed = TRUE))
})

test_that("a vectorised text grob keys each label separately", {
  s <- vl_scene(5, 2, dpi = 96, bg = "white") |>
    draw(text_grob(c("a", "b", "c"), x = c(.2, .5, .8), y = .5, name = "lab",
                   key = c("t1", "t2", "t3"),
                   meta = list(list(v = 1), list(v = 2), list(v = 3))))
  el <- scene_model(s)$elements
  expect_equal(el$key, c("t1", "t2", "t3"))
  expect_equal(unlist(lapply(el$meta, `[[`, "v")), 1:3)
  # Each label's box is its own, and they run left to right.
  expect_true(all(diff(el$x0) > 0))
})

test_that("rich (markdown) labels can be keyed too", {
  s <- vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(text_grob(list(md("**a**"), md("*b*")), x = c(.3, .7),
                   key = c("m1", "m2"), name = "rich"))
  expect_equal(scene_model(s)$elements$key, c("m1", "m2"))
})

test_that("unkeyed marks stay out of the element table", {
  # A plot is full of unkeyed axis text and gridlines; they must not become
  # thousands of phantom elements.
  s <- vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(text_grob("axis label")) |>
    draw(lines_grob(c(.1, .9), c(.5, .5))) |>
    draw(polygon_grob(c(.1, .3, .2), c(.6, .6, .9)))
  expect_equal(nrow(scene_model(s)$elements), 0L)
})

test_that("partially keyed text keeps only the keyed labels", {
  s <- vl_scene(5, 2, dpi = 96, bg = "white") |>
    draw(text_grob(c("a", "b", "c"), x = c(.2, .5, .8), y = .5,
                   key = c("t1", NA, "t3")))
  expect_equal(scene_model(s)$elements$key, c("t1", "t3"))
})

test_that("adding a key changes nothing that is drawn", {
  # Keys are metadata. The raster must be identical with and without them.
  mk <- function(...) {
    vl_scene(4, 2, dpi = 96, bg = "white") |>
      draw(lines_grob(c(.1, .9), c(.2, .8), ...)) |>
      draw(text_grob("hi", x = .5, y = .9, ...))
  }
  expect_identical(scene_raster(mk()), scene_raster(mk(key = "k")))
  expect_identical(scene_png(mk()), scene_png(mk(key = "k")))
})

# --- true-geometry hit-testing ------------------------------------------------

diag_scene <- function() {
  vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(segments_grob(0.1, 0.1, 0.9, 0.9, key = "diagonal")) |>
    draw(points_grob(0.8, 0.2, key = "corner")) |>
    draw(polygon_grob(c(.1, .4, .25), c(.6, .6, .9), key = "tri"))
}

test_that("a diagonal is ranked by its geometry, not its bounding box", {
  # The whole point of the feature. The probe sits INSIDE the diagonal's bbox
  # but far from the diagonal itself, so a bbox-based nearest would return it.
  s <- diag_scene()
  bb <- scene_model(s)$elements
  d <- bb[bb$key == "diagonal", ]
  probe <- c(0.8 * 384, (1 - 0.2) * 288) # device px
  expect_true(probe[1] > d$x0 && probe[1] < d$x1) # inside the box...
  expect_true(probe[2] > d$y0 && probe[2] < d$y1)

  near <- vl_nearest(s, 0.8, 0.2, n = 3)
  expect_equal(near$key[1], "corner") # ...but the point wins
  expect_gt(near$dist[near$key == "diagonal"], 100)
})

test_that("a point on a segment is at distance zero", {
  near <- vl_nearest(diag_scene(), 0.5, 0.5, n = 1)
  expect_equal(near$key, "diagonal")
  expect_lt(near$dist, 1e-6)
})

test_that("a filled polygon contains its interior", {
  # Clicking the middle of a region should hit the region, not its nearest edge.
  near <- vl_nearest(diag_scene(), 0.25, 0.68, n = 1)
  expect_equal(near$key, "tri")
  expect_equal(near$dist, 0)
})

test_that("round marks measure to the disc, not the bounding square", {
  s <- vl_scene(3, 3, dpi = 96, bg = "white") |>
    draw(points_grob(0.5, 0.5, size = vl_unit(10, "mm"), key = "big"))
  expect_equal(vl_nearest(s, 0.5, 0.5)$dist, 0) # centre
  # A point outside the disc is at (distance to centre - radius).
  far <- vl_nearest(s, 0.9, 0.5)
  expect_gt(far$dist, 0)
})

test_that("max_dist and n bound the result", {
  s <- diag_scene()
  expect_equal(nrow(vl_nearest(s, 0.5, 0.5, n = 2)), 2L)
  expect_equal(nrow(vl_nearest(s, 0.5, 0.5, max_dist = 1)), 1L)
  # A probe on empty canvas, far from everything, with a tight cutoff.
  expect_equal(nrow(vl_nearest(s, 0.95, 0.95, max_dist = 1)), 0L)
})

test_that("px and npc probes agree", {
  s <- diag_scene()
  a <- vl_nearest(s, 0.5, 0.5, units = "npc", n = 3)
  b <- vl_nearest(s, 0.5 * 384, (1 - 0.5) * 288, units = "px", n = 3)
  expect_equal(a, b)
})

test_that("only keyed elements are considered", {
  s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(points_grob(0.5, 0.5)) |>
    draw(points_grob(0.9, 0.9, key = "keyed"))
  # The unkeyed point is nearer, but it is not addressable, so reporting it
  # would be no use to a host.
  expect_equal(vl_nearest(s, 0.5, 0.5)$key, "keyed")
})

test_that("an empty scene gives an empty answer", {
  s <- vl_scene(2, 1, dpi = 96, bg = "white")
  expect_equal(nrow(vl_nearest(s, 0.5, 0.5)), 0L)
  expect_equal(nrow(element_geometry(s)), 0L)
})

# --- element_geometry ---------------------------------------------------------

test_that("element_geometry returns the true vertices", {
  g <- element_geometry(diag_scene())
  expect_setequal(unique(g$key), c("diagonal", "corner", "tri"))
  # A segment is two endpoints; a triangle is three vertices; a point is one.
  n <- table(g$key)
  expect_equal(as.integer(n[["diagonal"]]), 2L)
  expect_equal(as.integer(n[["tri"]]), 3L)
  expect_equal(as.integer(n[["corner"]]), 1L)
  expect_equal(g$vertex[g$key == "tri"], 1:3)
})

test_that("the geometry is the segment's endpoints, not its box corners", {
  # Both are two points, so this checks the values: the endpoints of a
  # bottom-left-to-top-right diagonal in device space (y down) go from low-x
  # high-y to high-x low-y. The box corners would both be at box extremes.
  g <- element_geometry(diag_scene())
  d <- g[g$key == "diagonal", ]
  expect_equal(d$x, c(0.1, 0.9) * 384, tolerance = 1e-6)
  expect_equal(d$y, c(1 - 0.1, 1 - 0.9) * 288, tolerance = 1e-6)
})

test_that("element_geometry agrees with vl_nearest", {
  # Distance computed in R from the exported geometry must match the engine's.
  s <- diag_scene()
  g <- element_geometry(s)
  d <- g[g$key == "diagonal", ]
  px <- 0.8 * 384
  py <- (1 - 0.2) * 288
  # Point-to-segment distance, done the way a client would.
  ab <- c(diff(d$x), diff(d$y))
  t <- max(0, min(1, sum((c(px, py) - c(d$x[1], d$y[1])) * ab) / sum(ab^2)))
  manual <- sqrt(sum((c(px, py) - (c(d$x[1], d$y[1]) + t * ab))^2))
  engine <- vl_nearest(s, 0.8, 0.2, n = 3)
  expect_equal(engine$dist[engine$key == "diagonal"], manual, tolerance = 1e-6)
})

test_that("geometry covers every keyed mark family", {
  s <- vl_scene(5, 3, dpi = 96, bg = "white") |>
    draw(lines_grob(c(.1, .5, .9), c(.2, .4, .2), key = "ln")) |>
    draw(polygon_grob(c(.1, .3, .2), c(.6, .6, .9), key = "pg")) |>
    draw(rect_grob(x = .8, width = .1, height = .1, key = "rc")) |>
    draw(text_grob("hi", x = .5, y = .9, key = "tx")) |>
    draw(segments_grob(.1, .1, .4, .15, key = "sg"))
  g <- element_geometry(s)
  expect_setequal(unique(g$kind), c("line", "polygon", "rect", "text", "segment"))
  expect_equal(sum(g$key == "ln"), 3L) # all three vertices, not a box
})
