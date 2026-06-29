test_that("a 2x2 null grid places a cell in the right quadrant", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(viewport(layout = grid_layout(unit(c(1, 1), "null"), unit(c(1, 1), "null")))) |>
    push(viewport(row = 2, col = 2)) |> # bottom-right
    draw(rect_grob(gp = gpar(fill = "red", col = NA)))
  expect_equal(px(s, 75, 75)[1:3], c(255L, 0L, 0L)) # bottom-right painted
  expect_equal(px(s, 25, 25)[1:3], c(255L, 255L, 255L)) # top-left empty
})

test_that("mixed absolute + null tracks size columns correctly", {
  # 4in wide at 100 dpi = 400px. Column 1 = 1in (100px) absolute; column 2 =
  # null, takes the remaining 300px.
  s <- vl_scene(width = 4, height = 1, dpi = 100, bg = "white") |>
    push(viewport(layout = grid_layout(unit(c(1, 1), c("in", "null")), unit(1, "null")))) |>
    push(viewport(row = 1, col = 1)) |>
    draw(rect_grob(gp = gpar(fill = "red", col = NA))) |>
    pop() |>
    push(viewport(row = 1, col = 2)) |>
    draw(rect_grob(gp = gpar(fill = "blue", col = NA)))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 0L, 0L)) # within first 100px
  expect_equal(px(s, 250, 50)[1:3], c(0L, 0L, 255L)) # in the null column
})

test_that("a cell can span multiple columns", {
  s <- vl_scene(width = 3, height = 1, dpi = 100, bg = "white") |> # 300px, 3 cols of 100
    push(viewport(layout = grid_layout(unit(c(1, 1, 1), "null"), unit(1, "null")))) |>
    push(viewport(row = 1, col = 1, colspan = 2)) |> # first two cells
    draw(rect_grob(gp = gpar(fill = "red", col = NA)))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 0L, 0L)) # col 1
  expect_equal(px(s, 150, 50)[1:3], c(255L, 0L, 0L)) # col 2 (spanned)
  expect_equal(px(s, 250, 50)[1:3], c(255L, 255L, 255L)) # col 3 empty
})

test_that("layout is resolution-independent (resize recompute)", {
  make <- function(dpi) {
    vl_scene(width = 1, height = 1, dpi = dpi, bg = "white") |>
      push(viewport(layout = grid_layout(unit(c(1, 1), "null"), unit(c(1, 1), "null")))) |>
      push(viewport(row = 1, col = 2)) |> # top-right
      draw(rect_grob(gp = gpar(fill = "red", col = NA)))
  }
  lo <- make(100)
  hi <- make(200)
  # same fractional position is painted at both resolutions
  expect_equal(px(lo, 75, 25)[1:3], c(255L, 0L, 0L))
  expect_equal(px(hi, 150, 50)[1:3], c(255L, 0L, 0L))
  # and the opposite quadrant is empty at both
  expect_equal(px(lo, 25, 75)[1:3], c(255L, 255L, 255L))
  expect_equal(px(hi, 50, 150)[1:3], c(255L, 255L, 255L))
})

# Blue panel bounding box (red channel < 100 = blue, not white bg).
.panel_bbox <- function(s) {
  red <- scene_raster(s)[1, , ]
  b <- which(red < 100, arr.ind = TRUE)
  list(
    w = diff(range(b[, 1])), h = diff(range(b[, 1])) * 0 + diff(range(b[, 2])),
    ymin = min(b[, 2]), ymax = max(b[, 2])
  )
}

test_that("grid_layout(respect = TRUE) locks the panel aspect from null weights", {
  # left gutter (abs) + panel col null weight 2; panel row null weight 1 + bottom
  # gutter (abs). respect=TRUE -> panel device aspect 2:1.
  mk <- function(respect, w = 4, h = 4) {
    vl_scene(w, h, dpi = 100, bg = "white") |>
      push(viewport(layout = grid_layout(
        widths  = unit(c(0.5, 2), c("in", "null")),
        heights = unit(c(1, 0.5), c("null", "in")),
        respect = respect
      ))) |>
      push(viewport(row = 1, col = 2)) |>
      draw(rect_grob(gp = gpar(fill = "blue", col = NA)))
  }
  off <- .panel_bbox(mk(FALSE))
  on <- .panel_bbox(mk(TRUE))
  expect_lt(abs(off$w / off$h - 1), 0.1) # off: panel fills its (≈square) cell
  expect_lt(abs(on$w / on$h - 2), 0.15) # on: 2:1 from the null weights
})

test_that("respect centers the grid, keeping the gutter attached to the panel", {
  s <- vl_scene(4, 4, dpi = 100, bg = "white") |>
    push(viewport(layout = grid_layout(
      widths  = unit(c(0.5, 2), c("in", "null")),
      heights = unit(c(1, 0.5), c("null", "in")),
      respect = TRUE
    ))) |>
    push(viewport(row = 1, col = 2)) |>
    draw(rect_grob(gp = gpar(fill = "blue", col = NA)))
  b <- .panel_bbox(s)
  H <- 400 # 4in * 100dpi
  top_margin <- b$ymin - 1
  bottom_margin <- H - (b$ymax + 50) # +50px = the 0.5in bottom gutter still attached
  expect_lt(abs(top_margin - bottom_margin), 4) # whole grid centered
})

test_that("respect re-applies at the device size (reflow keeps the aspect)", {
  asp <- function(w, h) {
    s <- vl_scene(w, h, dpi = 100, bg = "white") |>
      push(viewport(layout = grid_layout(unit(2, "null"), unit(1, "null"), respect = TRUE))) |>
      push(viewport(row = 1, col = 1)) |>
      draw(rect_grob(gp = gpar(fill = "blue", col = NA)))
    b <- .panel_bbox(s)
    b$w / b$h
  }
  expect_lt(abs(asp(4, 4) - 2), 0.15) # square device
  expect_lt(abs(asp(6, 3) - 2), 0.15) # wide device -> still 2:1 (re-solved)
})

test_that("grid_layout respect is validated", {
  expect_error(grid_layout(respect = "yes"), "respect")
  expect_error(grid_layout(respect = c(TRUE, FALSE)), "respect")
})
