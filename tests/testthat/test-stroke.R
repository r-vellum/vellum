# Stroke fidelity (P2): lty (dashing), lineend, linejoin, linemitre.

px <- function(scene, x, y) .scene_to_backend(scene)$pixel(x, y)

hline <- function(gp) {
  vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(lines_grob(unit(c(0.02, 0.98), "npc"), unit(c(0.5, 0.5), "npc"), gp = gp))
}
# count dark vs white pixels along the mid-row of a 200px-wide page
dark <- function(s) sum(vapply(2:198, function(x) px(s, x, 50)[1] < 128L, logical(1)))
white <- function(s) sum(vapply(2:198, function(x) px(s, x, 50)[1] >= 250L, logical(1)))

test_that("a dashed line leaves gaps a solid line does not", {
  d <- hline(gpar(col = "black", lwd = 3, lty = "dashed"))
  s <- hline(gpar(col = "black", lwd = 3, lty = "solid"))
  expect_gt(dark(d), 0L)
  expect_gt(white(d), 0L) # gaps present
  expect_gt(dark(s), dark(d)) # solid covers more
  expect_lt(white(s), 5L) # solid has ~no gaps
})

test_that("dotted and dashed produce different coverage", {
  expect_false(identical(dark(hline(gpar(col = "black", lwd = 3, lty = "dotted"))),
                         dark(hline(gpar(col = "black", lwd = 3, lty = "dashed")))))
})

test_that("lty accepts names, integer codes, hex strings, and numeric vectors", {
  for (lt in list("dashed", 2L, "44", c(4, 4))) {
    s <- hline(gpar(col = "black", lwd = 3, lty = lt))
    expect_gt(white(s), 0L)
  }
  # solid forms have no gaps
  for (lt in list("solid", 1L)) {
    expect_lt(white(hline(gpar(col = "black", lwd = 3, lty = lt))), 5L)
  }
})

test_that("lty inherits from the enclosing viewport", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    push(viewport(gp = gpar(lty = "dashed"))) |>
    draw(lines_grob(unit(c(0.02, 0.98), "npc"), unit(c(0.5, 0.5), "npc"), gp = gpar(col = "black", lwd = 3))) |>
    pop()
  expect_gt(white(s), 0L)
})

test_that("dash length scales with line width", {
  # wider line -> longer dashes/gaps -> fewer, longer 'off' runs but still gaps
  thin <- hline(gpar(col = "black", lwd = 1, lty = "dashed"))
  thick <- hline(gpar(col = "black", lwd = 6, lty = "dashed"))
  expect_gt(white(thin), 0L)
  expect_gt(white(thick), 0L)
})

test_that("SVG emits dasharray, linecap, linejoin, and miterlimit", {
  f <- withr::local_tempfile(fileext = ".svg")
  s <- vl_scene(2, 1, dpi = 100) |>
    draw(lines_grob(unit(c(0, 1), "npc"), unit(c(0.5, 0.5), "npc"),
                    gp = gpar(col = "black", lwd = 3, lty = "dashed", lineend = "butt", linejoin = "bevel")))
  render(s, f)
  svg <- paste(readLines(f, warn = FALSE), collapse = "\n")
  expect_match(svg, "stroke-dasharray=")
  expect_match(svg, 'stroke-linecap="butt"')
  expect_match(svg, 'stroke-linejoin="bevel"')
  expect_match(svg, "stroke-miterlimit=")
})

test_that("default line cap/join are round (grid convention)", {
  f <- withr::local_tempfile(fileext = ".svg")
  render(vl_scene(2, 1, dpi = 100) |>
           draw(lines_grob(unit(c(0, 1), "npc"), unit(c(0.5, 0.5), "npc"), gp = gpar(col = "black", lwd = 3))), f)
  svg <- paste(readLines(f, warn = FALSE), collapse = "\n")
  expect_match(svg, 'stroke-linecap="round"')
  expect_match(svg, 'stroke-linejoin="round"')
})

test_that("PDF renders dashed strokes without error", {
  f <- withr::local_tempfile(fileext = ".pdf")
  s <- vl_scene(2, 1, dpi = 100) |>
    draw(lines_grob(unit(c(0, 1), "npc"), unit(c(0.5, 0.5), "npc"), gp = gpar(col = "black", lwd = 3, lty = "dotdash")))
  expect_no_error(render(s, f))
  expect_equal(rawToChar(readBin(f, "raw", 5)), "%PDF-")
})

test_that("invalid lty is rejected (at compile time)", {
  expect_error(.scene_to_backend(hline(gpar(col = "black", lty = "zzz"))), "lty")
})
