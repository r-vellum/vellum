# Phase 13: tagged PDF output and reproducible font resolution.

# A PDF is binary, so search it as bytes. `rawToChar()` on a whole PDF fails on
# embedded nuls and on bytes that are invalid in the session locale -- searching
# the raw vector sidesteps both, and checks the file rather than checking that
# our own code ran.
has_bytes <- function(pdf, what) {
  length(grepRaw(what, pdf, fixed = TRUE, all = FALSE)) > 0L
}
# All `/Alt(...)` and `/T(...)` strings in a PDF, as text. Structure entries are
# not in compressed streams here, so a byte scan finds them.
pdf_labels <- function(pdf) {
  hits <- grepRaw("/Alt(", pdf, fixed = TRUE, all = TRUE)
  hits <- c(hits, grepRaw("/T(", pdf, fixed = TRUE, all = TRUE))
  vapply(
    hits,
    function(at) {
      tail <- pdf[at:min(length(pdf), at + 200L)]
      close <- grepRaw(")", tail, fixed = TRUE, all = FALSE)
      rawToChar(tail[seq_len(close)])
    },
    character(1)
  )
}

marked_scene <- function() {
  vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(rect_grob(
      gp = vl_gpar(fill = "grey95"),
      role = "presentation",
      name = "panel"
    )) |>
    draw(points_grob(
      c(0.3, 0.7),
      c(0.4, 0.6),
      name = "observations",
      role = "img"
    )) |>
    draw(text_grob(
      "Sales by region",
      y = 0.9,
      name = "Sales by region",
      role = "heading"
    ))
}

test_that("per-mark metadata produces a PDF structure tree", {
  pdf <- scene_pdf(marked_scene())
  expect_true(has_bytes(pdf, "StructTreeRoot"))
  expect_true(has_bytes(pdf, "/Marked"))
  # The role mapping reached the file: a heading became H1, a mark a Figure.
  expect_true(has_bytes(pdf, "/Figure"))
  expect_true(has_bytes(pdf, "/H1"))
})

test_that("alt text comes from the mark's name", {
  expect_true(any(grepl(
    "observations",
    pdf_labels(scene_pdf(marked_scene())),
    fixed = TRUE
  )))
})

test_that("describe() supplies the figure's alt text", {
  s <- describe(
    marked_scene(),
    title = "Regional sales",
    desc = "A scatter of sales by region."
  )
  expect_true(has_bytes(scene_pdf(s), "A scatter of sales by region."))
})

test_that("a scene with no metadata is untagged and unchanged", {
  # The whole point of gating on metadata: an ordinary plot's PDF must be
  # byte-for-byte what it was before tagging existed.
  plain <- function() {
    vl_scene(4, 3, dpi = 96, bg = "white") |>
      draw(points_grob(c(0.3, 0.7), c(0.4, 0.6))) |>
      draw(text_grob("hello", y = 0.9))
  }
  pdf <- scene_pdf(plain())
  expect_false(has_bytes(pdf, "StructTreeRoot"))
  expect_identical(pdf, scene_pdf(plain()))
})

test_that("a described but unmarked scene keeps the single-figure tagging", {
  # Per-mark tagging and the whole-content span are mutually exclusive (PDF
  # forbids nesting tagged spans), so this path must still work on its own.
  s <- describe(
    vl_scene(3, 2, dpi = 96, bg = "white") |> draw(points_grob(0.5, 0.5)),
    title = "One point",
    desc = "A single point."
  )
  pdf <- scene_pdf(s)
  expect_true(has_bytes(pdf, "StructTreeRoot"))
  expect_true(has_bytes(pdf, "A single point."))
})

test_that("decorative marks are artifacts, not structure entries", {
  # A gridline announced by a screen reader is noise. `role = "presentation"`
  # must not contribute an /Alt.
  deco <- vl_scene(3, 2, dpi = 96, bg = "white") |>
    draw(rect_grob(
      gp = vl_gpar(fill = "grey95"),
      role = "presentation",
      name = "background panel"
    )) |>
    draw(points_grob(0.5, 0.5, name = "the point", role = "img"))
  alts <- paste(pdf_labels(scene_pdf(deco)), collapse = " ")
  expect_true(grepl("the point", alts, fixed = TRUE))
  expect_false(grepl("background panel", alts, fixed = TRUE))
})

test_that("an all-decorative described scene still gets its single figure", {
  # Regression (vellumplot#145): when every mark is decorative
  # (`role = "presentation"`) but still carries a provenance `id`, the per-mark
  # path used to fire on those ids alone -- suppressing the whole-content span --
  # and then, since decorative marks are artifacts rather than structure entries,
  # leave the scene with NO Figure and no Alt at all. Decorative metadata must not
  # count as per-mark metadata: the page stays one Figure carrying the
  # description, with the marks as its (artifact) content.
  s <- describe(
    vl_scene(3, 2, dpi = 96, bg = "white") |>
      draw(points_grob(
        c(0.3, 0.7),
        c(0.5, 0.5),
        id = "layer-1-point",
        role = "presentation"
      )) |>
      draw(text_grob(
        "peak",
        y = 0.9,
        name = "repel:panel-1-1:2:0",
        role = "presentation"
      )),
    title = "One figure",
    desc = "A described chart."
  )
  pdf <- scene_pdf(s)
  expect_true(has_bytes(pdf, "StructTreeRoot"))
  expect_true(has_bytes(pdf, "/Figure"))
  # The description is the figure's alt text ...
  expect_true(has_bytes(pdf, "A described chart."))
  # ... and no internal id / repel handle ever surfaces as an /Alt.
  alts <- paste(pdf_labels(pdf), collapse = " ")
  expect_false(grepl("layer-1-point", alts, fixed = TRUE))
  expect_false(grepl("repel:", alts, fixed = TRUE))
})

test_that("tagging does not disturb the rendered pixels", {
  # Structure is metadata. The raster of a marked scene must equal the raster of
  # the same scene without the marks.
  marked <- vl_scene(3, 2, dpi = 96, bg = "white") |>
    draw(points_grob(c(0.3, 0.7), c(0.5, 0.5), name = "pts", role = "img"))
  bare <- vl_scene(3, 2, dpi = 96, bg = "white") |>
    draw(points_grob(c(0.3, 0.7), c(0.5, 0.5)))
  expect_identical(scene_raster(marked), scene_raster(bare))
  expect_identical(scene_png(marked), scene_png(bare))
})

test_that("many marks all reach the tree", {
  s <- vl_scene(4, 3, dpi = 96, bg = "white")
  for (i in 1:8) {
    s <- draw(
      s,
      points_grob(i / 9, 0.5, name = paste0("mark_", i), role = "img")
    )
  }
  alts <- paste(pdf_labels(scene_pdf(s)), collapse = " ")
  for (i in 1:8) {
    expect_true(grepl(paste0("mark_", i), alts, fixed = TRUE))
  }
})

test_that("SVG metadata is unchanged by the PDF work", {
  # `begin_node()` now carries the whole `NodeMeta` rather than a pre-formatted
  # string; the SVG it produces must be identical.
  svg <- scene_svg(marked_scene())
  expect_true(grepl('data-vellum-name="observations"', svg, fixed = TRUE))
  expect_true(grepl('role="img"', svg, fixed = TRUE))
})

# --- font pinning -------------------------------------------------------------

test_that("scene_fonts reports the faces text actually resolved to", {
  s <- vl_scene(4, 2, dpi = 96) |>
    draw(text_grob("hello", gp = vl_gpar(fontfamily = "serif")))
  f <- scene_fonts(s)
  expect_gte(nrow(f), 1L)
  expect_true(all(c("path", "index", "glyphs", "file", "exists") %in% names(f)))
  expect_true(all(f$exists))
  # One glyph per character for "hello" in any Latin font -- but a font with an
  # "ll" ligature would shape it to four, so assert the range rather than the
  # exact count.
  expect_true(sum(f$glyphs) %in% 4:5)
})

test_that("a scene with no text has no fonts", {
  expect_equal(
    nrow(scene_fonts(vl_scene(2, 1) |> draw(points_grob(0.5, 0.5)))),
    0L
  )
})

test_that("two families resolve to two faces", {
  s <- vl_scene(4, 2, dpi = 96) |>
    draw(text_grob("a", x = 0.3, gp = vl_gpar(fontfamily = "serif"))) |>
    draw(text_grob("b", x = 0.7, gp = vl_gpar(fontfamily = "mono")))
  expect_gte(nrow(scene_fonts(s)), 2L)
})

test_that("a pin matches its own scene and detects a change", {
  serif <- vl_scene(4, 2, dpi = 96) |>
    draw(text_grob("hello", gp = vl_gpar(fontfamily = "serif")))
  mono <- vl_scene(4, 2, dpi = 96) |>
    draw(text_grob("hello", gp = vl_gpar(fontfamily = "mono")))
  pin <- font_pin(serif)
  expect_equal(nrow(font_check(serif, pin)), 0L)

  diff <- suppressWarnings(font_check(mono, pin))
  expect_gt(nrow(diff), 0L)
  expect_true(all(diff$status %in% c("changed", "missing", "new")))
  expect_true("new" %in% diff$status)
})

test_that("font_check honours on_mismatch", {
  serif <- vl_scene(4, 2, dpi = 96) |>
    draw(text_grob("hello", gp = vl_gpar(fontfamily = "serif")))
  mono <- vl_scene(4, 2, dpi = 96) |>
    draw(text_grob("hello", gp = vl_gpar(fontfamily = "mono")))
  pin <- font_pin(serif)
  expect_warning(font_check(mono, pin), "do not match")
  expect_error(font_check(mono, pin, on_mismatch = "error"), "do not match")
  expect_silent(font_check(mono, pin, on_mismatch = "ignore"))
  # A matching scene never warns, whatever the setting.
  expect_silent(font_check(serif, pin, on_mismatch = "error"))
})

test_that("the pin is insensitive to how much text was set", {
  # The same face used for more glyphs is the same font. A pin that fired on
  # every label change would be ignored within a week.
  short <- vl_scene(4, 2, dpi = 96) |> draw(text_grob("a"))
  long <- vl_scene(4, 2, dpi = 96) |> draw(text_grob("a much longer label"))
  expect_equal(nrow(font_check(long, font_pin(short))), 0L)
})

test_that("font_pin rejects a non-pin and prints legibly", {
  s <- vl_scene(4, 2, dpi = 96) |> draw(text_grob("hi"))
  expect_error(font_check(s, list()), "font_pin")
  # cli writes through the condition system, not stdout, so this is a message.
  expect_message(print(font_pin(s)), "font face")
})
