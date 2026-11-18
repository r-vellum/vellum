test_that("scene_model() returns one row per element with key, mark, meta", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(points_grob(
      c(0.25, 0.75),
      c(0.5, 0.5),
      size = vl_unit(4, "mm"),
      gp = vl_gpar(fill = "red"),
      key = c("a", "b"),
      meta = list(list(lab = "A"), list(lab = "B")),
      id = "pts"
    ))
  m <- scene_model(sc)
  expect_named(m, c("elements", "panels"))
  expect_equal(nrow(m$elements), 2L)
  expect_equal(m$elements$key, c("a", "b"))
  expect_equal(m$elements$mark, c("point", "point"))
  expect_equal(m$elements$id, c("pts", "pts"))
  expect_equal(m$elements$meta[[1]]$lab, "A")
  expect_equal(m$elements$meta[[2]]$lab, "B")
})

test_that("scene_model() resolves device-px geometry (centre and size)", {
  # 2in x 100dpi = 200px; points at 0.25/0.75 npc -> x = 50/150, y = 100.
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(points_grob(
      c(0.25, 0.75),
      c(0.5, 0.5),
      size = vl_unit(4, "mm"),
      gp = vl_gpar(fill = "red"),
      key = c("a", "b")
    ))
  m <- scene_model(sc)
  expect_equal(m$elements$x, c(50, 150))
  expect_equal(m$elements$y, c(100, 100))
  # bbox is consistent with centre/size
  expect_equal(m$elements$x, (m$elements$x0 + m$elements$x1) / 2)
  expect_equal(m$elements$w, m$elements$x1 - m$elements$x0)
})

test_that("scene_model() attributes elements to their enclosing named panel", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    push(vl_viewport(name = "panel-1-1")) |>
    draw(points_grob(
      c(0.25, 0.75),
      0.5,
      gp = vl_gpar(fill = "red"),
      key = c("a", "b")
    )) |>
    pop() |>
    draw(rect_grob(
      x = 0.5,
      y = 0.5,
      width = 0.3,
      height = 0.3,
      gp = vl_gpar(fill = "blue"),
      key = "R"
    ))
  m <- scene_model(sc)
  expect_equal(m$elements$panel, c("panel-1-1", "panel-1-1", NA))
  expect_equal(m$panels$name, "panel-1-1")
})

test_that("scene_model() covers all keyable marks in paint order", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      x = 0.2,
      y = 0.5,
      width = 0.1,
      height = 0.1,
      key = "rect1"
    )) |>
    draw(segments_grob(
      0.1,
      0.1,
      0.9,
      0.9,
      gp = vl_gpar(col = "black", lwd = 1),
      key = "seg1"
    )) |>
    draw(points_grob(0.5, 0.5, gp = vl_gpar(fill = "red"), key = "pt1"))
  m <- scene_model(sc)
  expect_equal(m$elements$mark, c("rect", "segment", "point"))
  expect_equal(m$elements$key, c("rect1", "seg1", "pt1"))
})

test_that("scene_model() yields a geometry table even without keys/meta", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(points_grob(c(0.3, 0.6), 0.5, gp = vl_gpar(fill = "red")))
  m <- scene_model(sc)
  expect_equal(nrow(m$elements), 2L)
  expect_true(all(is.na(m$elements$key)))
  expect_true(all(vapply(m$elements$meta, is.null, logical(1))))
})

test_that("scene_model() includes keyed single-shape marks (path) but not unkeyed ones", {
  keyed <- path_grob(
    c(0.2, 0.8, 0.8),
    c(0.2, 0.2, 0.8),
    gp = vl_gpar(fill = "red")
  )
  keyed@keys <- "county-a"
  keyed@meta <- list(list(tooltip = "County A"))
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(keyed) |>
    draw(path_grob(
      c(0.1, 0.3, 0.3),
      c(0.1, 0.1, 0.3),
      gp = vl_gpar(fill = "blue")
    )) # unkeyed
  m <- scene_model(sc)
  kr <- m$elements[!is.na(m$elements$key), ]
  expect_equal(nrow(kr), 1L)
  expect_equal(kr$key, "county-a")
  expect_equal(kr$mark, "path")
  expect_equal(kr$meta[[1]]$tooltip, "County A")
  expect_true(kr$x1 > kr$x0 && kr$y1 > kr$y0) # a resolved bbox
})

test_that("scene_model() keys a multi-box roundrect grob per element", {
  # A `roundrect_grob()` is a batch (one box per element), keyed-only like text:
  # each keyed box is a row, and an unkeyed grob contributes nothing. This is the
  # backend's own accounting (`Node::RoundRect` is emitted per node under a
  # `key.is_some()` guard); the R walk must agree or `scene_model()` aborts on the
  # count check. Regression: roundrect used to be classed as a single shape (one
  # row per grob), which undercounted a 3-box keyed grob 1-against-3 and aborted.
  keyed <- roundrect_grob(
    x = c(0.2, 0.5, 0.8),
    y = 0.5,
    width = vl_unit(6, "mm"),
    height = vl_unit(4, "mm"),
    key = c("a", "b", "c"),
    meta = list(list(tooltip = "A"), list(tooltip = "B"), list(tooltip = "C"))
  )
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(keyed) |>
    # an unkeyed roundrect batch must stay out of the model entirely
    draw(roundrect_grob(
      x = c(0.3, 0.6),
      y = 0.9,
      width = vl_unit(6, "mm"),
      height = vl_unit(4, "mm")
    ))
  m <- scene_model(sc)
  kr <- m$elements[!is.na(m$elements$key), ]
  expect_equal(nrow(kr), 3L)
  expect_equal(kr$mark, rep("roundrect", 3L))
  expect_equal(kr$key, c("a", "b", "c"))
  # keys and meta stay aligned per box (the truncate-to-first bug dropped b/c)
  expect_equal(
    vapply(kr$meta, function(x) x$tooltip, character(1)),
    c("A", "B", "C")
  )
  expect_true(all(kr$x1 > kr$x0 & kr$y1 > kr$y0)) # resolved bboxes
})

test_that("scene_model() of an empty scene has zero elements and panels", {
  m <- scene_model(vl_scene(2, 2, dpi = 100))
  expect_equal(nrow(m$elements), 0L)
  expect_equal(nrow(m$panels), 0L)
})

# Multi-label text_grob(): keys/meta used to be recycled to length(x), so a
# scalar x with three labels kept one key, and scene_model() aborted with an
# element-count mismatch (1 from the walk, 3 from the backend).

test_that("scalar x + 3 labels + 3 keys gives 3 keyed text elements", {
  sc <- vl_scene(2, 2) |>
    draw(text_grob(c("a", "b", "c"), key = c("k1", "k2", "k3")))
  m <- scene_model(sc)
  el <- m$elements[m$elements$mark == "text", ]
  expect_identical(el$key, c("k1", "k2", "k3"))
})

test_that("vector y + scalar x recycles keys to the y length", {
  sc <- vl_scene(2, 2) |>
    draw(text_grob("a", y = c(0.2, 0.5, 0.8), key = c("k1", "k2", "k3")))
  el <- scene_model(sc)$elements
  el <- el[el$mark == "text", ]
  expect_identical(el$key, c("k1", "k2", "k3"))
  # y = 0.2 is lowest on the page, so largest in device px
  expect_true(all(diff(el$y) < 0))
})

test_that("text meta and a scalar key recycle to the label count", {
  g <- text_grob(
    c("a", "b", "c"),
    key = "k",
    meta = list(list(v = 1))
  )
  expect_identical(g@keys, rep("k", 3L))
  expect_length(g@meta, 3L)
  el <- scene_model(vl_scene(2, 2) |> draw(g))$elements
  el <- el[el$mark == "text", ]
  expect_identical(el$key, rep("k", 3L))
  expect_identical(el$meta, rep(list(list(v = 1)), 3L))
  g2 <- text_grob(
    c("a", "b"),
    key = c("p", "q"),
    meta = list(list(v = 1), list(v = 2))
  )
  el <- scene_model(vl_scene(2, 2) |> draw(g2))$elements
  expect_identical(el$meta, list(list(v = 1), list(v = 2)))
})

test_that("incompatible label/x/y lengths fail with a clear error", {
  expect_error(
    text_grob(c("a", "b", "c"), x = c(0.1, 0.2)),
    "must have compatible lengths"
  )
  expect_snapshot(text_grob(c("a", "b", "c"), x = c(0.1, 0.2)), error = TRUE)
})

# Batched marks with a scalar coordinate and a vector one: `.sm_n()` used to read
# `length(x)` for every batch but segments and text, so a rect with scalar `x`
# and three `y`s counted one element against the backend's three and aborted.
# The constructor, `compile()` and `scene_model()` now share `.batch_n()`.

batched_cases <- list(
  rect = function(x, y, key) {
    rect_grob(x = x, y = y, width = 0.05, height = 0.05, key = key)
  },
  roundrect = function(x, y, key) {
    roundrect_grob(x = x, y = y, width = 0.05, height = 0.05, key = key)
  },
  circle = function(x, y, key) circle_grob(x = x, y = y, r = 0.03, key = key),
  point = function(x, y, key) points_grob(x = x, y = y, key = key),
  hexagon = function(x, y, key) hexagon_grob(x = x, y = y, key = key),
  sector = function(x, y, key) {
    sector_grob(x = x, y = y, r1 = vl_unit(1, "mm"), key = key)
  },
  segment = function(x, y, key) {
    segments_grob(x, y, vl_unit(x, "npc") + vl_unit(1, "mm"), y, key = key)
  }
)

test_that("scalar x + vector y with keys gives one keyed row per element", {
  for (mark in names(batched_cases)) {
    g <- batched_cases[[mark]](0.5, c(0.2, 0.5, 0.8), c("a", "b", "c"))
    expect_identical(g@keys, c("a", "b", "c"), label = mark)
    el <- scene_model(vl_scene(2, 2) |> draw(g))$elements
    expect_identical(el$mark, rep(mark, 3L), label = mark)
    expect_identical(el$key, c("a", "b", "c"), label = mark)
    # npc y up is device y down: keys follow the elements, in order.
    expect_true(all(diff(el$y) < 0), label = mark)
  }
})

test_that("vector x + scalar y with keys gives one keyed row per element", {
  for (mark in names(batched_cases)) {
    g <- batched_cases[[mark]](c(0.2, 0.5, 0.8), 0.5, c("a", "b", "c"))
    el <- scene_model(vl_scene(2, 2) |> draw(g))$elements
    expect_identical(el$key, c("a", "b", "c"), label = mark)
    expect_true(all(diff(el$x) > 0), label = mark)
  }
})

test_that("a scalar key recycles to every element", {
  for (mark in names(batched_cases)) {
    g <- batched_cases[[mark]](0.5, c(0.2, 0.5, 0.8), "k")
    el <- scene_model(vl_scene(2, 2) |> draw(g))$elements
    expect_identical(el$key, rep("k", 3L), label = mark)
  }
})

test_that("a key or meta of the wrong length is an error, not truncated", {
  for (mark in names(batched_cases)) {
    expect_error(
      batched_cases[[mark]](0.5, c(0.2, 0.5, 0.8), c("a", "b")),
      "`key` must have length 1 or 3",
      label = mark
    )
    expect_error(
      batched_cases[[mark]](0.5, c(0.2, 0.5, 0.8), letters[1:4]),
      "`key` must have length 1 or 3",
      label = mark
    )
  }
  expect_error(
    rect_grob(y = c(0.2, 0.8), meta = list(1, 2, 3)),
    "`meta` must have length 1 or 2"
  )
  expect_error(text_grob(c("a", "b"), key = letters[1:3]), "`key`")
  expect_error(lines_grob(1:2, 1:2, key = c("a", "b")), "`key`")
  expect_snapshot(rect_grob(y = c(0.2, 0.8), key = letters[1:3]), error = TRUE)
})

test_that("incompatible per-element lengths fail up front, naming the args", {
  expect_error(
    rect_grob(x = c(0.1, 0.2), y = c(0.1, 0.2, 0.3)),
    "`x`, `y`, `width`, and `height` must have compatible lengths"
  )
  expect_error(
    points_grob(0.5, 0.5, size = 1:2, shape = rep("circle", 3)),
    "compatible"
  )
  expect_error(hexagon_grob(0.5, c(0.2, 0.8), size = 1:3), "compatible")
})
