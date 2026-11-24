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
  # it and no digit after it.
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
  expect_equal(g$baseline, 0)
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
