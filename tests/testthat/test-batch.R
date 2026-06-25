# Batched primitives (P1): one FFI call + one shared gpar for rect/circle/points,
# with a raster sprite fast path for large uniform point clouds. Probes go through
# a compiled backend Scene in-memory.

px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

test_that("a multi-element rect grob draws every rectangle", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(
      x = unit(c(0.25, 0.75), "npc"), y = unit(c(0.25, 0.75), "npc"),
      width = unit(0.2, "npc"), height = unit(0.2, "npc"),
      gp = gpar(fill = "red", col = NA)
    ))
  expect_equal(px(s, 25, 75)[1:3], c(255L, 0L, 0L)) # lower-left rect (y flips)
  expect_equal(px(s, 75, 25)[1:3], c(255L, 0L, 0L)) # upper-right rect
  expect_equal(px(s, 50, 50)[1:3], c(255L, 255L, 255L)) # gap between them
})

test_that("a multi-element circle grob draws every circle", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(circle_grob(
      x = unit(c(0.3, 0.7), "npc"), y = unit(c(0.5, 0.5), "npc"),
      r = unit(0.1, "npc"), gp = gpar(fill = "blue", col = NA)
    ))
  expect_equal(px(s, 30, 50)[1:3], c(0L, 0L, 255L))
  expect_equal(px(s, 70, 50)[1:3], c(0L, 0L, 255L))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 255L, 255L))
})

test_that("batched rects with a stroke render fill and border", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.6, height = 0.6,
                   gp = gpar(fill = "red", col = "blue", lwd = 4)))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 0L, 0L)) # centre: fill
  expect_equal(px(s, 50, 20)[1:3], c(0L, 0L, 255L)) # top edge (npc 0.8): border
})

test_that("a large uniform point cloud renders via the sprite path", {
  # > 10000 equal-radius solid markers triggers sprite stamping; a dense block
  # should paint its region and leave the corner as background.
  g <- expand.grid(x = seq(0.2, 0.8, length.out = 110), y = seq(0.2, 0.8, length.out = 110))
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(points_grob(unit(g$x, "npc"), unit(g$y, "npc"), size = unit(2, "mm"),
                     gp = gpar(fill = "darkgreen", col = NA)))
  centre <- px(s, 50, 50)
  expect_true(centre[2] > 80L && centre[1] < 60L && centre[3] < 60L) # green-ish
  expect_equal(px(s, 3, 3)[1:3], c(255L, 255L, 255L)) # corner: background
})

test_that("points with a stroke fall back to per-element drawing", {
  g <- expand.grid(x = seq(0.2, 0.8, length.out = 110), y = seq(0.2, 0.8, length.out = 110))
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(points_grob(unit(g$x, "npc"), unit(g$y, "npc"), size = unit(2, "mm"),
                     gp = gpar(fill = "white", col = "black", lwd = 1)))
  expect_no_error(.scene_to_backend(s)$pixel(50, 50))
})

test_that("a gradient-filled circle batch uses the per-element path", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(circle_grob(x = 0.5, y = 0.5, r = 0.4,
                     gp = gpar(col = NA, fill = radial_gradient(c("red", "yellow")))))
  centre <- px(s, 50, 50)
  expect_true(centre[1] > 200L && centre[2] < 80L) # red core
})

test_that("the sprite path respects clipping", {
  g <- expand.grid(x = seq(0.05, 0.95, length.out = 110), y = seq(0.05, 0.95, length.out = 110))
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(viewport(width = 0.4, height = 0.4, clip = TRUE)) |>
    draw(points_grob(unit(g$x, "npc"), unit(g$y, "npc"), size = unit(2, "mm"),
                     gp = gpar(fill = "darkgreen", col = NA))) |>
    pop()
  # The viewport occupies the central 40%; outside it must stay background.
  expect_equal(px(s, 5, 5)[1:3], c(255L, 255L, 255L))
})
