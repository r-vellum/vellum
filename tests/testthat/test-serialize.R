# Phase 9: scene serialization, hashing, diffing, and composition.

rich_scene <- function() {
  set.seed(1)
  vl_scene(3, 2, dpi = 120, bg = "grey95") |>
    push(vl_viewport(
      name = "p",
      xscale = c(0, 10),
      clip = TRUE,
      angle = 15,
      alpha = 0.9
    )) |>
    draw(rect_grob(
      gp = vl_gpar(fill = linear_gradient(c("red", "blue")), col = NA)
    )) |>
    draw(points_grob(
      runif(10),
      runif(10),
      key = paste0("k", 1:10),
      shape = "square"
    )) |>
    draw(text_grob(
      "hi\nthere",
      gp = vl_gpar(fontsize = 14, halo_col = "white", halo_width = 1)
    )) |>
    draw(text_grob(md("**bold** and *it*"), y = 0.2)) |>
    draw(segments_grob(
      0.1,
      0.1,
      0.9,
      0.9,
      gp = vl_gpar(lty = "dashed", dash_phase = 1)
    )) |>
    pop()
}

test_that("a scene round-trips through its spec", {
  s <- rich_scene()
  expect_identical(
    as_scene_spec(from_scene_spec(as_scene_spec(s))),
    as_scene_spec(s)
  )
})

test_that("a round-tripped scene renders byte-identically", {
  s <- rich_scene()
  a <- withr::local_tempfile(fileext = ".png")
  b <- withr::local_tempfile(fileext = ".png")
  vl_clear_render_cache()
  render(s, a)
  vl_clear_render_cache()
  render(from_scene_spec(as_scene_spec(s)), b)
  expect_identical(tools::md5sum(a)[[1]], tools::md5sum(b)[[1]])
})

test_that("both file formats round-trip to identical pixels", {
  for (ext in c("rds", "json")) {
    if (ext == "json") {
      skip_if_not_installed("jsonlite")
    }
    f <- withr::local_tempfile(fileext = paste0(".", ext))
    scene_write(rich_scene(), f)
    a <- withr::local_tempfile(fileext = ".png")
    b <- withr::local_tempfile(fileext = ".png")
    vl_clear_render_cache()
    render(rich_scene(), a)
    vl_clear_render_cache()
    render(scene_read(f), b)
    expect_identical(tools::md5sum(a)[[1]], tools::md5sum(b)[[1]], label = ext)
  }
})

test_that("JSON keeps NA and keeps doubles double", {
  # Both are real hazards: an unboxed length-1 NA becomes a bare null and reads
  # back as NULL, and JSON has one number type so 120 returns as an integer.
  skip_if_not_installed("jsonlite")
  s <- vl_scene(2, 2, dpi = 120) |>
    draw(rect_grob(gp = vl_gpar(fill = "red", col = NA))) |>
    draw(text_grob(md("**b**")))
  f <- withr::local_tempfile(fileext = ".json")
  scene_write(s, f)
  expect_identical(as_scene_spec(scene_read(f)), as_scene_spec(s))
})

test_that("the spec omits build-time identity", {
  # `nid` is a monotonic counter for the render cache. If it were serialized,
  # two identical scenes built separately would hash and diff differently.
  a <- vl_scene(2, 2) |> draw(circle_grob())
  b <- vl_scene(2, 2) |> draw(circle_grob())
  expect_identical(as_scene_spec(a), as_scene_spec(b))
  expect_identical(scene_hash(a), scene_hash(b))
})

test_that("scene_hash tracks content", {
  a <- vl_scene(2, 2) |> draw(circle_grob(gp = vl_gpar(fill = "red")))
  b <- vl_scene(2, 2) |> draw(circle_grob(gp = vl_gpar(fill = "blue")))
  expect_identical(scene_hash(a), scene_hash(a))
  expect_false(identical(scene_hash(a), scene_hash(b)))
  expect_false(identical(
    scene_hash(a),
    scene_hash(vl_scene(3, 2) |> draw(circle_grob(gp = vl_gpar(fill = "red"))))
  ))
})

test_that("a scene holding a function refuses to serialize", {
  s <- vl_scene(2, 2) |> draw(rect_grob(meta = list(list(f = function() 1))))
  expect_error(as_scene_spec(s), "cannot be serialized")
})

test_that("an unreadable spec errors clearly", {
  expect_error(from_scene_spec(list(a = 1)), "version")
  expect_error(from_scene_spec(list(version = 999L)), "Upgrade vellum")
  expect_error(scene_read(file.path(tempdir(), "nope.rds")), "No such file")
  expect_error(
    scene_write(vl_scene(1, 1), tempfile(fileext = ".xyz")),
    "Unsupported"
  )
})

# --- diffing -----------------------------------------------------------------

test_that("scene_diff finds changed, added and removed nodes", {
  a <- vl_scene(3, 2) |>
    draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "red"), name = "dot")) |>
    draw(text_grob("A", name = "lab"))
  b <- vl_scene(3, 2) |>
    draw(circle_grob(r = 0.4, gp = vl_gpar(fill = "blue"), name = "dot")) |>
    draw(text_grob("A", name = "lab")) |>
    draw(rect_grob(name = "extra"))
  d <- scene_diff(a, b)
  expect_gte(nrow(d), 3L)
  expect_true(any(grepl("fill", d$path) & d$detail == "red -> blue"))
  expect_true(any(d$change == "added" & grepl("extra", d$detail)))
  # Units read as units, not as their encoding.
  expect_true(any(d$detail == "0.3npc -> 0.4npc"))
})

test_that("scene_diff is empty for equivalent scenes", {
  a <- vl_scene(3, 2) |> draw(circle_grob(gp = vl_gpar(fill = "red")))
  b <- vl_scene(3, 2) |> draw(circle_grob(gp = vl_gpar(fill = "red")))
  expect_equal(nrow(scene_diff(a, b)), 0L)
  expect_equal(nrow(scene_diff(a, a)), 0L)
})

test_that("scene_diff notices page-level changes", {
  d <- scene_diff(vl_scene(3, 2), vl_scene(4, 2))
  expect_equal(nrow(d), 1L)
  expect_match(d$detail, "3in -> 4in")
})

test_that("the diff print method summarises", {
  d <- scene_diff(vl_scene(3, 2), vl_scene(4, 2))
  out <- paste(capture.output(print(d), type = "message"), collapse = " ")
  expect_match(out, "1 difference")
  clean <- paste(
    capture.output(
      print(scene_diff(vl_scene(1, 1), vl_scene(1, 1))),
      type = "message"
    ),
    collapse = " "
  )
  expect_match(clean, "structurally identical")
})

# --- composition -------------------------------------------------------------

test_that("scene_inset grafts a scene into a region", {
  main <- vl_scene(4, 3, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "#eef2f6", col = NA)))
  mini <- vl_scene(1, 1) |>
    draw(circle_grob(r = 0.4, gp = vl_gpar(fill = "tomato", col = NA)))
  comp <- scene_inset(
    main,
    mini,
    x = 0.8,
    y = 0.75,
    width = 0.3,
    height = 0.35,
    name = "inset"
  )
  expect_true("inset" %in% node_names(comp))
  expect_false(is.null(get_node(comp, "inset")))
  # The guest actually drew: there is tomato in the upper right.
  r <- scene_raster(comp)
  expect_true(any(r[1, 300:390, 40:110] > 200 & r[2, 300:390, 40:110] < 140))
})

test_that("an inset can itself be inset", {
  mini <- vl_scene(1, 1) |> draw(circle_grob(gp = vl_gpar(fill = "red")))
  once <- scene_inset(vl_scene(3, 3), mini, name = "a")
  twice <- scene_inset(
    once,
    mini,
    x = 0.2,
    y = 0.2,
    width = 0.2,
    height = 0.2,
    name = "b"
  )
  expect_true(all(c("a", "b") %in% node_names(twice)))
})

test_that("insetting an empty scene is a no-op", {
  main <- vl_scene(2, 2) |> draw(circle_grob())
  expect_identical(
    as_scene_spec(scene_inset(main, vl_scene(1, 1))),
    as_scene_spec(main)
  )
})

test_that("a composed scene serializes like any other", {
  mini <- vl_scene(1, 1) |> draw(circle_grob(gp = vl_gpar(fill = "red")))
  comp <- scene_inset(vl_scene(3, 2), mini, name = "inset")
  expect_identical(
    as_scene_spec(from_scene_spec(as_scene_spec(comp))),
    as_scene_spec(comp)
  )
})
