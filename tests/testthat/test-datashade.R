# PERF-5: aggregate-then-shade (datashader-style).

px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

test_that("rs_aggregate_2d counts points into the right cells (top-left origin)", {
  # weight 2 at bottom-left, weight 5 at top-right, on a 2x2 grid over [0,1]^2.
  g <- rs_aggregate_2d(c(0.1, 0.9), c(0.1, 0.9), c(2, 5), 2L, 2L, 0, 1, 0, 1)
  expect_equal(g, c(0, 5, 2, 0)) # row-major: TL, TR, BL, BR
})

test_that("rs_aggregate_2d counts (no weights) and skips out-of-range / NA", {
  g <- rs_aggregate_2d(c(0.5, 0.5, 0.5, 2, NA), c(0.5, 0.5, 0.5, 0.5, 0.5),
                       NULL, 1L, 1L, 0, 1, 0, 1)
  expect_equal(sum(g), 3) # three in-range points; the x=2 and NA are dropped
})

test_that("datashade returns a renderable raster grob", {
  set.seed(1)
  g <- datashade(rnorm(1e4), rnorm(1e4), width = 64, height = 48)
  expect_true(S7::S7_inherits(g, grob))
  expect_equal(g@iw, 64L)
  expect_equal(g@ih, 48L)
  f <- withr::local_tempfile(fileext = ".png")
  s <- vl_scene(2, 1.5, dpi = 100) |>
    push(vl_viewport(xscale = c(-4, 4), yscale = c(-4, 4))) |>
    draw(g)
  expect_no_error(render(s, f))
})

test_that("a dense cluster shades while empty space stays transparent", {
  # All mass in one tight cluster near the centre of the data range.
  x <- c(rnorm(5000, 0, 0.01), -3, 3)
  y <- c(rnorm(5000, 0, 0.01), -3, 3)
  g <- datashade(x, y, width = 100, height = 100, xlim = c(-4, 4), ylim = c(-4, 4),
                 colors = c("#ffffff", "#000000"))
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    push(vl_viewport(xscale = c(-4, 4), yscale = c(-4, 4))) |>
    draw(g)
  centre <- px(s, 100, 100)   # data (0,0) -> device centre: shaded (dark, high density)
  corner <- px(s, 100, 10)    # near top, away from the cluster: empty -> background
  expect_lt(centre[1], 200L)
  expect_equal(corner[1:3], c(255L, 255L, 255L))
})

test_that("the how mappings all produce a valid grob", {
  set.seed(2)
  x <- rnorm(2000); y <- rnorm(2000)
  for (h in c("eq_hist", "log", "cbrt", "linear")) {
    expect_no_error(datashade(x, y, width = 32, height = 32, how = h))
  }
})

test_that("datashade() validates / recycles the weight vector", {
  # a scalar weight is recycled to every point (no error)
  expect_no_error(datashade(c(0.2, 0.8), c(0.2, 0.8), weight = 3, width = 4, height = 4))
  # a full-length weight is accepted
  expect_no_error(datashade(c(0.2, 0.8), c(0.2, 0.8), weight = c(1, 2), width = 4, height = 4))
  # a wrong-length weight is a clear error, not a silent unweighted result
  expect_error(
    datashade(c(0.2, 0.5, 0.8), c(0.2, 0.5, 0.8), weight = c(1, 2)),
    "weight"
  )
})

# --- Phase 1: percentile / span colormap clamping -------------------------------

test_that("span / clip clamp the density range but leave the default unchanged", {
  set.seed(3)
  x <- c(rnorm(3000), rep(0, 200)) # a spike of duplicate density at the centre
  y <- c(rnorm(3000), rep(0, 200))
  base <- datashade(x, y, width = 40, height = 40, how = "linear")
  # A clip that trims the top percentile changes at least one shaded cell.
  clipped <- datashade(x, y, width = 40, height = 40, how = "linear", clip = c(0, 0.9))
  expect_false(identical(base@rgba, clipped@rgba))
  # An absolute span behaves the same way; both are additive (default NULL == today).
  spanned <- datashade(x, y, width = 40, height = 40, how = "linear", span = c(1, 5))
  expect_false(identical(base@rgba, spanned@rgba))
  again <- datashade(x, y, width = 40, height = 40, how = "linear")
  expect_identical(base@rgba, again@rgba) # NULL span/clip is byte-identical
})

test_that("span / clip are validated", {
  x <- rnorm(100); y <- rnorm(100)
  expect_error(datashade(x, y, clip = c(0.9, 0.1)), "clip")
  expect_error(datashade(x, y, clip = c(-1, 0.5)), "clip")
  expect_error(datashade(x, y, span = c(5, 1)), "span")
})

# --- Phase 2: categorical (count_cat) aggregation + blend -----------------------

test_that("rs_aggregate_2d_cat keeps a separate count grid per category", {
  # two categories, two points each, on a 2x2 grid: cat 0 top-right, cat 1 bottom-left
  g <- rs_aggregate_2d_cat(
    c(0.9, 0.1), c(0.9, 0.1), c(0L, 1L), 2L, NULL, 2L, 2L, 0, 1, 0, 1
  )
  expect_length(g, 2 * 4) # ncat * nx * ny, category-major
  cat0 <- g[1:4] # row-major TL, TR, BL, BR
  cat1 <- g[5:8]
  expect_equal(cat0, c(0, 1, 0, 0)) # cat 0's point in the top-right cell
  expect_equal(cat1, c(0, 0, 1, 0)) # cat 1's point in the bottom-left cell
})

test_that("rs_aggregate_2d_cat drops out-of-range categories and NA levels", {
  g <- rs_aggregate_2d_cat(
    c(0.5, 0.5, 0.5), c(0.5, 0.5, 0.5), c(0L, 5L, -1L), 2L, NULL, 1L, 1L, 0, 1, 0, 1
  )
  expect_equal(sum(g), 1) # only the cat-0 point lands; cat 5 (>=ncat) and -1 dropped
})

test_that("categorical datashade blends hues by count and is opacity-by-density", {
  # A pure-red cluster, a pure-blue cluster, and a 50/50 mixed cluster.
  n <- 2000
  rx <- rnorm(n, -2, 0.05); ry <- rnorm(n, -2, 0.05)
  bx <- rnorm(n, 2, 0.05); by <- rnorm(n, 2, 0.05)
  mx <- rnorm(2 * n, 0, 0.05); my <- rnorm(2 * n, 0, 0.05)
  x <- c(rx, bx, mx); y <- c(ry, by, my)
  cat <- factor(c(rep("r", n), rep("b", n), rep(c("r", "b"), n)))
  g <- datashade(x, y, category = cat, width = 100, height = 100,
                 xlim = c(-4, 4), ylim = c(-4, 4),
                 colors = c(r = "#ff0000", b = "#0000ff"))
  expect_true(S7::S7_inherits(g, grob))

  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    push(vl_viewport(xscale = c(-4, 4), yscale = c(-4, 4))) |>
    draw(g)
  red <- px(s, 50, 150)    # data (-2,-2) -> lower-left cluster: red-dominant
  blue <- px(s, 150, 50)   # data (2,2)  -> upper-right cluster: blue-dominant
  mixed <- px(s, 100, 100) # data (0,0)  -> mixed cluster: purple-ish
  expect_gt(red[1], red[3])    # more red than blue
  expect_gt(blue[3], blue[1])  # more blue than red
  expect_gt(mixed[1], 40L)     # mixed cell carries both channels
  expect_gt(mixed[3], 40L)
})

test_that("categorical colors must cover every level", {
  x <- rnorm(50); y <- rnorm(50); cat <- rep(c("a", "b", "c"), length.out = 50)
  expect_error(datashade(x, y, category = cat, colors = c(a = "red", b = "blue")), "colors")
  expect_error(datashade(x, y, category = cat, colors = c("red", "blue")), "colour per")
  # named covering, or one-per-level in order, both work
  expect_no_error(datashade(x, y, category = cat, colors = c(a = "red", b = "blue", c = "green")))
  expect_no_error(datashade(x, y, category = cat, colors = c("red", "blue", "green")))
})

test_that("category = NULL is byte-identical to the single-category path", {
  set.seed(4)
  x <- rnorm(5000); y <- rnorm(5000)
  a <- datashade(x, y, width = 50, height = 50)
  b <- datashade(x, y, width = 50, height = 50, category = NULL)
  expect_identical(a@rgba, b@rgba)
})

# --- Phase 3: line / segment aggregation (Rust rasteriser) ----------------------

test_that("rs_aggregate_segments lays an axis-aligned segment on the right cells", {
  # A vertical segment landing exactly on column 1's centre (x = 0.375 on a 4-wide
  # grid over [0,1]): all coverage in column 1, interior rows full, ends partial.
  g <- rs_aggregate_segments(0.375, 0.1, 0.375, 0.9, NULL, 4L, 4L, 0, 1, 0, 1)
  m <- matrix(g, 4L, 4L, byrow = TRUE) # row-major, top-left origin
  expect_true(all(m[, c(1, 3, 4)] == 0)) # only column 2 (1-based) carries ink
  expect_equal(m[2, 2], 1) # interior cell: full coverage
  expect_equal(m[3, 2], 1)
  expect_gt(m[1, 2], 0) # endpoint cells: partial coverage
  expect_gt(m[4, 2], 0)
})

test_that("rs_aggregate_segments AA-splits a segment straddling two rows", {
  # A horizontal segment at world y = 0.5 sits on the boundary between the two
  # middle rows of a 4-high grid, so coverage splits evenly across them.
  g <- rs_aggregate_segments(0.1, 0.5, 0.9, 0.5, NULL, 4L, 4L, 0, 1, 0, 1)
  m <- matrix(g, 4L, 4L, byrow = TRUE)
  expect_true(all(m[c(1, 4), ] == 0))    # top and bottom rows empty
  expect_equal(m[2, ], m[3, ])           # the two middle rows carry equal ink
  expect_gt(sum(m[2, ]), 0)
})

test_that("rs_aggregate_segments honours per-segment weights", {
  g1 <- rs_aggregate_segments(0.375, 0.1, 0.375, 0.9, NULL, 4L, 4L, 0, 1, 0, 1)
  g3 <- rs_aggregate_segments(0.375, 0.1, 0.375, 0.9, 3, 4L, 4L, 0, 1, 0, 1)
  expect_equal(g3, g1 * 3) # a weight of 3 scales the deposited coverage
})

test_that("rs_aggregate_lines connects a series but breaks across groups / NA", {
  x <- c(0.1, 0.9); y <- c(0.5, 0.5)
  same <- rs_aggregate_lines(x, y, c(1L, 1L), NULL, 3L, 3L, 0, 1, 0, 1)
  diff <- rs_aggregate_lines(x, y, c(1L, 2L), NULL, 3L, 3L, 0, 1, 0, 1)
  expect_gt(sum(same), 0)      # one connected series -> a drawn line
  expect_equal(sum(diff), 0)   # different groups -> no segment drawn
  # An NA vertex breaks the polyline just like a group change.
  nab <- rs_aggregate_lines(c(0.1, NA, 0.9), c(0.5, NA, 0.5), NULL, NULL, 3L, 3L, 0, 1, 0, 1)
  expect_equal(sum(nab), 0)
})

test_that("datashade_segments / datashade_lines return renderable rasters", {
  set.seed(10)
  n <- 2000
  e <- datashade_segments(rnorm(n), rnorm(n), rnorm(n), rnorm(n), width = 64, height = 48)
  expect_true(S7::S7_inherits(e, grob))
  expect_equal(c(e@iw, e@ih), c(64L, 48L))

  k <- 30; m <- 100
  walks <- apply(matrix(rnorm(k * m), m, k), 2, cumsum)
  tt <- rep(seq_len(m), k)
  g <- datashade_lines(tt, as.vector(walks), group = rep(seq_len(k), each = m),
                       width = 80, height = 60)
  expect_equal(c(g@iw, g@ih), c(80L, 60L))

  f <- withr::local_tempfile(fileext = ".png")
  s <- vl_scene(2, 1.5, dpi = 100) |>
    push(vl_viewport(xscale = range(tt), yscale = range(walks))) |>
    draw(g)
  expect_no_error(render(s, f))
})

test_that("a line shades along its path while empty space stays transparent", {
  # A single diagonal from (-3,-3) to (3,3) over [-4,4]^2 on a 100x100 grid, which
  # runs along the raster's anti-diagonal (row ~ 99 - col). Inspect the raster's
  # alpha directly: robust to sub-pixel AA placement that a device probe is not.
  g <- datashade_segments(-3, -3, 3, 3, NULL, width = 100, height = 100,
                          xlim = c(-4, 4), ylim = c(-4, 4),
                          colors = c("#ffffff", "#000000"))
  a <- matrix(g@rgba[c(FALSE, FALSE, FALSE, TRUE)], 100L, 100L, byrow = TRUE) # alpha
  on_win <- a[48:52, 48:52]   # centred on the line -> shaded
  off_win <- a[5:9, 5:9]      # far top-left corner -> empty
  expect_gt(sum(on_win > 0), 0)
  expect_equal(sum(off_win), 0)
})

test_that("datashade line/segment functions validate / recycle weights", {
  expect_no_error(datashade_segments(0, 0, 1, 1, weight = 2, width = 8, height = 8))
  expect_error(
    datashade_segments(c(0, 0), c(0, 0), c(1, 1), c(1, 1), weight = c(1, 2, 3)),
    "weight"
  )
  expect_error(
    datashade_lines(c(0, 1, 2), c(0, 1, 2), group = c(1, 2)),
    "group"
  )
})

# --- Phase 3: spread / dynspread ------------------------------------------------

test_that("spread dilates a lone pixel over its neighbourhood", {
  # A 5x5 canvas with a single opaque black pixel at the centre.
  img <- matrix("transparent", 5, 5)
  img[3, 3] <- "#000000"
  g <- raster_grob(img, interpolate = FALSE)
  alpha <- function(gr) matrix(gr@rgba[c(FALSE, FALSE, FALSE, TRUE)], 5, 5, byrow = TRUE)
  expect_equal(sum(alpha(g) > 0), 1L)

  sq <- spread(g, px = 1, shape = "square")
  expect_equal(sum(alpha(sq) > 0), 9L) # full 3x3 block

  ci <- spread(g, px = 1, shape = "circle")
  expect_equal(sum(alpha(ci) > 0), 5L) # plus-shaped: centre + 4 edge neighbours
})

test_that("spread grows coverage and dynspread picks a bounded radius", {
  set.seed(11)
  n <- 1500
  g <- datashade_segments(rnorm(n), rnorm(n), rnorm(n), rnorm(n), width = 80, height = 80)
  alpha_n <- function(gr) sum(gr@rgba[c(FALSE, FALSE, FALSE, TRUE)] > 0)
  base <- alpha_n(g)
  sp <- spread(g, px = 2)
  expect_gt(alpha_n(sp), base)               # spreading only adds ink
  dy <- dynspread(g, max_px = 3)
  expect_gte(alpha_n(dy), base)              # dynspread grows (or leaves) coverage
  expect_lte(alpha_n(dy), alpha_n(spread(g, px = 3)))
})

test_that("spread / dynspread are no-ops on px 0 and non-raster grobs", {
  g <- datashade_segments(0, 0, 1, 1, width = 16, height = 16)
  expect_identical(spread(g, px = 0)@rgba, g@rgba)
  # a non-raster grob passes through untouched
  r <- rect_grob()
  expect_identical(spread(r), r)
  expect_identical(dynspread(r), r)
  expect_error(spread(g, px = -1), "px")
  expect_error(dynspread(g, threshold = 2), "threshold")
})

test_that("the spread= convenience arg matches the standalone functions", {
  set.seed(12)
  n <- 800
  args <- list(rnorm(n), rnorm(n), rnorm(n), rnorm(n), width = 60, height = 60)
  raw <- do.call(datashade_segments, args)
  expect_identical(do.call(datashade_segments, c(args, list(spread = 2L)))@rgba,
                   spread(raw, px = 2L)@rgba)
  expect_identical(do.call(datashade_segments, c(args, list(spread = "auto")))@rgba,
                   dynspread(raw)@rgba)
  expect_error(do.call(datashade_segments, c(args, list(spread = -1L))), "spread")
})
