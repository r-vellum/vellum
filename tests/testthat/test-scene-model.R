test_that("scene_model() returns one row per element with key, mark, meta", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(points_grob(c(0.25, 0.75), c(0.5, 0.5), size = unit(4, "mm"),
                     gp = gpar(fill = "red"), key = c("a", "b"),
                     meta = list(list(lab = "A"), list(lab = "B")), id = "pts"))
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
    draw(points_grob(c(0.25, 0.75), c(0.5, 0.5), size = unit(4, "mm"),
                     gp = gpar(fill = "red"), key = c("a", "b")))
  m <- scene_model(sc)
  expect_equal(m$elements$x, c(50, 150))
  expect_equal(m$elements$y, c(100, 100))
  # bbox is consistent with centre/size
  expect_equal(m$elements$x, (m$elements$x0 + m$elements$x1) / 2)
  expect_equal(m$elements$w, m$elements$x1 - m$elements$x0)
})

test_that("scene_model() attributes elements to their enclosing named panel", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    push(viewport(name = "panel-1-1")) |>
    draw(points_grob(c(0.25, 0.75), 0.5, gp = gpar(fill = "red"), key = c("a", "b"))) |>
    pop() |>
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.3, height = 0.3,
                   gp = gpar(fill = "blue"), key = "R"))
  m <- scene_model(sc)
  expect_equal(m$elements$panel, c("panel-1-1", "panel-1-1", NA))
  expect_equal(m$panels$name, "panel-1-1")
})

test_that("scene_model() covers all keyable marks in paint order", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(x = 0.2, y = 0.5, width = 0.1, height = 0.1, key = "rect1")) |>
    draw(segments_grob(0.1, 0.1, 0.9, 0.9, gp = gpar(col = "black", lwd = 1), key = "seg1")) |>
    draw(points_grob(0.5, 0.5, gp = gpar(fill = "red"), key = "pt1"))
  m <- scene_model(sc)
  expect_equal(m$elements$mark, c("rect", "segment", "point"))
  expect_equal(m$elements$key, c("rect1", "seg1", "pt1"))
})

test_that("scene_model() yields a geometry table even without keys/meta", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(points_grob(c(0.3, 0.6), 0.5, gp = gpar(fill = "red")))
  m <- scene_model(sc)
  expect_equal(nrow(m$elements), 2L)
  expect_true(all(is.na(m$elements$key)))
  expect_true(all(vapply(m$elements$meta, is.null, logical(1))))
})

test_that("scene_model() includes keyed single-shape marks (path) but not unkeyed ones", {
  keyed <- path_grob(c(.2, .8, .8), c(.2, .2, .8), gp = gpar(fill = "red"))
  keyed@keys <- "county-a"
  keyed@meta <- list(list(tooltip = "County A"))
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(keyed) |>
    draw(path_grob(c(.1, .3, .3), c(.1, .1, .3), gp = gpar(fill = "blue"))) # unkeyed
  m <- scene_model(sc)
  kr <- m$elements[!is.na(m$elements$key), ]
  expect_equal(nrow(kr), 1L)
  expect_equal(kr$key, "county-a")
  expect_equal(kr$mark, "path")
  expect_equal(kr$meta[[1]]$tooltip, "County A")
  expect_true(kr$x1 > kr$x0 && kr$y1 > kr$y0) # a resolved bbox
})

test_that("scene_model() of an empty scene has zero elements and panels", {
  m <- scene_model(vl_scene(2, 2, dpi = 100))
  expect_equal(nrow(m$elements), 0L)
  expect_equal(nrow(m$panels), 0L)
})
