# Multi-line (\n) text and vectorised / multi-line md() labels. Single-line output
# is byte-identical (covered by the existing text snapshot tests); here we check
# the new stacking + vectorisation and that renders don't error.

test_that(".compose_plain: single-line delegates unchanged, multi-line stacks", {
  fam <- ""; it <- FALSE; wt <- "normal"; sz <- 12
  one <- .compose_plain("hello", fam, it, wt, sz)
  ref <- .shape_cached("hello", fam, it, wt, sz)[[1]]
  expect_equal(one$w, ref$w) # single line == plain cached entry
  expect_equal(one$h, ref$h)
  expect_equal(one$n, ref$n)

  hi <- .compose_plain("hi", fam, it, wt, sz)
  two <- .compose_plain("hello\nhi", fam, it, wt, sz)
  expect_gt(two$h, one$h) # two lines are taller
  expect_equal(two$w, max(one$w, hi$w)) # width is the widest line
  expect_equal(two$n, one$n + hi$n) # glyphs are the sum of both lines
})

test_that("md() is vectorised and handles embedded newlines", {
  expect_true(S7::S7_inherits(md("*a*"), vellum_md_label))
  v <- md(c("*a*", "**b**"))
  expect_type(v, "list")
  expect_length(v, 2L)
  expect_true(all(vapply(v, function(x) S7::S7_inherits(x, vellum_md_label), logical(1))))

  h1 <- .md_extent_pt(md("ab"), "", "plain", 12)[2]
  h2 <- .md_extent_pt(md("ab\ncd"), "", "plain", 12)[2]
  expect_gt(h2, h1) # a newline adds a line -> taller
})

test_that("multi-line plain and per-datum rich labels render without error", {
  s <- vl_scene(3, 2, bg = "white") |>
    draw(text_grob("a\nb\nc", 0.5, 0.6)) |>
    draw(text_grob(md(c("*x*", "**y**")), c(0.3, 0.7), 0.3))
  f <- withr::local_tempfile(fileext = ".png")
  expect_no_error(render(s, f))
})
