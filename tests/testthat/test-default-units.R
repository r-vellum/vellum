# VL-6: a bare numeric means "npc" in every constructor, as in grid, and each
# constructor takes a `default_units` to read bare numbers in some other unit.

# Exported constructors that take bare-numeric positions or sizes. contour_grob()
# is the one *_grob without `default_units`: it takes the data frame from
# vl_contour(), whose coordinates are data values and always drawn "native".
.unit_constructors <- function() {
  ns <- getNamespaceExports("vellum")
  grobs <- sort(grep("_grob$", ns, value = TRUE))
  c(setdiff(grobs, "contour_grob"), "vl_viewport")
}

test_that("every exported constructor defaults default_units to npc", {
  fns <- .unit_constructors()
  # Guard the list itself: a silently empty export scan would pass vacuously.
  expect_true(all(c("lines_grob", "rect_grob", "sector_grob") %in% fns))
  for (fn in fns) {
    f <- formals(getExportedValue("vellum", fn))
    expect_true(
      "default_units" %in% names(f),
      label = paste(fn, "has default_units")
    )
    expect_identical(
      f$default_units,
      "npc",
      label = paste0(fn, "(default_units)")
    )
  }
})

test_that("default_units is validated", {
  expect_error(rect_grob(default_units = "bogus"), "default_units")
  expect_error(
    lines_grob(0:1, 0:1, default_units = c("npc", "mm")),
    "default_units"
  )
  expect_error(circle_grob(default_units = NA_character_), "default_units")
  expect_error(vl_viewport(default_units = 1), "default_units")
})

test_that("a non-numeric coordinate is refused rather than cast", {
  expect_error(lines_grob(c("a", "b"), 0:1), "numeric")
  expect_error(rect_grob(x = "left"), "numeric")
})

# A 400 x 400 px page with one viewport on xscale/yscale 0..10: npc and native
# differ by a factor of ten, so a coordinate read in the wrong unit shows.
.scaled_scene <- function(...) {
  s <- vl_scene(4, 4, dpi = 100) |>
    push(vl_viewport(xscale = c(0, 10), yscale = c(0, 10)))
  for (g in list(...)) {
    s <- draw(s, g)
  }
  pop(s)
}

.geom_of <- function(scene, key) {
  g <- element_geometry(scene)
  g[g$key == key, , drop = FALSE]
}

test_that("bare numerics in lines/polygon/segments/path land at npc", {
  s <- .scaled_scene(
    lines_grob(c(0.2, 0.8), c(0.5, 0.5), key = "ln"),
    polygon_grob(c(0.2, 0.8, 0.5), c(0.2, 0.2, 0.8), key = "pg"),
    segments_grob(0.2, 0.5, 0.8, 0.5, key = "sg"),
    path_grob(c(0.2, 0.8, 0.5), c(0.2, 0.2, 0.8), key = "pt"),
    bezier_grob(c(0.2, 0.5, 0.8), c(0.5, 0.5, 0.5), n = 3),
    spline_grob(c(0.2, 0.8), c(0.5, 0.5), n = 2)
  )
  for (k in c("ln", "pg", "sg", "pt")) {
    expect_equal(range(.geom_of(s, k)$x), c(80, 320), label = k)
  }
})

test_that("default_units = 'native' reads bare numerics on the scale", {
  s <- .scaled_scene(
    lines_grob(c(2, 8), c(5, 5), key = "ln", default_units = "native"),
    polygon_grob(c(2, 8, 5), c(2, 2, 8), key = "pg", default_units = "native"),
    segments_grob(2, 5, 8, 5, key = "sg", default_units = "native"),
    path_grob(c(2, 8, 5), c(2, 2, 8), key = "pt", default_units = "native")
  )
  for (k in c("ln", "pg", "sg", "pt")) {
    expect_equal(range(.geom_of(s, k)$x), c(80, 320), label = k)
  }
  # ...and gives the same picture as wrapping the values in vl_unit().
  explicit <- .scaled_scene(
    lines_grob(
      vl_unit(c(2, 8), "native"),
      vl_unit(c(5, 5), "native"),
      key = "ln"
    )
  )
  expect_equal(.geom_of(explicit, "ln")$x, .geom_of(s, "ln")$x)
})

test_that("a vl_unit() keeps its own unit whatever default_units says", {
  s <- .scaled_scene(
    lines_grob(
      vl_unit(c(0.2, 0.8), "npc"),
      vl_unit(c(0.5, 0.5), "npc"),
      key = "ln",
      default_units = "native"
    )
  )
  expect_equal(range(.geom_of(s, "ln")$x), c(80, 320))
})

test_that("bare numerics in the formerly-npc constructors still mean npc", {
  s <- .scaled_scene(
    rect_grob(0.5, 0.5, 0.6, 0.2, key = "rc"),
    points_grob(c(0.2, 0.8), c(0.5, 0.5), key = "pts")
  )
  expect_equal(.geom_of(s, "rc")$x |> range(), c(80, 320))
  expect_equal(sort(.geom_of(s, "pts")$x), c(80, 320))
})

test_that("an npc radius is a fraction of the shorter side; native uses x", {
  # A 6 x 3 in page (600 x 300 px) with an xscale of 0..10: an npc radius of
  # 0.25 is a quarter of the 300 px height; a native one is 0.25 / 10 of the
  # 600 px width.
  page <- function(...) {
    s <- vl_scene(6, 3, dpi = 100) |>
      push(vl_viewport(xscale = c(0, 10), yscale = c(0, 10)))
    for (g in list(...)) {
      s <- draw(s, g)
    }
    pop(s)
  }
  reach <- function(scene, key) {
    g <- .geom_of(scene, key)
    max(abs(g$x - 300))
  }
  s <- page(
    sector_grob(0.5, 0.5, r0 = 0, r1 = 0.25, key = "npc"),
    sector_grob(
      vl_unit(5, "native"),
      vl_unit(5, "native"),
      r0 = 0,
      r1 = 0.25,
      key = "nat",
      default_units = "native"
    )
  )
  expect_equal(reach(s, "npc"), 75, tolerance = 1e-6)
  expect_equal(reach(s, "nat"), 15, tolerance = 1e-6)
})

test_that("an npc hexagon width/height resolves per axis", {
  # 600 x 300 px: width 0.1 npc spans 60 px, height 0.1 npc spans 30 px.
  s <- vl_scene(6, 3, dpi = 100) |>
    draw(hexagon_grob(0.5, 0.5, width = 0.1, height = 0.1, key = "hx"))
  g <- .geom_of(s, "hx")
  expect_equal(diff(range(g$x)), 60, tolerance = 1e-6)
  expect_equal(diff(range(g$y)), 30, tolerance = 1e-6)
})

test_that("physical defaults ignore default_units", {
  # A bare point `size` stays millimetres even with default_units = "native".
  a <- points_grob(0.5, 0.5, size = 2)
  b <- points_grob(5, 5, size = 2, default_units = "native")
  expect_equal(a@size, vl_unit(2, "mm"))
  expect_equal(b@size, vl_unit(2, "mm"))
  expect_equal(b@x, vl_unit(5, "native"))
  # Caps likewise.
  sg <- segments_grob(0, 0, 1, 1, end_cap = 3, default_units = "native")
  expect_equal(sg@end_cap, vl_unit(3, "mm"))
})

test_that("vl_path_op hands its result back in the operands' unit", {
  sq <- function(x0, s, unit) {
    list(
      x = vl_unit(c(x0, x0 + s, x0 + s, x0), unit),
      y = vl_unit(c(x0, x0, x0 + s, x0 + s), unit)
    )
  }
  nat <- vl_path_op(sq(1, 4, "native"), sq(3, 4, "native"), "union")
  expect_true(all(
    vctrs::field(nat@x, "unit") == vellum:::.unit_codes[["native"]]
  ))
  bare <- vl_path_op(
    list(x = c(0.1, 0.5, 0.5, 0.1), y = c(0.1, 0.1, 0.5, 0.5)),
    list(x = c(0.3, 0.7, 0.7, 0.3), y = c(0.3, 0.3, 0.7, 0.7)),
    "union"
  )
  expect_true(all(
    vctrs::field(bare@x, "unit") == vellum:::.unit_codes[["npc"]]
  ))
})
