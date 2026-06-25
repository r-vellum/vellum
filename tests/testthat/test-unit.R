test_that("unit() constructs, recycles, and validates", {
  u <- unit(c(1, 2, 3), "native")
  expect_s3_class(u, "vellum_unit")
  expect_equal(vctrs::vec_size(u), 3L)
  expect_equal(vctrs::field(u, "value"), c(1, 2, 3))
  expect_true(all(vctrs::field(u, "unit") == 1L)) # native = 1

  # units recycle against values
  m <- unit(c(0.5, 1), c("npc", "in"))
  expect_equal(vctrs::field(m, "unit"), c(0L, 3L))

  expect_error(unit(1, "furlong"), "Unknown unit")
  # "null" is allowed in the type (for layouts) but rejected as a coordinate
  expect_s3_class(unit(1, "null"), "vellum_unit")
  expect_error(.coord(unit(1, "null")), "only valid in layouts")
})

test_that("format / print show value+unit", {
  expect_equal(format(unit(c(1, 2), c("npc", "mm"))), c("1npc", "2mm"))
})

test_that("c(), [ and slicing work", {
  u <- c(unit(1, "npc"), unit(2, "mm"))
  expect_equal(vctrs::vec_size(u), 2L)
  expect_equal(format(u), c("1npc", "2mm"))
  expect_equal(format(u[2]), "2mm")
})

test_that("arithmetic: scalar scale, same-unit add/sub, unary minus", {
  expect_equal(format(unit(2, "npc") * 3), "6npc")
  expect_equal(format(3 * unit(2, "mm")), "6mm")
  expect_equal(format(unit(10, "pt") / 2), "5pt")
  expect_equal(format(unit(2, "npc") + unit(1, "npc")), "3npc")
  expect_equal(format(-unit(4, "mm")), "-4mm")
  # mixed units cannot be added
  expect_error(unit(1, "npc") + unit(1, "mm"), "same unit")
})

test_that("derived units resolve to absolute millimetres at construction", {
  expect_equal(vctrs::field(unit(2, "cm"), "unit"), 2L) # mm code
  expect_equal(vctrs::field(unit(2, "cm"), "value"), 20)
  # 1 char at 36pt = 36/72 in = 0.5in = 12.7mm
  expect_equal(vctrs::field(unit(1, "char", data = list(fontsize = 36)), "value"), 12.7,
               tolerance = 1e-9)
  # strwidth resolves via the shaper (positive, and scales with the value)
  w1 <- vctrs::field(unit(1, "strwidth", data = list(label = "Hi", fontsize = 20)), "value")
  w2 <- vctrs::field(unit(2, "strwidth", data = list(label = "Hi", fontsize = 20)), "value")
  expect_gt(w1, 0)
  expect_equal(w2, 2 * w1, tolerance = 1e-9)
  expect_error(unit(1, "strwidth"), "label")
})
