# The ecosystem contract. vellum is the backend for vellumplot (grammar) and vellumwidget
# (widget); both bind to the shape of `scene_model()` and the SVG attributes
# `scene_svg()` emits. These tests pin that contract so a change here fails
# loudly (and forces a co-release) rather than silently breaking the layers
# above. The authoritative prose is `vignettes/scene-contract.Rmd`.

test_that("scene_model() returns the documented element and panel columns", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    push(vl_viewport(name = "panel-1-1")) |>
    draw(points_grob(
      c(0.25, 0.75),
      0.5,
      gp = vl_gpar(fill = "red"),
      key = c("a", "b"),
      meta = list(list(t = "A"), list(t = "B"))
    )) |>
    pop()
  m <- scene_model(sc)

  expect_named(m, c("elements", "panels"))
  expect_identical(
    names(m$elements),
    c(
      "key",
      "mark",
      "id",
      "name",
      "panel",
      "x0",
      "y0",
      "x1",
      "y1",
      "x",
      "y",
      "w",
      "h",
      "meta"
    )
  )
  expect_identical(
    names(m$panels),
    c(
      "name",
      "x0",
      "y0",
      "x1",
      "y1",
      "px0",
      "py0",
      "px1",
      "py1",
      "xscale_lo",
      "xscale_hi",
      "yscale_lo",
      "yscale_hi",
      "meta"
    )
  )
  # meta is a list-column carried through untouched.
  expect_type(m$elements$meta, "list")
  expect_identical(m$elements$meta[[1]]$t, "A")
})

test_that("panels carry the panel viewport's pixel rect, native scale, and meta", {
  sc <- vl_scene(3, 2, dpi = 100) |>
    push(vl_viewport(
      name = "panel-1-1",
      xscale = c(0, 10),
      yscale = c(0, 20),
      meta = list(scales = list(x = list(type = "continuous")))
    )) |>
    draw(points_grob(5, 10, gp = vl_gpar(fill = "red"), key = "k1")) |>
    pop()
  p <- scene_model(sc)$panels
  row <- p[p$name == "panel-1-1", ]
  expect_equal(nrow(row), 1L)
  # native ranges come straight from the viewport's xscale/yscale
  expect_equal(c(row$xscale_lo, row$xscale_hi), c(0, 10))
  expect_equal(c(row$yscale_lo, row$yscale_hi), c(0, 20))
  # a true device-px rectangle (not the element extent): finite, ordered, and
  # wider/taller than the single mark's bbox
  expect_true(is.finite(row$px0) && row$px1 > row$px0 && row$py1 > row$py0)
  expect_true(row$px1 - row$px0 > row$x1 - row$x0)
  # the opaque panel-level meta rides through untouched
  expect_identical(row$meta[[1]]$scales$x$type, "continuous")
})

test_that("scene_model() warms the render cache so a following render need not recompile", {
  skip_if_not(isTRUE(getOption("vellum.cache", TRUE)), "render cache disabled")
  sc <- vl_scene(3, 2, dpi = 100) |>
    push(vl_viewport(
      name = "panel-1-1",
      xscale = c(0, 10),
      yscale = c(0, 20)
    )) |>
    draw(points_grob(5, 10, gp = vl_gpar(fill = "red"), key = "k1")) |>
    pop()
  cid <- .scene_cid(sc)
  skip_if(is.null(cid), "scene carries no cache id")
  vl_clear_render_cache()
  invisible(scene_model(sc))
  key <- .render_key(
    cid,
    .to_inches(sc@width),
    .to_inches(sc@height),
    sc@dpi,
    .rs_col(sc@bg) %||% c(255L, 255L, 255L, 0L),
    sc@title,
    sc@desc
  )
  expect_false(is.null(.render_cache_get(key)))
})

test_that("panels list named viewports that enclose elements, innermost first", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    push(vl_viewport(name = "empty")) |>
    pop() |>
    push(vl_viewport(name = "outer")) |>
    push(vl_viewport(name = "inner", width = 0.5)) |>
    draw(points_grob(0.5, 0.5, key = "a")) |>
    pop(2)
  m <- scene_model(sc)
  expect_identical(m$panels$name, "inner")
  expect_identical(m$elements$panel, "inner")
})

test_that("a panel whose viewport carries no meta yields NULL meta (no delete gotcha)", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    push(vl_viewport(name = "panel-1-1")) |>
    draw(points_grob(0.5, 0.5, gp = vl_gpar(fill = "red"), key = "a")) |>
    pop()
  p <- scene_model(sc)$panels
  expect_equal(nrow(p), 1L)
  expect_null(p$meta[[1]])
})

test_that("the `mark` vocabulary is the documented set, in paint order", {
  # Every keyable constructor takes `key`. Batched kinds always emit a row;
  # roundrect/text emit one per keyed element; path/line/polygon emit one row
  # per grob when keyed.
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(0.2, 0.2, width = 0.1, height = 0.1, key = "rect")) |>
    draw(points_grob(0.3, 0.3, gp = vl_gpar(fill = "red"), key = "point")) |>
    draw(circle_grob(0.4, 0.4, r = vl_unit(3, "mm"), key = "circle")) |>
    draw(hexagon_grob(0.5, 0.5, size = vl_unit(3, "mm"), key = "hexagon")) |>
    draw(sector_grob(
      0.6,
      0.6,
      r0 = 0,
      r1 = 0.1,
      theta0 = 0,
      theta1 = pi,
      key = "sector"
    )) |>
    draw(segments_grob(
      0.1,
      0.1,
      0.9,
      0.9,
      gp = vl_gpar(col = "black"),
      key = "segment"
    )) |>
    draw(roundrect_grob(
      0.3,
      0.9,
      width = 0.1,
      height = 0.05,
      key = "roundrect"
    )) |>
    draw(text_grob("t", 0.5, 0.9, key = "text")) |>
    draw(path_grob(
      c(0.7, 0.8, 0.75),
      c(0.7, 0.7, 0.8),
      gp = vl_gpar(fill = "grey"),
      key = "path"
    )) |>
    draw(lines_grob(
      c(0.1, 0.2),
      c(0.8, 0.9),
      gp = vl_gpar(col = "blue"),
      key = "line"
    )) |>
    draw(polygon_grob(
      c(0.85, 0.95, 0.9),
      c(0.1, 0.1, 0.2),
      gp = vl_gpar(fill = "green"),
      key = "polygon"
    ))
  marks <- scene_model(sc)$elements$mark

  vocab <- c(
    "rect",
    "point",
    "circle",
    "hexagon",
    "sector",
    "segment",
    "roundrect",
    "text",
    "path",
    "line",
    "polygon"
  )
  expect_true(all(marks %in% vocab))
  # paint order: the marks come out in the order drawn.
  expect_identical(marks, vocab)
  # Setting the `@keys` slot is equivalent to the `key` argument.
  g <- lines_grob(c(0.1, 0.2), c(0.8, 0.9))
  g@keys <- "slot"
  expect_identical(
    scene_model(vl_scene(1, 1) |> draw(g))$elements$key,
    "slot"
  )
})

test_that("keyed-only and single-shape marks contribute rows only when keyed", {
  unkeyed <- vl_scene(2, 2, dpi = 100) |>
    draw(text_grob(c("a", "b"), c(0.3, 0.7), 0.5)) |>
    draw(roundrect_grob(0.5, 0.2, width = 0.2, height = 0.1)) |>
    draw(lines_grob(c(0.1, 0.9), c(0.1, 0.9))) |>
    draw(polygon_grob(c(0.1, 0.2, 0.15), c(0.8, 0.8, 0.9))) |>
    draw(path_grob(c(0.7, 0.8, 0.75), c(0.7, 0.7, 0.8)))
  expect_equal(nrow(scene_model(unkeyed)$elements), 0L)
  # Within a keyed text grob, an NA key is skipped.
  part <- vl_scene(2, 2, dpi = 100) |>
    draw(text_grob(
      c("a", "b", "c"),
      c(0.2, 0.5, 0.8),
      0.5,
      key = c("a", NA, "c")
    ))
  expect_identical(scene_model(part)$elements$key, c("a", "c"))
  # A batched mark always emits, keys NA when unkeyed.
  batch <- vl_scene(2, 2, dpi = 100) |> draw(rect_grob(c(0.3, 0.7), 0.5))
  expect_identical(scene_model(batch)$elements$key, c(NA_character_, NA))
})

test_that("key and meta must have length 1 or the element count", {
  expect_error(
    points_grob(c(0.2, 0.8), 0.5, key = c("a", "b", "c")),
    "`key` must have length 1 or 2"
  )
  expect_error(
    rect_grob(c(0.2, 0.8), 0.5, meta = list(1, 2, 3)),
    "`meta` must have length 1 or 2"
  )
  expect_error(lines_grob(c(0, 1), c(0, 1), key = c("a", "b")), "`key`")
  shared <- points_grob(c(0.2, 0.8), 0.5, key = "k", meta = list(list(t = 1)))
  m <- scene_model(vl_scene(1, 1) |> draw(shared))$elements
  expect_identical(m$key, c("k", "k"))
  expect_identical(m$meta[[2]]$t, 1)
})

test_that("bare numbers are npc in every keyable constructor (default_units)", {
  # Inside a scaled panel, a bare 5 is half-way (npc), not native 5 of 0..100.
  at <- function(default_units) {
    sc <- vl_scene(2, 2, dpi = 100) |>
      push(vl_viewport(xscale = c(0, 100), yscale = c(0, 100))) |>
      draw(points_grob(
        0.5,
        0.5,
        key = "p",
        default_units = default_units
      )) |>
      pop()
    scene_model(sc)$elements$x
  }
  expect_equal(at("npc"), 100, tolerance = 1)
  expect_lt(at("native"), 5)
})

test_that("keyed elements carry their key to the SVG `data-key` attribute", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    draw(points_grob(
      c(0.25, 0.75),
      0.5,
      gp = vl_gpar(fill = "red"),
      key = c("a", "b")
    ))
  keys <- regmatches(
    scene_svg(sc),
    gregexpr('data-key="[^"]*"', scene_svg(sc))
  )[[1]]
  # A single element may be drawn as more than one SVG node (e.g. a marker's
  # fill and stroke sub-paths), so a key can repeat; the distinct set, in first
  # appearance, is the contract a host groups on.
  expect_identical(unique(keys), c('data-key="a"', 'data-key="b"'))
})

test_that("grob id/role/name and named panels surface as SVG attributes", {
  sc <- vl_scene(2, 2, dpi = 100) |>
    push(vl_viewport(name = "panel-1-1")) |>
    draw(rect_grob(
      0.5,
      0.5,
      width = 0.3,
      height = 0.3,
      gp = vl_gpar(fill = "red"),
      id = "el1",
      role = "img",
      name = "myrect"
    )) |>
    pop()
  svg <- scene_svg(sc)
  expect_match(svg, 'data-vellum-id="el1"', fixed = TRUE)
  expect_match(svg, 'role="img"', fixed = TRUE)
  expect_match(svg, 'data-vellum-name="myrect"', fixed = TRUE)
  expect_match(svg, 'data-vellum-panel="panel-1-1"', fixed = TRUE)
})

test_that("a pannable clipped panel emits outer(clip) > inner(data-vellum-pan) with one hoisted clip", {
  sc <- vl_scene(3, 2, dpi = 100) |>
    push(vl_viewport(
      name = "panel-1-1",
      xscale = c(0, 10),
      yscale = c(0, 10),
      clip = TRUE,
      pannable = TRUE
    )) |>
    draw(points_grob(
      c(3, 7),
      5,
      gp = vl_gpar(fill = "red"),
      key = c("a", "b"),
      default_units = "native"
    )) |>
    pop()
  svg <- scene_svg(sc)
  # the panel group carries the clip; a nested pan group holds the content
  expect_match(svg, 'data-vellum-panel="panel-1-1"[^>]*clip-path=')
  expect_match(svg, 'data-vellum-pan="panel-1-1"', fixed = TRUE)
  # clip is hoisted once to the outer group, not repeated per element
  expect_equal(lengths(regmatches(svg, gregexpr("clip-path=", svg))), 1L)
})

test_that("a non-pannable panel is unchanged (no pan group; per-element clips)", {
  sc <- vl_scene(3, 2, dpi = 100) |>
    push(vl_viewport(name = "p", clip = TRUE)) |>
    draw(points_grob(
      c(0.3, 0.7),
      0.5,
      gp = vl_gpar(fill = "red"),
      key = c("a", "b")
    )) |>
    pop()
  svg <- scene_svg(sc)
  expect_no_match(svg, 'data-vellum-pan="', fixed = TRUE)
  expect_match(svg, 'data-vellum-panel="p"', fixed = TRUE)
})

test_that("additivity: a scene with no keys/meta emits no data-key (byte-stable)", {
  plain <- vl_scene(2, 2, dpi = 100) |>
    draw(points_grob(c(0.25, 0.75), 0.5, gp = vl_gpar(fill = "red")))
  svg <- scene_svg(plain)
  expect_no_match(svg, "data-key=", fixed = TRUE)
  # scene_model() still yields a geometry table (keys NA).
  m <- scene_model(plain)
  expect_equal(nrow(m$elements), 2L)
  expect_true(all(is.na(m$elements$key)))
})

test_that("element_geometry() returns the documented columns and rule vocabulary", {
  keyed <- function(g, k) {
    g@keys <- k
    g
  }
  sc <- vl_scene(3, 2, dpi = 100) |>
    draw(segments_grob(0.1, 0.1, 0.4, 0.4, key = "seg")) |>
    draw(points_grob(0.5, 0.5, key = "pt")) |>
    draw(keyed(
      polygon_grob(c(0.6, 0.8, 0.7), c(0.1, 0.1, 0.3)),
      "poly"
    )) |>
    draw(path_grob(
      x = c(0.1, 0.4, 0.4, 0.1, 0.2, 0.3, 0.3, 0.2),
      y = c(0.6, 0.6, 0.9, 0.9, 0.7, 0.7, 0.8, 0.8),
      id = rep(1:2, each = 4),
      rule = "evenodd",
      key = "holed"
    ))
  g <- element_geometry(sc)
  # Additive only: `rule` was appended after `x`/`y`, nothing renamed or moved.
  expect_identical(
    names(g),
    c("key", "kind", "vertex", "ring", "x", "y", "rule")
  )
  expect_type(g$rule, "character")
  expect_true(all(g$rule %in% c("nonzero", "evenodd", NA)))
  # One value per element, repeated on each of its rows.
  rule_of <- tapply(g$rule, g$key, function(r) unique(r))
  expect_true(all(lengths(rule_of) == 1L))
  expect_identical(rule_of[["holed"]], "evenodd")
  expect_identical(rule_of[["poly"]], "nonzero")
  expect_true(is.na(rule_of[["seg"]]) && is.na(rule_of[["pt"]]))
  # The empty result has the same columns.
  expect_identical(names(element_geometry(vl_scene(1, 1))), names(g))
})

test_that("element_geometry() kinds: boxes are nonzero, a circle reports as point", {
  sc <- vl_scene(3, 2, dpi = 100) |>
    draw(rect_grob(0.2, 0.2, width = 0.1, height = 0.1, key = "r")) |>
    draw(roundrect_grob(0.5, 0.2, width = 0.1, height = 0.1, key = "rr")) |>
    draw(text_grob("t", 0.8, 0.2, key = "t")) |>
    draw(circle_grob(0.5, 0.7, r = vl_unit(2, "mm"), key = "c"))
  g <- element_geometry(sc)
  first <- g[!duplicated(g$key), ]
  kinds <- stats::setNames(first$kind, first$key)
  rules <- stats::setNames(first$rule, first$key)
  expect_identical(
    unname(kinds[c("r", "rr", "t", "c")]),
    c("rect", "roundrect", "text", "point")
  )
  expect_identical(unname(rules[c("r", "rr", "t")]), rep("nonzero", 3))
  expect_true(is.na(rules[["c"]]))
  expect_equal(sum(g$key == "r"), 2L) # two opposite corners
  expect_equal(sum(g$key == "t"), 4L) # the label box
})

test_that("a point in a hole is not a hit (containment follows the fill rule)", {
  sc <- vl_scene(4, 3, dpi = 100) |>
    draw(path_grob(
      x = c(0.1, 0.9, 0.9, 0.1, 0.4, 0.6, 0.6, 0.4),
      y = c(0.1, 0.1, 0.9, 0.9, 0.4, 0.4, 0.6, 0.6),
      id = rep(1:2, each = 4),
      rule = "evenodd",
      key = "donut"
    ))
  expect_gt(vl_nearest(sc, 0.5, 0.5)$dist, 0)
  expect_equal(vl_nearest(sc, 0.2, 0.5)$dist, 0)
  # hit_test() follows the same rule: nothing under the hole, the path on the ring.
  expect_null(hit_test(sc, 0.5, 0.5))
  expect_false(is.null(hit_test(sc, 0.2, 0.5)))
})
