# Inline `$...$` math in md() labels (F-31): each math run is typeset by the
# tex() engine and set on the run's baseline, inside the prose.

maths <- function(lab) {
  unlist(lapply(lab@runs, function(r) r$math))
}
texts <- function(lab) {
  vapply(Filter(function(r) is.null(r$math), lab@runs), function(r) r$text, "")
}

test_that("$...$ spans follow pandoc's tex_math_dollars rules", {
  expect_equal(maths(md("mass $m_e$ in **kg**")), "m_e")
  expect_equal(maths(md("$a$ and $b^2$")), c("a", "b^2"))
  # An opening $ needs a non-space after it; a closing one a non-space before
  # it and no letter or digit after it (stricter than pandoc, for currency).
  expect_null(maths(md("costs $5 to $10")))
  expect_null(maths(md("a $ b $ c")))
  expect_null(maths(md("from $x $ to")))
  expect_null(maths(md("$x$1")))
  expect_equal(maths(md("$x$, $y$.")), c("x", "y"))
  # \$ is a literal dollar, inside prose and next to math.
  lab <- md("price \\$3 and $p$")
  expect_equal(maths(lab), "p")
  expect_match(paste(texts(lab), collapse = ""), "price $3 and", fixed = TRUE)
  # $$ is not display math: it stays literal.
  lab <- md("a $$x$$ b")
  expect_null(maths(lab))
  expect_match(paste(texts(lab), collapse = ""), "$$x$$", fixed = TRUE)
  # An unclosed $ is a literal dollar.
  expect_null(maths(md("just $x")))
  # Currency in titles stays prose.
  expect_null(maths(md("Revenue ($M) vs cost ($K)")))
  expect_null(maths(md("**GDP** (US$bn) and (US$m)")))
  expect_null(maths(md("$x$y")))
  expect_equal(maths(md("($x$) and $y$!")), c("x", "y"))
})

test_that("markdown markup inside math is left to the math", {
  lab <- md("**bold** $x^2_{i}*y*$ and ~sub~")
  expect_equal(maths(lab), "x^2_{i}*y*")
})

test_that("a math run takes the surrounding style's colour and size", {
  lab <- md("plain [red $x$]{red}")
  runs <- Filter(function(r) !is.null(r$math), lab@runs)
  expect_equal(runs[[1]]$col, "red")
  g <- .label_compose(lab, "", "plain", 12, "black")
  expect_true("red" %in% g$cols)
  g2 <- .label_compose(md("plain $x$"), "", "plain", 12, "navy")
  expect_equal(unique(g2$cols), "navy")
})

test_that("bad math is a tex error with the position in the label", {
  expect_error(md("a $\\frac{x}$ b"), class = "vellum_tex_error")
  e <- tryCatch(md("ab $\\foo$"), error = identity)
  expect_match(conditionMessage(e), "position")
})

test_that("math-free labels compose exactly as before", {
  lab <- md("R^2^ = **0.9**\nsecond *line*")
  expect_null(maths(lab))
  g <- .label_compose(lab, "", "plain", 12, "black")
  expect_length(g$rx, 0L)
  expect_equal(g$gtext, "")
})

test_that("labels that share their plain text keep their own look", {
  pairs <- list(
    list(md("$x^2$ math"), md("\\$x^2\\$ math")),
    list(md("**bold**"), md("bold")),
    list(md("x"), tex("x"))
  )
  for (p in pairs) {
    expect_false(identical(.label_key(p[[1]]), .label_key(p[[2]])))
  }
  # Drawn side by side, each is composed on its own.
  px <- function(l) {
    s <- vl_scene(1, 0.5, dpi = 96, bg = "white") |>
      draw(text_grob(l, gp = vl_gpar(fontsize = 14)))
    scene_raster(s)
  }
  both <- vl_scene(2, 0.5, dpi = 96, bg = "white") |>
    draw(text_grob(
      list(md("**bold**"), md("bold")),
      x = c(0.25, 0.75),
      gp = vl_gpar(fontsize = 14)
    ))
  r <- scene_raster(both)
  left <- r[, 1:96, ]
  right <- r[, 97:192, ]
  expect_false(identical(left, right))
  expect_equal(left, px(md("**bold**")))
})

test_that("empty and NA md labels in a rich list draw nothing, no error", {
  s <- vl_scene(2, 1) |>
    draw(text_grob(list(md("a"), md(""), md(NA)), x = c(0.2, 0.5, 0.8)))
  expect_no_error(scene_raster(s))
})

test_that("an inline formula sits on the prose baseline", {
  lab <- md("x$x$")
  g <- .label_compose(lab, "", "plain", 20, "black")
  # Two glyphs: the text x and the math x, on one baseline.
  expect_length(g$gid, 2L)
  expect_equal(g$gy[1], g$gy[2], tolerance = 1e-6)
  # The math run is in the math font; the prose keeps the label's font.
  expect_false(identical(g$gpath[1], g$gpath[2]))
  # A plain md label of the prose alone has the same baseline and box.
  p <- .label_compose(md("x"), "", "plain", 20, "black")
  expect_equal(g$gy[1], p$gy[1], tolerance = 1e-6)
  expect_equal(g$h, p$h, tolerance = 1e-6)
})

test_that("tall math grows the line; the box holds the ink and rules", {
  short <- .label_compose(md("a $x$"), "", "plain", 20, "black")
  tall <- .label_compose(md("a $\\frac{1}{2}$"), "", "plain", 20, "black")
  expect_gt(tall$h, short$h)
  expect_length(tall$rx, 1L)
  expect_true(all(tall$ry >= 0 & tall$ry + tall$rh <= tall$h))
  # measure == draw
  lab <- md("ratio $\\frac{a}{b}$ and $\\sqrt{x}$")
  expect_equal(
    vl_strwidth(lab, fontsize = 20, unit = "pt"),
    .label_compose(lab, "", "plain", 20, "black")$w
  )
  expect_equal(
    vl_strheight(lab, fontsize = 20, unit = "pt"),
    .label_compose(lab, "", "plain", 20, "black")$h
  )
})

test_that("multi-line labels with math stack at least a leading apart", {
  one_line <- .label_compose(md("a $x$"), "", "plain", 10, "black")
  two <- .label_compose(md("a $x$\nb"), "", "plain", 10, "black")
  expect_equal(two$h - one_line$h, 12, tolerance = 1e-6)
  # A tall formula pushes the lines apart instead of overlapping them.
  tall <- .label_compose(
    md("top\n$\\displaystyle\\sum_{i=1}^n x_i$\nbottom"),
    "",
    "plain",
    10,
    "black"
  )
  expect_gt(tall$h, 3 * 12)
  expect_true(all(tall$gy >= 0))
})

test_that("tall lines keep TeX's lineskip apart: line boxes never meet", {
  h <- function(x) .label_compose(md(x), "", "plain", 10, "black")$h
  for (pair in list(
    c("$\\frac{1}{n}$", "$\\beta$"),
    c("$\\alpha_1$", "$\\sqrt[3]{x}$"),
    c("$\\displaystyle\\sum_{i=1}^n x_i$", "$\\frac{a}{b}$")
  )) {
    both <- h(paste(pair, collapse = "\n"))
    # Stacked boxes: never less than the two boxes plus the lineskip
    # (1pt at 10pt), and never less than a leading apart.
    expect_gte(both, h(pair[1]) + h(pair[2]) + 1 - 1e-6)
  }
})

test_that("multi-line md labels sit inside their box, plain or with math", {
  for (x in c("one\ntwo", "one\ntwo\nthree", "a~sub~ b", "a\n$x$")) {
    g <- .label_compose(md(x), "", "plain", 12, "black")
    expect_gte(min(g$gy), 0)
    expect_lte(max(g$gy), g$h)
    # The baseline is the first line's: inside the box, near its top.
    expect_gt(g$baseline, 0)
    expect_lt(g$baseline, g$h)
  }
  # Both composers agree on a shared first line.
  a <- .label_compose(md("a\nb"), "", "plain", 12, "black")
  b <- .label_compose(md("a\n$x$"), "", "plain", 12, "black")
  expect_equal(a$gy[1], b$gy[1], tolerance = 1e-9)
  expect_equal(a$h, b$h, tolerance = 1e-9)
  expect_equal(a$baseline, b$baseline, tolerance = 1e-9)
  # A one-line label's baseline is its glyphs' baseline.
  p <- .label_compose(md("a"), "", "plain", 12, "black")
  expect_equal(p$baseline, p$gy[1], tolerance = 1e-9)
})

test_that("a multi-line md label stays in its box under any vjust", {
  dpi <- 288
  ink_rows <- function(vj) {
    s <- vl_scene(3, 2, dpi = dpi, bg = "white") |>
      draw(text_grob(
        md("First\nSecond\nThird"),
        y = vl_unit(72, "pt"),
        just = c("centre", vj),
        gp = vl_gpar(fontsize = 20)
      ))
    r <- scene_raster(s)
    ink <- r[1, , ] < 200
    range(which(apply(ink, 2, any)))
  }
  px <- dpi / 72
  h <- vl_strheight(md("First\nSecond\nThird"), fontsize = 20, unit = "pt")
  # y = 72pt from the bottom: top-justified ink hangs below it, within h.
  top <- ink_rows("top")
  ytop <- 2 * dpi - 72 * px
  expect_gte(min(top), ytop - 1)
  expect_lte(max(top), ytop + h * px + 1)
  bottom <- ink_rows("bottom")
  expect_lte(max(bottom), ytop + 1)
  expect_gte(min(bottom), ytop - h * px - 1)
})

test_that("md labels with math render to png, svg and pdf", {
  s <- vl_scene(3, 1, dpi = 96) |>
    draw(text_grob(
      md("electron mass $m_e$ in **kg**, $\\frac{1}{2}mv^2$"),
      gp = vl_gpar(fontsize = 14)
    ))
  for (ext in c("png", "svg", "pdf")) {
    f <- withr::local_tempfile(fileext = paste0(".", ext))
    expect_no_error(render(s, f))
    expect_gt(file.size(f), 100)
  }
})

test_that("queries see the md source; PDF text has the prose and the math", {
  lab <- md("mass $m_e$ kg")
  s <- vl_scene(2, 1) |> draw(text_grob(lab))
  nodes <- as.data.frame(.scene_to_backend(s)$lint_table())
  expect_equal(nodes$label[nodes$kind == "text"], "mass $m_e$ kg")
  expect_equal(.text_labels(lab), "mass $m_e$ kg")
  g <- .label_compose(lab, "", "plain", 12, "black")
  expect_equal(nchar(g$gtext), length(g$gid))
  skip_if(unname(Sys.which("pdftotext")) == "", "pdftotext not available")
  f <- withr::local_tempfile(fileext = ".pdf")
  render(s, f)
  txt <- paste(
    system2("pdftotext", c(shQuote(f), "-"), stdout = TRUE),
    collapse = ""
  )
  expect_match(txt, "mass")
  expect_match(txt, "kg")
})

test_that("md labels with math round-trip through the scene spec", {
  s <- vl_scene(2, 1) |> draw(text_grob(md("a $x^2$ b")))
  spec <- as_scene_spec(s)
  back <- from_scene_spec(spec)
  expect_identical(as_scene_spec(back), spec)
})

test_that("plain strings in a rich list are drawn literally", {
  lits <- c("b*c*", "under_score_x_", "$x$ and $y$", "**not bold**", "a~b~")
  for (x in lits) {
    labs <- list(tex("\\alpha"), x)
    g <- text_grob(labs)
    expect_identical(g@label[[2]]@text, x)
    # Measured as the plain string, and drawn as it.
    expect_equal(
      vl_strwidth(labs, fontsize = 12, unit = "pt")[2],
      vl_strwidth(x, fontsize = 12, unit = "pt"),
      tolerance = 1e-6
    )
  }
  s <- vl_scene(2, 1) |>
    draw(text_grob(list(tex("a"), NA, "c"), x = c(.2, .5, .8)))
  expect_no_error(scene_raster(s))
})
