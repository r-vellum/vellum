px <- function(scene, x, y) rs_pixel(.scene_to_backend(scene), x, y)

test_that("node_names lists named grobs", {
  s <- vl_scene() |>
    draw(rect_grob(name = "bg")) |>
    draw(circle_grob(name = "dot")) |>
    draw(rect_grob()) # unnamed
  expect_equal(node_names(s), c("bg", "dot"))
})

test_that("scenes are immutable values: branching does not alias (copy-on-write)", {
  # Two grobs drawn onto the same base must not contaminate each other or the base.
  s1 <- push(vl_scene(), viewport(name = "vp1"))
  a <- draw(s1, rect_grob(name = "A"))
  b <- draw(s1, rect_grob(name = "B"))
  expect_equal(node_names(s1), "vp1")
  expect_equal(node_names(a), c("vp1", "A"))
  expect_equal(node_names(b), c("vp1", "B"))
})

test_that("branching diverges correctly across push/pop", {
  base <- vl_scene() |>
    draw(rect_grob(name = "R0")) |>
    push(viewport(name = "P")) |>
    draw(rect_grob(name = "R1"))
  b1 <- base |> draw(rect_grob(name = "X")) |> pop() |> draw(rect_grob(name = "topX"))
  b2 <- base |> draw(rect_grob(name = "Y"))
  expect_equal(node_names(base), c("R0", "P", "R1"))
  expect_equal(node_names(b1), c("R0", "P", "R1", "X", "topX"))
  expect_equal(node_names(b2), c("R0", "P", "R1", "Y"))
  expect_equal(node_names(base), c("R0", "P", "R1")) # base still intact after both branches
})

test_that("pop(n) never ascends past the root and ignores n < 0", {
  s <- vl_scene() |> push(viewport(name = "p")) |> pop(5) |> draw(rect_grob(name = "g"))
  expect_equal(node_names(s), c("p", "g")) # 'g' lands at the root, not in a phantom frame
  expect_no_error(.scene_to_backend(vl_scene() |> push(viewport()) |> pop(-1)))
})

test_that("get_node returns the named grob; missing errors", {
  s <- vl_scene() |> draw(rect_grob(name = "bg", gp = gpar(fill = "red")))
  expect_equal(get_node(s, "bg")@gp@fill, "red")
  expect_error(get_node(s, "nope"), "No node named")
})

test_that("edit_node changes a property and is reflected in the render", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.5, height = 0.5,
                   gp = gpar(fill = "red", col = NA), name = "box"))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 0L, 0L))

  s2 <- edit_node(s, "box", gp = gpar(fill = "blue", col = NA))
  expect_equal(px(s2, 50, 50)[1:3], c(0L, 0L, 255L))
  # original scene is unchanged (immutability)
  expect_equal(px(s, 50, 50)[1:3], c(255L, 0L, 0L))
})

test_that("named viewports are found by name too", {
  s <- vl_scene() |>
    push(viewport(name = "panel")) |>
    draw(rect_grob(name = "inner"))
  expect_true(all(c("panel", "inner") %in% node_names(s)))
})
