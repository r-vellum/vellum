# The public vl_render_animation() wrapper over the Rust engine.

anim_keys <- function() {
  mk <- function(x, fill) {
    vl_scene(3, 2, bg = "white") |>
      push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1), name = "panel")) |>
      draw(circle_grob(
        x = x,
        y = 0.5,
        r = vl_unit(5, "mm"),
        gp = vl_gpar(fill = fill, col = NA)
      )) |>
      pop()
  }
  list(mk(0.2, "steelblue"), mk(0.5, "tomato"), mk(0.8, "gold"))
}

test_that("vl_render_animation writes a GIF across K keyframes", {
  skip_if_not_installed("magick")
  keys <- anim_keys()
  # 2 segments x 10 frames, 1-based seg.
  seg <- rep(1:2, each = 10)
  frac <- rep(seq(0, 1, length.out = 10), 2)
  out <- withr::local_tempfile(fileext = ".gif")
  res <- vl_render_animation(keys, seg, frac, out, format = "gif", fps = 20)
  expect_equal(res, out)
  info <- magick::image_info(magick::image_read(out))
  expect_equal(nrow(info), 20L)
})

test_that("vl_render_animation honours the GIF quality controls", {
  skip_if_not_installed("magick")
  keys <- anim_keys()
  seg <- rep(1:2, each = 5)
  frac <- rep(seq(0, 1, length.out = 5), 2)

  # dithered (default) and undithered both produce a valid 10-frame GIF.
  for (dither in c(TRUE, FALSE)) {
    out <- withr::local_tempfile(fileext = ".gif")
    vl_render_animation(
      keys,
      seg,
      frac,
      out,
      format = "gif",
      gif_speed = 3,
      gif_dither = dither
    )
    expect_equal(nrow(magick::image_info(magick::image_read(out))), 10L)
  }

  expect_error(
    vl_render_animation(
      keys,
      seg,
      frac,
      withr::local_tempfile(fileext = ".gif"),
      gif_speed = 0
    ),
    "1:30"
  )
  expect_error(
    vl_render_animation(
      keys,
      seg,
      frac,
      withr::local_tempfile(fileext = ".gif"),
      gif_speed = 99
    ),
    "1:30"
  )
})

test_that("vl_render_animation writes an APNG and a frame directory", {
  skip_if_not_installed("png")
  keys <- anim_keys()
  seg <- c(1L, 1L, 2L, 2L)
  frac <- c(0, 1, 0, 1)

  apng <- withr::local_tempfile(fileext = ".png")
  vl_render_animation(keys, seg, frac, apng, format = "apng", fps = 10)
  expect_true(file.exists(apng))

  dir <- withr::local_tempdir()
  vl_render_animation(keys, seg, frac, dir, format = "frames", fps = 10)
  expect_length(list.files(dir, pattern = "\\.png$"), 4L)
})

test_that("vl_render_animation validates its schedule", {
  keys <- anim_keys()
  out <- withr::local_tempfile(fileext = ".gif")
  expect_error(vl_render_animation(keys[1], 1L, 0, out), "at least 2 scenes")
  expect_error(vl_render_animation(keys, c(1L, 2L), 0, out), "same length")
  # seg is 1-based and must leave room for seg + 1: 3 keyframes -> seg in 1:2.
  expect_error(vl_render_animation(keys, 3L, 0.5, out), "1-based left-keyframe")
  expect_error(vl_render_animation(keys, 1L, 0.5, out, fps = 0), "positive")
})
