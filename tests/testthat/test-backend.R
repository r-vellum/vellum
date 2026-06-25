test_that("backend identity is wired up", {
  expect_match(rs_backend_info(), "^vellum Rust backend v")
})
