# roundrect_grob: rounded corners, isotropic radius.

test_that("a rounded rect clips its corners but fills its centre", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(roundrect_grob(
      width = 1,
      height = 1,
      r = 0.4,
      gp = vl_gpar(fill = "red", col = NA)
    ))
  r <- scene_raster(s)
  expect_equal(r[1:3, 4, 4], c(255L, 255L, 255L)) # corner cut away -> background
  expect_equal(r[1:3, 100, 100], c(255L, 0L, 0L)) # centre filled
  expect_equal(r[1:3, 100, 4], c(255L, 0L, 0L)) # mid-top edge is straight -> filled
})

test_that("r = 0 is a plain rectangle (corner filled)", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(roundrect_grob(
      width = 1,
      height = 1,
      r = 0,
      gp = vl_gpar(fill = "red", col = NA)
    ))
  r <- scene_raster(s)
  expect_equal(r[1:3, 3, 3], c(255L, 0L, 0L))
})

test_that("npc radius is isotropic on a non-square rect (corners stay circular)", {
  # A wide, short rounded rect: the corner inset along x and y must be equal
  # (radius resolved against the shorter side), so the rect is symmetric.
  s <- vl_scene(4, 2, dpi = 100, bg = "white") |>
    draw(roundrect_grob(
      width = 1,
      height = 1,
      r = 0.3,
      gp = vl_gpar(fill = "blue", col = NA)
    ))
  r <- scene_raster(s)
  d <- dim(r) # c(4, 400, 200)
  # symmetric about both axes
  expect_equal(r[3, 5, 100], r[3, d[2] - 4, 100]) # left vs right edge mid-height
  expect_equal(r[3, 200, 5], r[3, 200, d[3] - 4]) # top vs bottom mid-width
})

test_that("the picking outline follows the drawn corners (VR-55)", {
  u <- function(v) vl_unit(v, "pt")
  # On a 144 x 144 px page, a corner of radius r whose arc passes the page
  # centre at angle `a` (y-down) on the top-left corner. Points 1.5 px inside
  # and outside that arc must hit and miss: the outline used to cut each
  # corner with 5 points, 0.012 r inside the arc.
  probe <- function(r, deg) {
    a <- (180 + deg) * pi / 180
    cxc <- 72 - r * cos(a)
    cyc <- 72 - r * sin(a)
    x0 <- cxc - r
    y0 <- cyc - r
    s <- vl_scene(2, 2, dpi = 72) |>
      draw(roundrect_grob(
        u(x0 + 1.5 * r),
        u(144 - (y0 + 1.5 * r)),
        u(3 * r),
        u(3 * r),
        r = u(r),
        key = "k",
        gp = vl_gpar(fill = "red", col = NA)
      ))
    at <- function(d) {
      length(hit_test(s, 72 - d * cos(a), 72 - d * sin(a), units = "px")) > 0
    }
    c(inside = at(1.5), outside = at(-1.5))
  }
  for (r in c(20, 200, 1000, 5000)) {
    for (deg in c(9, 30, 45, 81)) {
      expect_identical(
        probe(r, deg),
        c(inside = TRUE, outside = FALSE),
        info = paste(r, deg)
      )
    }
  }
})
