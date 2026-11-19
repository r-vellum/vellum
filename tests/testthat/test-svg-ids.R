# SVG ids are deterministic (VP-24): the same scene gives byte-identical SVG on
# every render, while different scenes on one HTML page get distinct ids.

ids_scene <- function(fill = "red", title = "Clipped") {
  vl_scene(2, 2, bg = "white", title = title, desc = "A clipped gradient.") |>
    push(vl_viewport(width = 0.5, height = 0.5, clip = TRUE)) |>
    draw(rect_grob(
      gp = vl_gpar(fill = linear_gradient(c(fill, "blue")))
    )) |>
    draw(points_grob(c(0.2, 0.8), 0.5, gp = vl_gpar(fill = fill))) |>
    pop()
}

svg_ids <- function(svg) {
  regmatches(svg, gregexpr(' id="[^"]*"', svg))[[1]]
}

test_that("two renders of the same scene give identical SVG", {
  s <- ids_scene()
  expect_identical(scene_svg(s), scene_svg(s))
  # also with the render cache off (a fresh compile each time)
  withr::local_options(vellum.cache = FALSE)
  expect_identical(scene_svg(s), scene_svg(s))
})

test_that("building the same scene twice gives identical SVG", {
  # ids used to come from a session counter stamped at construction
  # (vl2-d vs vl208-d), so identical scenes rendered differently
  a <- scene_svg(ids_scene())
  invisible(lapply(1:5, function(i) vl_scene(1, 1)))
  b <- scene_svg(ids_scene())
  expect_identical(a, b)
  f1 <- withr::local_tempfile(fileext = ".svg")
  f2 <- withr::local_tempfile(fileext = ".svg")
  render(ids_scene(), f1)
  render(ids_scene(), f2)
  expect_identical(readLines(f1), readLines(f2))
})

test_that("every id shares one per-document prefix, distinct across scenes", {
  a <- scene_svg(ids_scene())
  b <- scene_svg(ids_scene(fill = "green"))
  ia <- svg_ids(a)
  ib <- svg_ids(b)
  # title, desc, clipPath and gradient ids all carry the document prefix
  pa <- unique(sub(' id="(vl[0-9a-f]{8})-.*', "\\1", ia))
  pb <- unique(sub(' id="(vl[0-9a-f]{8})-.*', "\\1", ib))
  expect_length(pa, 1L)
  expect_length(pb, 1L)
  expect_match(pa, "^vl[0-9a-f]{8}$")
  expect_true(pa != pb)
  expect_true(any(grepl("-c0\"", ia, fixed = TRUE)))
  expect_true(any(grepl("-t\"", ia, fixed = TRUE)))
  # no id is shared by the two documents, so both can sit on one page
  expect_length(intersect(ia, ib), 0L)
  # every reference resolves to an id in its own document
  refs <- regmatches(a, gregexpr("url\\(#[^)]*\\)", a))[[1]]
  refs <- unique(sub("^url\\(#(.*)\\)$", "\\1", refs))
  expect_gt(length(refs), 0L)
  expect_true(all(paste0(' id="', refs, '"') %in% ia))
  lab <- strsplit(sub('.*aria-labelledby="([^"]*)".*', "\\1", a), " ")[[1]]
  expect_true(all(paste0(' id="', lab, '"') %in% ia))
  # no stray placeholder survives
  expect_false(grepl("\001|\\\\0", a))
})

test_that("an explicit a11y_prefix names every id", {
  s <- S7::set_props(ids_scene(), a11y_prefix = "fig1")
  svg <- scene_svg(s)
  ids <- svg_ids(svg)
  expect_true(all(startsWith(ids, ' id="fig1-')))
  expect_match(svg, 'aria-labelledby="fig1-t fig1-d"', fixed = TRUE)
})
