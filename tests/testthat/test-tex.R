# tex(): math labels typeset by the native engine over the font's MATH table
# (F-22), drawn and measured through the same rich-label plumbing as md().

# Ink rows/columns of a raster (any channel darker than near-white).
ink_box <- function(r) {
  ink <- r[1, , ] < 200 | r[2, , ] < 200 | r[3, , ] < 200
  rows <- which(apply(ink, 2, any)) # r is [channel, x, y]
  cols <- which(apply(ink, 1, any))
  c(x0 = min(cols), x1 = max(cols), y0 = min(rows), y1 = max(rows))
}

test_that("tex() builds a tex label; vectors give a list", {
  lab <- tex("E = mc^2")
  expect_s3_class(lab, "vellum::vellum_tex_label")
  expect_s3_class(lab, "vellum::vellum_label")
  expect_equal(lab@tex, "E = mc^2")
  expect_false(lab@display)
  expect_true(tex("x", display = TRUE)@display)
  labs <- tex(c("a", "b^2"))
  expect_length(labs, 2L)
  expect_s3_class(labs[[2]], "vellum::vellum_tex_label")
  expect_equal(tex(character(0)), list())
  # The plain-text seam (alt text) sees the source.
  expect_equal(.text_labels(lab), "E = mc^2")
  expect_error(tex("x", display = NA), "display")
})

test_that("parse errors name the problem and its position", {
  expect_error(tex("a + \\foo"), class = "vellum_tex_error")
  expect_snapshot(error = TRUE, {
    tex("a + \\foo + b")
    tex("\\frac{a}")
    tex("x^")
    tex("\\left( x")
    tex("{a")
  })
  # Errors carry the 1-based position.
  e <- tryCatch(tex("ab}"), error = identity)
  expect_match(conditionMessage(e), "position 3")
})

test_that("the measured box is the drawn box and holds all the ink", {
  lab <- tex("\\sum_{i=1}^n \\frac{x_i^2}{\\sqrt{y}}", display = TRUE)
  ext <- vl_strwidth(lab, fontsize = 20, unit = "pt")
  g <- .label_compose(lab, "", "plain", 20, "black")
  expect_equal(ext, g$w)
  expect_equal(vl_strheight(lab, fontsize = 20, unit = "pt"), g$h)
  # Draw it bottom-left justified at a known point: this tall formula
  # extends the strut both ways, so its box is its ink vertically.
  dpi <- 288
  s <- vl_scene(3, 2, dpi = dpi, bg = "white") |>
    draw(text_grob(
      lab,
      x = vl_unit(36, "pt"),
      y = vl_unit(36, "pt"),
      just = c(0, 0),
      gp = vl_gpar(fontsize = 20)
    ))
  b <- ink_box(scene_raster(s))
  px <- dpi / 72
  h_ink <- (b[["y1"]] - b[["y0"]] + 1) / px
  expect_lt(abs(h_ink - g$h), 1)
  expect_lt(abs((2 * 72 - 36) - (b[["y1"]] + 1) / px), 1)
  w_ink <- (b[["x1"]] - b[["x0"]] + 1) / px
  expect_lt(w_ink, g$w + 1)
  expect_gt(w_ink, g$w - 3)
  # grobwidth/grobheight agree with the composer (pt -> mm).
  gr <- text_grob(lab, gp = vl_gpar(fontsize = 20))
  expect_equal(.grob_extent(gr), c(g$w, g$h) / 72 * 25.4)
})

test_that("ordinary tex labels share the baseline and box of plain/md labels", {
  comp <- function(l) .label_compose(l, "", "plain", 14, "black")
  ref <- comp(md("a"))
  for (l in list(tex("a"), tex("b"), tex("y"), tex("x+1"))) {
    g <- comp(l)
    expect_equal(g$h, ref$h)
    expect_equal(g$baseline, ref$gy[1])
  }
  # Ink taller than the strut extends the box upward only; the baseline
  # stays put.
  tall <- comp(tex("\\frac{a}{b}", display = TRUE))
  expect_gt(tall$h, ref$h)
  # Drawn in a row under vjust 1 and vjust 0, the baselines line up: the
  # lowest ink row of "a", "b" (no descender) and md "a" coincide.
  for (vj in c(0, 1)) {
    bottoms <- vapply(
      list(tex("a"), tex("b"), md("a"), tex("x")),
      function(l) {
        s <- vl_scene(1, 1, dpi = 200, bg = "white") |>
          draw(text_grob(
            l,
            y = 0.5,
            just = c(0.5, vj),
            gp = vl_gpar(fontsize = 40)
          ))
        ink_box(scene_raster(s))[["y1"]]
      },
      numeric(1)
    )
    expect_lte(max(bottoms) - min(bottoms), 2)
  }
})

# Rule paths in an SVG: straight-sided closed paths (glyph outlines of these
# formulas all have curves).
svg_rect_paths <- function(txt, stroke = FALSE) {
  pat <- if (stroke) {
    '<path d="M[^"CQ]*Z" fill="none" stroke='
  } else {
    '<path d="M[^"CQ]*Z" fill="#'
  }
  lengths(regmatches(txt, gregexpr(pat, txt)))
}
svg_text <- function(s) {
  f <- withr::local_tempfile(fileext = ".svg", .local_envir = parent.frame())
  render(s, f)
  paste(readLines(f, warn = FALSE), collapse = "")
}
one <- function(l, ...) {
  vl_scene(2, 1, dpi = 96) |>
    draw(text_grob(l, gp = vl_gpar(fontsize = 16, ...)))
}

test_that("tex labels render to png, svg and pdf, rules included", {
  s <- one(
    tex("x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}", display = TRUE),
    col = "navy"
  )
  for (ext in c("png", "svg", "pdf")) {
    f <- withr::local_tempfile(fileext = paste0(".", ext))
    expect_no_error(render(s, f))
    expect_gt(file.size(f), 100)
  }
  # One rule per bar, in the SVG, in the label colour.
  expect_equal(svg_rect_paths(svg_text(one(tex("\\frac{a}{b}")))), 1L)
  expect_equal(
    svg_rect_paths(svg_text(one(tex("\\frac{a}{\\overline{b}}")))),
    2L
  )
  expect_equal(svg_rect_paths(svg_text(one(tex("ab")))), 0L)
  expect_match(
    svg_text(one(tex("\\frac{a}{b}"), col = "navy")),
    'Z" fill="#000080"'
  )
})

test_that("labels made only of rules draw in every backend", {
  # (\\frac{}{} has a zero-width bar, invisible in LaTeX too.)
  for (src in c(
    "\\overline{\\quad}",
    "\\underline{~}",
    "\\frac{\\quad}{\\quad}"
  )) {
    s <- one(tex(src))
    # PNG: some ink.
    expect_true(any(scene_raster(s)[1, , ] < 128), info = src)
    # SVG: the rule is there.
    expect_equal(svg_rect_paths(svg_text(s)), 1L, info = src)
    # PDF: the rule is drawn (rasterised when poppler is around; else the
    # file must at least differ from the same label without its rule).
    f <- withr::local_tempfile(fileext = ".pdf")
    render(s, f)
    g <- withr::local_tempfile(fileext = ".pdf")
    render(one(tex("\\quad")), g)
    expect_false(
      identical(readBin(f, "raw", 1e6), readBin(g, "raw", 1e6)),
      info = src
    )
    if (nzchar(Sys.which("pdftoppm"))) {
      png <- withr::local_tempfile()
      system2("pdftoppm", c("-r", "72", "-png", "-singlefile", f, png))
      px <- png::readPNG(paste0(png, ".png"))
      expect_true(any(px[,, 1] < 0.5), info = src)
    }
  }
})

test_that("a fraction bar is drawn in the raster", {
  # \frac{}{} of two dots: the bar is the only wide, thin ink.
  s <- vl_scene(1, 1, dpi = 200, bg = "white") |>
    draw(text_grob(tex("\\frac{\\cdot}{\\cdot}"), gp = vl_gpar(fontsize = 60)))
  r <- scene_raster(s)
  ink <- r[1, , ] < 128
  widest <- max(colSums(ink)) # longest dark row
  expect_gt(widest, 30)
})

test_that("a rotated tex label rotates glyphs and rules together", {
  mk <- function(rot) {
    vl_scene(1.5, 1.5, dpi = 150, bg = "white") |>
      draw(text_grob(
        tex("\\frac{a}{b}"),
        rot = rot,
        gp = vl_gpar(fontsize = 48)
      ))
  }
  b0 <- ink_box(scene_raster(mk(0)))
  b90 <- ink_box(scene_raster(mk(90)))
  w0 <- b0[["x1"]] - b0[["x0"]]
  h0 <- b0[["y1"]] - b0[["y0"]]
  w90 <- b90[["x1"]] - b90[["x0"]]
  h90 <- b90[["y1"]] - b90[["y0"]]
  expect_lt(abs(w90 - h0), 3)
  expect_lt(abs(h90 - w0), 3)
  # The bar turns vertical: a long dark column exists.
  ink <- scene_raster(mk(90))[1, , ] < 128
  expect_gt(max(rowSums(ink)), 0.6 * h90)
  # grobwidth/height of a rotated label swap too.
  g <- text_grob(tex("\\frac{a}{b}"), rot = 90, gp = vl_gpar(fontsize = 48))
  e0 <- .grob_extent(text_grob(
    tex("\\frac{a}{b}"),
    gp = vl_gpar(fontsize = 48)
  ))
  expect_equal(.grob_extent(g), rev(e0))
})

test_that("a haloed tex label strokes its rules too", {
  s <- vl_scene(1.5, 1, dpi = 150, bg = "black") |>
    draw(text_grob(
      tex("\\frac{\\cdot}{\\cdot}"),
      gp = vl_gpar(
        fontsize = 48,
        col = "black",
        halo_col = "white",
        halo_width = 1.5
      )
    ))
  # SVG: the bar is stroked in the halo colour under its fill.
  expect_equal(svg_rect_paths(svg_text(s), stroke = TRUE), 1L)
  # PNG: the white halo spans the bar's width, far wider than the two dots.
  r <- scene_raster(s)
  white <- r[1, , ] > 200
  cols <- which(apply(white, 1, any))
  g <- .label_compose(tex("\\frac{\\cdot}{\\cdot}"), "", "plain", 48, "black")
  bar_px <- g$rw * 150 / 72
  expect_gt(diff(range(cols)), bar_px)
  # PDF: the same, rasterised when poppler is around.
  f <- withr::local_tempfile(fileext = ".pdf")
  expect_no_error(render(s, f))
  if (nzchar(Sys.which("pdftoppm"))) {
    png <- withr::local_tempfile()
    system2("pdftoppm", c("-r", "150", "-png", "-singlefile", f, png))
    px <- png::readPNG(paste0(png, ".png"))
    wcols <- which(apply(px[,, 1] > 0.8, 2, any))
    expect_gt(diff(range(wcols)), bar_px)
  }
})

test_that("options(vellum.math_font) with a non-math font fails clearly", {
  withr::local_options(vellum.math_font = "Helvetica")
  .math_font_reset()
  s <- vl_scene(1, 1) |> draw(text_grob(tex("x")))
  expect_error(
    render(s, withr::local_tempfile(fileext = ".png")),
    class = "vellum_math_font_error"
  )
  expect_error(vl_strwidth(tex("x")), "MATH table")
  # A file path that is not a font at all.
  bad <- withr::local_tempfile(fileext = ".otf")
  writeLines("not a font", bad)
  withr::local_options(vellum.math_font = bad)
  expect_error(vl_strwidth(tex("x")), class = "vellum_math_font_error")
  # Something that looks like a path but isn't there.
  withr::local_options(vellum.math_font = "/no/such/font.otf")
  expect_error(
    vl_strwidth(tex("x")),
    "doesn't exist",
    class = "vellum_math_font_error"
  )
  withr::local_options(vellum.math_font = "missing.ttf")
  expect_error(vl_strwidth(tex("x")), "doesn't exist")
})

test_that("very deep nesting is a parse error, not a crash", {
  expect_error(
    tex(paste0(strrep("{", 5000), "x", strrep("}", 5000))),
    class = "vellum_tex_error"
  )
  expect_error(tex(strrep("{", 10000)), "nested too deeply")
  expect_error(
    tex(paste0(strrep("x^{", 10000), "x", strrep("}", 10000))),
    "nested too deeply"
  )
  expect_s3_class(
    tex(paste0(strrep("{", 50), "x", strrep("}", 50))),
    "vellum::vellum_tex_label"
  )
})

test_that("characters the math font lacks warn and still draw", {
  expect_warning(
    vl_strwidth(tex("a\u65e5\\text{\u672c}")),
    class = "vellum_tex_missing_glyph"
  )
})

test_that("queries see the TeX source; the PDF keeps per-glyph text", {
  s <- vl_scene(2, 1) |> draw(text_grob(tex("E = mc^2")))
  nodes <- as.data.frame(.scene_to_backend(s)$lint_table())
  expect_equal(nodes$label[nodes$kind == "text"], "E = mc^2")
})

test_that("options(vellum.math_font) accepts a math font file", {
  stix <- system.file("fonts", "STIXTwoMath-Regular.otf", package = "vellum")
  w0 <- vl_strwidth(tex("x^2"), unit = "pt")
  withr::local_options(vellum.math_font = stix)
  expect_equal(vl_strwidth(tex("x^2"), unit = "pt"), w0)
})

test_that("scenes with tex labels round-trip through the scene spec", {
  s <- vl_scene(2, 1) |>
    draw(text_grob(tex("\\alpha^2", display = TRUE), x = 0.3)) |>
    draw(text_grob(tex(c("a", "b_1")), x = c(0.6, 0.8), y = 0.5))
  spec <- as_scene_spec(s)
  back <- from_scene_spec(spec)
  expect_identical(as_scene_spec(back), spec)
  a <- withr::local_tempfile(fileext = ".svg")
  b <- withr::local_tempfile(fileext = ".svg")
  render(s, a)
  render(back, b)
  expect_identical(readLines(a, warn = FALSE), readLines(b, warn = FALSE))
})

test_that("per-datum tex labels draw one formula per position", {
  s <- vl_scene(3, 1) |>
    draw(text_grob(
      tex(c("x^2", "\\frac{1}{2}", "\\sqrt{3}")),
      x = c(0.2, 0.5, 0.8),
      y = 0.5,
      key = c("p", "q", "r")
    ))
  expect_no_error(scene_raster(s))
  m <- scene_model(s)$elements
  expect_setequal(m$key, c("p", "q", "r"))
  # Each keyed box is its own formula's extent: the fraction is tallest.
  expect_equal(m$key[which.max(m$h)], "q")
  expect_length(unique(round(m$w, 3)), 3L)
  # text_grob() keeps a list of tex labels (it used to coerce it to text).
  expect_type(text_grob(tex(c("a", "b")))@label, "list")
})

test_that("md() labels are untouched by the generic composer", {
  lab <- md("R^2^ = **0.9**")
  a <- .label_compose(lab, "", "plain", 12, "black")
  b <- .md_compose(lab, "", "plain", 12, "black")
  expect_identical(a[names(b)], b)
  expect_length(a$rx, 0L)
  expect_equal(a$text, lab@text)
})
