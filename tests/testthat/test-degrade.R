test_that("vellum.warn_on_degrade defaults to TRUE", {
  expect_true(isTRUE(getOption("vellum.warn_on_degrade")))
})

test_that(".emit_degrade_warnings warns by default and is silent when opted out", {
  msg <- "a tiling-pattern fill could not be rendered to PDF"
  withr::local_options(vellum.warn_on_degrade = TRUE)
  expect_warning(vellum:::.emit_degrade_warnings(msg), "could not be fully reproduced")
  withr::local_options(vellum.warn_on_degrade = FALSE)
  expect_no_warning(vellum:::.emit_degrade_warnings(msg))
  # an empty warning set never warns, regardless of the option
  withr::local_options(vellum.warn_on_degrade = TRUE)
  expect_no_warning(vellum:::.emit_degrade_warnings(character(0)))
})

test_that("a render that the backend can fully honour emits no degradation warning", {
  # A plain fill on every backend is fully reproducible -> no warning.
  s <- vl_scene(2, 2) |> draw(circle_grob(r = 0.3, gp = gpar(fill = "blue", col = NA)))
  for (ext in c("png", "svg", "pdf")) {
    f <- tempfile(fileext = paste0(".", ext))
    expect_no_warning(render(s, f))
    unlink(f)
  }
})
