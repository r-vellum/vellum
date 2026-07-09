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
                   gp = vl_gpar(fill = "red", col = NA)))
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
    draw(rect_grob(gp = vl_gpar(fill = "steelblue", col = NA)))
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
    push(vl_viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
    draw(points_grob(vl_unit(5, "native"), vl_unit(5, "native"),
                     size = vl_unit(6, "mm"), gp = vl_gpar(fill = "red", col = NA)))
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

# A detail-rich scene whose render sharpness scales with the dpi it is rasterized
# at. Measures a Laplacian-energy proxy (mean squared 2nd-difference over the
# greyscale image): a genuine high-dpi render has ~an order of magnitude more of
# it than a low-dpi render upscaled to the same pixel size.
.dpi_probe_scene <- function() {
  s <- vl_scene(7, 5, bg = "white", dpi = 96)
  set.seed(1)
  for (i in seq_len(120)) {
    s <- draw(s, circle_grob(x = stats::runif(1), y = stats::runif(1), r = 0.015,
                             gp = vl_gpar(fill = "tomato", col = "black")))
  }
  s
}
.sharpness <- function(f) {
  img <- png::readPNG(f)
  g <- apply(img[, , 1:3, drop = FALSE], c(1, 2), mean)
  dx <- diff(g, differences = 2)
  dy <- diff(t(g), differences = 2)
  (mean(dx^2) + mean(dy^2)) * 1e4
}

test_that("display() honors the authored dpi on a device that misreports px size", {
  # grDevices::png (knitr's default device) pins dev.size('px') to size_in*72 and
  # ignores its own res=, so a naive px/in ratio always yields 72. The display
  # path must distrust that and render at the scene's authored dpi instead of
  # clamping detail to 72 and upscaling a soft bitmap.
  skip_if_not_installed("png")
  # Pin that misreport: quartz png reports size_in*72, but cairo png (Linux)
  # reports true px, which would (correctly, by design) let the trustworthy
  # device density win. Mock it so this test deterministically exercises the
  # untrustworthy-device fallback on every backend.
  local_mocked_bindings(
    dev.size = function(units = "in", ...) if (identical(units, "px")) c(504, 360) else c(7, 5),
    .package = "grDevices"
  )
  s <- .dpi_probe_scene()
  lo <- S7::set_props(s, dpi = 72)
  hi <- S7::set_props(s, dpi = 200)
  render_sharp <- function(scene) {
    f <- withr::local_tempfile(fileext = ".png")
    grDevices::png(f, 7, 5, "in", res = 200) # emits 1400x1000 regardless of content dpi
    display(scene)
    grDevices::dev.off()
    .sharpness(f)
  }
  # Same emitted pixel size; the dpi=200 scene carries genuinely more detail.
  expect_gt(render_sharp(hi), render_sharp(lo) * 3)
})

test_that("display() lets the knitr chunk dpi win when knitting", {
  skip_if_not_installed("png")
  # Pin the px misreport (see the previous test) so the non-knit render falls
  # back to the authored dpi on cairo as well as quartz.
  local_mocked_bindings(
    dev.size = function(units = "in", ...) if (identical(units, "px")) c(504, 360) else c(7, 5),
    .package = "grDevices"
  )
  s <- S7::set_props(.dpi_probe_scene(), dpi = 72) # authored low; chunk asks high
  withr::local_options(knitr.in.progress = TRUE)
  # Stub knitr::opts_current$get('dpi') -> 200 without a full knit.
  local_mocked_bindings(
    opts_current = list(get = function(name, ...) if (identical(name, "dpi")) 200 else NULL),
    .package = "knitr"
  )
  f_knit <- withr::local_tempfile(fileext = ".png")
  grDevices::png(f_knit, 7, 5, "in", res = 200)
  display(s)
  grDevices::dev.off()
  sharp_knit <- .sharpness(f_knit)

  # Same scene, no knit context: falls back to the authored dpi (72) -> softer.
  withr::local_options(knitr.in.progress = NULL)
  f_plain <- withr::local_tempfile(fileext = ".png")
  grDevices::png(f_plain, 7, 5, "in", res = 200)
  display(s)
  grDevices::dev.off()
  expect_gt(sharp_knit, .sharpness(f_plain) * 3)
})

test_that("print() and plot() dispatch to display()", {
  f <- withr::local_tempfile(fileext = ".png")
  grDevices::png(f)
  s <- vl_scene(1, 1, bg = "white") |> draw(rect_grob(gp = vl_gpar(fill = "blue", col = NA)))
  expect_no_error(print(s))
  expect_no_error(plot(s))
  grDevices::dev.off()
})

test_that("display() coerces through as_vellum_scene()", {
  Spec3 <- S7::new_class("Spec3", properties = list())
  S7::method(as_vellum_scene, Spec3) <- function(x, ...) {
    vl_scene(1, 1, bg = "white") |> draw(rect_grob(gp = vl_gpar(fill = "green", col = NA)))
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
