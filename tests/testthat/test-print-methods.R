# The S3 print methods are easy to disable by accident: `S7::method(print, cls)
# <- fn` is a replacement call, so it binds `print` in the namespace, and R's
# loader then files every `S3method(print, <class>)` into vellum's own methods
# table rather than base's — dispatch stops finding them while the methods
# themselves still look fine. See the note next to the S7 methods in `api.R`.

test_that("no base generic is shadowed by a stray namespace binding", {
  ns <- asNamespace("vellum")
  for (g in c("print", "plot", "format")) {
    expect_null(get0(g, envir = ns, inherits = FALSE), label = g)
  }
})

test_that("the S3 print methods are registered where dispatch looks", {
  skip_if_not_installed("vellum")
  for (cls in c(
    "vellum_why_size",
    "vellum_gradient",
    "vellum_pattern",
    "vellum_mask"
  )) {
    expect_true(
      !is.null(getS3method("print", cls, optional = TRUE)),
      label = cls
    )
  }
})

test_that("the S3 print methods actually dispatch", {
  s <- vl_scene(4, 3) |>
    push(vl_viewport(
      name = "panel",
      width = vl_unit(2, "in"),
      height = vl_unit(1, "in")
    ))
  # These methods format with cli, which writes to stderr, so capture that.
  shown <- function(x) {
    paste(capture.output(print(x), type = "message"), collapse = "\n")
  }

  expect_match(shown(why_size(s, "panel")), "why_size")
  expect_match(shown(linear_gradient(c("red", "blue"))), "vellum_gradient")
  expect_match(shown(radial_gradient(c("red", "blue"))), "vellum_gradient")
  expect_match(shown(vl_pattern(rect_grob())), "vellum_pattern")
  expect_match(shown(as_mask(rect_grob())), "vellum_mask")
})

test_that("the S7 print/plot methods on a scene still dispatch", {
  s <- vl_scene(1, 1, dpi = 50)
  # display() no-ops without a device in a non-interactive session, so this
  # asserts dispatch (the scene comes back invisibly), not the drawing.
  expect_identical(print(s), s)
  expect_identical(plot(s), s)
})
