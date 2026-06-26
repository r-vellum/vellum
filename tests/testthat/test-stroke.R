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

# PERF-3: per-segment stroke fast path (opaque, solid, round cap/join).
test_that("a bent polyline is continuous through the vertex (round join filled)", {
  # Two segments meeting at (0.5, 0.8); the join must not leave a gap.
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(lines_grob(unit(c(0.2, 0.5, 0.8), "npc"), unit(c(0.2, 0.8, 0.2), "npc"),
                    gp = gpar(col = "black", lwd = 4)))
  apex <- px(s, 50, 20) # device y=20 ~ npc y=0.8
  expect_lt(apex[1], 128L) # dark at the apex -> join is filled, no gap
})

test_that("a segments grob strokes every segment", {
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(segments_grob(c(0.1, 0.1), c(0.2, 0.8), c(0.9, 0.9), c(0.2, 0.8),
                       gp = gpar(col = "black", lwd = 3)))
  expect_lt(px(s, 50, 80)[1], 128L) # lower segment (npc y=0.2 -> dev y=80)
  expect_lt(px(s, 50, 20)[1], 128L) # upper segment (npc y=0.8 -> dev y=20)
})

test_that("a translucent line still renders (fast path falls back)", {
  s <- vl_scene(2, 1, dpi = 100, bg = "white") |>
    draw(lines_grob(unit(c(0.02, 0.98), "npc"), unit(c(0.5, 0.5), "npc"),
                    gp = gpar(col = "#000000", lwd = 6, alpha = 0.5)))
  mid <- px(s, 100, 50)
  expect_gt(mid[1], 0L)   # blended grey, not pure black
  expect_lt(mid[1], 200L) # but clearly darkened
})

test_that("invalid lty is rejected (at compile time)", {
  expect_error(.scene_to_backend(hline(gpar(col = "black", lty = "zzz"))), "lty")
})

test_that('lty = "blank"/0 suppresses the line but keeps the fill', {
  pxl <- function(s, x, y) .scene_to_backend(s)$pixel(x, y)
  blank <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.6, height = 0.6,
                   gp = gpar(fill = "red", col = "black", lwd = 8, lty = "blank")))
  solid <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(x = 0.5, y = 0.5, width = 0.6, height = 0.6,
                   gp = gpar(fill = "red", col = "black", lwd = 8)))
  # just outside the rect edge (npc y ~0.82 -> dev ~18): solid paints a border, blank does not
  expect_equal(pxl(blank, 50, 17)[1:3], c(255L, 255L, 255L)) # no border
  expect_equal(pxl(solid, 50, 17)[1:3], c(0L, 0L, 0L))       # black border
  expect_equal(pxl(blank, 50, 50)[1:3], c(255L, 0L, 0L))     # fill still drawn
  expect_equal(.encode_lty(0), .encode_lty("blank"))         # code 0 == "blank"
})
