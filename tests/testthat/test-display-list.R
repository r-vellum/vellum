# VR-14: the marks-only display list. Decoded with the reference decoder in
# helper-display-list.R and checked against the scene's own element geometry.

.dl_scene <- function() {
  vl_scene(5, 4, dpi = 96, bg = "white") |>
    # Unkeyed furniture: never listed.
    draw(rect_grob(gp = vl_gpar(fill = "grey90"))) |>
    draw(text_grob("title", x = 0.5, y = 0.97)) |>
    push(vl_viewport(
      x = 0.5,
      y = 0.5,
      width = 0.8,
      height = 0.8,
      clip = TRUE,
      name = "panel-a"
    )) |>
    draw(points_grob(
      x = c(0.1, 0.2, 0.3),
      y = c(0.1, 0.2, 0.3),
      size = c(1, 2, 3),
      gp = vl_gpar(fill = "steelblue", col = "navy", lwd = 2),
      key = c("c1", "c2", "c3")
    )) |>
    draw(points_grob(
      x = c(0.5, 0.6, 0.7),
      y = 0.8,
      size = 2,
      shape = c("square", "triangle", "plus"),
      gp = vl_gpar(fill = "orange", col = "black"),
      key = c("m1", "m2", "m3")
    )) |>
    draw(rect_grob(
      x = c(0.2, 0.4),
      y = 0.5,
      width = 0.1,
      height = c(0.2, 0.3),
      gp = vl_gpar(fill = "tomato", col = NA),
      key = c("r1", "r2")
    )) |>
    draw(segments_grob(
      x0 = 0.6,
      y0 = 0.2,
      x1 = 0.9,
      y1 = 0.4,
      gp = vl_gpar(col = "darkgreen", lwd = 3, lty = "dashed"),
      key = "s1"
    )) |>
    draw(polygon_grob(
      c(0.6, 0.8, 0.7),
      c(0.5, 0.5, 0.7),
      gp = vl_gpar(fill = "purple", col = "black"),
      key = "poly"
    )) |>
    draw(lines_grob(c(0.05, 0.3, 0.5), c(0.9, 0.95, 0.9), key = "ln")) |>
    draw(text_grob("lab", x = 0.9, y = 0.9, key = "tx")) |>
    pop() |>
    # A keyed mark inside a translucent group, and one with a gradient fill.
    push(vl_viewport(alpha = 0.5)) |>
    draw(points_grob(0.95, 0.05, size = 2, key = "grp")) |>
    pop() |>
    draw(circle_grob(
      x = 0.05,
      y = 0.05,
      r = 0.03,
      gp = vl_gpar(fill = linear_gradient(c("red", "blue"))),
      key = "grad"
    ))
}

test_that("the display list lists every keyed mark, in paint order, and nothing else", {
  skip_if_not_installed("jsonlite")
  s <- .dl_scene()
  dl <- scene_display_list(s)
  expect_identical(dl$format, "vellum-display-list")
  d <- .dl_decode(dl)
  el <- scene_model(s)$elements
  el <- el[!is.na(el$key), ]
  expect_setequal(unique(d$key), el$key)
  expect_identical(unique(d$key), unique(el$key)) # paint order
  expect_equal(c(dl$width, dl$height), c(5, 4) * 96)
  expect_true(all(
    d$panel[d$key %in% c("c1", "m1", "r1", "s1", "poly")] == "panel-a"
  ))
})

test_that("points, rects and paths round-trip against the element geometry", {
  skip_if_not_installed("jsonlite")
  s <- .dl_scene()
  d <- .dl_decode(scene_display_list(s))
  el <- scene_model(s)$elements
  bb <- el[match(d$key, el$key), ]
  tol <- 1e-3 # f32 device px

  pt <- d$kind == "point" & d$key %in% c("c1", "c2", "c3")
  expect_equal(d$cx[pt], (bb$x0[pt] + bb$x1[pt]) / 2, tolerance = tol)
  expect_equal(d$cy[pt], (bb$y0[pt] + bb$y1[pt]) / 2, tolerance = tol)
  expect_equal(d$r[pt], (bb$x1[pt] - bb$x0[pt]) / 2, tolerance = tol)
  expect_true(all(d$shape[pt] == 0))
  expect_true(all(d$fill[pt] == "#4682b4ff"))
  expect_true(all(d$stroke[pt] == "#000080ff"))
  expect_equal(d$stroke_width[pt], rep(2, 3), tolerance = tol) # lwd 2 at 96 dpi

  # Markers: one point record each, with their shape code and their paint.
  mk <- d[d$key %in% c("m1", "m2", "m3"), ]
  expect_identical(mk$kind, rep("point", 3))
  expect_identical(mk$shape, c(1, 2, 4))
  expect_equal(
    mk$cx,
    (bb$x0[match(mk$key, d$key)] + bb$x1[match(mk$key, d$key)]) / 2,
    tolerance = tol
  )
  expect_identical(mk$fill[1:2], rep("#ffa500ff", 2))
  expect_true(is.na(mk$fill[3])) # a plus is stroke-only

  rc <- d$kind == "rect" & d$flags == 0
  expect_setequal(d$key[rc], c("r1", "r2"))
  expect_equal(d$x[rc], bb$x0[rc], tolerance = tol)
  expect_equal(d$y[rc], bb$y0[rc], tolerance = tol)
  expect_equal(d$x[rc] + d$w[rc], bb$x1[rc], tolerance = tol)
  expect_equal(d$y[rc] + d$h[rc], bb$y1[rc], tolerance = tol)
  expect_true(all(is.na(d$stroke[rc])))

  # Paths against element_geometry() vertex for vertex.
  g <- element_geometry(s)
  for (k in c("s1", "poly", "ln")) {
    row <- d[d$key == k, ]
    expect_identical(row$kind, "path")
    v <- do.call(rbind, row$runs[[1]])
    gk <- g[g$key == k, ]
    expect_equal(unname(v[, 1]), gk$x, tolerance = tol, info = k)
    expect_equal(unname(v[, 2]), gk$y, tolerance = tol, info = k)
  }
  expect_false(d$closed[d$key == "s1"])
  expect_true(d$closed[d$key == "poly"])
  expect_identical(d$fill[d$key == "poly"], "#a020f0ff")
  expect_match(d$dash[d$key == "s1"], "^[0-9.]+,[0-9.]+")
})

test_that("clips are listed as device rects", {
  skip_if_not_installed("jsonlite")
  s <- .dl_scene()
  dl <- scene_display_list(s)
  d <- .dl_decode(dl)
  w <- dl$width
  h <- dl$height
  expect_equal(length(dl$clips$x0), 1)
  expect_equal(
    c(dl$clips$x0, dl$clips$y0, dl$clips$x1, dl$clips$y1),
    c(0.1 * w, 0.1 * h, 0.9 * w, 0.9 * h),
    tolerance = 1e-3
  )
  expect_true(all(d$clip[d$panel %in% "panel-a"] == 1))
  expect_true(all(d$clip[d$key %in% c("grp", "grad")] == 0))
})

test_that("panels restricts the list to marks in those panels", {
  skip_if_not_installed("jsonlite")
  s <- .dl_scene()
  dl <- scene_display_list(s, panels = "panel-a")
  d <- .dl_decode(dl)
  expect_true(all(d$panel == "panel-a"))
  expect_identical(dl$panels, "panel-a")
  el <- scene_model(s)$elements
  expect_setequal(d$key, el$key[el$panel %in% "panel-a" & !is.na(el$key)])
  expect_identical(scene_display_list(s, panels = "none")$n, 0L)
  expect_error(scene_display_list(s, panels = 1), "panels")
})

test_that("what stage 1 cannot reproduce is flagged, the rest is not", {
  skip_if_not_installed("jsonlite")
  d <- .dl_decode(scene_display_list(.dl_scene()))
  flag <- function(k) d$flags[d$key == k]
  expect_true(all(d$flags[!d$key %in% c("tx", "grp", "grad")] == 0))
  expect_equal(bitwAnd(flag("tx"), 8L), 8L) # text: its box (here a rect)
  expect_identical(d$kind[d$key == "tx"], "rect")
  expect_equal(bitwAnd(flag("grp"), 4L), 4L) # translucent group
  expect_true(all(bitwAnd(flag("grad"), 1L) == 1L)) # gradient paint
  expect_true(all(is.na(d$fill[d$key == "grad"])))
  # A path clip is flagged too.
  s <- vl_scene(2, 2, dpi = 72) |>
    push(vl_viewport(
      clip = polygon_grob(c(0.1, 0.9, 0.5), c(0.1, 0.1, 0.9))
    )) |>
    draw(points_grob(0.5, 0.5, key = "a")) |>
    pop()
  expect_equal(bitwAnd(.dl_decode(scene_display_list(s))$flags, 2L), 2L)
})

test_that("columns collapse: constant, sequence, narrow integer types", {
  skip_if_not_installed("jsonlite")
  n <- 1000
  s <- vl_scene(4, 4, dpi = 72) |>
    draw(points_grob(
      x = seq(0, 1, length.out = n),
      y = 0.5,
      size = 1,
      gp = vl_gpar(fill = "black"),
      key = as.character(seq_len(n))
    ))
  dl <- scene_display_list(s)
  expect_identical(dl$record$kind$const, 0)
  expect_identical(dl$point$r$type, "f32")
  expect_false(is.null(dl$point$r$const))
  expect_identical(dl$record$key$seq, c(0, 1))
  # Integer keys ship as numbers (here a sequence), not strings.
  expect_true(is.list(dl$keys))
  expect_identical(dl$keys$seq, c(1, 1))
  expect_identical(dl$keys$type, "u16")
  d <- .dl_decode(dl)
  expect_identical(d$key, as.character(seq_len(n)))
  expect_equal(d$cx, seq(0, 4 * 72, length.out = n), tolerance = 1e-3)
  # Few runs: run-length encoded.
  s2 <- vl_scene(4, 4, dpi = 72) |>
    draw(points_grob(
      x = seq(0, 1, length.out = n),
      y = 0.5,
      size = rep(c(1, 2), each = n / 2),
      key = paste0("k", seq_len(n))
    ))
  dl2 <- scene_display_list(s2)
  expect_identical(dl2$point$r$rle$lengths, c(n / 2, n / 2))
  expect_type(dl2$keys, "character")
  expect_identical(.dl_decode(dl2)$key, paste0("k", seq_len(n)))
  # A scene with no keyed marks has an empty list.
  e <- scene_display_list(vl_scene(1, 1) |> draw(circle_grob()))
  expect_identical(e$n, 0L)
  expect_identical(nrow(.dl_decode(e)), 0L)
})

test_that("keyed batches render byte-identically with and without keys", {
  # The keys now travel with a circle batch; raster and PDF ignore them, SVG
  # tags each circle exactly as before.
  pts <- function(key = NULL) {
    vl_scene(3, 3, dpi = 72, bg = "white") |>
      draw(points_grob(
        x = c(0.2, 0.5, 0.8),
        y = c(0.3, 0.6, 0.4),
        size = 3,
        gp = vl_gpar(fill = "steelblue", col = "navy", alpha = 0.6),
        key = key
      ))
  }
  keyed <- pts(c("a", "b", "c"))
  plain <- pts()
  expect_identical(scene_png(keyed), scene_png(plain))
  expect_identical(scene_raster(keyed), scene_raster(plain))
  expect_identical(scene_pdf(keyed), scene_pdf(plain))
  svg_k <- scene_svg(keyed)
  expect_identical(lengths(regmatches(svg_k, gregexpr("data-key=", svg_k))), 3L)
  # Keys are the only difference: each circle is still written the same way.
  expect_identical(gsub(' data-key="[abc]"', "", svg_k), scene_svg(plain))
})

test_that("keyed marks that paint nothing are listed pick-only (VR-17)", {
  skip_if_not_installed("jsonlite")
  s <- vl_scene(3, 2, dpi = 96) |>
    push(vl_viewport(name = "p")) |>
    draw(rect_grob(
      x = c(0.25, 0.75),
      y = 0.5,
      width = 0.2,
      height = 0.4,
      gp = vl_gpar(fill = NA, col = NA),
      key = c("hr1", "hr2")
    )) |>
    draw(circle_grob(
      x = 0.5,
      y = 0.2,
      r = 0.05,
      gp = vl_gpar(fill = NA, col = NA),
      key = "hc"
    )) |>
    draw(points_grob(
      0.1,
      0.9,
      shape = "square",
      gp = vl_gpar(fill = NA, col = NA),
      key = "hm"
    )) |>
    draw(polygon_grob(
      c(0.6, 0.9, 0.75),
      c(0.7, 0.7, 0.95),
      gp = vl_gpar(fill = NA, col = NA),
      key = "hp"
    )) |>
    draw(rect_grob(
      x = 0.5,
      y = 0.5,
      width = 0.1,
      height = 0.1,
      gp = vl_gpar(fill = "red", col = NA),
      key = "vis"
    )) |>
    pop()
  dl <- scene_display_list(s)
  d <- .dl_decode(dl)
  el <- scene_model(s)$elements
  expect_setequal(d$key, el$key[!is.na(el$key)])
  hidden <- c("hr1", "hr2", "hc", "hm", "hp")
  expect_true(all(bitwAnd(d$flags[d$key %in% hidden], 16L) == 16L))
  expect_true(all(is.na(d$fill[d$key %in% hidden])))
  expect_true(all(is.na(d$stroke[d$key %in% hidden])))
  expect_identical(d$flags[d$key == "vis"], 0L)
  # Geometry is present: the rects land on their element boxes.
  rc <- d[d$key %in% c("hr1", "hr2"), ]
  bb <- el[match(rc$key, el$key), ]
  expect_identical(rc$kind, c("rect", "rect"))
  expect_equal(rc$x, bb$x0, tolerance = 1e-3)
  expect_equal(rc$x + rc$w, bb$x1, tolerance = 1e-3)
  expect_identical(d$kind[d$key == "hp"], "path")
  expect_true(d$closed[d$key == "hp"])
  expect_identical(d$kind[d$key %in% c("hc", "hm")], c("point", "point"))
  # Pick-only records change nothing that is drawn.
  expect_identical(
    scene_png(s),
    scene_png(
      vl_scene(3, 2, dpi = 96) |>
        draw(rect_grob(
          x = 0.5,
          y = 0.5,
          width = 0.1,
          height = 0.1,
          gp = vl_gpar(fill = "red", col = NA)
        ))
    )
  )
})
