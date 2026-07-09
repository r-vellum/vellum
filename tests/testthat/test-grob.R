test_that("grob constructors coerce numerics to units and recycle", {
  r <- rect_grob(x = c(0.2, 0.8), width = 0.3)
  expect_s3_class(r@x, "vellum_unit")
  expect_equal(vctrs::vec_size(r@x), 2L)

  cg <- circle_grob(x = c(1, 2, 3), y = 0, r = vl_unit(2, "mm"))
  expect_equal(vctrs::vec_size(cg@x), 3L)
  expect_equal(vctrs::vec_size(cg@r), 3L) # recycled

  expect_error(lines_grob(x = 1:3, y = 1:2), "same length")
})

test_that("point shape is validated (constructor and S7 class)", {
  expect_error(points_grob(0.5, 0.5, shape = "star"), "shape")
  # a bad shape reaching the class directly is caught too (was a cryptic if(NA))
  expect_error(
    grob_points(x = vl_unit(0.5, "npc"), y = vl_unit(0.5, "npc"), shape = "star"),
    "shape"
  )
  expect_no_error(points_grob(c(0, 1), 0.5, shape = c("circle", "diamond")))
})

test_that("grobs carry vl_gpar and name", {
  g <- rect_grob(gp = vl_gpar(fill = "red", lwd = 2), name = "box")
  expect_equal(g@gp@fill, "red")
  expect_equal(g@name, "box")
})

test_that("text_grob keeps label/just/rot", {
  t <- text_grob("hi", just = c("left", "top"), rot = 90)
  expect_equal(t@label, "hi")
  expect_equal(t@just, c("left", "top"))
  expect_equal(t@rot, 90)
})
