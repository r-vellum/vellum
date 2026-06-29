# sector_grob: batched annular sectors (pie / donut / rose wedges). Per-sector
# fill, angles in radians (0 at 3 o'clock, CCW), r0 = 0 -> pie, r0 == r1 -> arc.

test_that("a pie slice (r0 = 0) fills inside its wedge but not outside", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(sector_grob(x = 0.5, y = 0.5, r0 = 0, r1 = 0.45,
                     theta0 = -pi / 6, theta1 = pi / 6,
                     gp = gpar(fill = "blue", col = NA)))
  expect_equal(scene_len(s), 1L)
  expect_equal(px(s, 75, 50)[1:3], c(0L, 0L, 255L))       # right of centre: inside
  expect_equal(px(s, 25, 50)[1:3], c(255L, 255L, 255L))   # left of centre: outside
})

test_that("an annulus (r0 > 0) leaves a hollow centre", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(sector_grob(x = 0.5, y = 0.5, r0 = 0.25, r1 = 0.45,
                     theta0 = 0, theta1 = 2 * pi,
                     gp = gpar(fill = "red", col = NA)))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 255L, 255L))   # centre is hollow
  expect_equal(px(s, 85, 50)[1:3], c(255L, 0L, 0L))       # ring filled red
})

test_that("per-sector fill colours a whole pie in one batched grob", {
  # two opposite wedges, two colours, one call -> one primitive
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(sector_grob(x = 0.5, y = 0.5, r0 = 0, r1 = 0.45,
                     theta0 = c(-pi / 6, pi - pi / 6),
                     theta1 = c(pi / 6, pi + pi / 6),
                     fill = c("blue", "green"), gp = gpar(col = NA)))
  expect_equal(scene_len(s), 1L)
  expect_equal(px(s, 75, 50)[1:3], c(0L, 0L, 255L))                       # right wedge blue
  expect_equal(px(s, 25, 50)[1:3], as.integer(grDevices::col2rgb("green")[, 1])) # left wedge green
})

test_that("a uniform stroke draws a border on the wedge", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(sector_grob(x = 0.5, y = 0.5, r0 = 0, r1 = 0.45,
                     theta0 = -pi / 6, theta1 = pi / 6,
                     gp = gpar(fill = "white", col = "black", lwd = 3)))
  r <- scene_raster(s)
  expect_lt(min(r[1, , ]), 100L) # some dark stroke pixel exists
})

test_that("an arc outline (r0 == r1) renders without error", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(sector_grob(x = 0.5, y = 0.5, r0 = 0.4, r1 = 0.4,
                     theta0 = 0, theta1 = pi,
                     gp = gpar(fill = NA, col = "black", lwd = 2)))
  expect_equal(scene_len(s), 1L)
  r <- scene_raster(s)
  expect_lt(min(r[1, , ]), 100L) # the stroked arc paints ink
})

test_that("sectors render to SVG and PDF without error", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(sector_grob(x = 0.5, y = 0.5, r0 = 0.2, r1 = 0.45,
                     theta0 = c(0, pi), theta1 = c(pi, 2 * pi),
                     fill = c("#aa0000", "#0000aa"), gp = gpar(col = "black", lwd = 1)))
  svg <- withr::local_tempfile(fileext = ".svg")
  pdf <- withr::local_tempfile(fileext = ".pdf")
  expect_no_error(render(s, svg))
  expect_no_error(render(s, pdf))
  expect_equal(rawToChar(readBin(pdf, "raw", 5)), "%PDF-")
  txt <- paste(readLines(svg, warn = FALSE), collapse = "\n")
  expect_match(txt, 'fill="#aa0000"') # per-sector fill reaches the SVG
})
