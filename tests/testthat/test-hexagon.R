# hexagon_grob: batched regular hexagons for hex-binning. Per-hex fill, flat- vs
# pointy-top orientation, size = circumradius in mm.

test_that("a single flat-top hexagon fills its centre", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(hexagon_grob(0.5, 0.5, size = vl_unit(12, "mm"), gp = vl_gpar(fill = "red", col = NA)))
  r <- scene_raster(s)
  expect_equal(r[1:3, 100, 100], c(255L, 0L, 0L)) # centre filled red
  expect_equal(r[1:3, 4, 4], c(255L, 255L, 255L)) # far corner is background
})

test_that("per-hex fill colours one mesh in a single batched grob", {
  # The headline: two hexes, two colours, ONE call -> one primitive.
  s <- vl_scene(4, 2, dpi = 100, bg = "white") |>
    draw(hexagon_grob(x = c(0.25, 0.75), y = c(0.5, 0.5), size = vl_unit(8, "mm"),
                      fill = c("red", "blue"), gp = vl_gpar(col = NA)))
  expect_equal(scene_len(s), 1L) # batched: one grob, not two
  r <- scene_raster(s) # 400 x 200 px
  expect_equal(r[1:3, 100, 100], c(255L, 0L, 0L))   # left hex red
  expect_equal(r[1:3, 300, 100], c(0L, 0L, 255L))   # right hex blue
})

# Filled silhouette extent (black hex on white bg) at the centre row / column.
.filled_w <- function(r, cy) sum(r[1, , cy] < 128)
.filled_h <- function(r, cx) sum(r[1, cx, ] < 128)

test_that("orientation flips the silhouette aspect (flat wider, pointy taller)", {
  mk <- function(orient) {
    vl_scene(2, 2, dpi = 100, bg = "white") |>
      draw(hexagon_grob(0.5, 0.5, size = vl_unit(12, "mm"), orientation = orient,
                        gp = vl_gpar(fill = "black", col = NA))) |>
      scene_raster()
  }
  flat <- mk("flat"); pointy <- mk("pointy")
  expect_gt(.filled_w(flat, 100), .filled_h(flat, 100))     # flat-top: wider than tall
  expect_gt(.filled_h(pointy, 100), .filled_w(pointy, 100)) # pointy-top: taller than wide
})

test_that("many hexes render in one batched call", {
  g <- expand.grid(x = seq(0.1, 0.9, by = 0.2), y = seq(0.1, 0.9, by = 0.2))
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(hexagon_grob(g$x, g$y, size = vl_unit(3, "mm"), gp = vl_gpar(fill = "darkgreen", col = NA)))
  expect_equal(scene_len(s), 1L) # 25 hexes, one grob
  r <- scene_raster(s)
  expect_gt(r[2, 100, 100], 0L)  # a centre hex (0.5,0.5) is filled (green channel)
  expect_gt(r[2, 20, 20], 0L)    # a corner hex (0.1,0.9 -> top-left) is filled
})

test_that("uniform stroke draws a border around the fill", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(hexagon_grob(0.5, 0.5, size = vl_unit(15, "mm"),
                      gp = vl_gpar(fill = "grey", col = "black", lwd = 3)))
  r <- scene_raster(s)
  # The flat-top left vertex sits on the centre row; just inside it the stroke
  # (black) should darken the grey fill. Scan the centre row for a near-black px.
  row <- r[1, , 100] # red channel across the centre row
  expect_true(any(row < 40 & row > 0)) # a dark (stroked) pixel exists
})

test_that("NULL fill falls back to gp$fill", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(hexagon_grob(0.5, 0.5, size = vl_unit(12, "mm"), gp = vl_gpar(fill = "orange", col = NA)))
  px <- scene_raster(s)[1:3, 100, 100]
  expect_equal(px, as.integer(grDevices::col2rgb("orange")[, 1])) # orange centre
})

test_that("width/height override size with per-axis extent (non-regular hex)", {
  # Equal *native* width & height on a 2:1-wide panel whose scales are square
  # (1x1): x and y resolve to different device lengths, so the flat-top
  # silhouette comes out twice as wide as it is tall — a stretch the regular
  # size-only path (single x-scale radius) cannot produce.
  s <- vl_scene(4, 2, dpi = 100, bg = "white") |>
    push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1))) |>
    draw(hexagon_grob(vl_unit(0.5, "native"), vl_unit(0.5, "native"),
                      width = vl_unit(0.4, "native"), height = vl_unit(0.4, "native"),
                      orientation = "flat", gp = vl_gpar(fill = "black", col = NA)))
  r <- scene_raster(s) # 400 x 200 px panel, scales 1x1
  # 0.4 native in x -> 0.4 * 400 = 160 px full width; 0.4 native in y -> 0.4 * 200
  # = 80 px full height. Flat-top: full width == device width, full height ==
  # device height.
  expect_equal(.filled_w(r, 100), 160, tolerance = 2 / 160) # ~160 px (AA edge)
  expect_equal(.filled_h(r, 200), 80, tolerance = 2 / 80)   # ~80 px (half of width)
})

test_that("width and height must be supplied together", {
  expect_error(hexagon_grob(0.5, 0.5, width = vl_unit(1, "native")),
               "supplied together")
  expect_error(hexagon_grob(0.5, 0.5, height = vl_unit(1, "native")),
               "supplied together")
})

test_that("per-hex fill renders to SVG and PDF without error", {
  s <- vl_scene(3, 2, dpi = 100, bg = "white") |>
    draw(hexagon_grob(x = c(0.3, 0.7), y = 0.5, size = vl_unit(6, "mm"),
                      fill = c("#aa0000", "#0000aa"), gp = vl_gpar(col = "black", lwd = 1)))
  svg <- withr::local_tempfile(fileext = ".svg")
  pdf <- withr::local_tempfile(fileext = ".pdf")
  expect_no_error(render(s, svg))
  expect_no_error(render(s, pdf))
  expect_equal(rawToChar(readBin(pdf, "raw", 5)), "%PDF-")
  txt <- paste(readLines(svg, warn = FALSE), collapse = "\n")
  expect_match(txt, 'fill="#aa0000"') # per-hex fill reaches the SVG
  expect_match(txt, 'fill="#0000aa"')
})
