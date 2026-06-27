# display(): draw a scene into the active graphics device (the RStudio/Positron
# Plots pane interactively, or any open device — png()/pdf()/knitr chunk).

test_that("display() draws the scene into the active device", {
  skip_if_not_installed("png")
  f <- withr::local_tempfile(fileext = ".png")
  grDevices::png(f, width = 200, height = 150)
  s <- vl_scene(2, 1.5, bg = "white") |>
    draw(circle_grob(r = 0.3, gp = gpar(fill = "red", col = NA)))
  display(s)
  grDevices::dev.off()
  img <- png::readPNG(f)
  expect_gt(img[75, 100, 1], 0.8) # centre red: high red...
  expect_lt(img[75, 100, 2], 0.2) # ...low green
})

test_that("print() and plot() dispatch to display()", {
  f <- withr::local_tempfile(fileext = ".png")
  grDevices::png(f)
  s <- vl_scene(1, 1, bg = "white") |> draw(rect_grob(gp = gpar(fill = "blue", col = NA)))
  expect_no_error(print(s))
  expect_no_error(plot(s))
  grDevices::dev.off()
})

test_that("display() coerces through as_vellum_scene()", {
  Spec3 <- S7::new_class("Spec3", properties = list())
  S7::method(as_vellum_scene, Spec3) <- function(x, ...) {
    vl_scene(1, 1, bg = "white") |> draw(rect_grob(gp = gpar(fill = "green", col = NA)))
  }
  f <- withr::local_tempfile(fileext = ".png")
  grDevices::png(f)
  expect_no_error(display(Spec3()))
  grDevices::dev.off()
})

test_that("display() is a no-op with no device in a non-interactive session", {
  # (we are non-interactive under testthat) close any device first
  while (grDevices::dev.cur() > 1L) grDevices::dev.off()
  s <- vl_scene(1, 1) |> draw(rect_grob())
  expect_no_error(display(s)) # must not error or spawn Rplots.pdf
  expect_equal(unname(grDevices::dev.cur()), 1L) # still the null device
})
