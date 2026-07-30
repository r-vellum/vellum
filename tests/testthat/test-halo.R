# Text halo (shadowtext): glyph outlines stroked *under* the fill, so a label
# stays legible over dense marks. All three backends draw it; the raster and
# outline-SVG paths do two explicit passes, native SVG uses `paint-order`.

halo_scene <- function(...) {
  vl_scene(3, 1, dpi = 100, bg = "steelblue") |>
    draw(text_grob("Halo", gp = vl_gpar(fontsize = 30, col = "white", ...)))
}

test_that("a halo changes the raster output, and its absence does not", {
  plain <- withr::local_tempfile(fileext = ".png")
  haloed <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache(); render(halo_scene(), plain)
  vl_clear_render_cache(); render(halo_scene(halo_col = "black", halo_width = 2), haloed)
  expect_false(identical(tools::md5sum(plain)[[1]], tools::md5sum(haloed)[[1]]))
})

test_that("a halo is drawn under the fill, not over it", {
  # White glyphs, black halo, on a blue page. Sample the glyph interior: it must
  # still be white (the halo must not have painted over the fill), while pixels
  # just outside the glyph edge must be darker than the page.
  s <- vl_scene(3, 1, dpi = 100, bg = "#4682B4") |>
    draw(text_grob("H", x = 0.5, y = 0.5,
                   gp = vl_gpar(fontsize = 60, col = "white",
                                halo_col = "black", halo_width = 3)))
  r <- scene_raster(s)
  # The stem of a big centred "H" runs through the middle rows.
  mid <- r[, , dim(r)[3] %/% 2]
  # Somewhere on that row there must be near-white (fill) and near-black (halo).
  white <- any(mid[1, ] > 240 & mid[2, ] > 240 & mid[3, ] > 240)
  black <- any(mid[1, ] < 40 & mid[2, ] < 40 & mid[3, ] < 40)
  expect_true(white)
  expect_true(black)
})

test_that("halo needs both a colour and a positive width", {
  base <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache(); render(halo_scene(), base)
  ref <- tools::md5sum(base)[[1]]
  for (gp in list(list(halo_col = "black"), list(halo_width = 2),
                  list(halo_col = "black", halo_width = 0),
                  list(halo_col = NA, halo_width = 2))) {
    f <- withr::local_tempfile(fileext = ".png")
    vl_clear_render_cache()
    render(do.call(halo_scene, gp), f)
    expect_identical(tools::md5sum(f)[[1]], ref)
  }
})

test_that("native SVG uses paint-order and outline SVG emits stroked paths", {
  s <- halo_scene(halo_col = "black", halo_width = 2)
  native <- scene_svg(s)
  expect_match(native, "paint-order=\"stroke fill\"")
  # `halo_width` is in points like `fontsize`, so it scales by dpi/72, and the
  # emitted stroke is doubled because a centred stroke hides half under the fill:
  # 2 pt at 100 dpi -> 2 * 100/72 * 2 = 5.5555... px.
  expect_match(native, "stroke-width=\"5.55")
  outline <- scene_svg(s, text = "outline")
  expect_match(outline, "fill=\"none\" stroke=")
})

test_that("a halo renders in PDF without a degradation warning", {
  f <- withr::local_tempfile(fileext = ".pdf")
  vl_clear_render_cache()
  expect_no_warning(render(halo_scene(halo_col = "black", halo_width = 2), f))
  expect_gt(file.size(f), 0)
})

test_that("the glyph-sprite fast path is bypassed for haloed text", {
  # A sprite bakes the fill only, so haloed text must take the exact outline
  # path even when the bitmap cache is forced on. If it did not, the halo would
  # silently vanish above the glyph threshold.
  f1 <- withr::local_tempfile(fileext = ".png")
  f2 <- withr::local_tempfile(fileext = ".png")
  s <- halo_scene(halo_col = "black", halo_width = 2)
  withr::with_options(list(vellum.glyph_bitmap = "on"), {
    vl_clear_render_cache(); render(s, f1)
  })
  withr::with_options(list(vellum.glyph_bitmap = "off"), {
    vl_clear_render_cache(); render(s, f2)
  })
  expect_identical(tools::md5sum(f1)[[1]], tools::md5sum(f2)[[1]])
})

test_that("a negative halo_width is rejected", {
  expect_error(vl_gpar(halo_width = -1), "halo_width")
})

test_that("halo works on rich md() labels and multi-line text", {
  for (lab in list(md("**bold** halo"), "two\nlines")) {
    f <- withr::local_tempfile(fileext = ".png")
    vl_clear_render_cache()
    expect_no_error(render(
      vl_scene(3, 1.5, dpi = 100) |>
        draw(text_grob(lab, gp = vl_gpar(fontsize = 20, halo_col = "yellow", halo_width = 1.5))),
      f
    ))
  }
})
