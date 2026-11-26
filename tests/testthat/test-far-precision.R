# Geometry placed far from the origin and brought back onto the page (VR-45).
# Coordinates used to be narrowed to f32 before the viewport's offset was
# applied, so a mark 1e7 px into a viewport placed 1e7 px off the page snapped
# to whole pixels, and at 1e9 px to 64 px.

fill <- vl_gpar(fill = "red", col = NA)
base <- vl_scene(2, 2, dpi = 72)
rect_at <- function(s, x, y) {
  s |>
    draw(rect_grob(
      x = vl_unit(x, "pt"),
      y = vl_unit(y, "pt"),
      width = vl_unit(20.25, "pt"),
      height = vl_unit(10.5, "pt"),
      gp = fill,
      name = "r"
    ))
}
first_d <- function(s) {
  svg <- scene_svg(s)
  regmatches(svg, regexpr('<path d="[^"]*"', svg))
}
ref <- rect_at(base, 50.3, 60.7)

test_that("a mark far inside a far viewport lands where a near one does (VR-45)", {
  for (off in c(1e5, 1e7, 1e9)) {
    far <- base |>
      push(vl_viewport(
        x = vl_unit(-off, "pt"),
        y = vl_unit(-off, "pt"),
        width = vl_unit(2 * off, "pt"),
        height = vl_unit(2 * off, "pt")
      )) |>
      rect_at(2 * off + 50.3, 2 * off + 60.7)
    expect_identical(first_d(far), first_d(ref), info = format(off))
    expect_identical(scene_raster(far), scene_raster(ref), info = format(off))
    # hit testing walks the same rebased frame
    expect_identical(
      hit_test(far, 50.3 / 144, 60.7 / 144),
      "r",
      info = format(off)
    )
  }
})

test_that("nested viewports cancelling a large offset are composed exactly (VR-45)", {
  for (off in c(123456789.3, 9876543210.7)) {
    nested <- base |>
      push(vl_viewport(
        x = vl_unit(off + 0.3, "pt"),
        y = vl_unit(off + 0.3, "pt")
      )) |>
      push(vl_viewport(
        x = vl_unit(-off + 144, "pt"),
        y = vl_unit(-off + 144, "pt")
      )) |>
      rect_at(50, 60.4)
    expect_identical(first_d(nested), first_d(ref), info = format(off))
  }
})

test_that("a far viewport's clip keeps its edge on the page (VR-45)", {
  # A viewport from -1e9 px to 72 px, clipped: its right edge halves the page.
  off <- 1e9
  s <- base |>
    push(vl_viewport(
      x = vl_unit((72 - off) / 2, "pt"),
      width = vl_unit(off + 72, "pt"),
      clip = TRUE
    )) |>
    draw(rect_grob(
      x = vl_unit(off / 2, "pt"),
      width = vl_unit(off + 1000, "pt"),
      gp = fill
    ))
  a <- scene_raster(s)
  red <- a[1, , 72] > 128 & a[2, , 72] < 128
  expect_identical(sum(red), 72L)
  expect_true(all(red[1:72]))
})

test_that("a huge circle or rect with an edge on the page keeps that edge (VR-45)", {
  row_ink <- function(s) {
    # red on white: the green channel drops with coverage
    a <- scene_raster(s)
    sum(255 - a[2, , 72]) / 255
  }
  for (off in c(1e7, 1e9)) {
    circle <- base |>
      draw(circle_grob(
        x = vl_unit(off + 50.3, "pt"),
        r = vl_unit(off, "pt"),
        gp = fill
      ))
    expect_lt(abs(row_ink(circle) - (144 - 50.3)), 0.1)
    # the batched build (several circles in one grob)
    circles <- base |>
      draw(circle_grob(
        x = vl_unit(c(off + 50.3, 10), "pt"),
        y = c(0.5, 0.1),
        r = vl_unit(c(off, 1), "pt"),
        gp = fill
      ))
    expect_lt(abs(row_ink(circles) - (144 - 50.3)), 0.1)
    # a rect from far off the page to 70.55 px (the unit-rect fast path)
    rect <- base |>
      draw(rect_grob(
        x = vl_unit(70.55 - (off + 20.25) / 2, "pt"),
        width = vl_unit(off + 20.25, "pt"),
        height = 0.5,
        gp = fill
      ))
    expect_lt(abs(row_ink(rect) - 70.55), 0.1)
  }
})
