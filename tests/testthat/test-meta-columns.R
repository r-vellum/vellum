# Columnar element meta (VR-19): a grob's `meta` may be a data frame, and
# `scene_model(meta = "columns")` hands meta on as one column per field.

meta_scene <- function(m, swatch = TRUE) {
  sc <- vl_scene(2, 2, dpi = 72) |>
    draw(rect_grob(0.5, 0.5, 0.9, 0.9)) |>
    draw(points_grob(
      c(0.2, 0.4, 0.6, 0.8),
      0.5,
      key = c("p", "q", "r", "s"),
      meta = m
    ))
  if (swatch) {
    sc <- sc |>
      draw(points_grob(
        0.1,
        0.1,
        key = "sw",
        meta = list(list(legend_for = "color:x", tooltip = "swatch"))
      ))
  }
  sc
}

fct <- function(x) factor(x, levels = c("u", "w"))

mixed_records <- function() {
  list(
    list(tooltip = "a", legend = "color:x", v = 1, f = fct("u")),
    list(
      tooltip = "b",
      legend = c("color:y", "shape:z"),
      v = 2,
      f = fct("w")
    ),
    list(tooltip = NA_character_, v = 3, f = fct("u")),
    list(tooltip = "d", legend = character(0), v = 4, f = fct("w"))
  )
}

mixed_df <- function() {
  df <- data.frame(tooltip = c("a", "b", NA, "d"))
  df$legend <- list("color:x", c("color:y", "shape:z"), NULL, character(0))
  df$v <- c(1, 2, 3, 4)
  df$f <- factor(c("u", "w", "u", "w"))
  df
}

test_that("a data-frame meta gives the same records as the list form", {
  a <- scene_model(meta_scene(mixed_records()))$elements$meta
  b <- scene_model(meta_scene(mixed_df()))$elements$meta
  expect_identical(b, a)
  # the NULL list-column entry leaves `legend` out of the third record
  expect_named(b[[4]], c("tooltip", "v", "f"))
  expect_null(b[[1]]) # the unkeyed background rect
})

test_that("scene_model(meta = 'columns') gives one column per field", {
  m <- scene_model(meta_scene(mixed_df()), meta = "columns")
  el <- m$elements
  expect_s3_class(el$meta, "data.frame")
  expect_identical(nrow(el$meta), nrow(el))
  expect_named(el$meta, c("tooltip", "legend", "v", "f", "legend_for"))
  expect_identical(el$meta$tooltip, c(NA, "a", "b", NA, "d", "swatch"))
  expect_identical(el$meta$v, c(NA, 1, 2, 3, 4, NA))
  expect_identical(el$meta$f, c(NA, "u", "w", "u", "w", NA))
  expect_identical(el$meta$legend_for, c(rep(NA, 5), "color:x"))
  expect_type(el$meta$legend, "list")
  expect_identical(el$meta$legend[[3]], c("color:y", "shape:z"))
  expect_null(el$meta$legend[[4]])
  # rows subset with the table
  sub <- el[el$key %in% "q" & !is.na(el$key), ]
  expect_identical(sub$meta$legend[[1]], c("color:y", "shape:z"))
})

test_that("records and columns give the same columns", {
  a <- scene_model(meta_scene(mixed_records()), meta = "columns")$elements$meta
  b <- scene_model(meta_scene(mixed_df()), meta = "columns")$elements$meta
  # from records a factor stays a (list-column) factor; from a data frame it is
  # character -- every other field agrees
  keep <- setdiff(names(a), "f")
  expect_identical(b[keep], a[keep])
})

test_that("records read as columns follow exact `[[` semantics", {
  recs <- list(
    list(tooltip = "a", tooltip = "dup", g = NULL),
    NULL,
    list(tooltip = 1L, 99, g = "x"),
    c(tooltip = "named-atomic"),
    "bare"
  )
  sc <- vl_scene(2, 2) |>
    draw(points_grob(
      seq(0.1, 0.9, length.out = 5),
      0.5,
      key = letters[1:5],
      meta = recs
    ))
  el <- scene_model(sc, meta = "columns")$elements
  # mixed types -> a list-column; the first entry of a name wins
  expect_type(el$meta$tooltip, "list")
  expect_identical(el$meta$tooltip, list("a", NULL, 1L, "named-atomic", NULL))
  # a NULL value counts as absent
  expect_identical(el$meta$g, c(NA, NA, "x", NA, NA))
  # unnamed entries have no column
  expect_named(el$meta, c("tooltip", "g"))
})

test_that("a one-row data frame recycles; a wrong row count is an error", {
  one <- data.frame(tooltip = "all")
  g <- points_grob(c(0.2, 0.5, 0.8), 0.5, key = c("a", "b", "c"), meta = one)
  expect_identical(nrow(g@meta), 3L)
  el <- scene_model(vl_scene(2, 2) |> draw(g), meta = "columns")$elements
  expect_identical(el$meta$tooltip, rep("all", 3L))
  expect_error(
    points_grob(c(0.2, 0.5, 0.8), 0.5, meta = data.frame(t = 1:2)),
    "`meta` must have length 1 or 3"
  )
  bad <- data.frame(t = 1:3)
  bad$m <- matrix(1:6, 3)
  expect_error(
    points_grob(c(0.2, 0.5, 0.8), 0.5, meta = bad),
    "vector or a list"
  )
})

test_that("a data frame set on the grob directly still recycles in scene_model()", {
  g <- points_grob(c(0.2, 0.5, 0.8), 0.5, key = c("a", "b", "c"))
  g@meta <- data.frame(tooltip = "x")
  el <- scene_model(vl_scene(2, 2) |> draw(g))$elements
  expect_identical(el$meta, rep(list(list(tooltip = "x")), 3L))
})

test_that("keyed-only batches and single shapes take their rows of a data frame", {
  # text: only keyed labels are elements, so the NA-keyed row is skipped
  g <- text_grob(
    c("a", "b", "c"),
    x = c(0.2, 0.5, 0.8),
    key = c("ka", NA, "kc"),
    meta = data.frame(v = 1:3)
  )
  el <- scene_model(vl_scene(2, 2) |> draw(g), meta = "columns")$elements
  el <- el[el$mark == "text", ]
  expect_identical(el$key, c("ka", "kc"))
  expect_identical(el$meta$v, c(1L, 3L))
  rec <- scene_model(vl_scene(2, 2) |> draw(g))$elements
  expect_identical(
    rec$meta[rec$mark == "text"],
    list(list(v = 1L), list(v = 3L))
  )
  # a line is one element: its first row
  ln <- lines_grob(
    c(0.1, 0.9),
    c(0.1, 0.9),
    key = "L",
    meta = data.frame(v = 7)
  )
  el <- scene_model(vl_scene(2, 2) |> draw(ln), meta = "columns")$elements
  expect_identical(el$meta$v, 7)
})

test_that("columns mode without any meta, and on an empty scene", {
  sc <- vl_scene(2, 2) |> draw(points_grob(c(0.2, 0.8), 0.5, key = c("a", "b")))
  el <- scene_model(sc, meta = "columns")$elements
  expect_s3_class(el$meta, "data.frame")
  expect_identical(dim(el$meta), c(2L, 0L))
  empty <- scene_model(vl_scene(2, 2), meta = "columns")$elements
  expect_identical(nrow(empty), 0L)
  expect_s3_class(empty$meta, "data.frame")
  expect_error(scene_model(sc, meta = "rows"), "must be one of")
})

test_that("a columnar meta round-trips through records", {
  df <- mixed_df()
  df$f <- as.character(df$f)
  recs <- scene_model(meta_scene(df, swatch = FALSE))$elements$meta[-1]
  back <- scene_model(meta_scene(recs, swatch = FALSE), meta = "columns")
  cols <- back$elements$meta[-1, , drop = FALSE]
  expect_identical(cols$tooltip, df$tooltip)
  expect_identical(cols$v, df$v)
  expect_identical(cols$f, df$f)
  # `legend` is ragged: absent (NULL) stays absent, character(0) stays
  expect_identical(
    cols$legend,
    list("color:x", c("color:y", "shape:z"), NULL, character(0))
  )
})
