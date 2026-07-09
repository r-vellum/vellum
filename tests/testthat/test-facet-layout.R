# Faceting alignment spike (grammar-readiness).
#
# Proves that a faceted panel grid with content-sized axis gutters aligns purely
# R-side, using the public layout API (grid_layout + grobwidth/grobheight-measured
# tracks + null panel tracks) — no vellum/Rust change needed. This is also the
# reference skeleton the grammar package's panel layout will follow:
#
#   columns = [ y-axis-label gutter (measured) , panel (null) , panel (null) ]
#   rows    = [ panel (null) , panel (null) , x-axis-label gutter (measured) ]
#
# Panels are placed into the null cells; axis labels into the measured gutters.
# Because the gutter tracks are absolute (mm, from grobwidth/grobheight) and the
# panel tracks are equal-weight null, every panel is identical in size and the
# panel column/row boundaries align across the whole grid.

# Build a 2x2 facet skeleton; panels get four distinct colours so we can probe
# every cell boundary exactly.
facet_scene <- function(dpi = 100) {
  ylabs <- c("100", "200")
  xlabs <- c("A", "B")
  gutter_w <- grobwidth(text_grob("200", gp = vl_gpar(fontsize = 12)), mult = 1.5)
  gutter_h <- grobheight(text_grob("A", gp = vl_gpar(fontsize = 12)), mult = 1.8)
  cols <- c(gutter_w, vl_unit(1, "null"), vl_unit(1, "null"))
  rows <- c(vl_unit(1, "null"), vl_unit(1, "null"), gutter_h)
  fills <- c("red", "green", "blue", "orange") # (r1c2, r1c3, r2c2, r2c3)

  s <- vl_scene(width = 4, height = 4, dpi = dpi, bg = "white") |>
    push(vl_viewport(layout = grid_layout(cols, rows)))
  k <- 0L
  for (r in 1:2) for (cc in 2:3) {
    k <- k + 1L
    s <- s |>
      push(vl_viewport(row = r, col = cc)) |>
      draw(rect_grob(gp = vl_gpar(fill = fills[k], col = NA))) |>
      pop()
  }
  # axis labels in the gutters (just exercises the gutter cells)
  for (r in 1:2) {
    s <- s |> push(vl_viewport(row = r, col = 1)) |>
      draw(text_grob(ylabs[r], gp = vl_gpar(fontsize = 12))) |> pop()
  }
  for (cc in 2:3) {
    s <- s |> push(vl_viewport(row = 3, col = cc)) |>
      draw(text_grob(xlabs[cc - 1L], gp = vl_gpar(fontsize = 12))) |> pop()
  }
  list(scene = s, gutter_w = gutter_w, dpi = dpi)
}

# First/last column index whose pixel matches an RGB triple (within tol).
runs <- function(row_rgb, rgb, tol = 30) {
  hit <- which(abs(row_rgb[1, ] - rgb[1]) < tol &
               abs(row_rgb[2, ] - rgb[2]) < tol &
               abs(row_rgb[3, ] - rgb[3]) < tol)
  if (!length(hit)) return(NULL)
  c(min(hit), max(hit))
}

test_that("a 2x2 facet grid with measured axis gutters aligns R-side", {
  f <- facet_scene()
  r <- scene_raster(f$scene) # c(4, 400, 400)
  W <- dim(r)[2]

  # --- a horizontal scan through the FIRST panel row (red | green) ---
  yr1 <- 100
  row1 <- r[1:3, , yr1]
  red <- runs(row1, c(255, 0, 0))
  green <- runs(row1, c(0, 255, 0))
  expect_false(is.null(red))
  expect_false(is.null(green))
  expect_true(red[1] < red[2] && green[1] > red[2]) # red left of green

  # --- same scan through the SECOND panel row (blue | orange) ---
  yr2 <- 250
  row2 <- r[1:3, , yr2]
  blue <- runs(row2, c(0, 0, 255))
  orange <- runs(row2, c(255, 165, 0))
  expect_false(is.null(blue))
  expect_false(is.null(orange))

  # Column boundaries align across the two rows: red|green split == blue|orange split.
  expect_lt(abs(red[2] - blue[2]), 2) # left-panel right edge aligned
  expect_lt(abs(green[1] - orange[1]), 2) # right-panel left edge aligned

  # The two panel columns are equal width (the null tracks are equal weight).
  w_left <- red[2] - red[1]
  w_right <- green[2] - green[1]
  expect_lt(abs(w_left - w_right), 3)

  # The left gutter is content-sized: panels start at ~ the measured label width.
  gutter_px <- vctrs::field(f$gutter_w, "value") / 25.4 * f$dpi
  expect_lt(abs(red[1] - gutter_px), 6) # red panel begins just past the gutter

  # The right panels reach the page edge (no right gutter in this skeleton).
  expect_gt(green[2], W - 4)
})

test_that("facet panel rows are equal height and the x-axis gutter sits at the bottom", {
  f <- facet_scene()
  r <- scene_raster(f$scene)
  H <- dim(r)[3]

  # vertical scan through the LEFT panel column (red over blue)
  xc <- 150
  col <- r[1:3, xc, ]
  red <- runs(col, c(255, 0, 0))
  blue <- runs(col, c(0, 0, 255))
  expect_false(is.null(red))
  expect_false(is.null(blue))
  expect_lt(red[2], blue[1]) # red row above blue row

  # equal panel heights
  expect_lt(abs((red[2] - red[1]) - (blue[2] - blue[1])), 3)

  # bottom rows are the x-label gutter -> background (white), not a panel colour
  expect_equal(r[1:3, xc, H - 2], c(255L, 255L, 255L))
})
