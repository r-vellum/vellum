test_that("backend round-trip is wired up", {
  expect_match(rs_backend_info(), "^vellum Rust backend v")
})

test_that("rs_bbox computes the axis-aligned bounding box", {
  expect_equal(
    rs_bbox(c(3, -1, 4, 1, 5), c(9, 2, 6, 5, 3)),
    c(-1, 5, 2, 9)
  )
  # single point: degenerate box
  expect_equal(rs_bbox(2, 7), c(2, 2, 7, 7))
})

test_that("rs_bbox handles edge cases", {
  expect_null(rs_bbox(numeric(0), numeric(0)))
  expect_error(rs_bbox(c(1, 2, 3), c(1, 2)), "same length")
})
