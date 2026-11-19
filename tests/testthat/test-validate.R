# The shared validators in R/validate.R.

test_that(".check_default_units accepts unit names and refuses the rest", {
  expect_identical(.check_default_units("native"), "native")
  expect_identical(.check_default_units("cm"), "cm")
  expect_error(.check_default_units("null"), "default_units")
  expect_error(.check_default_units("strwidth"), "default_units")
  expect_error(.check_default_units(c("npc", "mm")), "default_units")
})

test_that(".as_unit_arg reads bare numbers in default_units", {
  expect_equal(.as_unit_arg(1:2, "x"), vl_unit(1:2, "npc"))
  expect_equal(.as_unit_arg(1:2, "x", "native"), vl_unit(1:2, "native"))
  u <- vl_unit(3, "mm")
  expect_identical(.as_unit_arg(u, "x", "native"), u)
  expect_null(.as_unit_arg(NULL, "x", allow_null = TRUE))
  expect_error(.as_unit_arg(NULL, "x"), "NULL")
  expect_error(.as_unit_arg("a", "x"), "numeric")
  # An all-NA logical is a missing coordinate, not a type error.
  expect_true(is_unit(.as_unit_arg(NA, "x")))
})

test_that("validators name the user-facing caller in the error", {
  f <- function(n) .check_scalar(n, "n")
  expect_error(f("a"), class = "rlang_error")
  cnd <- tryCatch(f("a"), error = identity)
  expect_identical(as.character(cnd$call[[1]]), "f")
})

test_that(".check_scalar checks type, length and NA", {
  expect_identical(.check_scalar(1, "n"), 1)
  expect_identical(.check_scalar(2L, "n", "integer"), 2L)
  expect_error(.check_scalar(1.5, "n", "integer"), "whole number")
  expect_error(.check_scalar(c(1, 2), "n"), "single number")
  expect_error(.check_scalar(NA_real_, "n"), "single number")
  expect_identical(.check_scalar(NA_real_, "n", allow_na = TRUE), NA_real_)
  expect_null(.check_scalar(NULL, "n", allow_null = TRUE))
  expect_error(.check_scalar("a", "flag", "logical"), "TRUE")
  expect_identical(.check_scalar("a", "s", "character"), "a")
})

test_that(".check_range enforces open and closed bounds", {
  expect_identical(.check_range(c(0, 1), "a", 0, 1), c(0, 1))
  expect_error(
    .check_range(1, "a", 0, 1, inclusive = c(TRUE, FALSE)),
    "[0, 1)",
    fixed = TRUE
  )
  expect_error(.check_range(-0.1, "a", 0, 1), "\\[0, 1\\]")
  expect_error(.check_range(Inf, "a"), "finite")
  expect_error(.check_range("1", "a"), "numeric")
  expect_identical(
    .check_range(c(NA, 0.5), "a", 0, 1, allow_na = TRUE),
    c(NA, 0.5)
  )
})

test_that(".check_colour accepts R colours and names the bad ones", {
  expect_identical(
    .check_colour(c("red", "#00FF00", NA), "col"),
    c("red", "#00FF00", NA)
  )
  expect_error(.check_colour("notacolour", "col"), "notacolour")
  expect_error(.check_colour(NA, "col", allow_na = FALSE), "NA")
  expect_error(.check_colour(list("red"), "col"), "colour")
  expect_null(.check_colour(NULL, "col", allow_null = TRUE))
})

test_that(".check_choice picks from a set without partial matching", {
  ch <- c("flat", "pointy")
  expect_identical(.check_choice(ch, ch, "o"), "flat")
  expect_identical(.check_choice("pointy", ch, "o"), "pointy")
  expect_error(.check_choice("po", ch, "o"), "flat")
  expect_error(.check_choice(c("flat", "pointy", "x"), ch, "o"), "one of")
})

test_that(".recycle_elems recycles units and plain vectors, skipping NULL", {
  out <- .recycle_elems(list(x = vl_unit(1, "npc"), a = 1:3, z = NULL), 3L)
  expect_equal(out$x, vl_unit(rep(1, 3), "npc"))
  expect_identical(out$a, 1:3)
  expect_null(out$z)
  expect_error(.recycle_elems(list(a = 1:2), 3L))
})
