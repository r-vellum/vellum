# Phase 14: animated SVG, multi-page PDF, parallel batch rendering.

keyframes <- function(n = 3) {
  lapply(seq(0.12, 0.34, length.out = n), function(r) {
    vl_scene(3, 2, dpi = 96, bg = "white") |>
      draw(circle_grob(r = r, gp = vl_gpar(fill = "tomato", col = "grey20")))
  })
}
schedule <- function(k = 3, per = 8) {
  list(seg = rep(seq_len(k - 1), each = per),
       frac = rep(seq(0, 1, length.out = per), k - 1))
}

# --- animated SVG -------------------------------------------------------------

test_that("animated SVG emits one group per frame", {
  sc <- schedule()
  f <- withr::local_tempfile(fileext = ".svg")
  vl_render_animation(keyframes(), sc$seg, sc$frac, f, format = "svg", fps = 24)
  txt <- paste(readLines(f, warn = FALSE), collapse = "")
  expect_equal(lengths(regmatches(txt, gregexpr('class="vf"', txt, fixed = TRUE))),
               length(sc$seg))
})

test_that("the animated SVG is well-formed XML with the right page box", {
  skip_if_not_installed("xml2")
  sc <- schedule()
  f <- withr::local_tempfile(fileext = ".svg")
  vl_render_animation(keyframes(), sc$seg, sc$frac, f, format = "svg", fps = 24)
  x <- xml2::read_xml(f)
  expect_equal(xml2::xml_name(x), "svg")
  expect_equal(xml2::xml_attr(x, "viewBox"), "0 0 288 192") # 3x2in at 96dpi
  expect_length(xml2::xml_find_all(x, '//*[@class="vf"]'), length(sc$seg))
})

test_that("frames are staggered so exactly one is visible at a time", {
  skip_if_not_installed("xml2")
  sc <- schedule(per = 5)
  f <- withr::local_tempfile(fileext = ".svg")
  vl_render_animation(keyframes(), sc$seg, sc$frac, f, format = "svg", fps = 10)
  x <- xml2::read_xml(f)
  styles <- xml2::xml_attr(xml2::xml_find_all(x, '//*[@class="vf"]'), "style")
  delays <- as.numeric(sub(".*animation-delay:(-?[0-9.]+)s.*", "\\1", styles))
  n <- length(delays)
  # One cycle is n/fps seconds and the delays step evenly through it, negatively.
  expect_equal(delays[1], 0)
  expect_true(all(diff(delays) < 0))
  expect_equal(min(delays), -(n - 1) / 10, tolerance = 1e-6)
})

test_that("the animation carries accessibility text once, not per frame", {
  skip_if_not_installed("xml2")
  sc <- schedule()
  kf <- lapply(keyframes(), describe, title = "Growing circle",
               desc = "A circle that grows and shrinks.")
  f <- withr::local_tempfile(fileext = ".svg")
  vl_render_animation(kf, sc$seg, sc$frac, f, format = "svg", fps = 24)
  x <- xml2::read_xml(f)
  # Exactly one title/desc, at the document level -- repeating them per frame
  # would have a screen reader announce the figure once for every frame.
  expect_length(xml2::xml_find_all(x, "//*[local-name()='title']"), 1L)
  expect_length(xml2::xml_find_all(x, "//*[local-name()='desc']"), 1L)
})

test_that("reduced motion is honoured", {
  sc <- schedule()
  f <- withr::local_tempfile(fileext = ".svg")
  vl_render_animation(keyframes(), sc$seg, sc$frac, f, format = "svg", fps = 24)
  txt <- paste(readLines(f, warn = FALSE), collapse = "")
  expect_true(grepl("prefers-reduced-motion", txt, fixed = TRUE))
})

test_that("frame content actually differs between frames", {
  # Guards the whole thing against emitting the same frame N times.
  skip_if_not_installed("xml2")
  sc <- schedule(per = 6)
  f <- withr::local_tempfile(fileext = ".svg")
  vl_render_animation(keyframes(), sc$seg, sc$frac, f, format = "svg", fps = 12)
  x <- xml2::read_xml(f)
  bodies <- vapply(xml2::xml_find_all(x, '//*[@class="vf"]'), as.character, character(1))
  expect_gt(length(unique(bodies)), length(bodies) / 2)
})

test_that("an unknown animation format is rejected", {
  sc <- schedule()
  expect_error(
    vl_render_animation(keyframes(), sc$seg, sc$frac, tempfile(), format = "webm"),
    "should be one of"
  )
})

test_that("the raster animation formats still work", {
  sc <- schedule()
  for (fmt in c("gif", "apng")) {
    f <- withr::local_tempfile(fileext = paste0(".", fmt))
    vl_render_animation(keyframes(), sc$seg, sc$frac, f, format = fmt, fps = 24)
    expect_gt(file.size(f), 100)
  }
})

# --- multi-page PDF -----------------------------------------------------------

pages3 <- function() {
  lapply(c("tomato", "steelblue", "seagreen"), function(col) {
    vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(circle_grob(r = 0.3, gp = vl_gpar(fill = col)))
  })
}

test_that("pdf_pages writes one document with all the pages", {
  f <- withr::local_tempfile(fileext = ".pdf")
  pdf_pages(pages3(), f)
  pdf <- readBin(f, "raw", file.size(f))
  # /Count in the page tree is the page count.
  hit <- grepRaw("/Count 3", pdf, fixed = TRUE, all = FALSE)
  expect_gt(length(hit), 0L)
  # And it is bigger than any single page.
  expect_gt(file.size(f), length(scene_pdf(pages3()[[1]])))
})

test_that("pdf_pages returns bytes when given no path", {
  b <- pdf_pages(pages3())
  expect_true(is.raw(b))
  expect_equal(rawToChar(b[1:4]), "%PDF")
})

test_that("a one-page document matches a single-page render", {
  # The two go through the same page-drawing code, so a document cannot drift
  # from a plain `render()`.
  s <- pages3()[[1]]
  expect_identical(pdf_pages(list(s)), scene_pdf(s))
})

test_that("pages may differ in size", {
  mixed <- list(
    vl_scene(4, 3, dpi = 96, bg = "white") |> draw(circle_grob(r = 0.3)),
    vl_scene(3, 5, dpi = 96, bg = "white") |> draw(rect_grob(width = 0.5, height = 0.5))
  )
  f <- withr::local_tempfile(fileext = ".pdf")
  expect_no_error(pdf_pages(mixed, f))
  expect_gt(file.size(f), 100)
})

test_that("per-page tagging survives into a document", {
  marked <- lapply(1:2, function(i) {
    describe(
      vl_scene(3, 2, dpi = 96, bg = "white") |>
        draw(points_grob(0.5, 0.5, name = paste0("page ", i, " mark"), role = "img")),
      title = paste("Page", i), desc = paste("Page", i, "description.")
    )
  })
  f <- withr::local_tempfile(fileext = ".pdf")
  pdf_pages(marked, f)
  pdf <- readBin(f, "raw", file.size(f))
  expect_gt(length(grepRaw("StructTreeRoot", pdf, fixed = TRUE, all = FALSE)), 0L)
  expect_gt(length(grepRaw("page 1 mark", pdf, fixed = TRUE, all = FALSE)), 0L)
  expect_gt(length(grepRaw("page 2 mark", pdf, fixed = TRUE, all = FALSE)), 0L)
})

test_that("pdf_pages refuses an empty page list", {
  expect_error(pdf_pages(list()), "non-empty")
  expect_error(pdf_pages("not a list"), "non-empty")
})

# --- parallel batch rendering -------------------------------------------------

batch <- function(n) {
  stats::setNames(
    lapply(seq_len(n), function(i) {
      vl_scene(3, 2, dpi = 96, bg = "white") |>
        draw(circle_grob(r = 0.1 + i / (n * 4), gp = vl_gpar(fill = "steelblue")))
    }),
    paste0("fig", seq_len(n))
  )
}

test_that("render_all writes every file", {
  dir <- withr::local_tempdir()
  s <- batch(4)
  paths <- file.path(dir, paste0(names(s), ".png"))
  render_all(s, paths)
  expect_true(all(file.exists(paths)))
  expect_true(all(file.size(paths) > 100))
})

test_that("render_all output matches rendering one at a time", {
  # Parallelism must not change a pixel.
  dir <- withr::local_tempdir()
  s <- batch(3)
  par_paths <- file.path(dir, paste0("p", seq_along(s), ".png"))
  seq_paths <- file.path(dir, paste0("s", seq_along(s), ".png"))
  render_all(s, par_paths)
  render_all(s, seq_paths, workers = 1)
  for (i in seq_along(s)) {
    expect_identical(readBin(par_paths[i], "raw", file.size(par_paths[i])),
                     readBin(seq_paths[i], "raw", file.size(seq_paths[i])))
  }
})

test_that("a directory plus named scenes names the files", {
  dir <- withr::local_tempdir()
  render_all(batch(3), dir)
  expect_true(all(file.exists(file.path(dir, paste0("fig", 1:3, ".png")))))
})

test_that("a directory needs names", {
  dir <- withr::local_tempdir()
  expect_error(render_all(unname(batch(3)), dir), "must be named")
})

test_that("render_all validates its arguments", {
  expect_error(render_all(list(), "x.png"), "non-empty")
  expect_error(render_all(batch(3), c("a.png", "b.png")), "one entry per scene")
})

test_that("render_all passes arguments through to render", {
  dir <- withr::local_tempdir()
  s <- batch(2)
  big <- file.path(dir, paste0("b", 1:2, ".png"))
  small <- file.path(dir, paste0("s", 1:2, ".png"))
  render_all(s, big, scale = 2)
  render_all(s, small)
  expect_gt(file.size(big[1]), file.size(small[1]))
})

test_that("a single scene short-circuits the parallel machinery", {
  dir <- withr::local_tempdir()
  p <- file.path(dir, "one.png")
  render_all(batch(1), p)
  expect_true(file.exists(p))
})
