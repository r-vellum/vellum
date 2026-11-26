# Clips that cannot be represented (VR-42) and geometry far beyond the page
# (VR-43). Each scene draws red content; the child process reports how many
# clearly red pixels every backend puts on the page. The renders run in a child
# process (`run_vellum_child()`): VR-43 was a tiny-skia panic, and a regression
# in a panic path must fail the test rather than the test run.

# The child's helpers: red pixel counts per backend, `NA` where no rasteriser
# is installed.
red_counter <- c(
  "red <- function(a) sum(a[, , 1] > 0.8 & a[, , 2] < 0.3 & a[, , 3] < 0.3)",
  "count <- function(s) {",
  "  r <- scene_raster(s) / 255",
  "  png <- red(aperm(r[1:3, , , drop = FALSE], c(3L, 2L, 1L)))",
  "  svg <- NA",
  "  if (requireNamespace('rsvg', quietly = TRUE)) {",
  "    f <- tempfile(fileext = '.svg'); writeLines(scene_svg(s), f)",
  "    svg <- red(rsvg::rsvg(f))",
  "  }",
  "  pdf <- NA",
  "  if (requireNamespace('pdftools', quietly = TRUE)) {",
  "    f <- tempfile(fileext = '.pdf'); render(s, f)",
  "    pdf <- red(pdftools::pdf_render_page(f, dpi = 72, numeric = TRUE))",
  "  }",
  "  f <- tempfile(fileext = '.pptx'); render(s, f)",
  "  xml <- paste(readLines(unz(f, 'ppt/slides/slide1.xml'), warn = FALSE), collapse = '')",
  "  pptx <- grepl('FF0000', xml, fixed = TRUE)",
  "  cat(sprintf('%s %s %s %s\\n', png, svg, pdf, pptx))",
  "}",
  "fill <- vl_gpar(fill = 'red', col = NA)"
)

# Parse the child's "png svg pdf pptx" lines into a list of named vectors.
red_counts <- function(res) {
  lines <- grep("^[0-9NA]+ [0-9NA]+ [0-9NA]+ (TRUE|FALSE)$", trimws(res$output), value = TRUE)
  lapply(strsplit(lines, " "), function(v) {
    list(
      px = suppressWarnings(as.integer(v[1:3])) |> stats::setNames(c("png", "svg", "pdf")),
      pptx = as.logical(v[4])
    )
  })
}

test_that("a clip that cannot be represented clips everything away, on every backend (VR-42)", {
  res <- run_vellum_child(c(
    red_counter,
    "base <- vl_scene(2, 2, dpi = 72)",
    # a clip path with a missing vertex
    "count(base |> push(vl_viewport(clip = polygon_grob(c(0.2, 0.8, NA), c(0.2, 0.2, 0.8)))) |>",
    "  draw(rect_grob(gp = fill)))",
    # a clip path whose device box overflows once rotated
    "sq <- function(a) list(x = vl_unit(c(-a, a, a, -a), 'pt'), y = vl_unit(c(-a, -a, a, a), 'pt'))",
    "big <- sq(1.5e38)",
    "count(base |> push(vl_viewport(angle = 45, clip = polygon_grob(big$x, big$y))) |>",
    "  draw(rect_grob(width = 0.5, height = 0.5, gp = fill)))",
    # a clip rect whose device box overflows once rotated (PDF drew it unclipped)
    "count(base |> push(vl_viewport(width = vl_unit(3e38, 'pt'), height = vl_unit(3e38, 'pt'),",
    "  angle = 45, clip = TRUE)) |> draw(circle_grob(r = vl_unit(0.5, 'in'), gp = fill)))",
    # control: a huge but representable clip path keeps its content
    "huge <- sq(1e20)",
    "count(base |> push(vl_viewport(clip = polygon_grob(huge$x, huge$y))) |>",
    "  draw(rect_grob(width = 0.5, height = 0.5, gp = fill)))"
  ))
  expect_identical(res$status, 0L)
  counts <- red_counts(res)
  expect_length(counts, 4L)
  for (k in 1:3) {
    expect_true(all(counts[[k]]$px %in% c(0L, NA)), info = k)
    expect_false(counts[[k]]$pptx, info = k)
  }
  # the control draws its 72 x 72 px square (librsvg, whose fixed-point
  # coordinates cannot hold 1e20, renders nothing under such a clip, so SVG is
  # not checked)
  px <- counts[[4]]$px[c("png", "pdf")]
  expect_true(all(abs(px - 72L * 72L) < 300L | is.na(px)))
  expect_true(counts[[4]]$pptx)
})

test_that("the PDF backend draws nothing under an empty or non-finite clip (VR-42)", {
  # The same page as one with nothing drawn under the clip, byte for byte.
  res <- run_vellum_child(c(
    "bytes <- function(s) { f <- tempfile(fileext = '.pdf'); render(s, f); readBin(f, 'raw', file.size(f)) }",
    "vp <- vl_viewport(width = vl_unit(3e38, 'pt'), height = vl_unit(3e38, 'pt'), angle = 45, clip = TRUE)",
    "empty <- vl_scene(2, 2, dpi = 72) |> push(vp)",
    "drawn <- empty |> draw(circle_grob(r = vl_unit(0.5, 'in'), gp = vl_gpar(fill = 'red')))",
    "cat(identical(bytes(drawn), bytes(empty)), '\\n')"
  ))
  expect_identical(res$status, 0L)
  expect_identical(trimws(tail(res$output, 1)), "TRUE")
})

test_that("PNG draws shapes reaching far past the page without a panic (VR-43)", {
  res <- run_vellum_child(c(
    red_counter,
    "base <- vl_scene(2, 2, dpi = 72)",
    # 1e10 px: tiny-skia panicked from ~2e9 px; these now fill the page
    "count(base |> draw(circle_grob(r = vl_unit(1e10, 'pt'), gp = fill)))",
    "count(base |> draw(points_grob(0.5, 0.5, size = vl_unit(1e10, 'pt'), gp = fill)))",
    "count(base |> draw(rect_grob(width = vl_unit(1e10, 'pt'), height = vl_unit(1e10, 'pt'), gp = fill)))",
    # a far stroke across the page (and the same stroke ending just off it),
    # and a far shape with an edge on the page
    "count(base |> draw(segments_grob(vl_unit(-1e12, 'pt'), 0.5, vl_unit(1e12, 'pt'), 0.5,",
    "  gp = vl_gpar(col = 'red', lwd = 8))))",
    "count(base |> draw(segments_grob(vl_unit(-10, 'pt'), 0.5, vl_unit(154, 'pt'), 0.5,",
    "  gp = vl_gpar(col = 'red', lwd = 8))))",
    "count(base |> draw(polygon_grob(vl_unit(c(-1e12, 72, 72, -1e12), 'pt'),",
    "  vl_unit(c(-1e12, -1e12, 1e12, 1e12), 'pt'), gp = fill)))",
    # beyond the PDF coordinate cap (1e15 px): skipped, as PDF skips it
    "count(base |> draw(circle_grob(r = vl_unit(1e37, 'pt'), gp = fill)))",
    "count(base |> draw(points_grob(0.5, 0.5, size = vl_unit(1e37, 'pt'), gp = fill)))",
    # a clip region that far out still clips (to the page) rather than panics
    "count(base |> push(vl_viewport(width = vl_unit(1e12, 'pt'), clip = TRUE)) |>",
    "  draw(circle_grob(r = vl_unit(0.5, 'in'), gp = fill)))"
  ))
  expect_identical(res$status, 0L)
  counts <- red_counts(res)
  expect_length(counts, 9L)
  page <- 144L * 144L
  png <- vapply(counts, function(k) k$px[["png"]], integer(1))
  expect_identical(png[1:3], rep(page, 3L))
  # the far stroke draws what the near one does
  expect_gt(png[5], 0L)
  expect_identical(png[4], png[5])
  # the polygon's right edge is on the page, half way across
  expect_identical(png[6], 72L * 144L)
  expect_identical(png[7:8], c(0L, 0L))
  expect_gt(png[9], 0L)
  # (Not compared with SVG or PDF: librsvg and poppler, the rasterisers at
  # hand, themselves draw nothing at such coordinates.)
})
