test_that("a nested viewport places drawing in the right region", {
  # child centred in the top-left quadrant (npc y=0.75 is near the top)
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(viewport(x = 0.25, y = 0.75, width = 0.5, height = 0.5)) |>
    draw(rect_grob(gp = gpar(fill = "red", col = NA)))
  expect_equal(px(s, 25, 25)[1:3], c(255L, 0L, 0L)) # inside child
  expect_equal(px(s, 75, 75)[1:3], c(255L, 255L, 255L)) # opposite quadrant
})

test_that("viewport rotation turns a square into a diamond", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(viewport(x = 0.5, y = 0.5, width = 0.5, height = 0.5, angle = 45)) |>
    draw(rect_grob(gp = gpar(fill = "red", col = NA)))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 0L, 0L)) # centre painted
  # a corner of the *unrotated* bounding box is outside the diamond
  expect_equal(px(s, 70, 70)[1:3], c(255L, 255L, 255L))
})

test_that("clip=TRUE confines drawing to the viewport rectangle", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(viewport(x = 0.5, y = 0.5, width = 0.4, height = 0.4, clip = TRUE)) |>
    draw(circle_grob(r = 0.9, gp = gpar(fill = "blue", col = NA))) # bigger than the viewport
  expect_equal(px(s, 50, 50)[1:3], c(0L, 0L, 255L)) # inside viewport
  # the circle reaches here, but it is above the viewport (top edge ~ y=30)
  expect_equal(px(s, 50, 20)[1:3], c(255L, 255L, 255L))
})

test_that("nested clips intersect", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(viewport(x = 0.5, y = 0.5, width = 0.6, height = 0.6, clip = TRUE)) |>
    push(viewport(x = 0.5, y = 0.5, width = 0.5, height = 1.5, clip = TRUE)) |>
    draw(rect_grob(gp = gpar(fill = "blue", col = NA))) # fills inner vp, clipped to intersection
  # vertically inside both, horizontally inside both -> painted
  expect_equal(px(s, 50, 50)[1:3], c(0L, 0L, 255L))
  # near top: inside the tall inner vp but OUTSIDE the outer vp (clipped away)
  expect_equal(px(s, 50, 10)[1:3], c(255L, 255L, 255L))
})

test_that("gpar fill inherits from the enclosing viewport and can be overridden", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(viewport(gp = gpar(fill = "red"))) |>
    draw(rect_grob(x = 0.25, width = 0.4, gp = gpar(col = NA))) |> # inherit -> red
    draw(rect_grob(x = 0.75, width = 0.4, gp = gpar(fill = "blue", col = NA))) # override -> blue
  expect_equal(px(s, 25, 50)[1:3], c(255L, 0L, 0L))
  expect_equal(px(s, 75, 50)[1:3], c(0L, 0L, 255L))
})

test_that("alpha multiplies down the viewport tree", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(viewport(gp = gpar(alpha = 0.5))) |>
    draw(rect_grob(gp = gpar(fill = "black", col = NA, alpha = 0.5))) # 0.5 * 0.5 = 0.25
  p <- px(s, 50, 50)
  expect_equal(p[4], 255L) # opaque over white
  # 0.25 black over white -> ~191 grey
  expect_true(all(abs(p[1:3] - 191L) <= 2L))
})

test_that("native positions account for a non-zero / negative scale origin", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(viewport(xscale = c(-10, 10), yscale = c(-10, 10))) |>
    # native (0, 0) is the centre of a symmetric scale -> device centre
    draw(rect_grob(x = unit(0, "native"), y = unit(0, "native"),
                   width = unit(4, "native"), height = unit(4, "native"),
                   gp = gpar(fill = "red", col = NA))) |>
    # native y = 8 -> npc (8+10)/20 = 0.9 -> near the top of the device
    draw(rect_grob(x = unit(0, "native"), y = unit(8, "native"),
                   width = unit(4, "native"), height = unit(2, "native"),
                   gp = gpar(fill = "blue", col = NA)))
  expect_equal(px(s, 50, 50)[1:3], c(255L, 0L, 0L))
  expect_equal(px(s, 50, 10)[1:3], c(0L, 0L, 255L))
})

test_that("a single pushed viewport with native scales draws correctly", {
  s <- vl_scene(width = 1, height = 1, dpi = 100, bg = "white") |>
    push(viewport(xscale = c(0, 10), yscale = c(0, 10))) |>
    draw(rect_grob(x = unit(5, "native"), y = unit(5, "native"),
                   width = unit(4, "native"), height = unit(4, "native"),
                   gp = gpar(fill = "blue", col = NA)))
  expect_equal(px(s, 50, 50)[1:3], c(0L, 0L, 255L))
})

test_that("viewport() rejects non-positive row/col", {
  expect_error(viewport(row = 0), "positive integer")
  expect_error(viewport(col = -1), "positive integer")
  expect_error(viewport(row = NA_integer_), "positive integer")
  expect_silent(viewport(row = 1, col = 2))
  expect_silent(viewport()) # NULL row/col is fine
})

test_that("a degenerate or non-finite native scale falls back instead of vanishing", {
  # zero-span x scale + non-finite y scale would yield NaN native coords (which
  # tiny-skia silently drops); the resolver falls back to (0, 1) so npc still draws.
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    push(viewport(xscale = c(0, 0), yscale = c(NA, 1))) |>
    draw(rect_grob(gp = gpar(fill = "red", col = NA))) |>
    pop()
  expect_equal(px(s, 50, 50)[1:3], c(255L, 0L, 0L))
})
