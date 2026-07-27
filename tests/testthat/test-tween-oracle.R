# Tests for the P0 pure-R tween oracle (R/tween-oracle.R). THROWAWAY: this test
# and the file it exercises are removed once the Rust tween is proven equal to it.

# Two single-circle scenes differing in x, r, and fill colour.
scene_ab <- function() {
  mk <- function(x, r_mm, fill) {
    vl_scene(4, 3, bg = "white") |>
      push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1), name = "panel")) |>
      draw(circle_grob(
        x = x, y = 0.5, r = vl_unit(r_mm, "mm"),
        gp = vl_gpar(fill = fill, col = NA), key = "c1"
      )) |>
      pop()
  }
  list(a = mk(0.2, 4, "#000000"), b = mk(0.8, 12, "#ffffff"))
}

# The single leaf grob of a tweened scene (panel -> child).
tw_leaf <- function(scene) {
  root <- vellum:::.materialize(scene)
  root@children[[1L]]@children[[1L]]
}

test_that("unit geometry lerps value + offset at t = 0, 0.5, 1", {
  s <- scene_ab()
  for (tt in c(0, 0.25, 0.5, 0.75, 1)) {
    g <- tw_leaf(vellum:::.scene_tween(s$a, s$b, tt))
    x <- vctrs::field(g@x, "value")
    r <- vctrs::field(g@r, "value")
    expect_equal(x, 0.2 + (0.8 - 0.2) * tt, tolerance = 1e-9)
    expect_equal(r, 4 + (12 - 4) * tt, tolerance = 1e-9)
    expect_equal(vctrs::field(g@r, "unit"), vellum:::.unit_codes[["mm"]])
  }
})

test_that("compound unit lerps its mm offset too", {
  ua <- vl_unit(0, "native") + vl_unit(0, "mm")
  ub <- vl_unit(1, "native") + vl_unit(4, "mm")
  m <- vellum:::.tw_tween_unit(ua, ub, 0.25)
  expect_equal(vctrs::field(m, "value"), 0.25)
  expect_equal(vctrs::field(m, "offset"), 1)
  expect_equal(vctrs::field(m, "unit"), vellum:::.unit_codes[["native"]])
})

test_that("cross-base units snap rather than lerp", {
  m <- vellum:::.tw_tween_unit(vl_unit(0.2, "npc"), vl_unit(0.9, "native"), 0.3)
  expect_equal(vctrs::field(m, "value"), 0.2) # t<0.5 -> near side (a)
  expect_equal(vctrs::field(m, "unit"), vellum:::.unit_codes[["npc"]])
  m2 <- vellum:::.tw_tween_unit(vl_unit(0.2, "npc"), vl_unit(0.9, "native"), 0.7)
  expect_equal(vctrs::field(m2, "value"), 0.9) # t>=0.5 -> far side (b)
})

test_that("colour tween is perceptual (Oklab), not the sRGB code midpoint", {
  mid <- vellum:::.tw_tween_col("#000000", "#ffffff", 0.5)
  r <- grDevices::col2rgb(mid)[1, ]
  # Oklab 50%-lightness black->white is code ~99, clearly below the sRGB 127
  # (matches oklab.rs's own midpoint bounds of 85..115).
  expect_lt(r, 115)
  expect_gt(r, 85)
})

test_that("colour endpoints are preserved at t = 0 and t = 1", {
  # rgb() carries the alpha byte through (col2rgb fills opaque -> FF).
  expect_equal(toupper(vellum:::.tw_tween_col("#123456", "#abcdef", 0)), "#123456FF")
  expect_equal(toupper(vellum:::.tw_tween_col("#123456", "#abcdef", 1)), "#ABCDEFFF")
})

test_that("Oklab port matches Ottosson reference (sRGB red)", {
  lab <- vellum:::.tw_rgb_to_oklab(255, 0, 0)
  expect_equal(lab$L, 0.6280, tolerance = 2e-3)
  expect_equal(lab$a, 0.2249, tolerance = 2e-3)
  expect_equal(lab$b, 0.1258, tolerance = 2e-3)
})

test_that("gp numerics (alpha, lwd) lerp; discrete (shape) snaps", {
  mk <- function(shape, alpha, lwd) {
    vl_scene(4, 3) |>
      push(vl_viewport(name = "panel")) |>
      draw(points_grob(
        x = 0.5, y = 0.5, shape = shape,
        gp = vl_gpar(fill = "red", alpha = alpha, lwd = lwd), key = "p"
      )) |>
      pop()
  }
  a <- mk("circle", 0.2, 1)
  b <- mk("square", 1.0, 5)
  g25 <- tw_leaf(vellum:::.scene_tween(a, b, 0.25))
  expect_equal(g25@gp@alpha, 0.2 + (1.0 - 0.2) * 0.25, tolerance = 1e-9)
  expect_equal(g25@gp@lwd, 1 + (5 - 1) * 0.25, tolerance = 1e-9)
  expect_equal(g25@shape, "circle") # snap: t<0.5 -> a
  g75 <- tw_leaf(vellum:::.scene_tween(a, b, 0.75))
  expect_equal(g75@shape, "square") # snap: t>=0.5 -> b
})

test_that("a node only in B enters (alpha 0 -> target)", {
  base <- vl_scene(4, 3) |> push(vl_viewport(name = "panel"))
  a <- base |>
    draw(circle_grob(x = 0.3, y = 0.5, gp = vl_gpar(fill = "red"), key = "a")) |>
    pop()
  b <- base |>
    draw(circle_grob(x = 0.3, y = 0.5, gp = vl_gpar(fill = "red"), key = "a")) |>
    draw(circle_grob(x = 0.7, y = 0.5, gp = vl_gpar(fill = "blue"), key = "b")) |>
    pop()
  # id-less children -> positional match; the 2nd child of B has no partner -> enters.
  panel <- vellum:::.materialize(vellum:::.scene_tween(a, b, 0.25))@children[[1L]]
  expect_length(panel@children, 2L)
  entering <- panel@children[[2L]]
  expect_equal(entering@gp@alpha, 0.25, tolerance = 1e-9)
})

test_that("a node only in A exits (target -> 0)", {
  base <- vl_scene(4, 3) |> push(vl_viewport(name = "panel"))
  a <- base |>
    draw(circle_grob(x = 0.3, y = 0.5, gp = vl_gpar(fill = "red"), key = "a")) |>
    draw(circle_grob(x = 0.7, y = 0.5, gp = vl_gpar(fill = "blue"), key = "b")) |>
    pop()
  b <- base |>
    draw(circle_grob(x = 0.3, y = 0.5, gp = vl_gpar(fill = "red"), key = "a")) |>
    pop()
  panel <- vellum:::.materialize(vellum:::.scene_tween(a, b, 0.25))@children[[1L]]
  expect_length(panel@children, 2L)
  exiting <- panel@children[[2L]]
  expect_equal(exiting@gp@alpha, 0.75, tolerance = 1e-9) # 1 - t
})

test_that("differing vertex counts crossfade instead of morphing", {
  mk <- function(n) {
    vl_scene(4, 3) |>
      push(vl_viewport(xscale = c(0, 1), yscale = c(0, 1), name = "panel")) |>
      draw(lines_grob(
        x = vl_unit(seq(0, 1, length.out = n), "native"),
        y = vl_unit(seq(0, 1, length.out = n), "native"),
        gp = vl_gpar(col = "black")
      )) |>
      pop()
  }
  a <- mk(3)
  b <- mk(7)
  panel <- vellum:::.materialize(vellum:::.scene_tween(a, b, 0.4))@children[[1L]]
  # crossfade -> two faded polylines, not one morphed line
  expect_length(panel@children, 2L)
  expect_equal(panel@children[[1L]]@gp@alpha, 0.6, tolerance = 1e-9) # a: 1 - t
  expect_equal(panel@children[[2L]]@gp@alpha, 0.4, tolerance = 1e-9) # b: t
  expect_equal(vellum:::.vsize(panel@children[[1L]]@x), 3L)
  expect_equal(vellum:::.vsize(panel@children[[2L]]@x), 7L)
})

test_that("schedule shape and easing", {
  sched <- vellum:::.anim_schedule(3, nframes = 4, ease = "linear")
  # 2 segments * 4 frames + 1 rest = 9 rows
  expect_equal(nrow(sched), 9L)
  expect_equal(sched$i, c(1, 1, 1, 1, 2, 2, 2, 2, 2))
  expect_equal(sched$t[1:4], c(0, 0.25, 0.5, 0.75))
  expect_equal(sched$t[9], 1)
  ci <- vellum:::.anim_schedule(2, nframes = 2, ease = "cubic-in-out")
  expect_equal(ci$t, c(vellum:::.tw_ease(0, "cubic-in-out"), vellum:::.tw_ease(0.5, "cubic-in-out"), 1))
})

test_that("scene_tween produces a renderable scene", {
  s <- scene_ab()
  arr <- scene_raster(vellum:::.scene_tween(s$a, s$b, 0.5))
  expect_equal(dim(arr)[1], 4L)
  expect_true(all(arr >= 0 & arr <= 255))
})
