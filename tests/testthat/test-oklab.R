# Perceptual (Oklab) gradient interpolation. `interpolation = "oklab"` pre-samples
# the stops in Oklab so the ramp blends perceptually on every backend; the default
# "srgb" is unchanged.

px <- function(scene, x, y) .scene_to_backend(scene)$pixel(as.integer(x), as.integer(y))

grad_scene <- function(interp) {
  vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(
      col = NA,
      fill = linear_gradient(c("black", "white"), x1 = 0, y1 = 0.5, x2 = 1, y2 = 0.5,
                             interpolation = interp)
    )))
}

test_that("interpolation is validated and stored", {
  g <- linear_gradient(c("black", "white"), interpolation = "oklab")
  expect_identical(g$interpolation, "oklab")
  # default is sRGB
  expect_identical(linear_gradient(c("black", "white"))$interpolation, "srgb")
  expect_identical(radial_gradient(c("red", "yellow"), interpolation = "oklab")$interpolation, "oklab")
  expect_identical(linear_gradient(c("blue", "yellow"), interpolation = "oklch")$interpolation, "oklch")
  expect_error(linear_gradient(c("black", "white"), interpolation = "furlong"))
})

# A blue->yellow ramp: near-complementary, so the straight Oklab line dips toward
# grey at the midpoint while oklch rotates the hue at held chroma.
bluyel_scene <- function(interp) {
  vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(
      col = NA,
      fill = linear_gradient(c("blue", "yellow"), x1 = 0, y1 = 0.5, x2 = 1, y2 = 0.5,
                             interpolation = interp)
    )))
}

test_that("oklch keeps the midpoint more vivid than oklab", {
  # sRGB max-min is a cheap vividness (chroma) proxy: a near-grey midpoint is
  # small, a saturated one is large.
  vivid <- function(interp) {
    p <- px(bluyel_scene(interp), 50, 50)[1:3]
    max(p) - min(p)
  }
  expect_gt(vivid("oklch"), vivid("oklab") + 20L)
})

test_that("oklch preserves endpoints (blue -> yellow)", {
  s <- bluyel_scene("oklch")
  lo <- px(s, 2, 50)[1:3]
  hi <- px(s, 98, 50)[1:3]
  # Near each end the hue has only just begun to rotate, so test that the
  # endpoint colour still dominates (blue full / red absent at the start; red+
  # green full / blue absent at the end) rather than exact channel purity.
  expect_true(lo[3] > 240L && lo[1] < 15L) # ~blue
  expect_true(hi[1] > 240L && hi[2] > 240L && hi[3] < 15L) # ~yellow
})

test_that("oklch pre-samples into more SVG stops; srgb is unchanged", {
  n <- function(interp) lengths(gregexpr("<stop ", scene_svg(bluyel_scene(interp))))
  expect_equal(n("srgb"), 2L)
  expect_gt(n("oklch"), 2L)
})

test_that("oklab blends perceptually: black->white midpoint is darker than sRGB", {
  srgb <- px(grad_scene("srgb"), 50, 50)[1:3]
  oklab <- px(grad_scene("oklab"), 50, 50)[1:3]
  # sRGB midpoint sits near code 127; the perceptual midpoint is clearly darker.
  expect_true(all(abs(srgb - 127L) < 20L))
  expect_true(all(oklab < srgb - 15L))
  expect_true(all(oklab > 80L) && all(oklab < 115L)) # ~100
  # still greyscale (no hue drift on a neutral ramp)
  expect_true(max(oklab) - min(oklab) <= 2L)
})

test_that("endpoints are preserved under oklab", {
  s <- grad_scene("oklab")
  expect_true(all(px(s, 2, 50)[1:3] < 12L)) # near black
  expect_true(all(px(s, 98, 50)[1:3] > 244L)) # near white
})

test_that("oklab pre-samples into more SVG stops; srgb is unchanged", {
  svg_srgb <- scene_svg(grad_scene("srgb"))
  svg_oklab <- scene_svg(grad_scene("oklab"))
  n_srgb <- lengths(gregexpr("<stop ", svg_srgb))
  n_oklab <- lengths(gregexpr("<stop ", svg_oklab))
  expect_equal(n_srgb, 2L) # the two author stops, verbatim
  expect_gt(n_oklab, n_srgb) # densely sampled
})

test_that("the default gradient is byte-identical to explicit srgb (additivity)", {
  default <- scene_svg(vl_scene(1, 1, dpi = 100) |>
    draw(rect_grob(gp = vl_gpar(col = NA, fill = linear_gradient(c("black", "white"))))))
  explicit <- scene_svg(vl_scene(1, 1, dpi = 100) |>
    draw(rect_grob(gp = vl_gpar(col = NA, fill = linear_gradient(c("black", "white"), interpolation = "srgb")))))
  expect_identical(default, explicit)
})
