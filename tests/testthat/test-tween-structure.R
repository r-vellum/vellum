# Keyframes that cannot be tweened element by element -- a different number of
# nodes, a line whose vertex count changes, a changed text label -- must still
# show every keyframe: the frames switch to the right keyframe at the positional
# midpoint (VR-26, VR-27, VR-28). These tests look at mid-transition frames, not
# just the keyframes.

panel_scene <- function(...) {
  s <- vl_scene(2, 1.5, dpi = 60, bg = "white") |>
    push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1), name = "panel"))
  for (g in list(...)) {
    s <- draw(s, g)
  }
  pop(s)
}

# Render the frames `seg`/`frac` of `keys` and return them as arrays.
tween_frames <- function(keys, frac, seg = rep(1L, length(frac)), ...) {
  dir <- withr::local_tempdir(.local_envir = parent.frame())
  vl_render_animation(keys, seg, frac, dir, format = "frames", ...)
  lapply(sort(list.files(dir, full.names = TRUE)), png::readPNG)
}

# A keyframe drawn alone (a one-segment animation held at fraction 0).
still <- function(s) tween_frames(list(s, s), 0)[[1L]]

test_that("an unkeyed node with no counterpart switches at the midpoint", {
  skip_if_not_installed("png")
  circ <- function(x) {
    circle_grob(x = x, y = 0.5, r = 0.2, gp = vl_gpar(fill = "steelblue", col = NA))
  }
  sq <- rect_grob(
    x = 0.2,
    y = 0.2,
    width = 0.2,
    height = 0.2,
    gp = vl_gpar(fill = "tomato", col = NA)
  )
  a <- panel_scene(circ(0.3))
  b <- panel_scene(circ(0.7), sq)
  fr <- tween_frames(list(a, b), c(0, 0.4, 0.6, 1))
  expect_equal(fr[[1]], still(a))
  # The circle pairs with the circle and moves; the square, which has no
  # counterpart, is absent before the midpoint and present from it on.
  expect_equal(fr[[2]], still(panel_scene(circ(0.46))), tolerance = 0.01)
  expect_equal(fr[[3]], still(panel_scene(circ(0.54), sq)), tolerance = 0.01)
  expect_equal(fr[[4]], still(b))
  p <- vl_tween_pairing(list(a, b, b))
  expect_identical(p$paired, c(TRUE, TRUE))
  expect_identical(p$nodes_to[1] - p$nodes_from[1], 1L)
  expect_identical(p$snapped, c(1L, 0L))
  expect_identical(p$entered, c(0L, 0L))
})

test_that("keyframes on different viewport trees cut at the midpoint", {
  skip_if_not_installed("png")
  dot <- circle_grob(x = 0.3, r = 0.2, gp = vl_gpar(fill = "steelblue", col = NA))
  a <- panel_scene(dot)
  b <- vl_scene(2, 1.5, dpi = 60, bg = "white") |>
    push(vl_viewport(width = 0.5, xscale = c(0, 1), name = "left")) |>
    draw(dot) |>
    pop() |>
    push(vl_viewport(x = 0.75, width = 0.5, name = "right")) |>
    draw(dot) |>
    pop()
  fr <- tween_frames(list(a, b), c(0.4, 0.6))
  expect_equal(fr[[1]], still(a))
  expect_equal(fr[[2]], still(b))
  p <- vl_tween_pairing(list(a, b))
  expect_false(p$paired)
  expect_identical(p$snapped, NA_integer_)
})

# --- identity: keyed marks match by key, not by position (VR-32) ------------

# A scene of keyed point batches, one per colour (like one node per colour group).
keyed_scene <- function(groups) {
  s <- vl_scene(2, 1.5, dpi = 60, bg = "white") |>
    push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1), name = "panel"))
  for (g in groups) {
    s <- draw(
      s,
      points_grob(
        x = g$x,
        y = g$y,
        size = vl_unit(4, "mm"),
        gp = vl_gpar(fill = g$fill, col = NA),
        key = g$key
      )
    )
  }
  pop(s)
}
grp <- function(fill, key, x, y = rep(0.5, length(x))) {
  list(fill = fill, key = key, x = x, y = y)
}

test_that("keyed batches match by key whatever their node order", {
  skip_if_not_installed("png")
  red <- grp("red", c("r1", "r2"), c(0.2, 0.4))
  blue <- grp("blue", c("b1", "b2"), c(0.6, 0.8))
  a <- keyed_scene(list(red, blue))
  # Same marks in the same places; the nodes and the rows within them reordered.
  b <- keyed_scene(list(
    grp("blue", c("b2", "b1"), c(0.8, 0.6)),
    grp("red", c("r2", "r1"), c(0.4, 0.2))
  ))
  mid <- tween_frames(list(a, b), 0.5)[[1]]
  # Nothing moves: the mid frame is the keyframe (no muddy blend of red and blue).
  expect_equal(mid, still(a))
  p <- vl_tween_pairing(list(a, b))
  expect_identical(c(p$snapped, p$exited, p$entered), c(0L, 0L, 0L))
})

test_that("a keyed point moving to another colour batch slides and recolours", {
  skip_if_not_installed("png")
  a <- keyed_scene(list(grp("red", c("p", "q"), c(0.2, 0.5), c(0.3, 0.7))))
  b <- keyed_scene(list(
    grp("red", "q", 0.5, 0.7),
    grp("blue", "p", 0.8, 0.3)
  ))
  mid <- tween_frames(list(a, b), 0.5)[[1]]
  px <- function(img, x, y) {
    img[round((1 - y) * dim(img)[1]), round(x * dim(img)[2]), 1:3]
  }
  # Halfway along its path, in a colour between red and blue.
  m <- px(mid, 0.5, 0.3)
  expect_gt(m[1], 0.25)
  expect_gt(m[3], 0.25)
  expect_lt(m[2], 0.6)
  # Not drawn at either end.
  expect_equal(px(mid, 0.2, 0.3), c(1, 1, 1))
  expect_equal(px(mid, 0.8, 0.3), c(1, 1, 1))
  # The other point stays put and stays red.
  expect_equal(px(mid, 0.5, 0.7), px(still(a), 0.5, 0.7))
  p <- vl_tween_pairing(list(a, b))
  expect_identical(c(p$exited, p$entered), c(0L, 0L))
})

test_that("a keyed group appearing fades in instead of cutting", {
  skip_if_not_installed("png")
  red <- grp("red", c("r1", "r2"), c(0.2, 0.4))
  a <- keyed_scene(list(red))
  b <- keyed_scene(list(red, grp("blue", "b1", 0.8)))
  fr <- tween_frames(list(a, b), c(0, 0.5, 1))
  img <- fr[[2]]
  at <- function(img, x) img[round(0.5 * dim(img)[1]), round(x * dim(img)[2]), 1:3]
  # Half faded at the midpoint: neither absent nor fully blue.
  expect_gt(at(img, 0.8)[1], 0.2)
  expect_lt(at(img, 0.8)[1], 0.9)
  # The red points are untouched throughout.
  expect_equal(at(img, 0.2), at(still(a), 0.2))
  expect_equal(fr[[3]], still(b))
  p <- vl_tween_pairing(list(a, b))
  expect_identical(c(p$paired, p$snapped, p$exited, p$entered), c(1L, 0L, 0L, 1L))
})

test_that("keyed rects and labels slide to their new places", {
  skip_if_not_installed("png")
  bars <- function(order) {
    s <- vl_scene(2, 1.5, dpi = 60, bg = "white") |>
      push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1), name = "panel"))
    for (k in seq_along(order)) {
      s <- s |>
        draw(rect_grob(
          x = 0.35,
          y = k / 4,
          width = 0.5,
          height = 0.15,
          gp = vl_gpar(fill = c(A = "red", B = "blue", C = "darkgreen")[[order[k]]], col = NA),
          key = order[k]
        )) |>
        draw(text_grob(order[k], x = 0.7, y = k / 4, key = paste0("t", order[k])))
    }
    pop(s)
  }
  a <- bars(c("A", "B", "C"))
  b <- bars(c("C", "A", "B"))
  p <- vl_tween_pairing(list(a, b))
  expect_identical(c(p$snapped, p$exited, p$entered), c(0L, 0L, 0L))
  mid <- tween_frames(list(a, b), 0.5)[[1]]
  row <- function(y) mid[round((1 - y) * dim(mid)[1]), round(0.3 * dim(mid)[2]), 1:3]
  # C slides from the top (y = .75) to the bottom (.25): at the midpoint it is
  # level with the middle row, and it is still green, not a red/green blend.
  expect_equal(row(0.5), c(0, 100 / 255, 0), tolerance = 0.02)
})

test_that("a line whose vertex count changes morphs and ends on the later shape (VR-37)", {
  skip_if_not_installed("png")
  a <- panel_scene(lines_grob(x = c(0.1, 0.5, 0.9), y = c(0.2, 0.4, 0.2), key = "L"))
  b <- panel_scene(lines_grob(
    x = c(0.1, 0.3, 0.5, 0.7, 0.9),
    y = c(0.2, 0.8, 0.2, 0.8, 0.2),
    key = "L"
  ))
  # The keyframes themselves are exact.
  fr <- tween_frames(list(a, b), c(0, 1))
  expect_equal(fr[[1]], still(a))
  expect_equal(fr[[2]], still(b))
  p <- vl_tween_pairing(list(a, b))
  expect_true(p$paired)
  expect_identical(p$snapped, 0L)
  # In between, the outline grows from a's height to b's: the top edge of the
  # box moves steadily rather than jumping at the midpoint.
  top <- function(f) {
    et <- as.data.frame(vellum:::.tween_frame(a, b, f)$element_table())
    min(et$y0[et$key == "L"])
  }
  tops <- vapply(c(0, 0.25, 0.5, 0.75, 1), top, numeric(1))
  expect_true(all(diff(tops) < 0))
  expect_gt(tops[3], tops[5] + 5)
  expect_lt(tops[3], tops[1] - 5)
})

test_that("polygons and paths with different vertex counts morph (VR-37)", {
  a <- panel_scene(
    polygon_grob(x = c(0.1, 0.3, 0.2), y = c(0.6, 0.6, 0.9), key = "P"),
    path_grob(x = c(0.1, 0.3, 0.2), y = c(0.1, 0.1, 0.3), key = "Q")
  )
  b <- panel_scene(
    polygon_grob(x = c(0.6, 0.9, 0.9, 0.6), y = c(0.6, 0.6, 0.9, 0.9), key = "P"),
    path_grob(x = c(0.6, 0.9, 0.9, 0.6), y = c(0.1, 0.1, 0.3, 0.3), key = "Q")
  )
  expect_identical(vl_tween_pairing(list(a, b))$snapped, 0L)
  x0 <- function(f, k) {
    et <- as.data.frame(vellum:::.tween_frame(a, b, f)$element_table())
    et$x0[et$key == k]
  }
  for (k in c("P", "Q")) {
    xs <- vapply(c(0, 0.5, 1), x0, numeric(1), k = k)
    expect_true(xs[1] < xs[2] && xs[2] < xs[3])
  }
})

test_that("a line in mixed units still switches at the midpoint", {
  a <- panel_scene(lines_grob(x = c(0.1, 0.9), y = c(0.2, 0.2), key = "L"))
  b <- panel_scene(lines_grob(
    x = vl_unit(c(0.1, 0.5, 0.9), "npc"),
    y = vl_unit(c(10, 20, 10), "mm"),
    key = "L"
  ))
  expect_identical(vl_tween_pairing(list(a, b))$snapped, 1L)
})

test_that("an equal-shape line still tweens (no snap)", {
  skip_if_not_installed("png")
  a <- panel_scene(lines_grob(x = c(0.1, 0.9), y = c(0.2, 0.2)))
  b <- panel_scene(lines_grob(x = c(0.1, 0.9), y = c(0.8, 0.8)))
  mid <- tween_frames(list(a, b), 0.5)[[1]]
  expect_false(isTRUE(all.equal(mid, still(a))))
  expect_false(isTRUE(all.equal(mid, still(b))))
  expect_identical(vl_tween_pairing(list(a, b))$snapped, 0L)
})

test_that("a changed text label switches to the later string at the midpoint", {
  skip_if_not_installed("png")
  a <- panel_scene(text_grob("first", x = 0.5, y = 0.5))
  b <- panel_scene(text_grob("third!", x = 0.5, y = 0.5))
  fr <- tween_frames(list(a, b), c(0.4, 0.6, 1))
  expect_equal(fr[[1]], still(a))
  expect_equal(fr[[2]], still(b))
  expect_equal(fr[[3]], still(b))
})

test_that("easing overshoot never draws a negative size or out-of-range alpha", {
  skip_if_not_installed("png")
  a <- panel_scene(circle_grob(
    x = 0.5,
    y = 0.5,
    r = 0.05,
    gp = vl_gpar(fill = "black", alpha = 0.2)
  ))
  b <- panel_scene(circle_grob(
    x = 0.5,
    y = 0.5,
    r = 0.4,
    gp = vl_gpar(fill = "black", alpha = 1)
  ))
  # Size and alpha far below 0: the circle collapses to nothing (blank page),
  # rather than a radius of -0.3.
  fr <- tween_frames(list(a, b), 0, frac_size = -1, frac_alpha = -1)
  blank <- still(panel_scene())
  expect_equal(fr[[1]], blank)
  # Far above 1: alpha clamps at 1, the radius overshoots (sizes may grow).
  over <- tween_frames(list(a, b), 1, frac_alpha = 3)[[1]]
  expect_equal(over, still(b))
})

# --- the animated SVG ---------------------------------------------------------

anim_svg <- function(keys, seg, frac, fps = 10) {
  f <- withr::local_tempfile(fileext = ".svg", .local_envir = parent.frame())
  vl_render_animation(keys, seg, frac, f, format = "svg", fps = fps)
  paste(readLines(f, warn = FALSE), collapse = "\n")
}

css_names <- function(svg) {
  st <- regmatches(svg, regexpr("<style>.*?</style>", svg))
  list(
    class = unique(regmatches(
      st,
      gregexpr("\\.[A-Za-z_][A-Za-z0-9_-]*vf\\b", st)
    )[[1]]),
    keyframes = regmatches(st, regexpr("@keyframes [^{]+", st))
  )
}

test_that("two animated SVGs use distinct CSS names (no page-wide collision)", {
  k1 <- list(
    panel_scene(circle_grob(x = 0.2, r = 0.1)),
    panel_scene(circle_grob(x = 0.8, r = 0.1))
  )
  k2 <- list(
    panel_scene(rect_grob(x = 0.2, width = 0.1)),
    panel_scene(rect_grob(x = 0.8, width = 0.1))
  )
  s1 <- anim_svg(k1, rep(1L, 4), (0:3) / 3)
  s2 <- anim_svg(k2, rep(1L, 8), (0:7) / 7, fps = 4)
  n1 <- css_names(s1)
  n2 <- css_names(s2)
  # No bare, global `.vf` / `vfcycle` any more.
  expect_false(grepl("\\.vf\\{|vfcycle", s1))
  expect_length(n1$class, 1L)
  expect_false(identical(n1$class, n2$class))
  expect_false(identical(n1$keyframes, n2$keyframes))
  # Every frame group carries the prefixed class, and no NUL token survives.
  cls <- sub("^\\.", "", n1$class)
  expect_identical(
    lengths(regmatches(s1, gregexpr(paste0("class=\"", cls), s1))),
    4L
  )
  expect_false(grepl("\\x01|\\x00", s1, useBytes = TRUE))
  # Element ids stay unique within the document.
  ids <- regmatches(s1, gregexpr(" id=\"[^\"]+\"", s1))[[1]]
  expect_false(anyDuplicated(ids) > 0)
})

test_that("an explicit a11y prefix becomes a valid CSS identifier", {
  k <- list(
    panel_scene(circle_grob(x = 0.2, r = 0.1)),
    panel_scene(circle_grob(x = 0.8, r = 0.1))
  )
  k <- lapply(k, function(s) {
    s@a11y_prefix <- "my fig.1"
    s
  })
  svg <- anim_svg(k, rep(1L, 3), c(0, 0.5, 1))
  expect_identical(css_names(svg)$class, ".my_fig_1-vf")
})

test_that("reduced motion holds the last frame when the schedule ends on the last keyframe", {
  k <- list(
    panel_scene(circle_grob(x = 0.2, r = 0.1)),
    panel_scene(circle_grob(x = 0.8, r = 0.1))
  )
  still_index <- function(svg) {
    g <- regmatches(
      svg,
      gregexpr("<g class=\"[^\"]*\" style=\"animation-delay", svg)
    )[[1]]
    which(grepl("-vs\"", g))
  }
  # Ends at fraction 1 (a reveal, a time series): the complete picture.
  expect_identical(still_index(anim_svg(k, rep(1L, 5), (0:4) / 4)), 5L)
  # A loop (stops short of the end): its first frame.
  expect_identical(still_index(anim_svg(k, rep(1L, 5), (0:4) / 5)), 1L)
  svg <- anim_svg(k, rep(1L, 5), (0:4) / 4)
  expect_match(
    svg,
    "prefers-reduced-motion:reduce\\)\\{\\.[^{]+-vf\\{animation:none\\}\\.[^{]+-vs\\{visibility:visible\\}"
  )
})

# --- frame timing -------------------------------------------------------------

test_that("fps becomes an exact rational frame delay", {
  expect_identical(.fps_delay(25), c(1L, 25L))
  expect_identical(.fps_delay(12.5), c(2L, 25L))
  expect_identical(.fps_delay(0.5), c(2L, 1L))
  expect_identical(.fps_delay(0.4), c(5L, 2L))
  expect_identical(.fps_delay(0.25), c(4L, 1L))
  expect_identical(.fps_delay(29.97), c(100L, 2997L))
  # Beyond what 16-bit terms can hold: the nearest bound, never 0.
  expect_identical(.fps_delay(1e5), c(1L, 65535L))
  expect_identical(.fps_delay(1e-6), c(65535L, 1L))
})

test_that("the APNG and animated SVG carry the exact delay", {
  skip_if_not_installed("png")
  k <- list(
    panel_scene(circle_grob(x = 0.2, r = 0.1)),
    panel_scene(circle_grob(x = 0.8, r = 0.1))
  )
  out <- withr::local_tempfile(fileext = ".png")
  vl_render_animation(
    k,
    rep(1L, 3),
    c(0, 0.5, 1),
    out,
    format = "apng",
    fps = 12.5
  )
  raw <- readBin(out, "raw", n = file.size(out))
  # First fcTL: seq(4) w(4) h(4) x(4) y(4) delay_num(2) delay_den(2).
  pos <- grepRaw("fcTL", raw)
  u16 <- function(i) sum(as.integer(raw[i:(i + 1L)]) * c(256, 1))
  expect_identical(c(u16(pos + 24L), u16(pos + 26L)), c(2, 25))
  # Animated SVG: 4 frames at 0.5 fps = 8 s, not the 4 s a rounded 1 fps gives.
  svg <- anim_svg(k, rep(1L, 4), (0:3) / 3, fps = 0.5)
  expect_match(svg, "vc 8s steps")
})

test_that("a GIF above 50 fps warns that it will play slower", {
  k <- list(
    panel_scene(circle_grob(x = 0.2, r = 0.1)),
    panel_scene(circle_grob(x = 0.8, r = 0.1))
  )
  out <- withr::local_tempfile(fileext = ".gif")
  expect_warning(
    vl_render_animation(k, rep(1L, 2), c(0, 1), out, format = "gif", fps = 60),
    "50 fps"
  )
  expect_no_warning(vl_render_animation(
    k,
    rep(1L, 2),
    c(0, 1),
    out,
    format = "gif",
    fps = 50
  ))
})

test_that("a mid-transition frame places each keyed element by its key", {
  a <- keyed_scene(list(
    grp("red", c("a", "b", "c"), c(0.1, 0.3, 0.5)),
    grp("blue", "d", 0.9)
  ))
  # Rows reordered, `c` gone, `d` moved to the red batch, `e` new.
  b <- keyed_scene(list(
    grp("blue", c("e", "b"), c(0.7, 0.5)),
    grp("red", c("d", "a"), c(0.1, 0.3))
  ))
  et <- as.data.frame(.tween_frame(a, b, 0.5)$element_table())
  cx <- (et$x0 + et$x1) / 2
  names(cx) <- et$key
  w <- 2 * 60 # page px
  expect_setequal(et$key, c("a", "b", "c", "d", "e"))
  expect_equal(cx[["a"]] / w, 0.2, tolerance = 0.01)
  expect_equal(cx[["b"]] / w, 0.4, tolerance = 0.01)
  expect_equal(cx[["d"]] / w, 0.5, tolerance = 0.01)
  # the leaving and entering points stay where they are while they fade
  expect_equal(cx[["c"]] / w, 0.5, tolerance = 0.01)
  expect_equal(cx[["e"]] / w, 0.7, tolerance = 0.01)
  p <- vl_tween_pairing(list(a, b))
  expect_identical(c(p$exited, p$entered), c(1L, 1L))
})

test_that("an animated SVG carries no data keys", {
  a <- keyed_scene(list(grp("red", c("a", "b"), c(0.2, 0.4))))
  b <- keyed_scene(list(grp("red", c("b", "a"), c(0.6, 0.8))))
  svg <- anim_svg(list(a, b), rep(1L, 3), c(0, 0.5, 1))
  expect_false(grepl("data-key", svg, fixed = TRUE))
})

test_that("keyed hexagons, sectors and segments match by key, not order (VR-33)", {
  xs <- c(0.2, 0.5, 0.8)
  k <- c("a", "b", "c")
  build <- function(o) {
    panel_scene(
      hexagon_grob(x = xs, y = 0.8, size = vl_unit(1, "mm"), key = k[o]),
      sector_grob(x = xs, y = 0.5, r1 = 0.05, key = paste0("s", k[o])),
      segments_grob(x0 = xs, y0 = 0.2, x1 = xs + 0.05, y1 = 0.25, key = paste0("g", k[o]))
    )
  }
  a <- build(1:3)
  b <- build(c(3, 1, 2)) # the keys move one place along
  p <- vl_tween_pairing(list(a, b))
  expect_identical(c(p$snapped, p$exited, p$entered), c(0L, 0L, 0L))
  cx <- function(f) {
    et <- as.data.frame(vellum:::.tween_frame(a, b, f)$element_table())
    et <- et[et$key != "", ]
    stats::setNames((et$x0 + et$x1) / 2, et$key)
  }
  c0 <- cx(0)
  c1 <- cx(1)
  mid <- cx(0.5)
  for (key in c("a", "sa", "ga", "c", "sc", "gc")) {
    # Each element travels from its own place to its own new place.
    expect_equal(mid[[key]], (c0[[key]] + c1[[key]]) / 2, tolerance = 0.02)
  }
  # "c" moves from the right to the left: by order it would have stayed put.
  expect_lt(c1[["c"]], c0[["c"]])
  # A keyed hexagon that leaves fades out instead of switching.
  b2 <- panel_scene(
    hexagon_grob(x = xs[1:2], y = 0.8, size = vl_unit(1, "mm"), key = k[1:2]),
    sector_grob(x = xs, y = 0.5, r1 = 0.05, key = paste0("s", k)),
    segments_grob(x0 = xs, y0 = 0.2, x1 = xs + 0.05, y1 = 0.25, key = paste0("g", k))
  )
  p2 <- vl_tween_pairing(list(a, b2))
  expect_identical(c(p2$snapped, p2$exited), c(0L, 1L))
})

test_that("overlapping marks swap paint order at the midpoint, not the keyframe (VR-35)", {
  sq <- function(key, fill, x) {
    rect_grob(x = x, y = 0.5, width = 0.4, height = 0.6, key = key, gp = vl_gpar(fill = fill, col = NA))
  }
  # Red over blue in `a`, blue over red in `b`; the squares overlap throughout.
  a <- panel_scene(sq("blue", "blue", 0.45), sq("red", "red", 0.55))
  b <- panel_scene(sq("red", "red", 0.55), sq("blue", "blue", 0.45))
  order_at <- function(f) {
    et <- as.data.frame(vellum:::.tween_frame(a, b, f)$element_table())
    et$key[et$key != ""]
  }
  expect_identical(order_at(0), c("blue", "red"))
  expect_identical(order_at(0.25), c("blue", "red"))
  expect_identical(order_at(0.5), c("red", "blue"))
  expect_identical(order_at(0.75), c("red", "blue"))
  # Within one batch too.
  a1 <- panel_scene(rect_grob(x = c(0.45, 0.55), y = 0.5, width = 0.4, height = 0.6, key = c("p", "q")))
  b1 <- panel_scene(rect_grob(x = c(0.55, 0.45), y = 0.5, width = 0.4, height = 0.6, key = c("q", "p")))
  ord1 <- function(f) {
    et <- as.data.frame(vellum:::.tween_frame(a1, b1, f)$element_table())
    et$key[et$key != ""]
  }
  expect_identical(ord1(0.25), c("p", "q"))
  expect_identical(ord1(0.75), c("q", "p"))
})

test_that("vl_render_frame() draws the animation's frame on its own (VP-96)", {
  skip_if_not_installed("png")
  dot <- function(x, r, lab) {
    panel_scene(
      circle_grob(x = x, y = 0.5, r = r, gp = vl_gpar(fill = "steelblue", col = NA)),
      text_grob(lab, x = 0.5, y = 0.9, key = "t")
    )
  }
  a <- dot(0.2, 0.1, "A")
  b <- dot(0.8, 0.3, "B")
  v <- vl_scene(2, 1.5, dpi = 60) |> draw(text_grob("mid", key = "t"))
  fr <- tween_frames(list(a, b), c(0.3, 0.6), text_variants = list(v), text_frame = c(0L, 1L))
  one <- function(frac, ...) {
    f <- withr::local_tempfile(fileext = ".png", .local_envir = parent.frame())
    vl_render_frame(list(a, b), 1, frac, f, ...)
    png::readPNG(f)
  }
  expect_equal(one(0.3), fr[[1]])
  expect_equal(one(0.6, text_variant = v), fr[[2]])
  # SVG and PDF too; `scale` multiplies the resolution.
  s <- withr::local_tempfile(fileext = ".svg")
  vl_render_frame(list(a, b), 1, 0.5, s)
  expect_match(paste(readLines(s, warn = FALSE), collapse = ""), "<svg")
  p <- withr::local_tempfile(fileext = ".pdf")
  vl_render_frame(list(a, b), 1, 0.5, p)
  expect_gt(file.size(p), 0)
  big <- one(0.3, scale = 2)
  expect_identical(dim(big)[1:2], 2L * dim(fr[[1]])[1:2])
  expect_error(vl_render_frame(list(a, b), 2, 0.5, s), "seg")
  expect_error(vl_render_frame(list(a, b), 1, 0.5, "x.gif"), "Unsupported")
})
