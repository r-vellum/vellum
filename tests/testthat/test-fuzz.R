# Property / fuzz coverage for the R -> Rust FFI boundary. The batched grob
# constructors hand vectors straight to the Rust scene, so the contract is: a
# hostile input must fail *gracefully* -- either a clean R error at construction/
# compile, or a stable non-panicking render -- never a segfault or hang that
# takes down the R session (which would fail R CMD check outright).
#
# The intended policy (see test-na-gap.R, test-validation.R):
#   * NA/NaN/Inf in a *coordinate* drops the primitive / breaks the path (grid-like);
#   * a non-finite *angle* or a negative *extent* is a hard error at construction;
#   * mismatched vector lengths are a hard error at construction;
#   * empty inputs are a no-op; huge-n completes without crashing.

# Renders through every public read-back path; returns invisibly if all succeed.
render_all <- function(scene) {
  scene_raster(scene)
  scene_svg(scene)
  scene_model(scene)
  f <- withr::local_tempfile(fileext = ".png")
  render(scene, f)
  invisible(TRUE)
}

nonfinite <- list(pos_inf = Inf, neg_inf = -Inf, nan = NaN, na = NA_real_)

test_that("non-finite coordinates render gracefully across batched primitives", {
  for (bad in nonfinite) {
    prims <- list(
      points = points_grob(c(0.5, bad), c(0.5, 0.5), size = unit(3, "mm"),
                            gp = gpar(fill = "red")),
      circle = circle_grob(c(0.5, bad), 0.5, r = unit(2, "mm"), gp = gpar(fill = "red")),
      rect   = rect_grob(c(0.5, bad), 0.5, width = 0.2, height = 0.2, gp = gpar(fill = "red")),
      seg    = segments_grob(c(0.1, bad), 0.1, 0.9, 0.9, gp = gpar(col = "black")),
      line   = lines_grob(c(0.1, 0.4, bad, 0.9), 0.5, gp = gpar(col = "black")),
      poly   = polygon_grob(c(0.1, 0.9, bad), c(0.1, 0.1, 0.9), gp = gpar(fill = "red"))
    )
    for (nm in names(prims)) {
      sc <- vl_scene(2, 2, dpi = 50, bg = "white") |> draw(prims[[nm]])
      expect_no_error(render_all(sc))
    }
  }
})

test_that("a non-finite bbox does not break the scene_model positional zip", {
  # The R (semantic) and Rust (geometry) element tables must still agree in count
  # and key order even when a coordinate is non-finite.
  for (bad in nonfinite) {
    sc <- vl_scene(2, 2, dpi = 50) |>
      draw(points_grob(c(0.5, bad), c(0.5, 0.5), size = unit(3, "mm"),
                       gp = gpar(fill = "red"), key = c("a", "b")))
    m <- scene_model(sc)
    expect_equal(nrow(m$elements), 2L)
    expect_identical(m$elements$key, c("a", "b"))
  }
})

test_that("mismatched vector lengths are a clean error at construction", {
  expect_error(lines_grob(x = 1:3, y = 1:2), "same length")
  expect_error(polygon_grob(x = 1:3, y = 1:2), "same length")
  expect_error(segments_grob(x0 = 1:3, y0 = 1:2, x1 = 1:3, y1 = 1:3), "length")
})

test_that("non-finite angles and negative extents are rejected at construction", {
  expect_error(sector_grob(0.5, 0.5, theta0 = 0, theta1 = NaN), "finite")
  expect_error(sector_grob(0.5, 0.5, theta0 = Inf, theta1 = 1), "finite")
  expect_error(rect_grob(0.5, 0.5, width = -1, height = 0.2), "non-negative")
  expect_error(circle_grob(0.5, 0.5, r = unit(-2, "mm")), "non-negative")
})

test_that("empty inputs are a no-op, not an error", {
  sc <- vl_scene(2, 2, dpi = 50) |>
    draw(points_grob(numeric(0), numeric(0), gp = gpar(fill = "red")))
  expect_no_error(render_all(sc))
  expect_equal(nrow(scene_model(sc)$elements), 0L)
})

test_that("a large point cloud renders without crashing the session", {
  n <- 5e4
  x <- stats::runif(n)
  y <- stats::runif(n)
  sc <- vl_scene(3, 3, dpi = 72, bg = "white") |>
    draw(points_grob(x, y, size = unit(0.5, "mm"), gp = gpar(fill = "black")))
  expect_no_error(scene_raster(sc))
})

test_that("datashade aggregation drops non-finite points instead of crashing", {
  # rs_aggregate_2d is the most defensive FFI entry: it skips non-finite inputs.
  g <- datashade(c(1, NaN, 3, Inf), c(1, 2, NaN, 4), width = 32, height = 32)
  sc <- vl_scene(2, 2, dpi = 50, bg = "white") |> draw(g)
  expect_no_error(scene_raster(sc))
})
