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

test_that("a far clipped viewport keeps a rect clip on every backend (VR-45)", {
  # The same 72 x 72 pt clipped box, placed near or 1e6 pt off the page: the
  # far one is rebased, but still clips as a rect, so PowerPoint and the
  # display list write exactly what they write for the near one.
  u <- function(v) vl_unit(v, "pt")
  far_vp <- vl_viewport(
    x = u((72 - 1e6) / 2),
    y = u((72 - 1e6) / 2),
    width = u(1e6 + 72),
    height = u(1e6 + 72),
    clip = TRUE
  )
  near_vp <- vl_viewport(
    x = u(36),
    y = u(36),
    width = u(72),
    height = u(72),
    clip = TRUE
  )
  mk <- function(vp, o) {
    base |>
      push(vp) |>
      draw(circle_grob(
        u(o + 36),
        u(o + 36),
        u(20),
        gp = vl_gpar(fill = "blue", col = "red", lwd = 2)
      )) |>
      draw(text_grob("Hi", u(o + 30), u(o + 30), gp = vl_gpar(col = "red"))) |>
      draw(points_grob(u(o + c(20, 50)), u(o + c(20, 50)), key = c("a", "b")))
  }
  slide <- function(s) {
    f <- withr::local_tempfile(fileext = ".pptx")
    expect_no_warning(render(s, f))
    paste(
      readLines(unz(f, "ppt/slides/slide1.xml"), warn = FALSE),
      collapse = ""
    )
  }
  far <- mk(far_vp, 1e6)
  near <- mk(near_vp, 0)
  expect_identical(slide(far), slide(near))
  expect_identical(scene_display_list(far), scene_display_list(near))
  expect_identical(scene_raster(far), scene_raster(near))
})
