test_that("grob constructors coerce numerics to units and recycle", {
  r <- rect_grob(x = c(0.2, 0.8), width = 0.3)
  expect_s3_class(r@x, "vellum_unit")
  expect_equal(vctrs::vec_size(r@x), 2L)

  cg <- circle_grob(x = c(1, 2, 3), y = 0, r = unit(2, "mm"))
  expect_equal(vctrs::vec_size(cg@x), 3L)
  expect_equal(vctrs::vec_size(cg@r), 3L) # recycled

  expect_error(lines_grob(x = 1:3, y = 1:2), "same length")
})

test_that("grobs carry gpar and name", {
  g <- rect_grob(gp = gpar(fill = "red", lwd = 2), name = "box")
  expect_equal(g@gp@fill, "red")
  expect_equal(g@name, "box")
})

test_that("text_grob keeps label/just/rot", {
  t <- text_grob("hi", just = c("left", "top"), rot = 90)
  expect_equal(t@label, "hi")
  expect_equal(t@just, c("left", "top"))
  expect_equal(t@rot, 90)
})
