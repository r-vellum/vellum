# Rich-text labels via md(): a markdown subset (**bold**, *italic*, ^sup^, ~sub~,
# [text]{colour}) shaped into one multi-run label with per-glyph colour/size/baseline.

test_that("md() parses the markup subset into styled runs", {
  lab <- md("R^2^ = **0.91** and [hot]{#cc0000}")
  expect_s3_class(lab, "vellum::vellum_md_label")
  expect_equal(lab@text, "R2 = 0.91 and hot") # markup-stripped plain text
  runs <- lab@runs
  # superscript run is smaller and raised
  sup <- runs[[which(vapply(runs, `[[`, "", "text") == "2")]]
  expect_lt(sup$size, 1)
  expect_gt(sup$dy, 0)
  # bold run
  bold <- runs[[which(vapply(runs, `[[`, "", "text") == "0.91")]]
  expect_true(bold$bold)
  # coloured run
  hot <- runs[[which(vapply(runs, `[[`, "", "text") == "hot")]]
  expect_equal(hot$col, "#cc0000")
})

test_that("md() with no markup equals the plain string", {
  lab <- md("plain text")
  expect_equal(lab@text, "plain text")
  expect_length(lab@runs, 1L)
  expect_false(lab@runs[[1]]$bold)
})

test_that("a plain md() label rasterizes identically to plain character text", {
  mk <- function(label) {
    vl_scene(width = 2, height = 1, dpi = 100, bg = "white") |>
      draw(text_grob(label, x = 0.5, y = 0.5, gp = vl_gpar(fontsize = 40, col = "black")))
  }
  r_plain <- scene_raster(mk("ABC"))
  r_md <- scene_raster(mk(md("ABC")))
  expect_identical(r_md, r_plain) # rich path with one black run == fast path
})

test_that("a coloured span renders in its colour (raster)", {
  s <- vl_scene(1, 1, dpi = 200, bg = "white") |>
    draw(text_grob(md("[X]{#ff0000}"), x = 0.5, y = 0.5,
                   gp = vl_gpar(fontsize = 120, col = "black")))
  expect_equal(scene_len(s), 1L) # one batched node
  r <- scene_raster(s)
  # a strongly-red, low-green/blue pixel exists somewhere in the glyph
  red <- r[1, , ] > 200 & r[2, , ] < 80 & r[3, , ] < 80
  expect_true(any(red))
})

test_that("the base gp$col applies to non-span runs while a span keeps its colour", {
  s <- vl_scene(2, 1, dpi = 150, bg = "white") |>
    draw(text_grob(md("k [r]{#ff0000}"), x = 0.5, y = 0.5,
                   gp = vl_gpar(fontsize = 80, col = "#0000ff")))
  r <- scene_raster(s)
  has_blue <- any(r[3, , ] > 200 & r[1, , ] < 80 & r[2, , ] < 80) # base run blue
  has_red <- any(r[1, , ] > 200 & r[2, , ] < 80 & r[3, , ] < 80)  # span run red
  expect_true(has_blue)
  expect_true(has_red)
})

test_that("a superscript raises the rich-label height versus the base", {
  fs <- 30
  h_base <- .grob_extent(text_grob(md("a"), gp = vl_gpar(fontsize = fs)))[2]
  h_sup <- .grob_extent(text_grob(md("a^2^"), gp = vl_gpar(fontsize = fs)))[2]
  expect_gt(h_sup, h_base)
})

test_that("grobwidth/grobheight of a rich label are positive and finite", {
  ext <- .grob_extent(text_grob(md("R^2^ = **0.91**"), gp = vl_gpar(fontsize = 14)))
  expect_true(all(is.finite(ext)))
  expect_true(all(ext > 0))
})

test_that("rich labels render to SVG and PDF without error", {
  s <- vl_scene(3, 1, dpi = 100, bg = "white") |>
    draw(text_grob(md("a^2^ + **b** + [c]{#ff0000}"), x = 0.5, y = 0.5,
                   gp = vl_gpar(fontsize = 28, col = "black")))
  svg <- withr::local_tempfile(fileext = ".svg")
  pdf <- withr::local_tempfile(fileext = ".pdf")
  expect_no_error(render(s, svg))
  expect_no_error(render(s, pdf))
  expect_equal(rawToChar(readBin(pdf, "raw", 5)), "%PDF-")
  txt <- paste(readLines(svg, warn = FALSE), collapse = "\n")
  expect_match(txt, "#ff0000|#f00", ignore.case = TRUE) # span colour reaches SVG
})

test_that("vl_strwidth()/vl_strheight() measure an md() label", {
  # A rich label is measured through the same composition path it draws with, so
  # reserved layout space matches drawn glyphs (regression: legend/axis titles
  # built from md() used to measure as 0 and clip).
  lbl <- md("Power (hp m^2^)")
  w_pt <- .md_extent_pt(lbl, "", "plain", 11)[1]
  h_pt <- .md_extent_pt(lbl, "", "plain", 11)[2]
  expect_equal(vl_strwidth(lbl, "", "plain", 11, unit = "pt"), w_pt)
  expect_equal(vl_strwidth(lbl, "", "plain", 11, unit = "mm"), w_pt / 72 * 25.4)
  expect_gt(vl_strwidth(lbl, "", "plain", 11, unit = "mm"), 0)
  expect_equal(vl_strheight(lbl, "", "plain", 11, unit = "pt"), h_pt)
})

test_that("vl_strwidth() accepts a list of md() labels, one width each", {
  labs <- md(c("*a*", "**bbb**"))
  w <- vl_strwidth(labs, "", "plain", 11, unit = "mm")
  expect_length(w, 2L)
  expect_true(all(w > 0))
  expect_gt(w[2], w[1]) # bold "bbb" is wider than a single italic "a"
})

test_that("a plain md() label measures like the equivalent character string", {
  expect_equal(
    vl_strwidth(md("plain text"), "", "plain", 12, unit = "mm"),
    vl_strwidth("plain text", "", "plain", 12, unit = "mm"),
    tolerance = 1e-6
  )
})
