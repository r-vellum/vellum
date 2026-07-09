# The ecosystem contract. vellum is the backend for vellumplot (grammar) and vellumwidget
# (widget); both bind to the shape of `scene_model()` and the SVG attributes
# `scene_svg()` emits. These tests pin that contract so a change here fails
# loudly (and forces a co-release) rather than silently breaking the layers
# above. The authoritative prose is `vignettes/scene-contract.Rmd`.

test_that("scene_model() returns the documented element and panel columns", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    push(viewport(name = "panel-1-1")) |>
    draw(points_grob(c(0.25, 0.75), 0.5, gp = gpar(fill = "red"),
                     key = c("a", "b"), meta = list(list(t = "A"), list(t = "B")))) |>
    pop()
  m <- scene_model(sc)

  expect_named(m, c("elements", "panels"))
  expect_identical(
    names(m$elements),
    c("key", "mark", "id", "name", "panel",
      "x0", "y0", "x1", "y1", "x", "y", "w", "h", "meta")
  )
  expect_identical(names(m$panels), c("name", "x0", "y0", "x1", "y1"))
  # meta is a list-column carried through untouched.
  expect_type(m$elements$meta, "list")
  expect_identical(m$elements$meta[[1]]$t, "A")
})

test_that("the `mark` vocabulary is the documented closed set, in paint order", {
  # The batched kinds take a `key` argument and always emit a row. The
  # single-shape kinds (path/line/polygon) surface only when keyed, and are
  # keyed via the `@keys` slot the grammar sets on the grob (their constructors
  # do not expose a `key` argument).
  keyed <- function(g, k) {
    g@keys <- k
    g
  }
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(0.2, 0.2, width = 0.1, height = 0.1, key = "rect")) |>
    draw(points_grob(0.3, 0.3, gp = gpar(fill = "red"), key = "point")) |>
    draw(circle_grob(0.4, 0.4, r = unit(3, "mm"), key = "circle")) |>
    draw(hexagon_grob(0.5, 0.5, size = unit(3, "mm"), key = "hexagon")) |>
    draw(sector_grob(0.6, 0.6, r0 = 0, r1 = 0.1, theta0 = 0, theta1 = pi, key = "sector")) |>
    draw(segments_grob(0.1, 0.1, 0.9, 0.9, gp = gpar(col = "black"), key = "segment")) |>
    draw(keyed(path_grob(c(0.7, 0.8, 0.75), c(0.7, 0.7, 0.8), gp = gpar(fill = "grey")),
               "path")) |>
    draw(keyed(lines_grob(c(0.1, 0.2), c(0.8, 0.9), gp = gpar(col = "blue")), "line")) |>
    draw(keyed(polygon_grob(c(0.85, 0.95, 0.9), c(0.1, 0.1, 0.2), gp = gpar(fill = "green")),
               "polygon"))
  marks <- scene_model(sc)$elements$mark

  vocab <- c("rect", "point", "circle", "hexagon", "sector",
             "segment", "path", "line", "polygon")
  expect_true(all(marks %in% vocab))
  # paint order: the marks come out in the order drawn.
  expect_identical(marks, vocab)
})

test_that("keyed elements carry their key to the SVG `data-key` attribute", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(points_grob(c(0.25, 0.75), 0.5, gp = gpar(fill = "red"), key = c("a", "b")))
  keys <- regmatches(scene_svg(sc), gregexpr('data-key="[^"]*"', scene_svg(sc)))[[1]]
  # A single element may be drawn as more than one SVG node (e.g. a marker's
  # fill and stroke sub-paths), so a key can repeat; the distinct set, in first
  # appearance, is the contract a host groups on.
  expect_identical(unique(keys), c('data-key="a"', 'data-key="b"'))
})

test_that("grob id/role/name and named panels surface as SVG attributes", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    push(viewport(name = "panel-1-1")) |>
    draw(rect_grob(0.5, 0.5, width = 0.3, height = 0.3, gp = gpar(fill = "red"),
                   id = "el1", role = "img", name = "myrect")) |>
    pop()
  svg <- scene_svg(sc)
  expect_match(svg, 'data-vellum-id="el1"', fixed = TRUE)
  expect_match(svg, 'role="img"', fixed = TRUE)
  expect_match(svg, 'data-vellum-name="myrect"', fixed = TRUE)
  expect_match(svg, 'data-vellum-panel="panel-1-1"', fixed = TRUE)
})

test_that("additivity: a scene with no keys/meta emits no data-key (byte-stable)", {
  plain <- vl_scene(2, 2, dpi = 100) |>
    draw(points_grob(c(0.25, 0.75), 0.5, gp = gpar(fill = "red")))
  svg <- scene_svg(plain)
  expect_no_match(svg, "data-key=", fixed = TRUE)
  # scene_model() still yields a geometry table (keys NA).
  m <- scene_model(plain)
  expect_equal(nrow(m$elements), 2L)
  expect_true(all(is.na(m$elements$key)))
})
