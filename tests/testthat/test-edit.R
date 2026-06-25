px <- function(scene, x, y) rs_pixel(.scene_to_backend(scene), x, y)

test_that("node_names lists named grobs", {
  s <- vl_scene() |>
    draw(rect_grob(name = "bg")) |>
    draw(circle_grob(name = "dot")) |>
    draw(rect_grob()) # unnamed
  expect_equal(node_names(s), c("bg", "dot"))
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
