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
    gif_dither = TRUE,
    frac_col = fracs,
    frac_size = fracs,
    frac_alpha = fracs
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
    gif_dither = TRUE,
    frac_col = c(0, 1),
    frac_size = c(0, 1),
    frac_alpha = c(0, 1)
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
    gif_dither = TRUE,
    frac_col = seq(0, 1, length.out = 10),
    frac_size = seq(0, 1, length.out = 10),
    frac_alpha = seq(0, 1, length.out = 10)
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
    gif_dither = TRUE,
    frac_col = seq(0, 1, length.out = 8),
    frac_size = seq(0, 1, length.out = 8),
    frac_alpha = seq(0, 1, length.out = 8)
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
    gif_dither = TRUE,
    frac_col = c(0, 0.5, 1),
    frac_size = c(0, 0.5, 1),
    frac_alpha = c(0, 0.5, 1)
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
    gif_dither = TRUE,
    frac_col = c(0, 0.5, 1),
    frac_size = c(0, 0.5, 1),
    frac_alpha = c(0, 0.5, 1)
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

# --- per-aesthetic easing ----------------------------------------------------
# `frac` schedules position (and every discrete snap); `frac_col`/`frac_size`/
# `frac_alpha` schedule their own classes. All four equal == single-curve easing.

# Render one frame at an explicit set of class fractions; return its PNG path.
one_frame <- function(scenes, pos, col = pos, size = pos, alpha = pos, dir) {
  render_animation(
    list(.scene_to_backend(scenes$a), .scene_to_backend(scenes$b)),
    seg = 0L,
    frac = pos,
    format = "frames",
    path = dir,
    delay_num = 1L,
    delay_den = 25L,
    gif_speed = 1L,
    gif_dither = TRUE,
    frac_col = col,
    frac_size = size,
    frac_alpha = alpha
  )
  sort(list.files(dir, pattern = "\\.png$", full.names = TRUE))[[1]]
}

test_that("equal class fractions reproduce single-curve easing byte-for-byte", {
  skip_if_not_installed("png")
  s <- anim_scenes()
  # The same frame, once with the three companions left to default and once with
  # them passed explicitly as `frac`. The engine must not be able to tell.
  d1 <- withr::local_tempdir()
  d2 <- withr::local_tempdir()
  f1 <- one_frame(s, pos = 0.37, dir = d1)
  render_animation(
    list(.scene_to_backend(s$a), .scene_to_backend(s$b)),
    seg = 0L,
    frac = 0.37,
    format = "frames",
    path = d2,
    delay_num = 1L,
    delay_den = 25L,
    gif_speed = 1L,
    gif_dither = TRUE,
    frac_col = 0.37,
    frac_size = 0.37,
    frac_alpha = 0.37
  )
  f2 <- sort(list.files(d2, pattern = "\\.png$", full.names = TRUE))[[1]]
  expect_identical(readBin(f1, "raw", 1e6), readBin(f2, "raw", 1e6))
})

test_that("size eases independently of position", {
  skip_if_not_installed("png")
  # The fixture circle moves 0.25 -> 0.75 npc AND grows 4 -> 12 mm. Hold position
  # at the midpoint and drive size to each end: the ink must sit at the same
  # centroid but be the keyframes' widths, not an interpolated one.
  s <- anim_scenes()
  small <- ink_stats(one_frame(
    s,
    pos = 0.5,
    size = 0,
    dir = withr::local_tempdir()
  ))
  big <- ink_stats(one_frame(
    s,
    pos = 0.5,
    size = 1,
    dir = withr::local_tempdir()
  ))
  # Same place ...
  expect_equal(small$cx, big$cx, tolerance = 0.01)
  expect_equal(small$cx, 0.5, tolerance = 0.02)
  # ... very different size: 4 mm vs 12 mm is a 3x diameter.
  expect_gt(big$width_px / small$width_px, 2.5)
  # And each matches the width that keyframe's radius renders at on its own.
  expect_equal(
    small$width_px,
    ink_stats(one_frame(s, pos = 0, dir = withr::local_tempdir()))$width_px,
    tolerance = 1
  )
})

test_that("colour eases independently of position", {
  skip_if_not_installed("png")
  # Fill runs #1f77b4 (blue-ish, low red) -> #e6ab02 (amber, high red). Hold the
  # circle at mid-position and drive only colour.
  s <- anim_scenes()
  centre_rgb <- function(png) {
    arr <- png::readPNG(png)
    round(arr[round(dim(arr)[1] / 2), round(dim(arr)[2] / 2), 1:3] * 255)
  }
  cold <- centre_rgb(one_frame(
    s,
    pos = 0.5,
    col = 0,
    dir = withr::local_tempdir()
  ))
  warm <- centre_rgb(one_frame(
    s,
    pos = 0.5,
    col = 1,
    dir = withr::local_tempdir()
  ))
  expect_equal(cold, c(31, 119, 180), tolerance = 2) # the left keyframe's fill
  expect_equal(warm, c(230, 171, 2), tolerance = 2) # the right keyframe's fill
})

test_that("alpha eases independently, and drives the enter/exit fade", {
  skip_if_not_installed("png")
  # Two keyed points: `a` exits, `b` enters. Hold every other class at the
  # midpoint and move only alpha -- the fade must follow it, not `frac`.
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
  s <- list(a = mk("a", 0.25), b = mk("b", 0.75))
  red_at <- function(png, xnpc) {
    arr <- png::readPNG(png)
    round(arr[round(0.5 * dim(arr)[1]), round(xnpc * dim(arr)[2]), 1] * 255)
  }
  # alpha = 0: the exiting point is fully opaque, the entering one invisible.
  early <- one_frame(s, pos = 0.5, alpha = 0, dir = withr::local_tempdir())
  expect_lt(red_at(early, 0.25), 90)
  expect_gt(red_at(early, 0.75), 240)
  # alpha = 1, same `frac`: the crossfade has completed even though nothing moved.
  late <- one_frame(s, pos = 0.5, alpha = 1, dir = withr::local_tempdir())
  expect_gt(red_at(late, 0.25), 240)
  expect_lt(red_at(late, 0.75), 90)
})

test_that("vl_render_animation defaults each class schedule to frac", {
  skip_if_not_installed("png")
  s <- anim_scenes()
  d1 <- withr::local_tempdir()
  d2 <- withr::local_tempdir()
  fr <- c(0, 0.5, 1)
  vl_render_animation(list(s$a, s$b), rep(1L, 3), fr, d1, format = "frames")
  vl_render_animation(
    list(s$a, s$b),
    rep(1L, 3),
    fr,
    d2,
    format = "frames",
    frac_col = fr,
    frac_size = fr,
    frac_alpha = fr
  )
  f1 <- sort(list.files(d1, pattern = "\\.png$", full.names = TRUE))
  f2 <- sort(list.files(d2, pattern = "\\.png$", full.names = TRUE))
  expect_length(f1, 3)
  for (i in seq_along(f1)) {
    expect_identical(readBin(f1[[i]], "raw", 1e6), readBin(f2[[i]], "raw", 1e6))
  }
})

test_that("vl_render_animation rejects a mis-sized class schedule", {
  s <- anim_scenes()
  expect_error(
    vl_render_animation(
      list(s$a, s$b),
      rep(1L, 3),
      c(0, 0.5, 1),
      withr::local_tempdir(),
      format = "frames",
      frac_size = c(0, 1)
    ),
    "same length as"
  )
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
      TRUE,
      0,
      0,
      0
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
      TRUE,
      0,
      0,
      0
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
      TRUE,
      0.5,
      0.5,
      0.5
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
      TRUE,
      0.5,
      0.5,
      0.5
    ),
    "unknown format"
  )
})
