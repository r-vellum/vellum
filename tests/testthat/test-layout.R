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
