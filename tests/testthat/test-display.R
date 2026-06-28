# display(): draw a scene into the active graphics device (the RStudio/Positron
# Plots pane interactively, or any open device — png()/pdf()/knitr chunk).

test_that("display() draws the scene into the active device (asymmetric, no shear)", {
  skip_if_not_installed("png")
  f <- withr::local_tempfile(fileext = ".png")
  grDevices::png(f, width = 300, height = 150)
  # A top-left red block: an asymmetric target so a transpose/shear/stride bug in
  # the draw path changes the output (a centred blob would not catch it).
  s <- vl_scene(4, 2, bg = "white") |>
    draw(rect_grob(x = 0.12, y = 0.82, width = 0.18, height = 0.28,
                   gp = gpar(fill = "red", col = NA)))
  display(s)
  grDevices::dev.off()
  img <- png::readPNG(f) # [150, 300, c]
  expect_gt(img[25, 35, 1], 0.8) # top-left red
  expect_lt(img[25, 35, 3], 0.2)
  expect_gt(min(img[125, 270, 1:3]), 0.8) # bottom-right white
  expect_gt(min(img[25, 270, 1:3]), 0.8) # top-right white (not mirrored/tiled)
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
