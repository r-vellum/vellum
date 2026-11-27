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

test_that("far markers and sectors keep their edge on the page (VR-47)", {
  # Red on white, row 72 of a 144 px page: ink from an edge at 50.3 px.
  row_ink <- function(s) {
    a <- scene_raster(s)
    sum(255 - a[2, , 72]) / 255
  }
  u <- function(v) vl_unit(v, "pt")
  stroked <- vl_gpar(fill = "red", col = "red", lwd = 0.01)
  marker <- function(off, shape, gp = fill) {
    base |>
      draw(points_grob(u(off + 50.3), 0.5, size = u(off), shape = shape, gp = gp))
  }
  # the same glyph built near the origin, as before
  near <- function(shape, gp = fill) row_ink(marker(1e4, shape, gp))
  for (off in c(1e5, 1e7, 1e9)) {
    info <- format(off)
    # the unit-shape fast path, and the per-element build
    expect_lt(abs(row_ink(marker(off, "square")) - near("square")), 0.05, label = paste("square", info))
    expect_lt(abs(row_ink(marker(off, "diamond")) - near("diamond")), 0.05, label = paste("diamond", info))
    expect_lt(
      abs(row_ink(marker(off, "square", stroked)) - near("square", stroked)),
      0.05,
      label = paste("stroked square", info)
    )
    # a half disc of radius `off` whose west point is at 50.3 px: drawn
    # with ~4 degree chords, it missed the page by up to 6e5 px
    sector <- base |>
      draw(sector_grob(
        u(off + 50.3),
        0.5,
        r1 = u(off),
        theta0 = pi / 2,
        theta1 = 3 * pi / 2,
        gp = fill
      ))
    expect_lt(abs(row_ink(sector) - (144 - 50.3)), 0.1, label = paste("sector", info))
  }
  # A disc crossing the page centre 22.5 degrees round from its west point,
  # where cubic quarter arcs missed the circle by 2.7e-4 of the radius: the
  # sector and the circle agree with each other and with the true crossing.
  a <- pi / 8
  for (off in c(1e5, 1e9)) {
    at <- list(u(off * cos(a) + 72), u(off * sin(a) + 72))
    circle <- draw(base, circle_grob(at[[1]], at[[2]], r = u(off), gp = fill))
    disc <- draw(base, sector_grob(at[[1]], at[[2]], r1 = u(off), gp = fill))
    # row 72 spans y in [71, 72] px from the top: the edge crosses it at
    # x = 72 - 0.5 * tan(a) on average, ink to its right
    want <- 72 + 0.5 * tan(a)
    expect_lt(abs(row_ink(circle) - want), 0.3, label = paste("circle", off))
    expect_lt(abs(row_ink(disc) - want), 0.3, label = paste("disc", off))
  }
})

test_that("a far edge between two far vertices crosses the page exactly (VR-47)", {
  row_ink <- function(s) {
    a <- scene_raster(s)
    sum(255 - a[2, , 72]) / 255
  }
  u <- function(v) vl_unit(v, "pt")
  # a diamond whose upper-left edge crosses the page centre, both of its
  # vertices r / 2 away; a sector whose first radial edge does, its centre
  # r away. Each vertex alone rounds by up to 64 px at 1e9.
  dia <- function(r) {
    base |>
      draw(points_grob(u(72 + r / 2), u(72 - r / 2), size = u(r), shape = "diamond", gp = fill))
  }
  a <- 0.3
  sec <- function(r) {
    base |>
      draw(sector_grob(
        u(72 - r * cos(a)),
        u(72 - r * sin(a)),
        r1 = u(2 * r),
        theta0 = a,
        theta1 = a + 0.5,
        gp = fill
      ))
  }
  for (r in c(1e5, 1e7, 1e9)) {
    expect_lt(abs(row_ink(dia(r)) - row_ink(dia(1e3))), 0.05, label = paste("diamond", r))
    expect_lt(abs(row_ink(sec(r)) - row_ink(sec(1e3))), 0.05, label = paste("sector", r))
  }
})

test_that("a far circle is split finely only over the page (VR-47)", {
  # r = 1e5 px crossing the page: a few hundred bytes of SVG, not a path
  # of thousands of 1/32 px chords
  a <- pi / 8
  s <- base |>
    draw(circle_grob(
      vl_unit(72 - 1e5 * cos(a), "pt"),
      vl_unit(72 - 1e5 * sin(a), "pt"),
      r = vl_unit(1e5, "pt"),
      gp = fill
    ))
  expect_lt(nchar(scene_svg(s)), 10000)
})

test_that("a far raster image draws the part over the page on every backend (VR-46)", {
  u <- function(v) vl_unit(v, "pt")
  two <- matrix(c("red", "blue"), 1, 2)
  img <- function(w, interpolate = FALSE) {
    base |>
      draw(raster_grob(two, width = u(w), height = 0.5, interpolate = interpolate))
  }
  # red left of the page centre, blue right of it (row 72)
  seam_ok <- function(a, info) {
    al <- if (dim(a)[3] == 4) a[72, , 4] else 1
    red <- a[72, , 1] * al > 0.5 & a[72, , 3] * al < 0.5
    blue <- a[72, , 3] * al > 0.5 & a[72, , 1] * al < 0.5
    expect_true(all(red[3:70]), label = info)
    expect_true(all(blue[75:142]), label = info)
  }
  for (w in c(1e7, 1e10)) {
    s <- img(w)
    a <- scene_raster(s)
    seam_ok(aperm(a, c(3, 2, 1)) / 255, paste("png", w))
    # the SVG image stays near the page
    svg <- scene_svg(s)
    xy <- as.numeric(regmatches(
      svg,
      gregexpr('(?<=<image href="data:image/png;base64,)[^"]*" x="[-0-9.e]+', svg, perl = TRUE)
    )[[1]] |> sub(pattern = '.*x="', replacement = ""))
    expect_true(all(abs(xy) < 1e4), label = paste("svg x", w))
    if (nzchar(Sys.which("rsvg-convert")) && requireNamespace("png", quietly = TRUE)) {
      f <- withr::local_tempfile(fileext = ".svg")
      o <- withr::local_tempfile(fileext = ".png")
      render(s, f)
      system2("rsvg-convert", c("-o", o, f))
      seam_ok(png::readPNG(o), paste("svg", w))
    }
    if (requireNamespace("pdftools", quietly = TRUE)) {
      f <- withr::local_tempfile(fileext = ".pdf")
      render(s, f)
      b <- pdftools::pdf_render_page(f, dpi = 72, numeric = TRUE)
      seam_ok(b, paste("pdf", w))
    }
    # PowerPoint places a picture of the visible part, in EMU range
    f <- withr::local_tempfile(fileext = ".pptx")
    render(s, f)
    d <- withr::local_tempdir()
    utils::unzip(f, exdir = d)
    x <- paste(readLines(file.path(d, "ppt/slides/slide1.xml"), warn = FALSE), collapse = "")
    off <- as.numeric(regmatches(x, gregexpr('(?<=<a:off x=")-?[0-9]+', x, perl = TRUE))[[1]])
    expect_true(all(abs(off) < 1e8), label = paste("pptx", w))
  }
})

test_that("large in-range circles, sectors and round rects follow their arcs (VR-48)", {
  row_ink <- function(s) {
    a <- scene_raster(s)
    sum(255 - a[2, , 72]) / 255
  }
  u <- function(v) vl_unit(v, "pt")
  # Row 72 spans y in [71, 72] px from the top, so y = 72.5 pt up from the
  # bottom; ink runs from the left edge of the page to the arc.
  crossing <- function(cx, cy, r, sign = 1) cx + sign * sqrt(r^2 - (72.5 - cy)^2)
  # A circle through the page centre 22.5 degrees from its east point: the
  # scaled unit circle missed it by 3.1e-3 r (3 px at r = 1e3, the whole
  # row at 3e4) and snapped to exact past PRECISE_PX. Now no jump.
  p <- pi / 8
  for (r in c(1e3, 1e4, 3e4, 6e4, 7e4, 1e5)) {
    cx <- 72 - r * cos(p)
    cy <- 72 - r * sin(p)
    one <- draw(base, circle_grob(u(cx), u(cy), r = u(r), gp = fill))
    expect_lt(abs(row_ink(one) - crossing(cx, cy, r)), 0.1, label = paste("circle", r))
    # the point marker fast path (a solid fill, no stroke)
    pt <- draw(base, points_grob(u(cx), u(cy), size = u(r), shape = "circle", gp = fill))
    expect_lt(abs(row_ink(pt) - crossing(cx, cy, r)), 0.1, label = paste("marker", r))
  }
  # A quarter disc crossing the page in the middle of its first ~4 degree
  # chord, which missed the arc by 6 px at r = 1e4.
  phi <- (pi / 2 / 23) / 2
  for (r in c(1e3, 1e4, 3e4, 6e4, 7e4)) {
    cx <- 72 - r * cos(phi)
    cy <- 72 - r * sin(phi)
    s <- draw(base, sector_grob(u(cx), u(cy), r1 = u(r), theta0 = 0, theta1 = pi / 2, gp = fill))
    expect_lt(abs(row_ink(s) - crossing(cx, cy, r)), 0.1, label = paste("sector", r))
  }
  # A round rect whose top-left corner crosses the page 22.5 degrees from
  # its west end, where cubic corners stray 2.7e-4 r.
  for (r in c(1e4, 6e4)) {
    cx <- 72 + r * cos(p)
    cy <- 72 - r * sin(p)
    s <- draw(base, roundrect_grob(
      u(cx),
      u(cy),
      width = u(2 * r),
      height = u(2 * r),
      r = u(r),
      gp = fill
    ))
    want <- 144 - crossing(cx, cy, r, -1)
    expect_lt(abs(row_ink(s) - want), 0.1, label = paste("roundrect", r))
  }
  # SVG still writes a large circle as a <circle>, and a large sector is
  # split finely only over the page
  r <- 1e4
  one <- draw(base, circle_grob(u(72 - r * cos(p)), u(72 - r * sin(p)), r = u(r), gp = fill))
  expect_match(scene_svg(one), "<circle ")
  s <- draw(base, sector_grob(u(72 - r), u(72), r1 = u(r), gp = fill))
  expect_lt(nchar(scene_svg(s)), 20000)
})

test_that("ordinary circles, sectors and round rects keep their bytes (VR-48)", {
  # Below the thresholds (a scaled unit circle to ~78 px, ~4 degree sector
  # chords to ~410 px, cubic corners to ~920 px) nothing changes: the path
  # is the one main built.
  s <- vl_scene(6, 6, dpi = 72) |>
    draw(sector_grob(0.5, 0.5, r1 = vl_unit(200, "pt"), theta0 = 0, theta1 = 2, gp = fill))
  d <- regmatches(scene_svg(s), regexpr('<path d="[^"]*"', scene_svg(s)))
  expect_identical(lengths(regmatches(d, gregexpr("L", d))), 59L)
  s <- vl_scene(6, 6, dpi = 72) |>
    draw(roundrect_grob(0.5, 0.5, 0.9, 0.9, r = vl_unit(100, "pt"), gp = fill))
  expect_match(scene_svg(s), "C")
})

test_that("far polygons, lines, paths and segments cross the page exactly (VR-50)", {
  row_ink <- function(s) {
    a <- scene_raster(s)
    sum(255 - a[2, , 72]) / 255
  }
  u <- function(v) vl_unit(v, "pt")
  pen <- vl_gpar(col = "red", lwd = 10)
  # The edge x + y = 144.3 through the page centre, between vertices r away
  # either way: each vertex alone rounds by up to 64 px in f32 at 1e9.
  tri <- function(r) list(x = 72.15 + c(-r, r, -r), y = 72.15 + c(r, -r, -r))
  shapes <- list(
    polygon = function(r) {
      v <- tri(r)
      draw(base, polygon_grob(u(v$x), u(v$y), gp = fill))
    },
    path = function(r) {
      v <- tri(r)
      draw(base, path_grob(u(v$x), u(v$y), gp = fill))
    },
    lines = function(r) {
      v <- tri(r)
      draw(base, lines_grob(u(v$x[1:2]), u(v$y[1:2]), gp = pen))
    },
    segments = function(r) {
      v <- tri(r)
      draw(base, segments_grob(u(v$x[1]), u(v$y[1]), u(v$x[2]), u(v$y[2]), gp = pen))
    }
  )
  for (kind in names(shapes)) {
    ref <- row_ink(shapes[[kind]](1e3))
    for (r in c(1e5, 1e7, 1e9)) {
      expect_lt(abs(row_ink(shapes[[kind]](r)) - ref), 0.05, label = paste(kind, r))
    }
  }
  # the polygon's ink ends at the edge
  expect_lt(abs(row_ink(shapes$polygon(1e9)) - (144.3 - 72.5)), 0.1)
})

test_that("a far image never reaches the display list (VR-49)", {
  # Images carry no key, so the display list (the widget's exact marks)
  # never lists one; the widget draws them in its base SVG, which fits a far
  # image to the page (VR-46).
  u <- function(v) vl_unit(v, "pt")
  pt <- points_grob(0.3, 0.3, size = u(5), shape = "circle", gp = fill, key = "a")
  img <- raster_grob(matrix(c("red", "blue"), 1, 2), width = u(1e10), height = 0.5)
  with_img <- base |> draw(img) |> draw(pt)
  without <- base |> draw(pt)
  for (v in 1:2) {
    expect_identical(
      scene_display_list(with_img, version = v),
      scene_display_list(without, version = v)
    )
  }
  svg <- scene_svg(with_img, layer = "unkeyed")
  x <- as.numeric(sub('.*x="', "", regmatches(
    svg,
    gregexpr('(?<=<image href="data:image/png;base64,)[^"]*" x="[-0-9.e]+', svg, perl = TRUE)
  )[[1]]))
  expect_length(x, 1)
  expect_lt(abs(x), 1e4)
})

test_that("a far line or segment is hit where it is drawn (VR-50)", {
  # Both ends 5e8 px away, chosen so their f32 rounding moves the crossing
  # of row 72 by ~25 px: the recorded geometry must follow the drawing.
  u <- function(v) vl_unit(v, "pt")
  pen <- vl_gpar(col = "red", lwd = 1)
  ds <- c(-5e8 - 1.7, 5e8 + 3 * 1.7)
  px <- 72.3 + ds
  py <- 72 + 2 * ds
  for (kind in c("lines", "segments")) {
    s <- switch(
      kind,
      lines = draw(base, lines_grob(u(px), u(144 - py), gp = pen, key = "k")),
      segments = draw(base, segments_grob(
        u(px[1]),
        u(144 - py[1]),
        u(px[2]),
        u(144 - py[2]),
        gp = pen,
        key = "k"
      ))
    )
    a <- scene_raster(s)
    ink <- which(a[1, , 72] > 100 & a[2, , 72] < 200)
    xs <- seq(0, 144, by = 0.25)
    hits <- xs[vapply(xs, function(x) length(hit_test(s, x, 71.5, units = "px")) > 0, TRUE)]
    expect_gt(length(hits), 0)
    expect_lt(abs(mean(hits) - mean(ink - 0.5)), 1.5, label = kind)
  }
})
