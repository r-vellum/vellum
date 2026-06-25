test_that(".unit_codes match the documented Rust ABI (Unit::from_code)", {
  # These integer codes are shared with src/rust/src/units.rs. If this breaks,
  # the two sides have drifted.
  expect_equal(
    .unit_codes[c("npc", "native", "mm", "in", "pt")],
    c(npc = 0L, native = 1L, mm = 2L, `in` = 3L, pt = 4L)
  )
})

test_that("per-axis units: x in native, y in npc, render to the right pixel", {
  s <- rs_scene(1, 1, dpi = 100, bg = "white") # 100 x 100
  rs_viewport(s, xscale = c(0, 10), yscale = c(0, 10))
  # centre: native x = 5 -> device x 50; npc y = 0.9 -> near the top, device y 10
  rs_rect(s,
    x = unit(5, "native"), y = unit(0.9, "npc"),
    width = unit(0.16, "npc"), height = unit(0.16, "npc"),
    fill = "red", col = NA
  )
  expect_equal(rs_pixel(s, 50, 10)[1:3], c(255L, 0L, 0L))
  expect_equal(rs_pixel(s, 50, 90)[1:3], c(255L, 255L, 255L)) # bottom is empty
})

test_that("each unit code resolves to the expected length in the backend", {
  # Centre x of a small red band drawn at position `xu`, on a 200px-wide device
  # at 100 dpi. Absolute positions are measured from the left edge.
  band_centre <- function(xu) {
    s <- rs_scene(2, 1, dpi = 100, bg = "white") # 200 x 100
    rs_rect(s,
      x = xu, y = unit(0.5, "npc"),
      width = unit(6, "pt"), height = unit(1, "npc"), fill = "red", col = NA
    )
    # red fill: detect ink via the GREEN channel (0 in red, 255 in white bg)
    green <- rs_raster(s)[2, , ]
    cols <- which(apply(green, 1, min) < 100)
    mean(range(cols))
  }
  expect_equal(band_centre(unit(1, "in")), 100, tolerance = 2) # 1in = 100px
  expect_equal(band_centre(unit(72, "pt")), 100, tolerance = 2) # 72pt = 1in
  expect_equal(band_centre(unit(25.4, "mm")), 100, tolerance = 2) # 25.4mm = 1in
  expect_equal(band_centre(unit(0.25, "npc")), 50, tolerance = 2) # 0.25*200
})

test_that("per-vertex units within a polyline (mixed axes) work", {
  s <- rs_scene(1, 1, dpi = 100, bg = "white")
  rs_viewport(s, xscale = c(0, 10), yscale = c(0, 10))
  # a horizontal line at npc y = 0.5 across native x = 2..8
  rs_lines(s,
    x = unit(c(2, 8), "native"), y = unit(c(0.5, 0.5), "npc"),
    col = "black", lwd = 4
  )
  expect_lt(rs_pixel(s, 50, 50)[1], 100) # ink mid-line
  expect_equal(rs_pixel(s, 50, 10)[1:3], c(255L, 255L, 255L)) # not near top
})
