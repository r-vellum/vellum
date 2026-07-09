test_that(".unit_codes match the documented Rust ABI (Unit::from_code)", {
  # These integer codes are shared with src/rust/src/units.rs. If this breaks,
  # the two sides have drifted.
  expect_equal(
    .unit_codes[c("npc", "native", "mm", "in", "pt")],
    c(npc = 0L, native = 1L, mm = 2L, `in` = 3L, pt = 4L)
  )
})

test_that("per-axis units: x in native, y in npc, render to the right pixel", {
  # centre: native x = 5 -> device x 50; npc y = 0.9 -> near the top, device y 10
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |> # 100 x 100
    push(vl_viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
    draw(rect_grob(
      x = vl_unit(5, "native"), y = vl_unit(0.9, "npc"),
      width = vl_unit(0.16, "npc"), height = vl_unit(0.16, "npc"),
      gp = vl_gpar(fill = "red", col = NA)
    ))
  expect_equal(px(s, 50, 10)[1:3], c(255L, 0L, 0L))
  expect_equal(px(s, 50, 90)[1:3], c(255L, 255L, 255L)) # bottom is empty
})

test_that("each unit code resolves to the expected length in the backend", {
  # Centre x of a small red band drawn at position `xu`, on a 200px-wide device
  # at 100 dpi. Absolute positions are measured from the left edge.
  band_centre <- function(xu) {
    s <- vl_scene(2, 1, dpi = 100, bg = "white") |> # 200 x 100
      draw(rect_grob(
        x = xu, y = vl_unit(0.5, "npc"),
        width = vl_unit(6, "pt"), height = vl_unit(1, "npc"),
        gp = vl_gpar(fill = "red", col = NA)
      ))
    # red fill: detect ink via the GREEN channel (0 in red, 255 in white bg)
    green <- scene_raster(s)[2, , ]
    cols <- which(apply(green, 1, min) < 100)
    mean(range(cols))
  }
  expect_equal(band_centre(vl_unit(1, "in")), 100, tolerance = 2) # 1in = 100px
  expect_equal(band_centre(vl_unit(72, "pt")), 100, tolerance = 2) # 72pt = 1in
  expect_equal(band_centre(vl_unit(25.4, "mm")), 100, tolerance = 2) # 25.4mm = 1in
  expect_equal(band_centre(vl_unit(0.25, "npc")), 50, tolerance = 2) # 0.25*200
})

test_that("a compound base + mm unit offsets by an exact device length (B1)", {
  # Centre x of a 6pt-wide red band positioned at `xu`, on a 200px@100dpi device.
  band_centre <- function(xu, xscale = NULL) {
    s <- vl_scene(2, 1, dpi = 100, bg = "white")
    if (!is.null(xscale)) s <- push(s, vl_viewport(xscale = xscale, yscale = c(0, 1)))
    s <- draw(s, rect_grob(
      x = xu, y = vl_unit(0.5, "npc"),
      width = vl_unit(6, "pt"), height = vl_unit(1, "npc"),
      gp = vl_gpar(fill = "red", col = NA)
    ))
    green <- scene_raster(s)[2, , ]
    cols <- which(apply(green, 1, min) < 100)
    mean(range(cols))
  }
  # npc 0.25 = 50px, plus an exact 25.4mm = 100px, lands at 150px
  expect_equal(band_centre(vl_unit(0.25, "npc") + vl_unit(25.4, "mm")), 150, tolerance = 2)
  # subtracting mm moves left: 0.5npc (100px) - 12.7mm (50px) = 50px
  expect_equal(band_centre(vl_unit(0.5, "npc") - vl_unit(12.7, "mm")), 50, tolerance = 2)
  # the mm offset is scale-independent: native 5 + 12.7mm is 50px past the anchor
  # whether the anchor sits at 100px (xscale 0..10) or 10px (xscale 0..100)
  expect_equal(band_centre(vl_unit(5, "native") + vl_unit(12.7, "mm"), c(0, 10)), 150, tolerance = 2)
  expect_equal(band_centre(vl_unit(5, "native") + vl_unit(12.7, "mm"), c(0, 100)), 60, tolerance = 2)
})

test_that("a compound y offset moves up (R's y-up convention)", {
  # a point at npc y 0.5 (=50px) + 10mm should sit *above* centre (smaller device y)
  yc <- function(yu) {
    s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
      draw(points_grob(vl_unit(0.5, "npc"), yu, size = vl_unit(2, "mm"), gp = vl_gpar(fill = "red")))
    m <- scene_model(s |> draw(points_grob(vl_unit(0.5, "npc"), yu, size = vl_unit(2, "mm"),
                                            gp = vl_gpar(fill = "red"), key = "p")))
    m$elements$y[!is.na(m$elements$key)][1]
  }
  base <- yc(vl_unit(0.5, "npc"))
  up <- yc(vl_unit(0.5, "npc") + vl_unit(10, "mm"))
  expect_lt(up, base) # up = smaller device-y
  expect_equal(base - up, 10 / 25.4 * 100, tolerance = 1) # ~39.4px
})

test_that("per-vertex units within a polyline (mixed axes) work", {
  # a horizontal line at npc y = 0.5 across native x = 2..8
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(vl_viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
    draw(lines_grob(
      x = vl_unit(c(2, 8), "native"), y = vl_unit(c(0.5, 0.5), "npc"),
      gp = vl_gpar(col = "black", lwd = 4)
    ))
  expect_lt(px(s, 50, 50)[1], 100) # ink mid-line
  expect_equal(px(s, 50, 10)[1:3], c(255L, 255L, 255L)) # not near top
})
