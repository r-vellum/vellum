# plotmath() and tex(<language>): R's plotmath notation translated to TeX
# (F-31). Each construct must lay out exactly as the equivalent TeX does.

lay <- function(lab) {
  g <- .label_compose(lab, "", "plain", 12, "black")
  g[c("gid", "gx", "gy", "gsize", "w", "h", "rx", "ry", "rw", "rh")]
}

# Every documented construct, with the TeX it should look like.
pm_cases <- list(
  c("x[i]", "x_i"),
  c("x^2", "x^2"),
  c("x[i]^2", "x_i^2"),
  c("x[i, j]", "x_{i,j}"),
  c("x + y - z", "x+y-z"),
  c("x / y", "x/y"),
  c("-x", "-x"),
  c("x %+-% y", "x \\pm y"),
  c("x %/% y", "x \\div y"),
  c("x %*% y", "x \\times y"),
  c("x %.% y", "x \\cdot y"),
  c("x %~~% y", "x \\approx y"),
  c("x %=~% y", "x \\cong y"),
  c("x %==% y", "x \\equiv y"),
  c("x %prop% y", "x \\propto y"),
  c("x %~% y", "x \\sim y"),
  c("x %<->% y", "x \\leftrightarrow y"),
  c("x %->% y", "x \\to y"),
  c("x %<-% y", "x \\leftarrow y"),
  c("x %up% y", "x \\uparrow y"),
  c("x %down% y", "x \\downarrow y"),
  c("x %<=>% y", "x \\Leftrightarrow y"),
  c("x %=>% y", "x \\Rightarrow y"),
  c("x %<=% y", "x \\Leftarrow y"),
  c("x %dblup% y", "x ⇑ y"),
  c("x %dbldown% y", "x ⇓ y"),
  c("A %subset% B", "A \\subset B"),
  c("A %subseteq% B", "A \\subseteq B"),
  c("A %supset% B", "A \\supset B"),
  c("A %supseteq% B", "A \\supseteq B"),
  c("A %notsubset% B", "A ⊄ B"),
  c("x %in% A", "x \\in A"),
  c("x %notin% A", "x \\notin A"),
  c("x == y", "x = y"),
  c("x != y", "x \\ne y"),
  c("x < y", "x < y"),
  c("x > y", "x > y"),
  c("x <= y", "x \\le y"),
  c("x >= y", "x \\ge y"),
  c("!x", "\\neg x"),
  c("x * y", "xy"),
  c("x ~ y", "x\\ y"),
  c("paste(x, y, z)", "xyz"),
  c("list(a, b, c)", "a, b, c"),
  c("sqrt(x)", "\\sqrt{x}"),
  c("sqrt(x, 3)", "\\sqrt[3]{x}"),
  c("frac(a, b)", "\\frac{a}{b}"),
  c("over(a, b)", "\\frac{a}{b}"),
  c("atop(n, k)", "{n \\atop k}"),
  c("hat(x)", "\\hat{x}"),
  c("bar(x)", "\\bar{x}"),
  c("bar(xy)", "\\overline{xy}"),
  c("tilde(x)", "\\tilde{x}"),
  c("dot(x)", "\\dot{x}"),
  c("ring(A)", "\\mathring{A}"),
  c("widehat(xy)", "\\widehat{xy}"),
  c("widetilde(xy)", "\\widetilde{xy}"),
  c("underline(x)", "\\underline{x}"),
  c("alpha + omega", "\\alpha + \\omega"),
  c("Gamma + Omega", "\\Gamma + \\Omega"),
  c("Alpha + Beta", "\\mathrm{A} + \\mathrm{B}"),
  c("theta1 + phi1 + sigma1", "\\vartheta + \\varphi + \\varsigma"),
  c("infinity", "\\infty"),
  c("partialdiff * f", "\\partial f"),
  c("nabla * f", "\\nabla f"),
  c("32 * degree", "32^\\circ"),
  c("60 * minute", "60'"),
  c("30 * second", "30''"),
  c("x[1] * cdots * x[n]", "x_1 \\cdots x_n"),
  c("x[1] * ldots * x[n]", "x_1 \\ldots x_n"),
  c("x[1] * ... * x[n]", "x_1 \\ldots x_n"),
  c("sum(x[i], i == 1, n)", "\\sum\\limits_{i=1}^n x_i"),
  c("prod(x[i], i)", "\\prod\\limits_i x_i"),
  c("integral(f(x) * dx, a, b)", "\\int\\limits_a^b f(x)dx"),
  c("union(A[i], i == 1, n)", "\\bigcup\\limits_{i=1}^n A_i"),
  c("intersect(A[i], i == 1, n)", "\\bigcap\\limits_{i=1}^n A_i"),
  c("lim(f(x), x %->% 0)", "\\lim\\limits_{x \\to 0} f(x)"),
  c("min(g(x), x > 0)", "\\min\\limits_{x>0} g(x)"),
  c("max(x)", "\\max x"),
  c("inf(S)", "\\inf S"),
  c("sup(S)", "\\sup S"),
  c("group('(', list(a, b), ']')", "(a, b]"),
  c("group(lceil, x, rceil)", "\\lceil x \\rceil"),
  c("bgroup('(', frac(a, b), ')')", "\\left( \\frac{a}{b} \\right)"),
  c("bgroup('{', x, '.')", "\\left\\{ x \\right."),
  c("italic(x) + bold(x)", "\\mathit{x} + \\mathbf{x}"),
  c("plain(x) + bolditalic(x)", "\\mathrm{x} + \\mathbfit{x}"),
  c("bold('kg')", "\\textbf{kg}"),
  c("italic('kg')", "\\textit{kg}"),
  c("bolditalic('kg')", "\\textbfit{kg}"),
  c("displaystyle(sum(x[i], i, n))", "\\displaystyle\\sum\\limits_i^n x_i"),
  c("textstyle(frac(1, 2))", "\\textstyle\\frac12"),
  c("scriptstyle(x)", "\\scriptstyle x"),
  c("scriptscriptstyle(x)", "\\scriptscriptstyle x"),
  c("x + phantom(0) + y", "x + \\phantom{0} + y"),
  c("'mass' == 3.5", "\\text{mass} = 3.5"),
  c("(x + y)^2", "{(x+y)}^2"),
  c("x^{y + z}", "x^{y+z}"),
  c("log(x) + f(x, y)", "\\log(x) + f(x, y)"),
  c("plain(P)(X == x)", "\\mathrm{P}(X = x)"),
  c("hat(beta)[1] == 0.42", "\\hat\\beta_1 = 0.42")
)

test_that("each plotmath construct lays out as its TeX equivalent", {
  for (case in pm_cases) {
    expect_equal(
      lay(plotmath(case[[1]])),
      lay(tex(case[[2]])),
      label = case[[1]]
    )
  }
})

test_that("tex() accepts calls, symbols, bquote() and expressions", {
  expect_equal(tex(quote(x[i]^2))@tex, plotmath("x[i]^2")@tex)
  expect_equal(tex(quote(alpha))@tex, "\\alpha")
  k <- 3
  expect_equal(tex(bquote(x^.(k)))@tex, "x^{3}")
  labs <- tex(expression(alpha, beta + 1))
  expect_length(labs, 2L)
  expect_equal(labs[[2]]@tex, "\\beta + 1")
  expect_s3_class(tex(expression(x)), "vellum::vellum_tex_label")
  expect_true(tex(quote(x), display = TRUE)@display)
})

test_that("plotmath() is vectorised like tex(); the source is the TeX", {
  labs <- plotmath(c("a", "b[1]"))
  expect_length(labs, 2L)
  expect_equal(labs[[2]]@text, "b_{1}")
  expect_equal(plotmath(character(0)), list())
  expect_equal(plotmath("")@tex, "")
  expect_equal(plotmath(NA)@tex, "")
  # The first expression of a string is used, as in ggplot2.
  expect_equal(plotmath("a; b")@tex, "a")
})

test_that("unsupported plotmath is an error", {
  expect_error(plotmath("symbol('a')"), class = "vellum_plotmath_error")
  expect_error(plotmath("x <- 1"), class = "vellum_plotmath_error")
  expect_error(plotmath("if (a) b"), class = "vellum_plotmath_error")
  expect_error(plotmath("group('<<', x, ')')"), class = "vellum_plotmath_error")
  expect_error(plotmath("x +"), class = "vellum_plotmath_error")
  expect_error(tex(quote(a$b)), class = "vellum_plotmath_error")
})
