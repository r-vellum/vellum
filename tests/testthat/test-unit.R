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
  expect_equal(
    vctrs::field(vl_unit(0.5, "npc") - vl_unit(3, "mm"), "offset"),
    -3
  )
  expect_equal(
    vctrs::field(vl_unit(0, "native") + vl_unit(1, "in"), "offset"),
    25.4
  )

  # offsets accumulate; adding another native adds the base, keeps the offset
  expect_equal(
    format(vl_unit(1, "native") + vl_unit(2, "mm") + vl_unit(3, "mm")),
    "1native+5mm"
  )
  expect_equal(
    format(vl_unit(1, "native") + vl_unit(2, "mm") + vl_unit(4, "native")),
    "5native+2mm"
  )

  # scaling scales the base and the offset together
  expect_equal(
    format(2 * (vl_unit(1, "native") + vl_unit(3, "mm"))),
    "2native+6mm"
  )

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
  expect_equal(
    vctrs::field(vl_unit(1, "char", data = list(fontsize = 36)), "value"),
    12.7,
    tolerance = 1e-9
  )
  # strwidth resolves via the shaper (positive, and scales with the value)
  w1 <- vctrs::field(
    vl_unit(1, "strwidth", data = list(label = "Hi", fontsize = 20)),
    "value"
  )
  w2 <- vctrs::field(
    vl_unit(2, "strwidth", data = list(label = "Hi", fontsize = 20)),
    "value"
  )
  expect_gt(w1, 0)
  expect_equal(w2, 2 * w1, tolerance = 1e-9)
  expect_error(vl_unit(1, "strwidth"), "label")
})

# --- vl_convert() (Phase 2) --------------------------------------------------

test_that("vl_convert() handles absolute units with no scene", {
  expect_equal(vl_convert(vl_unit(1, "in"), "mm"), 25.4)
  expect_equal(vl_convert(vl_unit(25.4, "mm"), "in"), 1)
  expect_equal(vl_convert(vl_unit(1, "in"), "pt"), 72)
  expect_equal(vl_convert(vl_unit(c(1, 2), "cm"), "mm"), c(10, 20))
  expect_equal(vl_convert(numeric(0), "mm"), numeric(0))
})

test_that("vl_convert() resolves npc against the page, per axis", {
  s <- vl_scene(4, 3, dpi = 100)
  expect_equal(vl_convert(vl_unit(0.5, "npc"), "mm", s), 4 * 25.4 / 2)
  expect_equal(
    vl_convert(vl_unit(0.5, "npc"), "mm", s, axis = "y"),
    3 * 25.4 / 2
  )
  expect_equal(vl_convert(vl_unit(1, "in"), "px", s), 100)
  expect_equal(vl_convert(vl_unit(0.3, "npc"), "npc", s), 0.3)
})

test_that("vl_convert() resolves against a named viewport", {
  s <- vl_scene(4, 3, dpi = 100) |>
    push(vl_viewport(width = 0.5, xscale = c(10, 20), name = "panel"))
  # Half of a 4in page is 2in = 50.8mm; half of that again is 25.4mm.
  expect_equal(vl_convert(vl_unit(0.5, "npc"), "mm", s, name = "panel"), 25.4)
})

test_that("vl_convert() distinguishes a native length from a native position", {
  s <- vl_scene(4, 3, dpi = 100) |>
    push(vl_viewport(width = 0.5, xscale = c(10, 20), name = "panel"))
  # Panel is 50.8mm across a scale spanning 10 units.
  expect_equal(
    vl_convert(vl_unit(12, "native"), "mm", s, name = "panel"),
    12 / 10 * 50.8
  )
  expect_equal(
    vl_convert(
      vl_unit(12, "native"),
      "mm",
      s,
      name = "panel",
      what = "position"
    ),
    (12 - 10) / 10 * 50.8
  )
  # Round-trips both ways.
  expect_equal(
    vl_convert(
      vl_unit(50.8, "mm"),
      "native",
      s,
      name = "panel",
      what = "position"
    ),
    20
  )
})

test_that("vl_convert() carries the absolute offset of a compound unit", {
  s <- vl_scene(4, 3, dpi = 100)
  expect_equal(
    vl_convert(vl_unit(1, "npc") + vl_unit(2, "mm"), "mm", s),
    4 * 25.4 + 2
  )
})

test_that("vl_convert() errors informatively without the context it needs", {
  s <- vl_scene(4, 3)
  expect_error(vl_convert(vl_unit(1, "npc"), "mm"), "scene")
  expect_error(vl_convert(vl_unit(1, "null"), "mm", s), "null")
  expect_error(
    vl_convert(vl_unit(1, "npc"), "mm", s, name = "nope"),
    "No viewport named"
  )
})
