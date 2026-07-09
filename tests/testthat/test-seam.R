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
