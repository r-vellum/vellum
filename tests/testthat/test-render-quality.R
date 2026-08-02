# Phase 5: CVD simulation, anti-aliasing / crisp control, and group effects.
# All three are opt-in, so the first thing each block checks is that the feature
# absent leaves output exactly as it was.

# --- CVD simulation ----------------------------------------------------------

swatches <- function() {
  vl_scene(3, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(
      x = 0.17,
      width = 0.3,
      gp = vl_gpar(fill = "#D62728", col = NA)
    )) |>
    draw(rect_grob(
      x = 0.50,
      width = 0.3,
      gp = vl_gpar(fill = "#2CA02C", col = NA)
    )) |>
    draw(rect_grob(
      x = 0.83,
      width = 0.3,
      gp = vl_gpar(fill = "#1F77B4", col = NA)
    ))
}
mid_cols <- function(cvd = "none") {
  r <- scene_raster(swatches(), cvd = cvd)
  list(red = r[1:3, 50, 50], green = r[1:3, 150, 50], blue = r[1:3, 250, 50])
}

test_that("cvd = 'none' is the default and leaves colours untouched", {
  a <- mid_cols()
  expect_equal(a$red, c(214L, 39L, 40L))
  expect_equal(a$green, c(44L, 160L, 44L))
})

test_that("deuteranopia collapses red and green toward each other", {
  plain <- mid_cols()
  sim <- mid_cols("deuteranopia")
  # The point of the simulation: a red/green encoding stops being separable.
  sep_plain <- sum(abs(plain$red - plain$green))
  sep_sim <- sum(abs(sim$red - sim$green))
  expect_lt(sep_sim, sep_plain / 3)
})

test_that("achromatopsia produces pure greys", {
  sim <- mid_cols("achromatopsia")
  for (ch in sim) {
    expect_equal(ch[1], ch[2], tolerance = 1)
  }
  for (ch in sim) {
    expect_equal(ch[2], ch[3], tolerance = 1)
  }
})

test_that("a simulation is never written into the render cache", {
  # The cache key does not include `cvd`, so a simulated pixmap must not be
  # stored -- otherwise a later plain render would be served the simulation.
  before <- mid_cols()
  invisible(mid_cols("deuteranopia"))
  expect_equal(mid_cols()$red, before$red)
})

test_that("cvd on a vector target warns and leaves the file unsimulated", {
  s <- swatches()
  f <- withr::local_tempfile(fileext = ".svg")
  vl_clear_render_cache()
  expect_warning(render(s, f, cvd = "deuteranopia"), "raster")
  plain <- withr::local_tempfile(fileext = ".svg")
  vl_clear_render_cache()
  render(plain_s <- s, plain)
  expect_identical(tools::md5sum(f)[[1]], tools::md5sum(plain)[[1]])
})

test_that("an unknown cvd kind is rejected", {
  expect_error(scene_raster(swatches(), cvd = "nope"))
})

# --- anti-aliasing and crisp edges -------------------------------------------

test_that("crisp snaps a fractional axis-parallel rule onto one pixel row", {
  rule <- function(...) {
    vl_scene(2, 0.6, dpi = 100, bg = "white") |>
      draw(segments_grob(
        0.05,
        0.5013,
        0.95,
        0.5013,
        gp = vl_gpar(col = "black", lwd = 1, ...)
      ))
  }
  col <- function(s) scene_raster(s)[1, 100, ]
  muddy <- col(rule())
  sharp <- col(rule(crisp = TRUE))
  # Default: the stroke straddles two rows, so neither reaches full black.
  expect_gt(min(muddy), 0)
  expect_length(which(muddy < 250), 2)
  # Crisp: one row, fully inked.
  expect_equal(min(sharp), 0)
  expect_length(which(sharp < 250), 1)
})

test_that("crisp leaves diagonals alone", {
  diag <- function(...) {
    vl_scene(1, 1, dpi = 100, bg = "white") |>
      draw(segments_grob(0.1, 0.1, 0.9, 0.9, gp = vl_gpar(col = "black", ...)))
  }
  a <- withr::local_tempfile(fileext = ".png")
  b <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache()
  render(diag(), a)
  vl_clear_render_cache()
  render(diag(crisp = TRUE), b)
  expect_identical(tools::md5sum(a)[[1]], tools::md5sum(b)[[1]])
})

test_that("antialias = FALSE gives hard edges", {
  tri <- function(aa) {
    vl_scene(1, 1, dpi = 100, bg = "white") |>
      draw(polygon_grob(
        c(.1, .9, .5),
        c(.1, .1, .9),
        gp = vl_gpar(fill = "black", col = NA, antialias = aa)
      ))
  }
  greys <- function(s) length(unique(as.vector(scene_raster(s)[1, , ])))
  expect_gt(greys(tri(TRUE)), 2)
  expect_equal(greys(tri(FALSE)), 2) # black and white only
})

test_that("antialias inherits from a viewport", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(vl_viewport(gp = vl_gpar(antialias = FALSE))) |>
    draw(polygon_grob(
      c(.1, .9, .5),
      c(.1, .1, .9),
      gp = vl_gpar(fill = "black", col = NA)
    )) |>
    pop()
  expect_equal(length(unique(as.vector(scene_raster(s)[1, , ]))), 2)
})

test_that("a non-logical antialias/crisp is rejected", {
  s <- function(v) {
    vl_scene(1, 1) |> draw(rect_grob(gp = vl_gpar(antialias = v)))
  }
  expect_error(scene_raster(s("yes")), "antialias")
  expect_error(scene_raster(s(NA)), "antialias")
})

# --- group effects -----------------------------------------------------------

boxed <- function(...) {
  vl_scene(2, 2, dpi = 100, bg = "white") |>
    push(vl_viewport(width = 0.4, height = 0.4, ...)) |>
    draw(rect_grob(gp = vl_gpar(fill = "steelblue", col = NA))) |>
    pop()
}

test_that("blur softens the edge and preserves the centre", {
  plain <- scene_raster(boxed())
  blurred <- scene_raster(boxed(blur = 4))
  # Centre stays the fill colour; the edge picks up intermediate values.
  expect_equal(blurred[1:3, 100, 100], plain[1:3, 100, 100], tolerance = 4)
  edge_plain <- length(unique(plain[3, , 100]))
  edge_blur <- length(unique(blurred[3, , 100]))
  expect_gt(edge_blur, edge_plain)
})

test_that("a shadow darkens pixels outside the shape, offset from it", {
  plain <- scene_raster(boxed())
  shadowed <- scene_raster(boxed(shadow = vl_shadow(dx = 6, dy = 6, blur = 2)))
  # The 0.4-npc box on a 200x200 px page spans 60..140; a dx/dy of 6 puts the
  # shadow at 66..146. Probe at 143: outside the box, inside the shadow.
  bg_before <- plain[1, 143, 143]
  bg_after <- shadowed[1, 143, 143]
  expect_equal(bg_before, 255L)
  expect_lt(bg_after, 255L)
})

test_that("effects are opt-in: no blur and no shadow renders unchanged", {
  a <- withr::local_tempfile(fileext = ".png")
  b <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache()
  render(boxed(), a)
  vl_clear_render_cache()
  render(boxed(blur = 0, shadow = NULL), b)
  expect_identical(tools::md5sum(a)[[1]], tools::md5sum(b)[[1]])
})

test_that("SVG emits native filter primitives rather than rasterising", {
  svg <- scene_svg(boxed(blur = 3))
  expect_match(svg, "feGaussianBlur")
  svg2 <- scene_svg(boxed(shadow = vl_shadow()))
  expect_match(svg2, "feDropShadow")
})

test_that("PDF reports the effect it cannot honour", {
  f <- withr::local_tempfile(fileext = ".pdf")
  vl_clear_render_cache()
  expect_warning(render(boxed(blur = 3), f), "blur/shadow")
})

test_that("vl_shadow validates its arguments", {
  expect_error(vl_shadow(blur = -1), "non-negative")
  expect_error(vl_shadow(dx = c(1, 2)), "single number")
  expect_error(
    scene_raster(
      vl_scene(1, 1) |> push(vl_viewport(shadow = "black")) |> pop()
    ),
    "vl_shadow"
  )
})
