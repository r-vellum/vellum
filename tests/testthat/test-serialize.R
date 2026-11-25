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

# --- attributes on atomic vectors ---------------------------------------------

# Every `vl_gpar()` field set to a non-default value, plus the shapes of value
# that used to lose their attributes on the way through a spec: named numerics
# (`features`), a numeric dash vector (`lty`), a classed list (a systemfonts
# `font_feature()`), named per-element `meta`, and compound units.
gpar_scene <- function() {
  gp_all <- list(
    col = "#336699",
    fill = c(a = "#ffcc00"),
    lwd = 2,
    alpha = 0.8,
    lty = c(dash = 4, gap = 2),
    lineend = "butt",
    linejoin = "mitre",
    linemitre = 4,
    fontfamily = "sans",
    fontface = "bold",
    fontweight = 600L,
    fontsize = 13,
    cex = 1.1,
    lineheight = 1.3,
    halo_col = "white",
    halo_width = 1,
    features = c(tnum = 1, liga = 0),
    antialias = FALSE,
    crisp = TRUE,
    dash_phase = 1.5
  )
  expect_setequal(names(gp_all), names(vl_gpar@properties))
  gp <- do.call(vl_gpar, gp_all)
  vl_scene(3, 2) |>
    draw(text_grob(c("10", "11"), y = c(0.3, 0.6), key = c("a", "b"), gp = gp)) |>
    draw(text_grob(
      "fi",
      x = vl_unit(0.5, "npc") + vl_unit(2, "mm"),
      gp = vl_gpar(features = systemfonts::font_feature(ligatures = "standard"))
    )) |>
    draw(rect_grob(
      x = vl_unit(0.2, "npc") - vl_unit(1, "mm"),
      width = 0.1,
      height = 0.1,
      key = "r",
      meta = list(c(min = 1, max = 2, flag = NA)),
      gp = gp
    )) |>
    draw(segments_grob(0.1, 0.1, 0.9, 0.9, gp = gp))
}

test_that("named and classed values survive a file round-trip", {
  s <- gpar_scene()
  svg <- scene_svg(s)
  for (ext in c("rds", "json")) {
    if (ext == "json") {
      skip_if_not_installed("jsonlite")
    }
    f <- withr::local_tempfile(fileext = paste0(".", ext))
    scene_write(s, f)
    r <- scene_read(f)
    expect_identical(scene_svg(r), svg, label = ext)
    expect_identical(as_scene_spec(r), as_scene_spec(s), label = ext)
    m <- scene_model(r)$elements
    expect_identical(
      m$meta[[match("r", m$key)]],
      c(min = 1, max = 2, flag = NA),
      label = ext
    )
  }
})

test_that("integer and logical vectors keep their names too", {
  s <- vl_scene(2, 2) |>
    draw(rect_grob(key = "k", meta = list(list(n = c(a = 1L), b = c(x = TRUE)))))
  for (ext in c("rds", "json")) {
    if (ext == "json") {
      skip_if_not_installed("jsonlite")
    }
    f <- withr::local_tempfile(fileext = paste0(".", ext))
    scene_write(s, f)
    m <- scene_model(scene_read(f))$elements
    expect_identical(m$meta[[1]], list(n = c(a = 1L), b = c(x = TRUE)))
  }
})

test_that("a spec from the old encoder (no names field) still reads", {
  spec <- as_scene_spec(vl_scene(2, 2) |> draw(circle_grob(r = 0.3)))
  strip <- function(x) {
    if (is.list(x)) {
      x$names <- if (identical(x[["_t"]], "list")) x$names else NULL
      x$attrs <- NULL
      x[] <- lapply(x, strip)
    }
    x
  }
  expect_identical(
    as_scene_spec(from_scene_spec(strip(spec))),
    as_scene_spec(from_scene_spec(spec))
  )
})

test_that("scene_inset() fits a guest that declares a fixed-aspect content box (VP-120)", {
  host <- vl_scene(6, 4)
  # a guest whose content is a 2:1 null-track panel plus a 10 mm frame each way
  guest <- vl_scene(2, 2) |>
    draw(rect_grob(gp = vl_gpar(fill = "tomato", col = NA)))
  npc <- function(u) vctrs::field(u, "value")
  # no declaration: the region is left as given (fill)
  plain <- scene_inset(host, guest, width = 0.5, height = 0.5)
  expect_equal(.node_children(.materialize(plain))[[1]]@vp@width, vl_unit(0.5, "npc"))
  attr(guest, "vellum_content_fit") <- c(10, 10, 2, 1)
  fitted <- scene_inset(host, guest, width = 0.5, height = 0.5, name = "ins")
  vp <- .node_children(.materialize(fitted))[[1]]@vp
  # region 76.2 x 50.8 mm; null space 66.2 x 40.8 -> u = min(33.1, 40.8) = 33.1
  expect_equal(npc(vp@width), 0.5, tolerance = 1e-9)
  h_mm <- npc(vp@height) * 4 * 25.4
  expect_equal(h_mm, 10 + 33.1, tolerance = 1e-6)
  # fill keeps the region; contain without a declaration is an error
  kept <- scene_inset(host, guest, width = 0.5, height = 0.5, fit = "fill")
  expect_equal(.node_children(.materialize(kept))[[1]]@vp@height, vl_unit(0.5, "npc"))
  attr(guest, "vellum_content_fit") <- NULL
  expect_error(
    scene_inset(host, guest, width = 0.5, height = 0.5, fit = "contain"),
    "content box"
  )
  # absolute units work too
  attr(guest, "vellum_content_fit") <- c(0, 0, 1, 1)
  sq <- scene_inset(host, guest, width = vl_unit(2, "in"), height = vl_unit(1, "in"))
  vp <- .node_children(.materialize(sq))[[1]]@vp
  expect_equal(vl_convert(vp@width, "mm"), 25.4, tolerance = 1e-6)
  expect_equal(vl_convert(vp@height, "mm"), 25.4, tolerance = 1e-6)
  expect_error(scene_inset(host, guest, fit = "squash"), "fit")
})
