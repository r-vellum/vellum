# Inputs that reached an out-of-bounds index, an unbounded loop or an uncapped
# allocation in the Rust renderer. A panic surfaces as a cryptic R error, but a
# failed allocation or an R error raised on a render worker thread takes down the
# whole session, so each case must now either draw or fail with a clear message.

# --- out-of-bounds indexing -------------------------------------------------

test_that("a sketched sector with a gradient fill draws instead of panicking", {
  # The sketch path indexed the per-wedge colour vector, which is empty when one
  # shared gradient/pattern paints every wedge.
  s <- vl_scene(1, 1, dpi = 50, bg = "white") |>
    draw(sector_grob(
      r1 = 0.4,
      theta1 = pi,
      sketch = sketch(fill_style = "solid"),
      gp = vl_gpar(fill = linear_gradient(c("red", "blue")), col = "black")
    ))
  expect_no_error(px <- scene_raster(s))
  expect_true(any(px[4, , ] == 255) && any(px[1, , ] < 255)) # something drawn
})

test_that("tweening a regular hexagon into a width/height one does not panic", {
  # The hexagon loop was bounded by the position arrays only, then indexed
  # size/width/height and their unit codes. A tween frame past the halfway point
  # takes B's width with A's (empty) width unit codes.
  hex <- function(...) {
    vl_scene(1, 1, dpi = 40, bg = "white") |>
      draw(hexagon_grob(c(0.3, 0.7), 0.5, ..., gp = vl_gpar(fill = "grey")))
  }
  a <- hex(size = vl_unit(3, "mm"))
  b <- hex(width = vl_unit(0.2, "npc"), height = vl_unit(0.2, "npc"))
  dir <- withr::local_tempdir()
  expect_no_error(
    vl_render_animation(list(a, b), c(1L, 1L), c(0.25, 0.75), dir, "frames")
  )
  expect_length(list.files(dir, pattern = "\\.png$"), 2L)
})

# --- the sector bbox --------------------------------------------------------

test_that("a sector sweeping many turns is boxed as the full disc", {
  # Past ~45 turns the capped segment count joined points hundreds of radians
  # apart, so the outline was a star polygon rather than the disc. The sweep is
  # now limited to one turn, so the box and the paint are exactly the disc's.
  box <- function(theta1) {
    s <- vl_scene(2, 2, dpi = 100) |>
      draw(sector_grob(r1 = 0.25, theta1 = theta1, key = "s"))
    m <- scene_model(s)$elements
    unlist(m[1, c("x0", "y0", "x1", "y1")])
  }
  full <- box(2 * pi)
  expect_equal(unname(full), c(50, 50, 150, 150), tolerance = 0.01)
  expect_equal(box(1e6), full, tolerance = 0.01)
  expect_equal(box(-1e6), full, tolerance = 0.01)
  # ...and painted as the full disc: the star polygon left pinholes.
  ink <- function(theta1) {
    a <- scene_raster(
      vl_scene(2, 2, dpi = 100, bg = "white") |>
        draw(sector_grob(
          r1 = 0.25,
          theta1 = theta1,
          gp = vl_gpar(fill = "black", col = NA)
        ))
    )
    sum(a[1, , ] < 128)
  }
  expect_equal(ink(1e6), ink(2 * pi))
})

# --- errors that ran on render worker threads -------------------------------

test_that("an out-of-range layout cell errors at compile, before an animation renders", {
  # Resolved lazily at render time, the cell check raised an R error from a
  # rayon worker thread when the scene was an animation keyframe.
  kf <- function(r) {
    vl_scene(1, 1, dpi = 30) |>
      push(vl_viewport(
        layout = grid_layout(vl_unit(c(1, 1), "null"), vl_unit(c(1, 1), "null"))
      )) |>
      push(vl_viewport(row = r, col = 1)) |>
      draw(rect_grob())
  }
  dir <- withr::local_tempdir()
  expect_error(
    vl_render_animation(list(kf(5), kf(1)), 1L, 0.5, dir, "frames"),
    "out of range"
  )
  expect_no_error(vl_render_animation(list(kf(2), kf(1)), 1L, 0.5, dir, "frames"))
})

test_that("keyframes of different pixel sizes are refused", {
  # Each frame is drawn at its left keyframe's size but the encoder was sized
  # from the first, so a GIF got frames of the wrong length (a panic).
  kf <- function(w) vl_scene(w, 1, dpi = 30, bg = "white") |> draw(rect_grob())
  f <- withr::local_tempfile(fileext = ".gif")
  expect_error(
    vl_render_animation(list(kf(1), kf(2), kf(1)), c(1L, 2L), c(0, 0.5), f),
    "same pixel size"
  )
})

test_that("a negative keyframe index is an error, not a wrapped index", {
  b <- .scene_to_backend(vl_scene(1, 1, dpi = 20))
  expect_error(
    render_animation(
      list(b, b),
      -1L,
      0.5,
      "frames",
      withr::local_tempdir(),
      delay_num = 1L,
      delay_den = 10L,
      gif_speed = 1L,
      gif_dither = FALSE,
      frac_col = 0.5,
      frac_size = 0.5,
      frac_alpha = 0.5,
      text_variants = list(),
      text_frame = integer(0)
    ),
    "references keyframe pair"
  )
})

# --- allocations sized by user input ----------------------------------------

test_that("a raster render over the pixel cap errors; vector output still works", {
  # 20000 x 20000 px passes the 30000 px per-side cap, but each raster layer is
  # 1.6 GB, and a failed allocation aborts the session.
  s <- vl_scene(200, 200, dpi = 100, bg = "white") |> draw(rect_grob())
  expect_error(scene_raster(s), "raster too large")
  expect_error(render(s, withr::local_tempfile(fileext = ".png")), "raster too large")
  expect_no_error(render(s, withr::local_tempfile(fileext = ".svg")))
})

test_that("vl_empty_region() refuses a grid too large to allocate", {
  s <- vl_scene(2, 2, dpi = 50) |> draw(points_grob(0.2, 0.2))
  expect_error(vl_empty_region(s, grid = 1e5), "grid too large")
  expect_no_error(vl_empty_region(s, grid = 50))
})

test_that("datashade() refuses a grid too large to allocate", {
  expect_error(
    datashade(runif(10), runif(10), width = 1e5, height = 1e5),
    "grid too large"
  )
  expect_error(
    datashade(
      runif(10),
      runif(10),
      width = 1e4,
      height = 1e4,
      category = rep(c("a", "b"), 5)
    ),
    "grid too large"
  )
})

# A minimal PNG writer: enough to hand-craft headers and palette images.
.png_crc32 <- function(bytes) {
  # Bitwise CRC-32 on doubles, kept to 32 bits via two 16-bit halves (bitwXor
  # works on signed 32-bit ints, which cannot hold the full range).
  xor32 <- function(a, b) {
    hi <- bitwXor(a %/% 65536, b %/% 65536)
    lo <- bitwXor(a %% 65536, b %% 65536)
    hi * 65536 + lo
  }
  crc <- 4294967295
  for (b in as.integer(bytes)) {
    crc <- xor32(crc, b)
    for (k in 1:8) {
      crc <- if (crc %% 2 == 1) xor32(crc %/% 2, 3988292384) else crc %/% 2
    }
  }
  xor32(crc, 4294967295)
}
.png_u32 <- function(v) as.raw(c(v %/% 2^24, (v %/% 2^16) %% 256, (v %/% 256) %% 256, v %% 256))
.png_chunk <- function(type, data = raw(0)) {
  td <- c(charToRaw(type), data)
  c(.png_u32(length(data)), td, .png_u32(.png_crc32(td)))
}
.png_file <- function(w, h, depth, ctype, idat, plte = NULL) {
  ihdr <- c(.png_u32(w), .png_u32(h), as.raw(c(depth, ctype, 0, 0, 0)))
  f <- withr::local_tempfile(fileext = ".png", .local_envir = parent.frame())
  writeBin(
    c(
      as.raw(c(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)),
      .png_chunk("IHDR", ihdr),
      if (!is.null(plte)) .png_chunk("PLTE", plte),
      .png_chunk("IDAT", memCompress(idat, "gzip")),
      .png_chunk("IEND")
    ),
    f
  )
  f
}

test_that("a PNG declaring a vast image is refused before allocating", {
  # A 1-bit 20000 x 20000 header fits the decoder's 64 MB buffer limit, but the
  # RGBA result was reserved at 16 bytes a pixel (6.4 GB) from the header alone.
  f <- .png_file(20000, 20000, 1L, 0L, as.raw(0))
  expect_error(raster_grob(f), "PNG too large")
})

test_that("palette and sub-byte PNGs are expanded to their colours", {
  # Indexed PNGs used to come back as grey palette indices.
  f <- .png_file(
    2,
    1,
    8L,
    3L,
    as.raw(c(0, 0, 1)),
    plte = as.raw(c(255, 0, 0, 0, 0, 255))
  )
  v <- rs_read_png(f)
  expect_equal(v, c(2L, 1L, 255L, 0L, 0L, 255L, 0L, 0L, 255L, 255L))
  # 1-bit greyscale: one byte holds eight pixels (0b10100000 -> white, black, white).
  g <- .png_file(3, 1, 1L, 0L, as.raw(c(0, 0xa0)))
  expect_equal(
    rs_read_png(g),
    c(3L, 1L, rep(255L, 4), 0L, 0L, 0L, 255L, rep(255L, 4))
  )
})

# --- unbounded loops ----------------------------------------------------------

test_that("a hachure fill on a huge sketched shape stays bounded", {
  # The scanline count was extent / gap with no cap: ~1e9 lines here (and, past
  # 2^53 gaps, a loop that never ended).
  for (style in c("hachure", "zigzag", "dots")) {
    s <- vl_scene(1, 1, dpi = 30, bg = "white") |>
      draw(circle_grob(
        r = vl_unit(5e7, "in"),
        sketch = sketch(fill_style = style),
        gp = vl_gpar(fill = "red", col = NA)
      ))
    t <- system.time(scene_raster(s))[["elapsed"]]
    expect_lt(t, 30)
  }
})

test_that("an enormous blur radius is clamped to the image", {
  # box_blur looped `radius` times per row; `blur = Inf` overflowed the window.
  for (b in c(1e9, Inf)) {
    s <- vl_scene(1, 1, dpi = 30, bg = "white") |>
      push(vl_viewport(blur = b)) |>
      draw(rect_grob(width = 0.5, gp = vl_gpar(fill = "black"))) |>
      pop()
    t <- system.time(px <- scene_raster(s))[["elapsed"]]
    expect_lt(t, 10)
    expect_equal(dim(px)[2:3], c(30L, 30L))
  }
})
