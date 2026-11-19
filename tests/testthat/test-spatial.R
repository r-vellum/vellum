# F-6: the cached spatial index behind vl_nearest(), vl_brush() and vl_lasso().

# The full pick-table answer vl_nearest() used to compute per call, kept here
# as the reference the index must reproduce.
ref_nearest <- function(s, x, y, n = 1L, max_dist = Inf) {
  b <- .scene_to_backend(s)
  d <- b$dim()
  t <- b$pick_table(x * d[1], (1 - y) * d[2])
  out <- data.frame(key = t$key, kind = t$kind, dist = t$dist)
  out <- out[out$dist <= max_dist, , drop = FALSE]
  out <- out[order(out$dist), , drop = FALSE]
  rownames(out) <- NULL
  utils::head(out, n)
}

sp_scene <- function() {
  set.seed(6)
  n <- 400
  vl_scene(4, 3, dpi = 96) |>
    draw(points_grob(
      x = runif(n),
      y = runif(n),
      key = sprintf("p%03d", seq_len(n)),
      gp = vl_gpar(fill = "grey40", col = NA)
    )) |>
    draw(segments_grob(0.05, 0.05, 0.95, 0.95, key = "diag")) |>
    draw(polygon_grob(
      x = c(0.6, 0.9, 0.9, 0.6),
      y = c(0.1, 0.1, 0.3, 0.3),
      key = "box"
    ))
}

test_that("vl_nearest() from the index matches the full pick-table scan", {
  s <- sp_scene()
  set.seed(1)
  for (i in 1:60) {
    x <- runif(1, -0.1, 1.1)
    y <- runif(1, -0.1, 1.1)
    for (n in c(1L, 3L)) {
      got <- vl_nearest(s, x, y, n = n)
      rownames(got) <- NULL
      expect_equal(got, ref_nearest(s, x, y, n), info = paste(x, y, n))
    }
  }
  expect_equal(
    vl_nearest(s, 0.5, 0.5, n = 5, max_dist = 3),
    ref_nearest(s, 0.5, 0.5, 5, max_dist = 3),
    ignore_attr = TRUE
  )
  # more than there are elements: everything, nearest first
  all <- vl_nearest(s, 0.5, 0.5, n = 10000L)
  expect_identical(nrow(all), 402L)
  expect_false(is.unsorted(all$dist))
  expect_identical(nrow(vl_nearest(s, 0.5, 0.5, n = 0L)), 0L)
})

test_that("vl_nearest() on a scene with no keyed marks is empty", {
  s <- vl_scene(2, 2) |> draw(points_grob(0.5, 0.5))
  out <- vl_nearest(s, 0.5, 0.5)
  expect_identical(nrow(out), 0L)
  expect_named(out, c("key", "kind", "dist"))
})

test_that("vl_brush() selects by true geometry", {
  s <- vl_scene(4, 3, dpi = 96) |>
    draw(segments_grob(0.1, 0.1, 0.9, 0.9, key = "diagonal")) |>
    draw(points_grob(c(0.2, 0.8), c(0.8, 0.2), key = c("tl", "br")))
  # the diagonal's box covers this corner; the line does not reach it
  expect_identical(vl_brush(s, 0.7, 0.9, 0.1, 0.3)$key, "br")
  expect_identical(vl_brush(s, 0.4, 0.6, 0.4, 0.6)$key, "diagonal")
  # edges in either order
  expect_identical(vl_brush(s, 0.9, 0.7, 0.3, 0.1)$key, "br")
  # paint order, with kinds
  out <- vl_brush(s, 0, 1, 0, 1)
  expect_identical(out$key, c("diagonal", "tl", "br"))
  expect_identical(out$kind, c("segment", "point", "point"))
  # contain: the whole line must be inside
  expect_identical(nrow(vl_brush(s, 0.4, 0.6, 0.4, 0.6, mode = "contain")), 0L)
  expect_identical(
    vl_brush(s, 0, 1, 0, 1, mode = "contain")$key,
    c("diagonal", "tl", "br")
  )
  # px units: device px, y down
  d <- .scene_to_backend(s)$dim()
  expect_identical(
    vl_brush(
      s,
      0.7 * d[1],
      0.9 * d[1],
      0.7 * d[2],
      0.9 * d[2],
      units = "px"
    )$key,
    "br"
  )
})

test_that("contain and centre differ on a point the rectangle cuts", {
  # a 10 px-radius point centred at (50, 50) px (1 in at 100 dpi)
  s <- vl_scene(1, 1, dpi = 100) |>
    draw(points_grob(0.5, 0.5, size = vl_unit(2.54, "mm"), key = "p"))
  cut <- function(mode) {
    vl_brush(s, 45, 70, 45, 70, units = "px", mode = mode)$key
  }
  expect_identical(cut("intersect"), "p")
  expect_identical(cut("centre"), "p")
  expect_identical(cut("contain"), character(0))
  expect_identical(
    vl_brush(s, 30, 70, 30, 70, units = "px", mode = "contain")$key,
    "p"
  )
})

test_that("a region in a polygon's hole does not meet the polygon", {
  s <- vl_scene(1, 1, dpi = 100) |>
    draw(path_grob(
      x = c(10, 90, 90, 10, 40, 60, 60, 40) / 100,
      y = c(10, 10, 90, 90, 40, 40, 60, 60) / 100,
      id = rep(1:2, each = 4),
      rule = "evenodd",
      key = "donut"
    ))
  expect_identical(nrow(vl_brush(s, 45, 55, 45, 55, units = "px")), 0L)
  expect_identical(vl_brush(s, 15, 25, 15, 25, units = "px")$key, "donut")
  expect_identical(
    nrow(vl_lasso(s, c(45, 55, 50), c(45, 45, 55), units = "px")),
    0L
  )
  expect_identical(
    vl_lasso(s, c(15, 25, 20), c(15, 15, 25), units = "px")$key,
    "donut"
  )
})

test_that("vl_lasso() selects inside a polygon, even-odd", {
  s <- vl_scene(4, 3, dpi = 96) |>
    draw(segments_grob(0.1, 0.1, 0.9, 0.9, key = "diagonal")) |>
    draw(points_grob(c(0.2, 0.8), c(0.8, 0.2), key = c("tl", "br")))
  expect_identical(
    vl_lasso(s, c(0.05, 0.4, 0.05), c(0.6, 0.95, 0.95))$key,
    "tl"
  )
  # a triangle around the bottom-right point that the diagonal skirts
  expect_identical(
    vl_lasso(s, c(0.6, 0.95, 0.95), c(0.05, 0.05, 0.4))$key,
    "br"
  )
  # a lasso across the diagonal: intersects, does not contain
  lx <- c(0.4, 0.6, 0.6, 0.4)
  ly <- c(0.4, 0.4, 0.6, 0.6)
  expect_identical(vl_lasso(s, lx, ly)$key, "diagonal")
  expect_identical(nrow(vl_lasso(s, lx, ly, mode = "contain")), 0L)
  expect_identical(vl_lasso(s, lx, ly, mode = "centre")$key, "diagonal")
})

test_that("vl_brush() and vl_lasso() agree on a rectangle", {
  s <- sp_scene()
  set.seed(3)
  for (i in 1:20) {
    xs <- sort(runif(2))
    ys <- sort(runif(2))
    for (mode in c("intersect", "contain", "centre")) {
      expect_identical(
        vl_brush(s, xs[1], xs[2], ys[1], ys[2], mode = mode)$key,
        vl_lasso(s, xs[c(1, 2, 2, 1)], ys[c(1, 1, 2, 2)], mode = mode)$key,
        info = mode
      )
    }
  }
})

test_that("the index follows an edited scene", {
  s <- vl_scene(2, 2) |> draw(points_grob(0.2, 0.2, key = "a"))
  expect_identical(vl_nearest(s, 0.8, 0.8)$key, "a")
  s2 <- s |> draw(points_grob(0.8, 0.8, key = "b"))
  expect_identical(vl_nearest(s2, 0.8, 0.8)$key, "b")
  expect_identical(vl_brush(s2, 0.7, 0.9, 0.7, 0.9)$key, "b")
  # the original is untouched
  expect_identical(vl_nearest(s, 0.8, 0.8)$key, "a")
})

test_that("the backend drops its index when drawn into", {
  withr::local_options(vellum.cache = FALSE)
  b <- .scene_to_backend(
    vl_scene(2, 2) |> draw(points_grob(0.2, 0.2, key = "a"))
  )
  d <- b$dim()
  expect_identical(b$nearest_table(0.8 * d[1], 0.2 * d[2], 1L, Inf)$key, "a")
  compile(points_grob(0.8, 0.8, key = "b"), b)
  expect_identical(b$nearest_table(0.8 * d[1], 0.2 * d[2], 1L, Inf)$key, "b")
})

test_that("region arguments are validated", {
  s <- vl_scene(2, 2) |> draw(points_grob(0.5, 0.5, key = "a"))
  expect_error(vl_brush(s, NA, 1, 0, 1), "xmin")
  expect_error(vl_brush(s, 0, 1, 0, 1, mode = "touch"))
  expect_error(vl_lasso(s, c(0, 1), c(0, 1)), "three")
  expect_error(vl_lasso(s, c(0, 1, 1), c(0, 1)), "same length")
  expect_error(vl_lasso(s, c(0, NA, 1), c(0, 1, 1)), "three finite")
})
