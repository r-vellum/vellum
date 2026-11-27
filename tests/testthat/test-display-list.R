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

test_that("version 2 lists gradients, path clips and opacity groups exactly (VW-23)", {
  skip_if_not_installed("jsonlite")
  s <- .dl_scene()
  v1 <- scene_display_list(s)
  v2 <- scene_display_list(s, version = 2)
  expect_identical(v1$version, 1L)
  expect_identical(v2$version, 2L)
  # version 1 is unchanged: no version-2 fields
  expect_null(v1$gradients)
  expect_null(v1$groups)
  expect_null(v1$record$group)
  expect_null(v1$paints$fill_gradient)
  d1 <- .dl_decode(v1)
  d2 <- .dl_decode(v2)
  expect_identical(d2$key, d1$key)
  flag <- function(d, k) d$flags[d$key == k]
  # the gradient and the translucent group are no longer flagged
  expect_true(all(flag(d2, "grad") == 0))
  expect_true(all(flag(d2, "grp") == 0))
  expect_equal(bitwAnd(flag(d2, "tx"), 8L), 8L) # text stays flagged
  # gradient table
  rec <- lapply(v2$record, .dl_col)
  pg <- v2$paints$fill_gradient[rec$paint + 1]
  gi <- unique(pg[d2$key == "grad"])
  expect_length(gi, 1L)
  expect_gt(gi, 0L)
  expect_true(all(pg[d2$key != "grad"] == 0L))
  g <- v2$gradients
  expect_identical(g$type[gi], "linear")
  stops <- (g$stop_offset[gi] + 1):g$stop_offset[gi + 1]
  expect_identical(g$stop_color[stops], c("#ff0000ff", "#0000ffff"))
  expect_equal(g$stop_pos[stops], c(0, 1))
  # an npc gradient spans the viewport (here the page) in device px, through
  # its transform
  ex <- g$a[gi] * c(g$x1[gi], g$x2[gi]) + g$c[gi] * c(g$y1[gi], g$y2[gi]) + g$e[gi]
  expect_equal(ex, c(0, v2$width), tolerance = 0.5)
  # group table: the "grp" point is in a 0.5 group
  expect_equal(v2$groups$alpha, 0.5)
  expect_identical(v2$groups$parent, 0L)
  expect_true(all(rec$group[d2$key == "grp"] == 1))
  expect_true(all(rec$group[d2$key != "grp"] == 0))
  # a rect clip has no paths
  expect_identical(v2$clips$path_n, 0L)
  expect_error(scene_display_list(s, version = 3), "version")
})

test_that("version 2 lists a path clip as device-px clip paths (VW-23)", {
  skip_if_not_installed("jsonlite")
  s <- vl_scene(2, 2, dpi = 72) |>
    push(vl_viewport(
      clip = polygon_grob(c(0.1, 0.9, 0.5), c(0.1, 0.1, 0.9))
    )) |>
    draw(points_grob(0.5, 0.5, key = "a")) |>
    pop()
  dl <- scene_display_list(s, version = 2)
  d <- .dl_decode(dl)
  expect_equal(d$flags, 0)
  expect_equal(d$clip, 1)
  expect_identical(dl$clips$path_n, 1L)
  cp <- lapply(dl$clip_paths, .dl_col)
  xy <- matrix(cp$xy, ncol = 2, byrow = TRUE)
  # the triangle, 144 px square device, y down
  expect_equal(range(xy[, 1]), c(0.1, 0.9) * 144, tolerance = 1e-3)
  expect_equal(range(xy[, 2]), c(0.1, 0.9) * 144, tolerance = 1e-3)
  expect_equal(cp$path_offset, c(0, 1))
  # the clip rect is bounded by the path's box
  expect_equal(c(dl$clips$x0, dl$clips$x1), c(0.1, 0.9) * 144, tolerance = 1e-3)
  # nested opacity groups chain their parents; a blend group stays flagged
  s2 <- vl_scene(2, 2, dpi = 72) |>
    push(vl_viewport(alpha = 0.5)) |>
    push(vl_viewport(alpha = 0.4)) |>
    draw(points_grob(0.5, 0.5, key = "in")) |>
    pop() |>
    pop() |>
    push(vl_viewport(blend = "multiply")) |>
    draw(points_grob(0.2, 0.2, key = "bl")) |>
    pop()
  dl2 <- scene_display_list(s2, version = 2)
  d2 <- .dl_decode(dl2)
  rec <- lapply(dl2$record, .dl_col)
  expect_equal(dl2$groups$alpha, c(0.5, 0.4))
  expect_identical(dl2$groups$parent, c(0L, 1L))
  expect_equal(rec$group[d2$key == "in"], 2)
  expect_equal(d2$flags[d2$key == "in"], 0)
  expect_equal(bitwAnd(d2$flags[d2$key == "bl"], 4L), 4L)
  # ...and says it blends (32), which no separate raster reproduces (VW-30)
  expect_equal(bitwAnd(d2$flags[d2$key == "bl"], 32L), 32L)
  expect_equal(bitwAnd(d2$flags[d2$key != "bl"], 32L), rep(0L, sum(d2$key != "bl")))
  # a repeating gradient stays flagged
  s3 <- vl_scene(2, 2, dpi = 72) |>
    draw(rect_grob(gp = vl_gpar(fill = linear_gradient(c("red", "blue"), extend = "repeat")), key = "rep"))
  expect_equal(bitwAnd(.dl_decode(scene_display_list(s3, version = 2))$flags, 1L), 1L)
})

test_that("records can index a key table the caller already has (VR-22)", {
  n <- 50
  s <- vl_scene(4, 4, dpi = 72) |>
    draw(points_grob(
      x = seq(0, 1, length.out = n),
      y = 0.5,
      size = 1,
      key = as.character(seq_len(n))
    )) |>
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.1, height = 0.1, key = "box"))
  ref <- .dl_decode(scene_display_list(s, version = 2L))
  # The caller's table in the same order as the records: one sequence, and
  # the list ships no keys of its own.
  given <- c(as.character(seq_len(n)), "box")
  dl <- scene_display_list(s, version = 2L, keys = given)
  expect_identical(dl$keys_given, as.integer(n + 1))
  expect_identical(dl$record$key$seq, c(0, 1))
  expect_length(dl$keys, 0L)
  expect_identical(.dl_decode(dl, given), ref)
  # A shuffled table with extra keys, an NA and a duplicate: records point
  # at the first match, keys it lacks follow it.
  given2 <- c("zzz", NA, rev(as.character(seq_len(n - 5))), "10")
  dl2 <- scene_display_list(s, version = 2L, keys = given2)
  expect_identical(dl2$keys_given, length(given2))
  expect_identical(.dl_decode(dl2, given2), ref)
  missing <- c(as.character((n - 4):n), "box")
  extra <- if (is.list(dl2$keys)) as.character(.dl_col(dl2$keys)) else dl2$keys
  expect_setequal(extra, missing)
  k <- .dl_col(dl2$record$key)
  expect_equal(k[1], match("1", given2) - 1)
  # Version 1 takes it too; no table leaves the list as before.
  expect_identical(
    .dl_decode(scene_display_list(s, keys = given), given),
    .dl_decode(scene_display_list(s))
  )
  expect_null(scene_display_list(s)$keys_given)
  # Unicode keys survive the round trip.
  u <- vl_scene(2, 2) |>
    draw(points_grob(x = c(0.2, 0.8), y = 0.5, key = c("café", "日本")))
  du <- scene_display_list(u, keys = c("日本", "café"))
  expect_equal(.dl_col(du$record$key), c(1, 0))
  expect_length(du$keys, 0L)
  expect_error(scene_display_list(s, keys = 1:3), "character vector")
})

test_that("compact coordinates quantise the geometry within each column (VR-18)", {
  skip_if_not_installed("jsonlite")
  s <- .dl_scene()
  ref <- .dl_decode(scene_display_list(s, version = 2L))
  geo <- c("cx", "cy", "r", "x", "y", "w", "h")
  coords <- function(d) {
    c(unlist(d[geo]), unlist(lapply(d$runs, function(r) unlist(r))))
  }
  near <- function(dl, ref) {
    d <- .dl_decode(dl)
    # Everything but the geometry is unchanged.
    expect_identical(d[setdiff(names(d), c(geo, "runs"))], ref[setdiff(names(ref), c(geo, "runs"))])
    cols <- c(dl$point[c("cx", "cy", "r")], dl$rect, list(xy = dl$path$xy))
    worst <- max(vapply(cols, function(c) if (is.null(c$step)) 0 else c$step / 2, 0))
    err <- abs(coords(d) - coords(ref))
    expect_true(all(err[!is.na(err)] <= worst + 1e-4))
    invisible(d)
  }
  u16 <- scene_display_list(s, version = 2L, precision = "u16")
  expect_identical(u16$point$cx$type, "u16")
  expect_named(u16$point$cx, c("type", "n", "lo", "step", "data"))
  expect_equal(u16$point$cx$lo, min(ref$cx, na.rm = TRUE), tolerance = 1e-6)
  expect_equal(
    u16$point$cx$step,
    diff(range(ref$cx, na.rm = TRUE)) / 65535,
    tolerance = 1e-6
  )
  near(u16, ref)
  u24 <- scene_display_list(s, version = 2L, precision = "u24")
  expect_identical(u24$path$xy$type, "u24")
  near(u24, ref)
  expect_lt(u24$path$xy$step, u16$path$xy$step / 200)
  # An error bound picks the fewest bits that meet it, per column.
  d5 <- scene_display_list(s, version = 2L, precision = 0.005)
  expect_identical(d5$point$cx$type, "u16") # the page is 480 px wide
  expect_lte(d5$point$cx$step / 2, 0.005)
  near(d5, ref)
  expect_identical(scene_display_list(s, precision = 1e-4)$point$cx$type, "u24")
  expect_identical(scene_display_list(s, precision = 2)$point$cx$type, "u8")
  expect_identical(scene_display_list(s, precision = 1e-9)$point$cx$type, "f32")
  # The default and "f32" are the plain list.
  expect_identical(scene_display_list(s, precision = "f32"), scene_display_list(s))
  # It combines with a caller's key table.
  given <- unique(ref$key)
  dk <- scene_display_list(s, version = 2L, keys = given, precision = "u16")
  expect_identical(.dl_decode(dk, given)$key, ref$key)
  expect_error(scene_display_list(s, precision = "u12"), "precision")
  expect_error(scene_display_list(s, precision = 0), "precision")
  expect_error(scene_display_list(s, precision = c(0.1, 0.2)), "precision")
})

test_that("compact coordinates keep a 200-point cloud within half a step", {
  skip_if_not_installed("jsonlite")
  set.seed(3)
  n <- 200
  s <- vl_scene(7, 5, dpi = 96) |>
    draw(points_grob(
      x = runif(n),
      y = runif(n),
      size = runif(n, 1, 3),
      key = as.character(seq_len(n))
    ))
  ref <- .dl_decode(scene_display_list(s))
  for (p in list("u16", "u24", 0.005)) {
    dl <- scene_display_list(s, precision = p)
    d <- .dl_decode(dl)
    for (f in c("cx", "cy", "r")) {
      expect_lte(max(abs(d[[f]] - ref[[f]])), dl$point[[f]]$step / 2 + 1e-4)
    }
  }
  # 0.005 px takes 16 bits up to a 655.35 px span, 24 above: x spans most
  # of the 672 px page, y less of the 480.
  d5 <- scene_display_list(s, precision = 0.005)$point
  span <- function(v) diff(range(v))
  expect_identical(d5$cx$type, if (span(ref$cx) > 655.35) "u24" else "u16")
  expect_identical(d5$cy$type, "u16")
  # A column that collapses stays f32: one size, one radius.
  s1 <- vl_scene(7, 5, dpi = 96) |>
    draw(points_grob(x = runif(n), y = runif(n), size = 2, key = as.character(seq_len(n))))
  r <- scene_display_list(s1, precision = "u16")$point$r
  expect_identical(r$type, "f32")
  expect_false(is.null(r$const))
  # Empty tables (no rects, no paths) stay plain empty f32 columns.
  dl1 <- scene_display_list(s1, precision = "u16")
  expect_identical(dl1$path$xy, scene_display_list(s1)$path$xy)
  expect_identical(dl1$rect$x$type, "f32")
})

test_that("a hatched fill is listed as exact geometry, not flagged (VL-19)", {
  h <- vl_hatch(angle = 45, spacing = 4, col = "navy", bg = "lightyellow")
  gp <- vl_gpar(fill = h, col = NA)
  base <- function() vl_scene(3, 2, dpi = 72, bg = "white")
  shapes <- list(
    rect = rect_grob(width = 0.5, height = 0.5, key = "k", gp = gp),
    polygon = polygon_grob(c(0.2, 0.8, 0.5), c(0.2, 0.2, 0.8), key = "k", gp = gp),
    circle = circle_grob(r = 0.3, key = "k", gp = gp)
  )
  for (nm in names(shapes)) {
    for (v in 1:2) {
      dl <- scene_display_list(base() |> draw(shapes[[nm]]), version = v)
      d <- .dl_decode(dl)
      # the shape in the hatch's background, then the rules in its colour
      expect_identical(d$flags, c(0, 0), info = paste(nm, v))
      expect_identical(d$fill, c("#ffffe0ff", NA), info = paste(nm, v))
      expect_identical(d$stroke, c(NA, "#000080ff"), info = paste(nm, v))
      expect_identical(d$kind[2], "path", info = paste(nm, v))
    }
  }
  # a hatched marker of any shape is listed as its geometry, not as a point
  # record, which cannot carry the rules (VR-53): exact, like a circle
  for (shape in c("square", "triangle", "diamond", "star")) {
    sc <- base() |>
      draw(points_grob(
        x = 0.5,
        y = 0.5,
        shape = shape,
        size = vl_unit(10, "mm"),
        key = "k",
        gp = vl_gpar(fill = h, col = "black")
      ))
    for (v in 1:2) {
      dl <- scene_display_list(sc, version = v)
      d <- .dl_decode(dl)
      kind <- if (shape == "square") "rect" else "path"
      expect_identical(d$kind, c(kind, "path", kind), info = paste(shape, v))
      expect_identical(d$flags, c(0, 0, 0), info = paste(shape, v))
      expect_identical(d$fill, c("#ffffe0ff", NA, NA), info = paste(shape, v))
      expect_identical(
        d$stroke,
        c(NA, "#000080ff", "#000000ff"),
        info = paste(shape, v)
      )
      # no point record is left behind in the point table
      expect_length(.dl_col(dl$point$cx), 0)
    }
  }
  # a solid marker stays exact
  sc <- base() |>
    draw(points_grob(0.5, 0.5, shape = "square", key = "k", gp = vl_gpar(fill = "red")))
  expect_identical(.dl_decode(scene_display_list(sc))$flags, 0)
  # rotated and clipped to a rotated viewport: exact in version 2
  sc <- base() |>
    push(vl_viewport(width = 0.5, height = 0.5, angle = 30, clip = TRUE)) |>
    draw(rect_grob(width = 1.5, height = 0.5, key = "k", gp = gp)) |>
    pop()
  expect_identical(.dl_decode(scene_display_list(sc, version = 2))$flags, c(0, 0))
  expect_identical(scene_display_list(sc, version = 2)$runs, 0L)
  # a non-rectangular clip flags it in version 1, as it would any record
  expect_identical(.dl_decode(scene_display_list(sc))$flags, c(2, 2))
})

test_that("a huge in-range arc is refined finely only near the page (VR-56)", {
  u <- function(v) vl_unit(v, "pt")
  r <- 30000
  # A ring of 36 sectors whose outer arc crosses a 576 px page: the list
  # keeps that arc within 1/8 px near the page, and coarser with the
  # distance from it, instead of refining the whole ring at 1/8 px.
  th <- seq(0, 2 * pi, length.out = 37)
  s <- vl_scene(8, 8, dpi = 72) |>
    draw(sector_grob(
      u(288 - r),
      0.5,
      r0 = u(r * 0.6),
      r1 = u(r),
      theta0 = th[-37],
      theta1 = th[-1],
      key = paste0("k", 1:36),
      gp = vl_gpar(fill = "steelblue", col = NA)
    ))
  d <- .dl_decode(scene_display_list(s, version = 2))
  runs <- unlist(d$runs[d$kind == "path"], recursive = FALSE)
  expect_lt(sum(vapply(runs, nrow, 1L)), 1000) # was 2664
  cx <- 288 - r
  cy <- 288
  near <- 0
  for (xy in runs) {
    # outer-arc chords: both ends on the arc, within a page of the page
    on <- abs(sqrt((xy[, 1] - cx)^2 + (xy[, 2] - cy)^2) - r) < 0.05
    inb <- xy[, 1] > -576 & xy[, 1] < 1152 & xy[, 2] > -576 & xy[, 2] < 1152
    k <- which(on[-1] & on[-nrow(xy)] & inb[-1] & inb[-nrow(xy)])
    for (i in k) {
      m <- (xy[i, ] + xy[i + 1, ]) / 2
      sag <- r - sqrt((m[1] - cx)^2 + (m[2] - cy)^2)
      expect_lt(sag, 1 / 8 + 0.01)
      near <- near + 1
    }
  }
  expect_gt(near, 3)
})
