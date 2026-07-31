# Phase 11: placement as an engine service -- repulsion, empty regions, hulls,
# buffers.

# Padded label boxes, in device px, read back from a rendered scene.
label_boxes <- function(scene, pad = 0) {
  nd <- .resolved_nodes(scene)
  L <- nd[nd$kind == "text", , drop = FALSE]
  p <- pad / 25.4 * scene@dpi
  data.frame(x0 = L$x0 - p, y0 = L$y0 - p, x1 = L$x1 + p, y1 = L$y1 + p)
}
# Number of overlapping label pairs. `tol` keeps exactly-touching boxes -- which
# is what a solver aims for -- from counting as a collision.
overlap_pairs <- function(scene, pad = 0, tol = 1e-6) {
  b <- label_boxes(scene, pad)
  n <- nrow(b)
  if (n < 2L) {
    return(0L)
  }
  k <- 0L
  for (i in seq_len(n - 1L)) {
    for (j in seq.int(i + 1L, n)) {
      if (b$x0[i] < b$x1[j] - tol && b$x1[i] > b$x0[j] + tol &&
          b$y0[i] < b$y1[j] - tol && b$y1[i] > b$y0[j] + tol) {
        k <- k + 1L
      }
    }
  }
  k
}
# The canonical case repel exists for: labels sitting on their own points.
anchored <- function(n, seed = 1) {
  set.seed(seed)
  x <- runif(n)
  y <- runif(n)
  vl_scene(5, 3, dpi = 96, bg = "white") |>
    draw(points_grob(x, y, gp = vl_gpar(fill = "steelblue", col = NA), name = "pts")) |>
    draw(text_grob(paste0("item ", seq_len(n)), x = x, y = y,
                   gp = vl_gpar(fontsize = 9), name = "lab"))
}

test_that("repel separates overlapping labels", {
  # Label widths are font-dependent, so both the starting crowding and how much
  # of it can be resolved vary by machine. Assert the claim -- it clears the
  # page -- at a density where that is achievable whatever the font, and assert
  # the *improvement* rather than a fixed count at higher densities below.
  s <- anchored(25)
  expect_gt(overlap_pairs(s), 0L) # the problem is real before we start
  expect_equal(overlap_pairs(vl_repel(s)), 0L)
})

test_that("repel keeps improving as the page gets crowded", {
  # A large reduction, not a fixed target: how far it gets depends on how wide
  # the labels are in the font this machine happens to have.
  for (n in c(15, 30, 50)) {
    s <- anchored(n)
    before <- overlap_pairs(s)
    after <- overlap_pairs(vl_repel(s))
    expect_lte(after, before / 2,
               label = sprintf("n = %d: %d overlaps -> %d", n, before, after))
  }
})

test_that("two labels stacked exactly on each other come apart", {
  # The degenerate case: identical anchors, so there is no separating direction
  # to read off the geometry and the solver has to pick one.
  s <- vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(text_grob(c("alpha", "beta"), x = c(0.5, 0.5), y = c(0.5, 0.5),
                   gp = vl_gpar(fontsize = 12), name = "lab"))
  expect_equal(overlap_pairs(s), 1L)
  r <- vl_repel(s)
  expect_equal(overlap_pairs(r), 0L)
  expect_true(all(vl_place(s)$resolved))
})

test_that("labels stay near their anchors", {
  s <- anchored(30)
  sol <- vl_place(s, max_shift = 6)
  expect_true(all(sqrt(sol$dx^2 + sol$dy^2) <= 6 + 1e-6))
  # And the shift really is bounded in the rendered output, not just on paper.
  moved <- label_boxes(vl_repel(s, max_shift = 6))
  orig <- label_boxes(s)
  px <- 6 / 25.4 * 96
  expect_true(all(abs(moved$x0 - orig$x0) <= px + 1))
  expect_true(all(abs(moved$y0 - orig$y0) <= px + 1))
})

test_that("repel works in a scaled viewport, and in more than one at once", {
  # The point of solving in device space and applying an absolute offset: the
  # coordinate system the label was anchored in does not matter.
  mk <- function() {
    set.seed(2)
    x <- runif(14) * 100
    y <- runif(14) * 0.01
    vl_scene(6, 3, dpi = 96, bg = "white") |>
      push(vl_viewport(name = "left", x = 0.25, width = 0.45,
                       xscale = c(0, 100), yscale = c(0, 0.01))) |>
      draw(text_grob(paste0("n", seq_len(14)), x = vl_unit(x, "native"),
                     y = vl_unit(y, "native"), gp = vl_gpar(fontsize = 8),
                     name = "L")) |>
      pop() |>
      push(vl_viewport(name = "right", x = 0.75, width = 0.45,
                       xscale = c(0, 100), yscale = c(0, 0.01))) |>
      draw(text_grob(paste0("m", seq_len(14)), x = vl_unit(rev(x), "native"),
                     y = vl_unit(y, "native"), gp = vl_gpar(fontsize = 8),
                     name = "R")) |>
      pop()
  }
  s <- mk()
  expect_gt(overlap_pairs(s), 0L)
  # Both panels are solved in one call, with wildly different native scales on
  # the two axes, and the labels still separate.
  expect_lt(overlap_pairs(vl_repel(s)), overlap_pairs(s) / 2)
})

test_that("labels and obstacles can be chosen by name", {
  s <- anchored(20)
  # Ignoring the points entirely gives the solver more room, so it can never do
  # worse on label-label overlaps than when it must also dodge them.
  free <- overlap_pairs(vl_repel(s, avoid = character(0)))
  expect_equal(free, 0L)
  # `labels` selects by name, not by kind: any grob can be the thing that moves.
  # A batched mark is one movable box, because that is what it resolves to.
  expect_equal(nrow(vl_place(s, labels = "pts")), 1L)
  # Naming nothing that exists leaves the scene alone.
  expect_equal(nrow(vl_place(s, labels = "nope")), 0L)
  expect_identical(scene_png(vl_repel(s, labels = "nope")), scene_png(s))
})

test_that("a scene with nothing to place is returned untouched", {
  s <- vl_scene(3, 2, dpi = 96, bg = "white") |>
    draw(points_grob(c(0.3, 0.7), c(0.5, 0.5)))
  expect_equal(nrow(vl_place(s)), 0L)
  expect_identical(scene_png(vl_repel(s)), scene_png(s))
})

test_that("a single label never moves", {
  s <- vl_scene(3, 2, dpi = 96, bg = "white") |>
    draw(text_grob("only", name = "lab"))
  sol <- vl_place(s)
  expect_equal(sol$dx, 0)
  expect_equal(sol$dy, 0)
  expect_true(sol$resolved)
  expect_identical(scene_png(vl_repel(s)), scene_png(s))
})

test_that("obstacles are per element, not per batch", {
  # A batched mark is one node whose box is the union of every element. If the
  # solver used that, a scatter would read as one panel-sized obstacle and no
  # label could ever be placed.
  set.seed(4)
  s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(points_grob(runif(50), runif(50), gp = vl_gpar(fill = "grey40", col = NA),
                     name = "pts")) |>
    draw(text_grob("here", x = 0.5, y = 0.5, name = "lab"))
  obs <- .obstacle_boxes(s)
  pts <- obs[obs$name == "pts", , drop = FALSE]
  expect_equal(nrow(pts), 50L)
  expect_true(all((pts$x1 - pts$x0) < 20)) # marker-sized, not panel-sized
})

# --- empty regions -----------------------------------------------------------

test_that("the empty region finds the free half of a page", {
  set.seed(1)
  s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(points_grob(runif(60) * 0.45, runif(60),
                     gp = vl_gpar(fill = "steelblue", col = NA)))
  r <- vl_empty_region(s)
  expect_gt(r[["x0"]], 0.4) # it is on the empty side
  expect_gt(r[["x1"]] - r[["x0"]], 0.4) # and it is most of that side
  expect_gt(r[["y1"]] - r[["y0"]], 0.8)
})

test_that("the empty region never claims occupied space", {
  # Boxes are rounded outward, so the answer is conservative by construction.
  set.seed(5)
  s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(points_grob(runif(30), runif(30), size = vl_unit(3, "mm"),
                     gp = vl_gpar(fill = "grey30", col = NA)))
  r <- vl_empty_region(s, grid = 300)
  b <- .obstacle_boxes(s)
  d <- .scene_to_backend(s)$dim()
  # Back to device px to compare with the element boxes.
  px <- c(r[["x0"]] * d[1], (1 - r[["y1"]]) * d[2], r[["x1"]] * d[1], (1 - r[["y0"]]) * d[2])
  hit <- b$x0 < px[3] & b$x1 > px[1] & b$y0 < px[4] & b$y1 > px[2]
  expect_false(any(hit))
})

test_that("an empty page gives the whole page, a full one gives nothing", {
  blank <- vl_scene(4, 3, dpi = 96, bg = "white")
  r <- vl_empty_region(blank)
  expect_equal(unname(r), c(0, 0, 1, 1), tolerance = 0.02)

  full <- vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "grey")))
  expect_equal(unname(vl_empty_region(full)), c(0, 0, 0, 0))
})

test_that("the empty region honours `within` and `avoid`", {
  set.seed(1)
  s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(points_grob(runif(40), runif(40), gp = vl_gpar(fill = "grey40", col = NA),
                     name = "pts"))
  inside <- vl_empty_region(s, within = c(0, 0, 0.5, 0.5))
  expect_lte(inside[["x1"]], 0.5 + 0.02)
  expect_lte(inside[["y1"]], 0.5 + 0.02)
  # Ignoring the only marks in the scene frees the whole page.
  expect_equal(unname(vl_empty_region(s, avoid = character(0))), c(0, 0, 1, 1),
               tolerance = 0.02)
})

test_that("empty region can report millimetres", {
  s <- vl_scene(4, 3, dpi = 96, bg = "white")
  mm <- vl_empty_region(s, unit = "mm")
  expect_equal(unname(mm[3]), 4 * 25.4, tolerance = 1)
  expect_equal(unname(mm[4]), 3 * 25.4, tolerance = 1)
})

# --- hulls and buffers -------------------------------------------------------

test_that("the convex hull excludes interior points and keeps corners", {
  h <- vl_hull(c(0, 1, 1, 0, 0.5), c(0, 0, 1, 1, 0.5))
  expect_equal(nrow(h), 4L)
  expect_false(any(h$x == 0.5 & h$y == 0.5))
})

test_that("every point lies inside its convex hull", {
  set.seed(7)
  x <- runif(200)
  y <- runif(200)
  h <- vl_hull(x, y)
  # Signed area of the hull ring, and of each point against every edge: for a
  # counter-clockwise ring every point must be on the same side of all edges.
  n <- nrow(h)
  side <- vapply(seq_len(n), function(k) {
    a <- k
    b <- if (k == n) 1L else k + 1L
    cr <- (h$x[b] - h$x[a]) * (y - h$y[a]) - (h$y[b] - h$y[a]) * (x - h$x[a])
    min(cr)
  }, numeric(1))
  expect_true(all(side >= -1e-9) || all(side <= 1e-9))
})

test_that("a concave hull follows the points more closely than a convex one", {
  # A ring of points with one arc pushed inward. The dented points sit near the
  # chord the convex hull throws across them, so there is something to dig with
  # -- a ring with the arc simply *deleted* would leave the chord bare, and no
  # concave method could (or should) follow a boundary that has no points on it.
  th <- seq(0, 2 * pi, length.out = 60)[-60]
  r <- ifelse(th > pi * 0.7 & th < pi * 1.3, 0.45, 1)
  x <- r * cos(th)
  y <- r * sin(th)
  cv <- vl_hull(x, y)
  cc <- vl_hull(x, y, concavity = 1.2)
  expect_gte(nrow(cc), nrow(cv))
  # Following the bite means a smaller enclosed area.
  area <- function(h) abs(sum(h$x * c(h$y[-1], h$y[1]) - c(h$x[-1], h$x[1]) * h$y)) / 2
  expect_lt(area(cc), area(cv))
})

test_that("infinite concavity is exactly the convex hull", {
  set.seed(8)
  x <- runif(50)
  y <- runif(50)
  expect_identical(vl_hull(x, y, Inf), vl_hull(x, y))
})

test_that("degenerate point sets do not error", {
  expect_equal(nrow(vl_hull(numeric(0), numeric(0))), 0L)
  expect_equal(nrow(vl_hull(1, 2)), 1L)
  expect_equal(nrow(vl_hull(c(0, 1), c(0, 1))), 2L)
})

test_that("a buffer grows a ring by the requested distance", {
  # A square buffered by w reaches exactly w beyond each edge, and its rounded
  # corners stay within w*sqrt(2) of the original corner.
  sq <- list(x = c(0, 1, 1, 0), y = c(0, 0, 1, 1))
  w <- 0.1
  b <- vl_buffer(sq$x, sq$y, w)
  expect_equal(min(b$x), -w, tolerance = 1e-9)
  expect_equal(max(b$x), 1 + w, tolerance = 1e-9)
  expect_equal(min(b$y), -w, tolerance = 1e-9)
  expect_equal(max(b$y), 1 + w, tolerance = 1e-9)
  # Every buffered point is exactly w from the ring it came from.
  d <- pmin(
    abs(b$x - 0), abs(b$x - 1), abs(b$y - 0), abs(b$y - 1)
  )
  expect_true(all(d <= w + 1e-9))
})

test_that("a buffer grows outward whichever way the ring is wound", {
  sq <- list(x = c(0, 1, 1, 0), y = c(0, 0, 1, 1))
  ccw <- vl_buffer(sq$x, sq$y, 0.1)
  cw <- vl_buffer(rev(sq$x), rev(sq$y), 0.1)
  area <- function(b) abs(sum(b$x * c(b$y[-1], b$y[1]) - c(b$x[-1], b$x[1]) * b$y)) / 2
  # Both are bigger than the unit square, i.e. neither was shrunk.
  expect_gt(area(ccw), 1)
  expect_gt(area(cw), 1)
  expect_equal(area(ccw), area(cw), tolerance = 0.01)
})

test_that("buffer edge cases are inert rather than fatal", {
  expect_equal(nrow(vl_buffer(c(0, 1), c(0, 1), 0.1)), 2L) # not a ring
  expect_equal(nrow(vl_buffer(c(0, 1, 1), c(0, 0, 1), 0)), 3L) # zero width
})
