# OpenType feature control (`vl_gpar(features = )`). Features change which
# glyphs HarfBuzz produces, so they must reach BOTH drawing and measurement --
# and must be part of the shape-cache key, or a second grob would be served the
# first one's glyphs.
#
# `kern` is used as the probe because every text font has kerning pairs, whereas
# `smcp`/`onum`/`tnum` alternates are absent from most system fonts (so testing
# with those would silently pass on a font that ignores them).

KERN_FAM <- "Times New Roman"

skip_if_no_kerning <- function() {
  a <- textshaping::shape_text("AV", family = KERN_FAM, size = 40)$metrics$width
  b <- textshaping::shape_text(
    "AV",
    family = KERN_FAM,
    size = 40,
    features = systemfonts::font_feature(kern = 0)
  )$metrics$width
  skip_if(isTRUE(all.equal(a, b)), "no kerning available for the probe font")
}

test_that("features reach measurement", {
  skip_if_no_kerning()
  on <- vl_strwidth("AV", KERN_FAM, fontsize = 40)
  off <- vl_strwidth("AV", KERN_FAM, fontsize = 40, features = c(kern = 0))
  expect_gt(off, on)
})

test_that("features reach grob measurement through gpar", {
  skip_if_no_kerning()
  g <- function(...) {
    text_grob("AV", gp = vl_gpar(fontfamily = KERN_FAM, fontsize = 40, ...))
  }
  expect_false(identical(
    format(grobwidth(g())),
    format(grobwidth(g(features = c(kern = 0))))
  ))
})

test_that("features reach drawing", {
  skip_if_no_kerning()
  mk <- function(f) {
    vl_scene(3, 1, dpi = 150) |>
      draw(text_grob(
        "AV Wa To",
        gp = vl_gpar(fontfamily = KERN_FAM, fontsize = 30, features = f)
      ))
  }
  a <- withr::local_tempfile(fileext = ".png")
  b <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache()
  render(mk(NULL), a)
  vl_clear_render_cache()
  render(mk(c(kern = 0)), b)
  expect_false(identical(tools::md5sum(a)[[1]], tools::md5sum(b)[[1]]))
})

test_that("the shape cache is keyed on the feature set", {
  # Shaping the same string with and then without a feature, in that order,
  # must not return the first result the second time.
  skip_if_no_kerning()
  w1 <- vl_strwidth("AV", KERN_FAM, fontsize = 40)
  w2 <- vl_strwidth("AV", KERN_FAM, fontsize = 40, features = c(kern = 0))
  w3 <- vl_strwidth("AV", KERN_FAM, fontsize = 40)
  expect_equal(w1, w3)
  expect_false(isTRUE(all.equal(w1, w2)))
})

test_that("a systemfonts font_feature() object is accepted directly", {
  skip_if_no_kerning()
  a <- format(grobwidth(text_grob(
    "AV",
    gp = vl_gpar(
      fontfamily = KERN_FAM,
      fontsize = 40,
      features = c(kern = 0)
    )
  )))
  b <- format(grobwidth(text_grob(
    "AV",
    gp = vl_gpar(
      fontfamily = KERN_FAM,
      fontsize = 40,
      features = systemfonts::font_feature(kern = 0)
    )
  )))
  expect_identical(a, b)
})

test_that("no features leaves output unchanged", {
  mk <- function(f) {
    vl_scene(2, 1, dpi = 100) |>
      draw(text_grob("Text 123", gp = vl_gpar(fontsize = 14, features = f)))
  }
  a <- withr::local_tempfile(fileext = ".png")
  b <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache()
  render(mk(NULL), a)
  vl_clear_render_cache()
  render(mk(character(0)), b)
  expect_identical(tools::md5sum(a)[[1]], tools::md5sum(b)[[1]])
})

test_that("malformed feature specs are rejected", {
  expect_error(.gp_features(vl_gpar(features = c(1, 2))), "named")
  expect_error(
    .gp_features(vl_gpar(features = c(toolong = 1))),
    "four characters"
  )
  expect_error(.gp_features(vl_gpar(features = c(ab = 1))), "four characters")
})

test_that("features apply to rich md() labels too", {
  skip_if_no_kerning()
  mk <- function(f) {
    vl_scene(3, 1, dpi = 150) |>
      draw(text_grob(
        md("**AV** Wa"),
        gp = vl_gpar(fontfamily = KERN_FAM, fontsize = 30, features = f)
      ))
  }
  a <- withr::local_tempfile(fileext = ".png")
  b <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache()
  render(mk(NULL), a)
  vl_clear_render_cache()
  render(mk(c(kern = 0)), b)
  expect_false(identical(tools::md5sum(a)[[1]], tools::md5sum(b)[[1]]))
})
