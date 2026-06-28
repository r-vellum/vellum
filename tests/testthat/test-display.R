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

test_that("display() fills the device at any aspect (reflow, no letterbox)", {
  skip_if_not_installed("png")
  s <- vl_scene(6, 4, bg = "white") |> # 6:4 authored aspect
    draw(rect_grob(gp = gpar(fill = "steelblue", col = NA)))
  edges_filled <- function(W, H) {
    f <- tempfile(fileext = ".png")
    grDevices::png(f, W, H)
    display(s)
    grDevices::dev.off()
    img <- png::readPNG(f) # [H, W, c]; steelblue has low red, white is high red
    max(img[1, , 1]) < 0.7 && max(img[H, , 1]) < 0.7 && # top, bottom rows
      max(img[, 1, 1]) < 0.7 && max(img[, W, 1]) < 0.7 # left, right cols
  }
  expect_true(edges_filled(500, 500)) # square: previously letterboxed top/bottom
  expect_true(edges_filled(800, 300)) # wide: previously letterboxed left/right
})

test_that("display() re-renders on resize so round markers stay round", {
  # Resizing the Plots pane replays the display list. A static bitmap would be
  # stretched (distorting circles); our makeContent grob re-renders at the new
  # size instead. Simulate a resize with recordPlot()/replayPlot() at a new aspect.
  skip_if_not_installed("png")
  s <- vl_scene(4, 4, bg = "white") |>
    push(viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
    draw(points_grob(unit(5, "native"), unit(5, "native"),
                     size = unit(6, "mm"), gp = gpar(fill = "red", col = NA)))
  f1 <- tempfile(fileext = ".png")
  f2 <- tempfile(fileext = ".png")
  grDevices::png(f1, 400, 400)
  grDevices::dev.control(displaylist = "enable")
  display(s)
  p <- grDevices::recordPlot()
  grDevices::dev.off()
  grDevices::png(f2, 800, 300) # "resize" to a very different aspect
  grDevices::replayPlot(p)
  grDevices::dev.off()
  img <- png::readPNG(f2)
  red <- which(img[, , 1] > 0.7 & img[, , 2] < 0.3, arr.ind = TRUE)
  expect_gt(nrow(red), 0)
  wpx <- diff(range(red[, 2]))
  hpx <- diff(range(red[, 1]))
  expect_lt(abs(wpx - hpx), 4) # round, not stretched into an ellipse
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
