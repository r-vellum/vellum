# The as_vellum_scene() compiler-backend seam: the stable entry point a
# higher-level package (e.g. the grammar layer) implements to compile its own
# object into a vellum scene, so render(x, path) works for any such x.

test_that("as_vellum_scene() is identity on a vellum_scene", {
  sc <- vl_scene(2, 1)
  expect_identical(as_vellum_scene(sc), sc)
})

test_that("render() dispatches an arbitrary object through as_vellum_scene()", {
  skip_if_not_installed("png")
  # A stand-in for a downstream grammar spec: a foreign S7 class that knows how to
  # compile itself into a vellum scene. (The method registers on the package
  # generic for this test-local class; harmless to leave registered.)
  Spec <- S7::new_class("Spec", properties = list(fill = S7::class_character))
  S7::method(as_vellum_scene, Spec) <- function(x, ...) {
    vl_scene(2, 1, dpi = 80, bg = "white") |>
      draw(rect_grob(gp = vl_gpar(fill = x@fill, col = NA)))
  }
  f <- withr::local_tempfile(fileext = ".png")
  expect_no_error(render(Spec(fill = "blue"), f))
  px <- png::readPNG(f)
  expect_gt(px[40, 80, 3], 0.8) # centre is blue: high blue...
  expect_lt(px[40, 80, 1], 0.2) # ...low red
})

test_that("hit_test() and the node functions coerce through as_vellum_scene()", {
  SpecNodes <- S7::new_class(
    "SpecNodes",
    properties = list(fill = S7::class_character)
  )
  S7::method(as_vellum_scene, SpecNodes) <- function(x, ...) {
    vl_scene(2, 1, dpi = 80, bg = "white") |>
      draw(rect_grob(name = "bg", gp = vl_gpar(fill = "white", col = NA))) |>
      draw(points_grob(
        0.5,
        0.5,
        size = vl_unit(20, "pt"),
        name = "dot",
        gp = vl_gpar(fill = x@fill, col = NA)
      ))
  }
  sp <- SpecNodes(fill = "red")
  expect_equal(node_names(sp), c("bg", "dot"))
  expect_true(S7::S7_inherits(get_node(sp, "dot")))
  expect_equal(hit_test(sp, 0.5, 0.5), "dot")
  expect_equal(hit_test(sp, 0.05, 0.05), "bg")

  edited <- edit_node(sp, "dot", gp = vl_gpar(fill = "blue", col = NA))
  expect_true(S7::S7_inherits(edited, vellum_scene))
  expect_equal(get_node(edited, "dot")@gp@fill, "blue")
  expect_error(get_node(sp, "nope"), "No node named")
})
