test_that("vellum.warn_on_degrade defaults to TRUE", {
  expect_true(isTRUE(getOption("vellum.warn_on_degrade")))
})

test_that(".emit_degrade_warnings warns by default and is silent when opted out", {
  msg <- "a tiling-pattern fill could not be rendered to PDF"
  withr::local_options(vellum.warn_on_degrade = TRUE)
  expect_warning(
    .emit_degrade_warnings(msg),
    "could not be fully reproduced"
  )
  withr::local_options(vellum.warn_on_degrade = FALSE)
  expect_no_warning(.emit_degrade_warnings(msg))
  # an empty warning set never warns, regardless of the option
  withr::local_options(vellum.warn_on_degrade = TRUE)
  expect_no_warning(.emit_degrade_warnings(character(0)))
})

test_that("a render that the backend can fully honour emits no degradation warning", {
  # A plain fill on every backend is fully reproducible -> no warning.
  s <- vl_scene(2, 2) |>
    draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "blue", col = NA)))
  for (ext in c("png", "svg", "pdf")) {
    f <- tempfile(fileext = paste0(".", ext))
    expect_no_warning(render(s, f))
    unlink(f)
  }
})

test_that("a degenerate PDF pattern warning names the role it was painting", {
  # A zero-size tile cannot become a PDF tiling pattern. As a stroke the warning
  # said "fill" and "left unfilled".
  tile <- vl_pattern(rect_grob(gp = vl_gpar(fill = "red", col = NA)), width = 0, height = 0.2)
  stroke <- vl_scene(1, 1) |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, gp = vl_gpar(col = tile, lwd = 10)))
  fill <- vl_scene(1, 1) |>
    draw(rect_grob(gp = vl_gpar(fill = tile, col = NA)))
  withr::local_options(vellum.warn_on_degrade = TRUE)
  f <- withr::local_tempfile(fileext = ".pdf")
  w <- character(0)
  withCallingHandlers(
    render(stroke, f),
    warning = function(cnd) {
      w <<- c(w, conditionMessage(cnd))
      invokeRestart("muffleWarning")
    }
  )
  w <- paste(w, collapse = "\n")
  expect_match(w, "tiling-pattern stroke", fixed = TRUE)
  expect_match(w, "left unstroked", fixed = TRUE)
  expect_no_match(w, "pattern fill", fixed = TRUE)
  expect_warning(render(fill, f), "tiling-pattern fill")
})
