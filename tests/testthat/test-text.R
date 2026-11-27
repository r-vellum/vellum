test_that("vl_strwidth matches textshaping (fidelity) and scales", {
  ref <- textshaping::shape_text("Hello", size = 20)$metrics$width
  expect_equal(
    vl_strwidth("Hello", fontsize = 20, unit = "pt"),
    ref,
    tolerance = 1e-6
  )
  expect_equal(
    vl_strwidth("Hello", fontsize = 20, unit = "in"),
    ref / 72,
    tolerance = 1e-6
  )
  expect_gt(
    vl_strwidth("Hello", fontsize = 40),
    vl_strwidth("Hello", fontsize = 20)
  )
  expect_gt(vl_strwidth("Hello", fontface = "bold"), 0)
})

test_that("empty or NA labels are a no-op", {
  # "" and NA shape to nothing; whitespace shapes to (blank) space glyphs and
  # still emits one node.
  s <- vl_scene(1, 1, dpi = 50) |>
    draw(text_grob("")) |>
    draw(text_grob(NA)) |>
    draw(text_grob("   "))
  expect_equal(scene_len(s), 1L)
})

test_that("a text grob adds a node and paints ink, leaving the background intact", {
  s <- vl_scene(width = 2, height = 1, dpi = 100, bg = "white") |>
    draw(text_grob(
      "ABC",
      x = 0.5,
      y = 0.5,
      gp = vl_gpar(fontsize = 40, col = "black")
    ))
  expect_equal(scene_len(s), 1L)
  r <- scene_raster(s) # dim c(4, w, h)
  expect_equal(dim(r), c(4L, 200L, 100L))
  expect_lt(min(r[1, , ]), 100L) # dark ink somewhere
  expect_equal(r[1:3, 1, 1], c(255L, 255L, 255L)) # corner still white
})

test_that("text colour reaches the raster", {
  s <- vl_scene(width = 2, height = 1, dpi = 100, bg = "white") |>
    draw(text_grob("ABC", gp = vl_gpar(fontsize = 40, col = "red")))
  r <- scene_raster(s)
  green <- r[2, , ]
  idx <- which(green == min(green), arr.ind = TRUE)[1, ]
  p <- r[, idx[1], idx[2]]
  expect_gt(p[1], p[2]) # red dominates green
  expect_gt(p[1], p[3]) # red dominates blue
})

test_that("the shape cache is transparent: cold and warm renders are identical", {
  clear <- function() {
    rm(
      list = setdiff(ls(.shape_cache, all.names = TRUE), ".n"),
      envir = .shape_cache
    )
  }
  scene <- function() {
    vl_scene(2, 1, dpi = 100, bg = "white") |>
      draw(text_grob(
        c("Ab", "Ab", "cD"),
        x = c(0.2, 0.5, 0.8),
        y = 0.5,
        gp = vl_gpar(fontsize = 24)
      ))
  }
  clear()
  cold <- scene_raster(scene()) # populates the cache (one shape per distinct label)
  warm <- scene_raster(scene()) # all cache hits
  expect_identical(cold, warm)
})

test_that("the shape cache keys on size (no cross-size collision)", {
  # Same string at two sizes must produce different ink widths -> the cache key
  # includes size (otherwise the second render would reuse the first's glyphs).
  ink_w <- function(sz) {
    red <- scene_raster(
      vl_scene(3, 1, dpi = 100, bg = "white") |>
        draw(text_grob(
          "WW",
          x = 0.5,
          y = 0.5,
          gp = vl_gpar(fontsize = sz, col = "black")
        ))
    )[1, , ]
    cols <- which(apply(red, 1, min) < 100)
    if (length(cols)) diff(range(cols)) else 0
  }
  expect_gt(ink_w(40), ink_w(12))
})

test_that("the persistent glyph cache is transparent (cold == warm render)", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(text_grob(
      "Ahoy Ahoy",
      x = 0.5,
      y = 0.5,
      gp = vl_gpar(fontsize = 28, col = "black")
    ))
  rs_clear_glyph_cache()
  cold <- scene_raster(s) # populates the persistent glyph cache
  warm <- scene_raster(s) # reuses it
  expect_identical(cold, warm)
})

test_that("a newline produces two stacked lines of text", {
  # "X" over "X": two separated dark bands in the central column.
  s <- vl_scene(1, 1.5, dpi = 100, bg = "white") |>
    draw(text_grob(
      "X\nX",
      x = 0.5,
      y = 0.5,
      gp = vl_gpar(fontsize = 40, col = "black")
    ))
  col <- scene_raster(s)[1, 50, ] # central column, top->bottom
  dark <- which(col < 128L)
  expect_gt(length(dark), 0L)
  # a gap between the two glyph bands => more than one contiguous run of ink
  runs <- sum(diff(dark) > 1L) + 1L
  expect_gte(runs, 2L)
})

test_that("justification places text on the correct side of the anchor", {
  inked_x <- function(hjust) {
    s <- vl_scene(width = 3, height = 1, dpi = 100, bg = "white") |>
      draw(text_grob(
        "WORD",
        x = 0.5,
        y = 0.5,
        just = as.character(hjust),
        gp = vl_gpar(fontsize = 30, col = "black")
      ))
    red <- scene_raster(s)[1, , ]
    which(apply(red, 1, min) < 100) # x columns containing ink
  }
  anchor_px <- 150 # x = 0.5 of a 300px-wide device
  expect_gt(mean(inked_x(0)), anchor_px) # left-justified -> ink right of anchor
  expect_lt(mean(inked_x(1)), anchor_px) # right-justified -> ink left of anchor
})

test_that("text measured outside a render has a finite width, or errors", {
  # VR-15: no scene or device exists here. A valid size measures a sane width
  # on every platform ...
  w <- vl_strwidth(c("p", "a longer label"), fontsize = 8.8, unit = "mm")
  expect_true(all(is.finite(w) & w > 0 & w < 100))
  h <- vl_strheight("Ag", fontsize = 8.8, unit = "mm")
  expect_true(is.finite(h) && h > 0 && h < 100)
  expect_true(all(is.finite(vellum:::.grob_extent(text_grob("legend")))))
  # ... and a missing or non-finite one is an error, not textshaping's
  # platform-dependent cast (-33554432 pt on x86_64 Linux, 0 on arm64)
  for (fs in list(NULL, NA_real_, NaN, Inf)) {
    expect_error(
      vl_strwidth("p", "", "plain", fs, unit = "mm"),
      "finite number of points"
    )
    expect_error(vl_strheight("Ag", fontsize = fs), "finite number of points")
  }
  expect_error(vl_strwidth("p", cex = NA), "finite number of points")
  expect_error(
    vl_strwidth(md("**p**"), fontsize = NA),
    "finite number of points"
  )
})

test_that("an absurd font size is an error, not a crash (VR-38 review)", {
  # textshaping segfaults on a face sized past FreeType's 16-bit ppem; vellum
  # refuses such a size before shaping. Run in a child so a regression fails
  # here rather than killing the test run.
  res <- run_vellum_child(c(
    "s <- draw(vl_scene(2, 2), text_grob('Hello', gp = vl_gpar(fontsize = 1e30)))",
    "msg <- tryCatch({render(s, tempfile(fileext = '.png')); 'drawn'},",
    "  error = function(e) conditionMessage(e))",
    "cat(gsub('\\n', ' ', msg), '\\n')",
    "f <- tempfile(fileext = '.pdf')",
    "render(draw(vl_scene(2, 2), text_grob('Hi', gp = vl_gpar(fontsize = 9000))), f)",
    "cat('alive\\n')"
  ))
  expect_identical(res$status, 0L)
  expect_match(paste(res$output, collapse = " "), "at most 10000 points")
  expect_identical(tail(res$output, 1), "alive")
  expect_error(
    vl_strwidth("Hello", fontsize = 2e4),
    "at most 10000 points"
  )
})

test_that("a face systemfonts cannot open is shaped in the default font (VL-22)", {
  # textshaping uses a face systemfonts failed to load and crashes R (macOS
  # Skia once system_fonts() has run): vellum checks the face first.
  local_mocked_bindings(
    font_info = function(...) stop("Failed to open font file"),
    .package = "systemfonts"
  )
  rm(list = ls(vellum:::.face_warned), envir = vellum:::.face_warned)
  expect_warning(
    w <- vl_strwidth("Hamburg", family = "serif", fontsize = 20),
    "could not be loaded"
  )
  expect_equal(w, vl_strwidth("Hamburg", family = "", fontsize = 20))
  # once per face
  expect_no_warning(vl_strwidth("Hamburg", family = "serif", fontsize = 21))
  sc <- vl_scene(2, 1, dpi = 72) |>
    draw(text_grob("Hamburg", gp = vl_gpar(fontfamily = "serif")))
  expect_no_error(scene_raster(sc))
})
