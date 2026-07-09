# vl_viewport(alpha=): group opacity. The subtree composites as one isolated layer,
# so overlaps do NOT accumulate (unlike per-element vl_gpar(alpha=)).

test_that("group alpha fades the whole layer and overlaps do not compound", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    push(vl_viewport(alpha = 0.5)) |>
    draw(rect_grob(x = 0.45, width = 0.4, height = 0.8, gp = vl_gpar(fill = "black", col = NA))) |>
    draw(rect_grob(x = 0.55, width = 0.4, height = 0.8, gp = vl_gpar(fill = "black", col = NA))) |>
    pop()
  red <- scene_raster(s)[1, , ]
  single <- red[60, 100] # only one rect here
  overlap <- red[100, 100] # both rects overlap here
  expect_lt(abs(single - 127), 12) # ~50% of black over white
  expect_lt(abs(overlap - single), 3) # group composited once -> no double-darkening
})

test_that("per-element alpha DOES compound on overlap (contrast with group alpha)", {
  # Same geometry, opacity via vl_gpar instead of the viewport: the overlap is darker.
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(rect_grob(x = 0.45, width = 0.4, height = 0.8, gp = vl_gpar(fill = "black", col = NA, alpha = 0.5))) |>
    draw(rect_grob(x = 0.55, width = 0.4, height = 0.8, gp = vl_gpar(fill = "black", col = NA, alpha = 0.5)))
  red <- scene_raster(s)[1, , ]
  expect_lt(red[100, 100], red[60, 100] - 20) # overlap noticeably darker than single
})

test_that("alpha is validated", {
  expect_error(vl_viewport(alpha = 1.5), "alpha")
  expect_error(vl_viewport(alpha = c(0.2, 0.3)), "alpha")
})
