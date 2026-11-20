# VR-13: the split render. `layer = "keyed"` draws only keyed marks on a
# transparent page; `layer = "unkeyed"` draws the rest. Overlaid, they must
# reproduce the full render.

# A plot-like scene: background, gridlines, keyed points inside a clipped,
# masked, half-transparent panel, keyed segments, and unkeyed furniture
# (axis line, title text) that does not overlap the marks.
.split_scene <- function() {
  set.seed(42)
  n <- 300
  vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(rect_grob(
      x = 0.55,
      y = 0.5,
      width = 0.8,
      height = 0.7,
      gp = vl_gpar(fill = "grey95", col = NA)
    )) |>
    draw(segments_grob(
      x0 = seq(0.2, 0.9, by = 0.1),
      y0 = 0.15,
      x1 = seq(0.2, 0.9, by = 0.1),
      y1 = 0.85,
      gp = vl_gpar(col = "white", lwd = 2)
    )) |>
    push(vl_viewport(
      x = 0.55,
      y = 0.5,
      width = 0.8,
      height = 0.7,
      clip = TRUE,
      alpha = 0.8,
      mask = as_mask(circle_grob(r = 0.6, gp = vl_gpar(fill = "black")))
    )) |>
    draw(points_grob(
      x = runif(n, -0.1, 1.1),
      y = runif(n),
      size = 1.2,
      gp = vl_gpar(fill = "steelblue", col = "navy", alpha = 0.7),
      key = paste0("p", seq_len(n))
    )) |>
    draw(segments_grob(
      x0 = c(0.1, 0.2),
      y0 = c(0.1, 0.9),
      x1 = c(0.9, 0.8),
      y1 = c(0.9, 0.1),
      gp = vl_gpar(col = "firebrick", lwd = 3),
      key = c("s1", "s2")
    )) |>
    pop() |>
    draw(lines_grob(c(0.15, 0.15), c(0.15, 0.85), gp = vl_gpar(lwd = 1.5))) |>
    draw(text_grob("title", x = 0.5, y = 0.95))
}

.png_arr <- function(bytes) {
  a <- png::readPNG(bytes) # [y, x, channel], 0..1
  if (dim(a)[3] == 3) {
    a <- array(c(a, rep(1, prod(dim(a)[1:2]))), c(dim(a)[1:2], 4))
  }
  a
}

# Porter-Duff source-over of straight-alpha `top` onto `bot` (both [y, x, 4]).
.over <- function(top, bot) {
  ta <- top[,, 4]
  ba <- bot[,, 4]
  oa <- ta + ba * (1 - ta)
  out <- bot
  for (k in 1:3) {
    num <- top[,, k] * ta + bot[,, k] * ba * (1 - ta)
    out[,, k] <- ifelse(oa > 0, num / oa, 0)
  }
  out[,, 4] <- oa
  out
}

test_that("keyed over unkeyed reproduces the full PNG render", {
  skip_if_not_installed("png")
  s <- .split_scene()
  full <- .png_arr(scene_png(s))
  keyed <- .png_arr(scene_png(s, layer = "keyed"))
  unkeyed <- .png_arr(scene_png(s, layer = "unkeyed"))
  expect_identical(dim(keyed), dim(full))
  expect_identical(dim(unkeyed), dim(full))
  # The two layers really are different parts of the picture.
  expect_gt(sum(keyed[,, 4] > 0), 1000)
  expect_lt(sum(keyed[,, 4] > 0), 0.9 * prod(dim(full)[1:2]))
  expect_true(all(unkeyed[,, 4] == 1)) # opaque page background
  comp <- .over(keyed, unkeyed)
  d <- abs(comp - full)
  # Antialiasing/rounding only: an 8-bit step or two, never a missing mark.
  expect_lt(max(d), 3 / 255)
  expect_lt(mean(d), 0.2 / 255)
})

test_that("the keyed layer keeps its clip, mask and group opacity", {
  skip_if_not_installed("png")
  s <- .split_scene()
  keyed <- .png_arr(scene_png(s, layer = "keyed"))
  full <- .png_arr(scene_png(s))
  h <- dim(keyed)[1]
  w <- dim(keyed)[2]
  # Points at x < 0 / x > 1 in the panel are clipped away: nothing left of
  # the panel (x < 0.15 of the page) or right of it (x > 0.95).
  expect_true(all(keyed[, seq_len(floor(0.14 * w)), 4] == 0))
  expect_true(all(keyed[, seq(ceiling(0.96 * w), w), 4] == 0))
  # The mask's circle cuts the panel corners off.
  corner <- keyed[
    seq(ceiling(0.16 * h), ceiling(0.2 * h)),
    seq(ceiling(0.16 * w), ceiling(0.2 * w)),
    4
  ]
  expect_true(all(corner == 0))
  # Group alpha 0.8 x point alpha 0.7: no keyed pixel is fully opaque.
  expect_lt(max(keyed[,, 4]), 0.95)
})

test_that("a layer render never poisons the memoised full render", {
  skip_if_not_installed("png")
  s <- .split_scene()
  before <- scene_png(s)
  scene_png(s, layer = "keyed")
  scene_png(s, layer = "unkeyed")
  expect_identical(scene_png(s), before)
})

test_that("an unkeyed scene has an empty keyed layer and a full unkeyed one", {
  skip_if_not_installed("png")
  s <- vl_scene(2, 2, dpi = 72, bg = "white") |>
    draw(circle_grob(gp = vl_gpar(fill = "tomato")))
  expect_true(all(.png_arr(scene_png(s, layer = "keyed"))[,, 4] == 0))
  expect_identical(scene_png(s, layer = "unkeyed"), scene_png(s))
})

test_that("scene_svg() splits the same way", {
  s <- .split_scene()
  full <- scene_svg(s)
  unkeyed <- scene_svg(s, layer = "unkeyed")
  keyed <- scene_svg(s, layer = "keyed")
  n_key <- function(x) {
    lengths(regmatches(x, gregexpr("data-key=", x, fixed = TRUE)))
  }
  expect_equal(n_key(unkeyed), 0)
  expect_equal(n_key(keyed), n_key(full))
  expect_gt(n_key(keyed), 300)
  # Same page: identical root element (size + viewBox).
  root <- function(x) regmatches(x, regexpr("<svg[^>]*>", x))
  expect_identical(root(keyed), root(full))
  expect_identical(root(unkeyed), root(full))
  # Furniture stays with the unkeyed layer; the keyed one has no background.
  expect_match(unkeyed, ">title<", fixed = TRUE)
  expect_false(grepl(">title<", keyed, fixed = TRUE))
  expect_false(grepl('fill="#FFFFFF"', keyed, fixed = TRUE))
  # The keyed marks keep their clip and mask.
  expect_match(keyed, "clip-path=", fixed = TRUE)
  expect_match(keyed, "mask=", fixed = TRUE)
})

test_that("unkeyed SVG furniture composited under the keyed PNG matches the full render", {
  skip_if_not_installed("png")
  skip_if_not_installed("rsvg")
  s <- .split_scene()
  dims <- dim(.png_arr(scene_png(s)))
  ras <- function(svg) {
    .png_arr(rsvg::rsvg_png(charToRaw(svg), width = dims[2], height = dims[1]))
  }
  full <- ras(scene_svg(s, text = "outline"))
  comp <- .over(
    .png_arr(scene_png(s, layer = "keyed")),
    ras(scene_svg(s, text = "outline", layer = "unkeyed"))
  )
  expect_identical(dim(comp), dim(full))
  # Two different rasterisers (librsvg, tiny-skia) disagree on antialiasing
  # only; a misplaced layer would differ by whole marks.
  expect_lt(mean(abs(comp - full)), 2 / 255)
})

test_that("layer is validated", {
  s <- vl_scene(1, 1)
  expect_error(scene_png(s, layer = "marks"), "should be one of")
  expect_error(scene_svg(s, layer = "nope"), "should be one of")
})

test_that("panels narrows the mark layer to keyed marks in those panels", {
  skip_if_not_installed("png")
  # Two named panels, each with a keyed batch: "data" and "legend".
  s <- vl_scene(4, 2, dpi = 72, bg = "white") |>
    push(vl_viewport(x = 0.25, width = 0.5, name = "data")) |>
    draw(points_grob(
      0.5,
      0.5,
      size = 5,
      key = "d1",
      gp = vl_gpar(fill = "red")
    )) |>
    pop() |>
    push(vl_viewport(x = 0.75, width = 0.5, name = "legend")) |>
    draw(points_grob(
      0.5,
      0.5,
      size = 5,
      key = "l1",
      gp = vl_gpar(fill = "blue")
    )) |>
    pop()
  expect_setequal(scene_model(s)$elements$panel, c("data", "legend"))
  k <- scene_svg(s, layer = "keyed", panels = "data")
  u <- scene_svg(s, layer = "unkeyed", panels = "data")
  expect_match(k, 'data-key="d1"', fixed = TRUE)
  expect_false(grepl('data-key="l1"', k, fixed = TRUE))
  expect_match(u, 'data-key="l1"', fixed = TRUE)
  expect_false(grepl('data-key="d1"', u, fixed = TRUE))
  # Still complements in pixels.
  full <- .png_arr(scene_png(s))
  comp <- .over(
    .png_arr(scene_png(s, layer = "keyed", panels = "data")),
    .png_arr(scene_png(s, layer = "unkeyed", panels = "data"))
  )
  expect_lt(max(abs(comp - full)), 3 / 255)
  # No listed panel matches: an empty mark layer.
  expect_true(all(
    .png_arr(scene_png(s, layer = "keyed", panels = "nope"))[,, 4] == 0
  ))
  expect_error(scene_png(s, layer = "keyed", panels = 1), "panels")
})

# VW-21: paint-order split of the unkeyed layer.
.order_scene <- function() {
  vl_scene(4, 2, dpi = 72, bg = "white") |>
    push(vl_viewport(x = 0.25, width = 0.5, name = "p1", clip = TRUE)) |>
    draw(rect_grob(gp = vl_gpar(fill = "grey90", col = NA))) |>
    draw(points_grob(
      c(0.3, 0.5, 0.7),
      0.5,
      size = 8,
      key = c("a", "b", "c"),
      gp = vl_gpar(fill = "red", col = NA)
    )) |>
    # An annotation over the points, between two keyed batches.
    draw(text_grob("between", x = 0.5, y = 0.8)) |>
    draw(points_grob(0.5, 0.2, size = 8, key = "d", gp = vl_gpar(fill = "red"))) |>
    draw(lines_grob(c(0, 1), c(0.5, 0.5), gp = vl_gpar(col = "blue", lwd = 4))) |>
    pop() |>
    # A second facet painted after p1's marks: its background stays below.
    push(vl_viewport(x = 0.75, width = 0.5, name = "p2")) |>
    draw(rect_grob(gp = vl_gpar(fill = "grey80", col = NA))) |>
    draw(text_grob("facet2bg", x = 0.5, y = 0.9)) |>
    draw(points_grob(0.5, 0.5, size = 8, key = "e", gp = vl_gpar(fill = "red"))) |>
    draw(text_grob("facet2top", x = 0.5, y = 0.1)) |>
    pop() |>
    draw(text_grob("caption", x = 0.5, y = 0.02))
}

test_that("layer choices are visible for feature detection", {
  ch <- eval(formals(scene_png)$layer)
  expect_true(all(c("unkeyed_below", "unkeyed_above") %in% ch))
  expect_identical(eval(formals(scene_svg)$layer), ch)
})

test_that("unkeyed_below/above split the furniture by paint order per panel", {
  s <- .order_scene()
  below <- scene_svg(s, layer = "unkeyed_below")
  above <- scene_svg(s, layer = "unkeyed_above")
  has <- function(x, t) grepl(paste0(">", t, "<"), x, fixed = TRUE)
  expect_true(has(below, "facet2bg"))
  expect_false(has(above, "facet2bg"))
  for (t in c("between", "facet2top", "caption")) {
    expect_true(has(above, t), label = t)
    expect_false(has(below, t), label = t)
  }
  expect_false(grepl("data-key=", below, fixed = TRUE))
  expect_false(grepl("data-key=", above, fixed = TRUE))
  # The above layer has no page background; the below layer keeps it.
  expect_false(grepl('fill="#FFFFFF"', above, fixed = TRUE))
  # The overlay keeps the panel clip around the annotation.
  expect_match(above, "clip-path=", fixed = TRUE)
})

test_that("below + keyed + above reproduces the full render", {
  skip_if_not_installed("png")
  s <- .order_scene()
  full <- .png_arr(scene_png(s))
  comp <- .over(
    .png_arr(scene_png(s, layer = "unkeyed_above")),
    .over(
      .png_arr(scene_png(s, layer = "keyed")),
      .png_arr(scene_png(s, layer = "unkeyed_below"))
    )
  )
  expect_lt(max(abs(comp - full)), 3 / 255)
  # The old two-layer stack loses the line drawn over the points.
  two <- .over(
    .png_arr(scene_png(s, layer = "keyed")),
    .png_arr(scene_png(s, layer = "unkeyed"))
  )
  expect_gt(max(abs(two - full)), 0.5)
  # below + above is exactly unkeyed.
  expect_lt(
    max(abs(
      .over(
        .png_arr(scene_png(s, layer = "unkeyed_above")),
        .png_arr(scene_png(s, layer = "unkeyed_below"))
      ) -
        .png_arr(scene_png(s, layer = "unkeyed"))
    )),
    3 / 255
  )
})

test_that("panels changes which marks set the paint-order threshold", {
  s <- .order_scene()
  # With p1 not in the mark layer, p1's keyed points are furniture, so p1's
  # annotation still comes after them but no mark precedes it in p1.
  above <- scene_svg(s, layer = "unkeyed_above", panels = "p2")
  below <- scene_svg(s, layer = "unkeyed_below", panels = "p2")
  expect_false(grepl(">between<", above, fixed = TRUE))
  expect_match(below, 'data-key="a"', fixed = TRUE)
  expect_match(above, ">facet2top<", fixed = TRUE)
})

test_that("an unkeyed scene is all below", {
  skip_if_not_installed("png")
  s <- vl_scene(2, 2, dpi = 72, bg = "white") |>
    draw(circle_grob(gp = vl_gpar(fill = "tomato")))
  expect_identical(scene_png(s, layer = "unkeyed_below"), scene_png(s))
  expect_true(all(.png_arr(scene_png(s, layer = "unkeyed_above"))[,, 4] == 0))
})
