# Masks (isolated compositing groups). Raster probes compile to a backend Scene
# and read pixels in-memory; SVG asserts the <mask> structure; PDF renders the
# documented unmasked fallback.

px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

test_that("as_mask validates its type", {
  expect_s3_class(as_mask(circle_grob()), "vellum_mask")
  expect_equal(as_mask(circle_grob())$type, "alpha")
  expect_error(as_mask(circle_grob(), type = "sparkle"))
})

test_that("an alpha mask shows content only where the mask is opaque", {
  m <- as_mask(circle_grob(r = 0.3, gp = gpar(fill = "white", col = NA)), type = "alpha")
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    push(viewport(mask = m)) |>
    draw(rect_grob(gp = gpar(fill = "blue", col = NA))) |>
    pop()
  expect_equal(px(s, 100, 100)[1:3], c(0L, 0L, 255L)) # inside disc: blue
  expect_equal(px(s, 3, 3)[1:3], c(255L, 255L, 255L)) # corner: masked -> page
})

test_that("alpha vs luminance read coverage differently", {
  # A solid BLACK mask grob: opaque (alpha 255) but luminance 0.
  black <- rect_grob(gp = gpar(fill = "black", col = NA))
  content <- function(type) {
    vl_scene(1, 1, dpi = 100, bg = "white") |>
      push(viewport(mask = as_mask(black, type = type))) |>
      draw(rect_grob(gp = gpar(fill = "blue", col = NA))) |>
      pop()
  }
  # alpha: fully opaque mask -> content shown.
  expect_equal(px(content("alpha"), 50, 50)[1:3], c(0L, 0L, 255L))
  # luminance: black -> 0 coverage -> content hidden, page shows.
  expect_equal(px(content("luminance"), 50, 50)[1:3], c(255L, 255L, 255L))
})

test_that("a soft (gradient) mask gives partial coverage", {
  # Luminance mask: black (left) -> white (right). Right shows, left hidden,
  # middle partially blends blue with the white page.
  grad <- rect_grob(gp = gpar(
    col = NA,
    fill = linear_gradient(c("black", "white"), x1 = 0, y1 = 0.5, x2 = 1, y2 = 0.5)
  ))
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    push(viewport(mask = as_mask(grad, type = "luminance"))) |>
    draw(rect_grob(gp = gpar(fill = "blue", col = NA))) |>
    pop()
  left <- px(s, 3, 50)
  right <- px(s, 197, 50)
  mid <- px(s, 100, 50)
  expect_true(all(left[1:3] > 240L)) # masked out -> white page
  expect_true(right[3] > 240L && right[1] < 20L) # shown -> blue
  expect_true(mid[3] > 120L && mid[1] > 60L) # partial: blue blended over white
})

test_that("SVG emits a <mask> referenced by the group", {
  f <- withr::local_tempfile(fileext = ".svg")
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(viewport(mask = as_mask(circle_grob(r = 0.4, gp = gpar(fill = "white", col = NA))))) |>
    draw(rect_grob(gp = gpar(fill = "blue", col = NA))) |>
    pop()
  render(s, f)
  svg <- paste(readLines(f, warn = FALSE), collapse = "\n")
  expect_match(svg, "<mask ")
  expect_match(svg, 'mask="url\\(#')
  expect_match(svg, "data:image/png;base64,")
})

test_that("PDF renders a masked group (unmasked fallback) without error", {
  f <- withr::local_tempfile(fileext = ".pdf")
  s <- vl_scene(2, 1, dpi = 100) |>
    push(viewport(mask = as_mask(circle_grob(r = 0.4, gp = gpar(fill = "white", col = NA))))) |>
    draw(rect_grob(gp = gpar(fill = "blue", col = NA))) |>
    pop()
  expect_no_error(render(s, f))
  expect_equal(rawToChar(readBin(f, "raw", 5)), "%PDF-")
})

test_that("a mask accepts a list of grobs", {
  m <- as_mask(list(
    circle_grob(x = 0.3, r = 0.2, gp = gpar(fill = "white", col = NA)),
    circle_grob(x = 0.7, r = 0.2, gp = gpar(fill = "white", col = NA))
  ))
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    push(viewport(mask = m)) |>
    draw(rect_grob(gp = gpar(fill = "blue", col = NA))) |>
    pop()
  # Between the two discs (centre) is masked out; over a disc is blue.
  expect_equal(px(s, 100, 50)[1:3], c(255L, 255L, 255L))
})
