# P1: the Rust render_animation() engine must reproduce the pure-R tween oracle
# (R/tween-oracle.R). Both interpolate the same quantities — geometry values on a
# frozen native/mm scale and colours in Oklab — so a Rust frame at fraction t must
# match scene_raster(.scene_tween(a, b, t)) within a small tolerance (Oklab is f32
# in Rust vs f64 in R; identical geometry -> identical rasterisation).

# Two keyframes: a circle that moves, grows, and changes fill.
anim_scenes <- function() {
  mk <- function(x, r_mm, fill) {
    vl_scene(3, 2, bg = "white") |>
      push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1), name = "panel")) |>
      draw(circle_grob(
        x = x, y = 0.5, r = vl_unit(r_mm, "mm"),
        gp = vl_gpar(fill = fill, col = NA), key = "c1"
      )) |>
      pop()
  }
  list(a = mk(0.25, 4, "#1f77b4"), b = mk(0.75, 12, "#e6ab02"))
}

# Rust frame [h, w, 4] in 0..1 -> compare to oracle scene_raster [4, w, h] in 0:255.
max_channel_diff <- function(rust_png, oracle_arr) {
  rust255 <- aperm(rust_png, c(3, 2, 1)) * 255 # -> [channel, x, y]
  max(abs(rust255 - oracle_arr))
}

test_that("render_animation frames match the pure-R oracle (frames dir)", {
  skip_if_not_installed("png")
  s <- anim_scenes()
  ba <- vellum:::.scene_to_backend(s$a)
  bb <- vellum:::.scene_to_backend(s$b)

  fracs <- c(0, 0.25, 0.5, 0.75, 1)
  dir <- withr::local_tempdir()
  warns <- vellum:::render_animation(
    keyframes = list(ba, bb),
    seg = rep(0L, length(fracs)),
    frac = fracs,
    format = "frames",
    path = dir,
    delay_num = 1L, delay_den = 25L
  )
  expect_length(warns, 0L)

  files <- sort(list.files(dir, pattern = "\\.png$", full.names = TRUE))
  expect_length(files, length(fracs))

  for (k in seq_along(fracs)) {
    rust <- png::readPNG(files[k])
    oracle <- scene_raster(vellum:::.scene_tween(s$a, s$b, fracs[k]))
    expect_lte(max_channel_diff(rust, oracle), 4)
  }
})

test_that("endpoints render identically to the keyframes themselves", {
  skip_if_not_installed("png")
  s <- anim_scenes()
  ba <- vellum:::.scene_to_backend(s$a)
  bb <- vellum:::.scene_to_backend(s$b)
  dir <- withr::local_tempdir()
  vellum:::render_animation(
    list(ba, bb), seg = c(0L, 0L), frac = c(0, 1),
    format = "frames", path = dir, delay_num = 1L, delay_den = 25L
  )
  files <- sort(list.files(dir, pattern = "\\.png$", full.names = TRUE))
  # t = 0 is keyframe A, t = 1 is keyframe B, byte-for-byte on geometry (colour
  # is an endpoint so no interpolation happens).
  expect_lte(max_channel_diff(png::readPNG(files[1]), scene_raster(s$a)), 2)
  expect_lte(max_channel_diff(png::readPNG(files[2]), scene_raster(s$b)), 2)
})

test_that("render_animation writes a valid multi-frame APNG", {
  skip_if_not_installed("png")
  s <- anim_scenes()
  ba <- vellum:::.scene_to_backend(s$a)
  bb <- vellum:::.scene_to_backend(s$b)
  out <- withr::local_tempfile(fileext = ".png")
  vellum:::render_animation(
    list(ba, bb), seg = rep(0L, 10), frac = seq(0, 1, length.out = 10),
    format = "apng", path = out, delay_num = 1L, delay_den = 25L
  )
  expect_true(file.exists(out))
  expect_gt(file.size(out), 100)
  # acTL chunk (animation control) marks it as an APNG, and its frame count is
  # encoded big-endian right after the chunk name.
  raw <- readBin(out, "raw", n = file.size(out))
  # locate the "acTL" chunk-type marker
  sig <- charToRaw("acTL")
  pos <- NA_integer_
  for (i in seq_len(length(raw) - 3L)) {
    if (identical(raw[i:(i + 3L)], sig)) { pos <- i; break }
  }
  expect_false(is.na(pos))
  nframes <- sum(as.integer(raw[(pos + 4L):(pos + 7L)]) * 256^(3:0))
  expect_equal(nframes, 10L)
})

test_that("render_animation writes a valid looping GIF", {
  skip_if_not_installed("magick")
  s <- anim_scenes()
  ba <- vellum:::.scene_to_backend(s$a)
  bb <- vellum:::.scene_to_backend(s$b)
  out <- withr::local_tempfile(fileext = ".gif")
  vellum:::render_animation(
    list(ba, bb), seg = rep(0L, 8), frac = seq(0, 1, length.out = 8),
    format = "gif", path = out, delay_num = 1L, delay_den = 20L
  )
  expect_true(file.exists(out))
  info <- magick::image_info(magick::image_read(out))
  expect_equal(nrow(info), 8L)
  expect_equal(info$width[1], vellum:::.scene_to_backend(s$a)$dim()[1])
})

test_that("keyed elements enter and exit (per-element fade)", {
  skip_if_not_installed("png")
  # One point batch, keyed. A has {a, b}; B has {b, c}: `a` exits, `c` enters,
  # `b` is matched (stays put). All steelblue on white (red channel 70 opaque).
  mk <- function(keys, xs) {
    vl_scene(3, 2, dpi = 96, bg = "white") |>
      push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1), name = "p")) |>
      draw(points_grob(
        x = xs, y = rep(0.5, length(xs)), size = vl_unit(6, "mm"),
        gp = vl_gpar(fill = "steelblue", col = NA), key = keys
      )) |>
      pop()
  }
  a <- mk(c("a", "b"), c(0.2, 0.5))
  b <- mk(c("b", "c"), c(0.5, 0.8))
  dir <- withr::local_tempdir()
  vellum:::render_animation(
    list(vellum:::.scene_to_backend(a), vellum:::.scene_to_backend(b)),
    seg = c(0L, 0L, 0L), frac = c(0, 0.5, 1),
    format = "frames", path = dir, delay_num = 1L, delay_den = 10L
  )
  files <- sort(list.files(dir, pattern = "\\.png$", full.names = TRUE))
  red_at <- function(png, xnpc) {
    arr <- png::readPNG(png)
    round(arr[round(0.5 * dim(arr)[1]), round(xnpc * dim(arr)[2]), 1] * 255)
  }
  # Exiting point (x = 0.2): opaque -> half -> gone (white).
  expect_lt(red_at(files[1], 0.2), 90)
  expect_gt(red_at(files[3], 0.2), 240)
  # Entering point (x = 0.8): gone -> half -> opaque.
  expect_gt(red_at(files[1], 0.8), 240)
  expect_lt(red_at(files[3], 0.8), 90)
  # Matched point (x = 0.5): present throughout.
  expect_lt(red_at(files[1], 0.5), 90)
  expect_lt(red_at(files[3], 0.5), 90)
})

test_that("render_animation validates its inputs", {
  s <- anim_scenes()
  ba <- vellum:::.scene_to_backend(s$a)
  bb <- vellum:::.scene_to_backend(s$b)
  dir <- withr::local_tempdir()
  expect_error(
    vellum:::render_animation(list(ba), seg = 0L, frac = 0, "frames", dir, 1L, 25L),
    "at least 2 keyframes"
  )
  expect_error(
    vellum:::render_animation(list(ba, bb), seg = c(0L, 0L), frac = 0, "frames", dir, 1L, 25L),
    "same length"
  )
  expect_error(
    vellum:::render_animation(list(ba, bb), seg = 5L, frac = 0.5, "frames", dir, 1L, 25L),
    "references keyframe pair"
  )
  expect_error(
    vellum:::render_animation(list(ba, bb), seg = 0L, frac = 0.5, "webp", dir, 1L, 25L),
    "unknown format"
  )
})
