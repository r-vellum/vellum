# The Rust render_animation() engine interpolates geometry (on frozen scales) and
# colour (in Oklab), renders frames in parallel, and streams them to an encoder.
# These tests assert the rendered frames directly: geometry lands where the tween
# puts it, endpoints reproduce the keyframes, colours blend, elements enter/exit,
# masks wipe, and every encoder writes a valid file.

# Two keyframes: a circle that moves, grows, and changes fill.
anim_scenes <- function() {
  mk <- function(x, r_mm, fill) {
    vl_scene(3, 2, bg = "white") |>
      push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1), name = "panel")) |>
      draw(circle_grob(
        x = x,
        y = 0.5,
        r = vl_unit(r_mm, "mm"),
        gp = vl_gpar(fill = fill, col = NA),
        key = "c1"
      )) |>
      pop()
  }
  list(a = mk(0.25, 4, "#1f77b4"), b = mk(0.75, 12, "#e6ab02"))
}

# Rust frame [h, w, 4] in 0..1 -> [channel, x, y] in 0:255, vs a scene_raster.
max_channel_diff <- function(rust_png, ref_arr) {
  rust255 <- aperm(rust_png, c(3, 2, 1)) * 255
  max(abs(rust255 - ref_arr))
}

# Horizontal centroid (npc) and pixel width of the non-white ink in a frame.
ink_stats <- function(png) {
  arr <- png::readPNG(png)
  ink <- arr[,, 1] < 0.9 | arr[,, 2] < 0.9 | arr[,, 3] < 0.9
  per_col <- colSums(ink)
  cols <- which(per_col > 0)
  list(
    cx = weighted.mean(seq_along(per_col), per_col) / ncol(ink),
    width_px = if (length(cols)) diff(range(cols)) + 1 else 0
  )
}

test_that("render_animation interpolates geometry across frames", {
  skip_if_not_installed("png")
  s <- anim_scenes() # circle: x 0.25 -> 0.75 (npc), r 4 -> 12 mm
  fracs <- c(0, 0.5, 1)
  dir <- withr::local_tempdir()
  warns <- render_animation(
    keyframes = list(
      .scene_to_backend(s$a),
      .scene_to_backend(s$b)
    ),
    seg = rep(0L, length(fracs)),
    frac = fracs,
    format = "frames",
    path = dir,
    delay_num = 1L,
    delay_den = 25L,
    gif_speed = 1L,
    gif_dither = TRUE
  )
  expect_length(warns, 0L)
  files <- sort(list.files(dir, pattern = "\\.png$", full.names = TRUE))
  expect_length(files, length(fracs))

  stats <- lapply(files, ink_stats)
  # Centre moves linearly 0.25 -> 0.5 -> 0.75, and the radius grows monotonically.
  expect_equal(
    vapply(stats, `[[`, numeric(1), "cx"),
    c(0.25, 0.5, 0.75),
    tolerance = 0.03
  )
  wd <- vapply(stats, `[[`, numeric(1), "width_px")
  expect_true(wd[2] > wd[1] && wd[3] > wd[2])
})

test_that("endpoints render identically to the keyframes themselves", {
  skip_if_not_installed("png")
  s <- anim_scenes()
  ba <- .scene_to_backend(s$a)
  bb <- .scene_to_backend(s$b)
  dir <- withr::local_tempdir()
  render_animation(
    list(ba, bb),
    seg = c(0L, 0L),
    frac = c(0, 1),
    format = "frames",
    path = dir,
    delay_num = 1L,
    delay_den = 25L,
    gif_speed = 1L,
    gif_dither = TRUE
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
  ba <- .scene_to_backend(s$a)
  bb <- .scene_to_backend(s$b)
  out <- withr::local_tempfile(fileext = ".png")
  render_animation(
    list(ba, bb),
    seg = rep(0L, 10),
    frac = seq(0, 1, length.out = 10),
    format = "apng",
    path = out,
    delay_num = 1L,
    delay_den = 25L,
    gif_speed = 1L,
    gif_dither = TRUE
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
    if (identical(raw[i:(i + 3L)], sig)) {
      pos <- i
      break
    }
  }
  expect_false(is.na(pos))
  nframes <- sum(as.integer(raw[(pos + 4L):(pos + 7L)]) * 256^(3:0))
  expect_equal(nframes, 10L)
})

test_that("render_animation writes a valid looping GIF", {
  skip_if_not_installed("magick")
  s <- anim_scenes()
  ba <- .scene_to_backend(s$a)
  bb <- .scene_to_backend(s$b)
  out <- withr::local_tempfile(fileext = ".gif")
  render_animation(
    list(ba, bb),
    seg = rep(0L, 8),
    frac = seq(0, 1, length.out = 8),
    format = "gif",
    path = out,
    delay_num = 1L,
    delay_den = 20L,
    gif_speed = 1L,
    gif_dither = TRUE
  )
  expect_true(file.exists(out))
  info <- magick::image_info(magick::image_read(out))
  expect_equal(nrow(info), 8L)
  expect_equal(info$width[1], .scene_to_backend(s$a)$dim()[1])
})

test_that("keyed elements enter and exit (per-element fade)", {
  skip_if_not_installed("png")
  # One point batch, keyed. A has {a, b}; B has {b, c}: `a` exits, `c` enters,
  # `b` is matched (stays put). All steelblue on white (red channel 70 opaque).
  mk <- function(keys, xs) {
    vl_scene(3, 2, dpi = 96, bg = "white") |>
      push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1), name = "p")) |>
      draw(points_grob(
        x = xs,
        y = rep(0.5, length(xs)),
        size = vl_unit(6, "mm"),
        gp = vl_gpar(fill = "steelblue", col = NA),
        key = keys
      )) |>
      pop()
  }
  a <- mk(c("a", "b"), c(0.2, 0.5))
  b <- mk(c("b", "c"), c(0.5, 0.8))
  dir <- withr::local_tempdir()
  render_animation(
    list(.scene_to_backend(a), .scene_to_backend(b)),
    seg = c(0L, 0L, 0L),
    frac = c(0, 0.5, 1),
    format = "frames",
    path = dir,
    delay_num = 1L,
    delay_den = 10L,
    gif_speed = 1L,
    gif_dither = TRUE
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

test_that("viewport masks tween (a reveal wipe)", {
  skip_if_not_installed("png")
  # A full blue rect masked to the npc x-range [0, f]; the mask rect grows with f.
  mk <- function(f) {
    vl_scene(3, 2, dpi = 96, bg = "white") |>
      push(vl_viewport(
        mask = as_mask(
          rect_grob(
            x = vl_unit(f / 2, "npc"),
            width = vl_unit(f, "npc"),
            gp = vl_gpar(fill = "white", col = NA)
          ),
          type = "alpha"
        )
      )) |>
      draw(rect_grob(gp = vl_gpar(fill = "steelblue", col = NA))) |>
      pop()
  }
  dir <- withr::local_tempdir()
  render_animation(
    list(.scene_to_backend(mk(0)), .scene_to_backend(mk(1))),
    seg = c(0L, 0L, 0L),
    frac = c(0, 0.5, 1),
    format = "frames",
    path = dir,
    delay_num = 1L,
    delay_den = 10L,
    gif_speed = 1L,
    gif_dither = TRUE
  )
  files <- sort(list.files(dir, pattern = "\\.png$", full.names = TRUE))
  blue <- vapply(
    files,
    function(f) {
      arr <- png::readPNG(f)
      sum(arr[,, 3] > arr[,, 1]) # bluish pixels
    },
    numeric(1)
  )
  # The unmasked (revealed) blue region grows monotonically with the tweened mask.
  expect_equal(blue[[1]], 0)
  expect_gt(blue[[2]], 0)
  expect_gt(blue[[3]], blue[[2]])
})

test_that("render_animation validates its inputs", {
  s <- anim_scenes()
  ba <- .scene_to_backend(s$a)
  bb <- .scene_to_backend(s$b)
  dir <- withr::local_tempdir()
  expect_error(
    render_animation(
      list(ba),
      seg = 0L,
      frac = 0,
      "frames",
      dir,
      1L,
      25L,
      1L,
      TRUE
    ),
    "at least 2 keyframes"
  )
  expect_error(
    render_animation(
      list(ba, bb),
      seg = c(0L, 0L),
      frac = 0,
      "frames",
      dir,
      1L,
      25L,
      1L,
      TRUE
    ),
    "same length"
  )
  expect_error(
    render_animation(
      list(ba, bb),
      seg = 5L,
      frac = 0.5,
      "frames",
      dir,
      1L,
      25L,
      1L,
      TRUE
    ),
    "references keyframe pair"
  )
  expect_error(
    render_animation(
      list(ba, bb),
      seg = 0L,
      frac = 0.5,
      "webp",
      dir,
      1L,
      25L,
      1L,
      TRUE
    ),
    "unknown format"
  )
})
