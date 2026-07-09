test_that("vl_unit() constructs, recycles, and validates", {
  u <- vl_unit(c(1, 2, 3), "native")
  expect_s3_class(u, "vellum_unit")
  expect_equal(vctrs::vec_size(u), 3L)
  expect_equal(vctrs::field(u, "value"), c(1, 2, 3))
  expect_true(all(vctrs::field(u, "unit") == 1L)) # native = 1

  # units recycle against values
  m <- vl_unit(c(0.5, 1), c("npc", "in"))
  expect_equal(vctrs::field(m, "unit"), c(0L, 3L))

  expect_error(vl_unit(1, "furlong"), "Unknown unit")
  # "null" is allowed in the type (for layouts) but rejected as a coordinate
  expect_s3_class(vl_unit(1, "null"), "vellum_unit")
  expect_error(.coord(vl_unit(1, "null")), "only valid in layouts")
})

test_that("format / print show value+unit", {
  expect_equal(format(vl_unit(c(1, 2), c("npc", "mm"))), c("1npc", "2mm"))
})

test_that("c(), [ and slicing work", {
  u <- c(vl_unit(1, "npc"), vl_unit(2, "mm"))
  expect_equal(vctrs::vec_size(u), 2L)
  expect_equal(format(u), c("1npc", "2mm"))
  expect_equal(format(u[2]), "2mm")
})

test_that("arithmetic: scalar scale, same-unit add/sub, unary minus", {
  expect_equal(format(vl_unit(2, "npc") * 3), "6npc")
  expect_equal(format(3 * vl_unit(2, "mm")), "6mm")
  expect_equal(format(vl_unit(10, "pt") / 2), "5pt")
  expect_equal(format(vl_unit(2, "npc") + vl_unit(1, "npc")), "3npc")
  expect_equal(format(-vl_unit(4, "mm")), "-4mm")
})

test_that("a position base + an absolute unit makes a compound (native/npc + mm)", {
  u <- vl_unit(1, "native") + vl_unit(2, "mm")
  expect_equal(vctrs::field(u, "value"), 1)
  expect_equal(vctrs::field(u, "unit"), 1L) # native base
  expect_equal(vctrs::field(u, "offset"), 2) # +2mm
  expect_equal(format(u), "1native+2mm")

  # npc base, subtraction, and inch folded to mm
  expect_equal(vctrs::field(vl_unit(0.5, "npc") - vl_unit(3, "mm"), "offset"), -3)
  expect_equal(vctrs::field(vl_unit(0, "native") + vl_unit(1, "in"), "offset"), 25.4)

  # offsets accumulate; adding another native adds the base, keeps the offset
  expect_equal(format(vl_unit(1, "native") + vl_unit(2, "mm") + vl_unit(3, "mm")), "1native+5mm")
  expect_equal(format(vl_unit(1, "native") + vl_unit(2, "mm") + vl_unit(4, "native")), "5native+2mm")

  # scaling scales the base and the offset together
  expect_equal(format(2 * (vl_unit(1, "native") + vl_unit(3, "mm"))), "2native+6mm")

  # two *different* position bases still can't be reduced
  expect_error(vl_unit(1, "npc") + vl_unit(1, "native"), "position base")
})

test_that("absolute-unit arithmetic resolves to mm at construction", {
  # mm/in/pt (and cm, which is already mm) combine across codes -> mm
  expect_equal(format(vl_unit(10, "mm") + vl_unit(1, "in")), "35.4mm")
  expect_equal(format(vl_unit(2, "cm") - vl_unit(5, "mm")), "15mm")
  expect_equal(vctrs::field(vl_unit(0, "pt") + vl_unit(72, "pt"), "value"), 72) # same-code stays pt
  expect_equal(vctrs::field(vl_unit(0, "pt") + vl_unit(72, "pt"), "unit"), 4L)
  # vectorised + recycled
  expect_equal(
    format(vl_unit(c(1, 2), "in") + vl_unit(1, "mm")),
    c("26.4mm", "51.8mm")
  )
})

test_that("derived units resolve to absolute millimetres at construction", {
  expect_equal(vctrs::field(vl_unit(2, "cm"), "unit"), 2L) # mm code
  expect_equal(vctrs::field(vl_unit(2, "cm"), "value"), 20)
  # 1 char at 36pt = 36/72 in = 0.5in = 12.7mm
  expect_equal(vctrs::field(vl_unit(1, "char", data = list(fontsize = 36)), "value"), 12.7,
               tolerance = 1e-9)
  # strwidth resolves via the shaper (positive, and scales with the value)
  w1 <- vctrs::field(vl_unit(1, "strwidth", data = list(label = "Hi", fontsize = 20)), "value")
  w2 <- vctrs::field(vl_unit(2, "strwidth", data = list(label = "Hi", fontsize = 20)), "value")
  expect_gt(w1, 0)
  expect_equal(w2, 2 * w1, tolerance = 1e-9)
  expect_error(vl_unit(1, "strwidth"), "label")
})
