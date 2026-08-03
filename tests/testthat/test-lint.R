# Static analysis over the resolved scene. Every rule reads the geometry the
# renderer would draw with, so the tests plant a specific defect and check that
# the matching rule (and only it) fires.

rules_of <- function(x) sort(unique(x$rule))

test_that("a clean scene lints clean", {
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "steelblue", col = NA))) |>
    draw(text_grob("hello", y = 0.85, gp = vl_gpar(fontsize = 14)))
  expect_equal(nrow(vl_lint(s)), 0L)
})

test_that("offscreen catches a mark past the page edge", {
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      x = 2.5,
      width = 0.2,
      height = 0.2,
      gp = vl_gpar(fill = "red")
    ))
  expect_true("offscreen" %in% rules_of(vl_lint(s)))
})

test_that("clipped_away catches a mark outside its viewport's clip", {
  s <- vl_scene(2, 2, dpi = 100) |>
    push(vl_viewport(x = 0.25, width = 0.3, height = 0.3, clip = TRUE)) |>
    # x = 2 npc of a viewport spanning 20..80 px puts it at ~140 px: still on a
    # 200 px page, but well outside the clip. (x = 4 would be off-page too, and
    # would be reported by `offscreen` instead.)
    draw(rect_grob(
      x = 2,
      width = 0.2,
      height = 0.2,
      gp = vl_gpar(fill = "red")
    )) |>
    pop()
  found <- rules_of(vl_lint(s))
  expect_true("clipped_away" %in% found)
  # It is on the page, so it is not also reported as offscreen.
  expect_false("offscreen" %in% found)
})

test_that("truncated catches a label partly cut off by its clip", {
  s <- vl_scene(2, 2, dpi = 100) |>
    push(vl_viewport(width = 0.4, height = 0.4, clip = TRUE)) |>
    draw(text_grob(
      "a long label that overflows",
      gp = vl_gpar(fontsize = 12)
    )) |>
    pop()
  found <- vl_lint(s)
  expect_true("truncated" %in% rules_of(found))
  cut <- found[found$rule == "truncated", , drop = FALSE]
  # A cut label is unreadable, so it is a warning rather than a note.
  expect_equal(cut$severity, "warning")
  expect_match(cut$message, "viewport's clip")
  # It is still partly visible, so the entirely-gone rules must stay quiet.
  expect_false(any(c("offscreen", "clipped_away") %in% rules_of(found)))
})

test_that("truncated catches a mark hanging off the page, as a note", {
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      x = 0.95,
      width = 0.4,
      height = 0.3,
      gp = vl_gpar(fill = "red")
    ))
  found <- vl_lint(s)
  cut <- found[found$rule == "truncated", , drop = FALSE]
  expect_equal(nrow(cut), 1L)
  # A cropped mark is often deliberate, so it is only a note.
  expect_equal(cut$severity, "note")
  expect_match(cut$message, "page edge")
})

test_that("truncated ignores boundary contact and sub-pixel overhang", {
  # A rect filling its own clipped viewport sits exactly on the boundary.
  flush <- vl_scene(4, 3, dpi = 96) |>
    push(vl_viewport(width = 0.8, height = 0.8, clip = TRUE)) |>
    draw(rect_grob(gp = vl_gpar(fill = "grey95", col = "grey40"))) |>
    pop()
  expect_false("truncated" %in% rules_of(vl_lint(flush)))
  # A label a hair from the page edge loses a fraction of a descender row.
  hair <- vl_scene(5, 3, dpi = 96) |>
    draw(text_grob("x axis", x = 0.55, y = 0.02, gp = vl_gpar(fontsize = 10)))
  expect_false("truncated" %in% rules_of(vl_lint(hair)))
})

test_that("truncated treats a batched mark by its whole union box", {
  set.seed(1)
  # A scatter spanning its panel always grazes the clip; that says nothing about
  # any individual point, so it must not fire.
  grazing <- vl_scene(4, 3, dpi = 96) |>
    push(vl_viewport(width = 0.8, height = 0.8, clip = TRUE)) |>
    draw(points_grob(
      runif(200),
      runif(200),
      gp = vl_gpar(fill = "steelblue", col = NA)
    )) |>
    pop()
  expect_false("truncated" %in% rules_of(vl_lint(grazing)))
  # A batch drawn at the wrong scale loses most of its union box, and does.
  wrong <- vl_scene(3, 3, dpi = 96) |>
    push(vl_viewport(width = 0.5, height = 0.5, clip = TRUE)) |>
    draw(points_grob(
      runif(200) * 4 - 1.5,
      runif(200),
      gp = vl_gpar(fill = "red", col = NA)
    )) |>
    pop()
  expect_true("truncated" %in% rules_of(vl_lint(wrong)))
})

test_that("subpixel catches an area mark thinner than a pixel", {
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      width = vl_unit(0.4, "pt"),
      height = 0.5,
      gp = vl_gpar(fill = "red")
    ))
  found <- vl_lint(s)
  expect_true("subpixel" %in% rules_of(found))
  expect_match(
    found$message[found$rule == "subpixel"],
    "thinner than one pixel"
  )
  # A horizontal segment has a zero-height box by construction -- its thickness
  # is `lwd`, not geometry -- so stroke-only kinds are left alone.
  line <- vl_scene(2, 2, dpi = 100) |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, gp = vl_gpar(col = "black")))
  expect_false("subpixel" %in% rules_of(vl_lint(line)))
})

test_that("blank_label catches text with nothing in it", {
  s <- vl_scene(2, 2, dpi = 100) |> draw(text_grob("   "))
  expect_true("blank_label" %in% rules_of(vl_lint(s)))
  ok <- vl_scene(2, 2, dpi = 100) |> draw(text_grob("hello"))
  expect_false("blank_label" %in% rules_of(vl_lint(ok)))
})

test_that("duplicate_name catches an unaddressable node", {
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      width = 0.2,
      height = 0.2,
      gp = vl_gpar(fill = "red"),
      name = "box"
    )) |>
    draw(rect_grob(
      width = 0.3,
      height = 0.3,
      gp = vl_gpar(fill = "blue"),
      name = "box"
    ))
  found <- vl_lint(s)
  dup <- found[found$rule == "duplicate_name", , drop = FALSE]
  # Both nodes are reported: the finding is about the pair.
  expect_equal(nrow(dup), 2L)
  expect_equal(dup$severity, rep("warning", 2))
  expect_match(dup$message[1], "2 nodes share this name")
  # Unnamed nodes are not duplicates of each other.
  anon <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(width = 0.2, height = 0.2, gp = vl_gpar(fill = "red"))) |>
    draw(rect_grob(width = 0.3, height = 0.3, gp = vl_gpar(fill = "blue")))
  expect_false("duplicate_name" %in% rules_of(vl_lint(anon)))
})

test_that("invisible catches elements nothing will paint", {
  none <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      width = 0.5,
      height = 0.5,
      gp = vl_gpar(fill = NA, col = NA)
    ))
  expect_true("invisible" %in% rules_of(vl_lint(none)))
  zero <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      width = 0.5,
      height = 0.5,
      gp = vl_gpar(fill = "red", alpha = 0)
    ))
  expect_true("invisible" %in% rules_of(vl_lint(zero)))
})

test_that("invisible catches a fill that is present but fully transparent", {
  # `has_fill` sees a fill; only the fill's own alpha says it paints nothing.
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      width = 0.4,
      height = 0.4,
      gp = vl_gpar(fill = "#FF000000", col = NA)
    ))
  expect_true("invisible" %in% rules_of(vl_lint(s)))
})

test_that("invisible_fill catches a mark filled in the background colour", {
  s <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(rect_grob(
      width = 0.4,
      height = 0.4,
      gp = vl_gpar(fill = "white", col = NA)
    ))
  expect_true("invisible_fill" %in% rules_of(vl_lint(s)))
  # An outline saves it: white-on-white with a border is a normal thing to draw.
  outlined <- vl_scene(2, 2, dpi = 100, bg = "white") |>
    draw(rect_grob(
      width = 0.4,
      height = 0.4,
      gp = vl_gpar(fill = "white", col = "black")
    ))
  expect_false("invisible_fill" %in% rules_of(vl_lint(outlined)))
  # On a dark page the same fill is perfectly visible.
  dark <- vl_scene(2, 2, dpi = 100, bg = "grey10") |>
    draw(rect_grob(
      width = 0.4,
      height = 0.4,
      gp = vl_gpar(fill = "white", col = NA)
    ))
  expect_false("invisible_fill" %in% rules_of(vl_lint(dark)))
})

test_that("hairline catches a stroke thinner than half a pixel", {
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(segments_grob(
      0.1,
      0.5,
      0.9,
      0.5,
      gp = vl_gpar(col = "black", lwd = 0.3)
    ))
  found <- vl_lint(s)
  expect_true("hairline" %in% rules_of(found))
  expect_match(found$message[found$rule == "hairline"], "0.31 px")
  ok <- vl_scene(2, 2, dpi = 100) |>
    draw(segments_grob(0.1, 0.5, 0.9, 0.5, gp = vl_gpar(col = "black")))
  expect_false("hairline" %in% rules_of(vl_lint(ok)))
})

test_that("bleed catches a mark escaping a viewport that does not clip", {
  s <- vl_scene(4, 3, dpi = 96) |>
    push(vl_viewport(
      x = 0.5,
      y = 0.5,
      width = 0.4,
      height = 0.4,
      clip = FALSE
    )) |>
    draw(rect_grob(
      width = 1.8,
      height = 0.5,
      gp = vl_gpar(fill = "green", col = NA)
    )) |>
    pop()
  found <- vl_lint(s)
  expect_true("bleed" %in% rules_of(found))
  expect_equal(found$severity[found$rule == "bleed"], "note")
  # Clip the same viewport and it is `truncated`'s business, not `bleed`'s.
  clipped <- vl_scene(4, 3, dpi = 96) |>
    push(vl_viewport(
      x = 0.5,
      y = 0.5,
      width = 0.4,
      height = 0.4,
      clip = TRUE
    )) |>
    draw(rect_grob(
      width = 1.8,
      height = 0.5,
      gp = vl_gpar(fill = "green", col = NA)
    )) |>
    pop()
  found2 <- rules_of(vl_lint(clipped))
  expect_false("bleed" %in% found2)
  expect_true("truncated" %in% found2)
  # A mark in the root viewport cannot escape it -- that is the page.
  root <- vl_scene(4, 3, dpi = 96) |>
    draw(rect_grob(
      x = 0.5,
      width = 0.9,
      height = 0.5,
      gp = vl_gpar(fill = "green", col = NA)
    ))
  expect_false("bleed" %in% rules_of(vl_lint(root)))
})

test_that("the node table reports colours that survive the round trip", {
  # `0xRRGGBBAA` does not fit in a signed 32-bit integer once red reaches 128,
  # and packing it there silently ate the red channel of every light colour.
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      width = 0.5,
      height = 0.5,
      gp = vl_gpar(fill = "#EEEEEE", col = "#FF8800")
    ))
  n <- as.data.frame(.scene_to_backend(s)$lint_table())
  expect_equal(.lint_unpack_col(n$fill[1]), c(238, 238, 238, 255))
  expect_equal(.lint_unpack_col(n$col[1]), c(255, 136, 0, 255))
  expect_equal(n$fill_kind[1], "solid")
})

test_that("the node table marks a non-solid fill as such", {
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      width = 0.5,
      height = 0.5,
      gp = vl_gpar(fill = linear_gradient(c("red", "blue")), col = NA)
    ))
  n <- as.data.frame(.scene_to_backend(s)$lint_table())
  # A gradient has no single colour, so `fill` must not pretend otherwise.
  expect_equal(n$fill_kind[1], "linear")
  expect_equal(n$fill[1], 0)
  expect_equal(n$has_fill[1], 1L)
})

test_that("double_draw catches an identical mark drawn twice", {
  s <- vl_scene(3, 2, dpi = 100) |>
    draw(rect_grob(width = 0.4, height = 0.4, gp = vl_gpar(fill = "red"))) |>
    draw(rect_grob(width = 0.4, height = 0.4, gp = vl_gpar(fill = "red")))
  found <- vl_lint(s)
  # Both nodes are reported: neither is the culprit on its own.
  expect_equal(sum(found$rule == "double_draw"), 2L)
})

test_that("double_draw leaves the fill-then-border idiom alone", {
  # Drawing the same box twice is legitimate when the two differ: a filled rect
  # and then the same rect with `fill = NA` to put its border on top.
  s <- vl_scene(3, 2, dpi = 100) |>
    draw(rect_grob(
      width = 0.4,
      height = 0.4,
      gp = vl_gpar(fill = "red", col = NA)
    )) |>
    draw(rect_grob(
      width = 0.4,
      height = 0.4,
      gp = vl_gpar(fill = NA, col = "black")
    ))
  expect_false("double_draw" %in% rules_of(vl_lint(s)))
})

test_that("occluded catches a mark hidden behind a later one", {
  s <- vl_scene(3, 2, dpi = 100) |>
    draw(rect_grob(
      width = 0.3,
      height = 0.3,
      gp = vl_gpar(fill = "red"),
      name = "under"
    )) |>
    draw(rect_grob(
      width = 0.9,
      height = 0.9,
      gp = vl_gpar(fill = "blue"),
      name = "over"
    ))
  found <- vl_lint(s)
  hit <- found[found$rule == "occluded", , drop = FALSE]
  expect_equal(hit$node, "under")
  expect_match(hit$message, "covered by over")
})

test_that("occluded respects paint order and transparency", {
  # The same two rects the other way round: the small one is on top and visible.
  ordered <- vl_scene(3, 2, dpi = 100) |>
    draw(rect_grob(width = 0.9, height = 0.9, gp = vl_gpar(fill = "blue"))) |>
    draw(rect_grob(width = 0.3, height = 0.3, gp = vl_gpar(fill = "red")))
  expect_false("occluded" %in% rules_of(vl_lint(ordered)))
  # A see-through cover hides nothing.
  ghost <- vl_scene(3, 2, dpi = 100) |>
    draw(rect_grob(width = 0.3, height = 0.3, gp = vl_gpar(fill = "red"))) |>
    draw(rect_grob(
      width = 0.9,
      height = 0.9,
      gp = vl_gpar(fill = "blue", alpha = 0.4)
    ))
  expect_false("occluded" %in% rules_of(vl_lint(ghost)))
})

test_that("occluded does not treat a circle's box as a cover", {
  # A circle fills about 79% of its bounding box, so containment in that box is
  # not containment in the circle -- reporting it would be wrong, not just noisy.
  s <- vl_scene(3, 2, dpi = 100) |>
    draw(rect_grob(width = 0.05, height = 0.5, gp = vl_gpar(fill = "red"))) |>
    draw(circle_grob(r = 0.4, gp = vl_gpar(fill = "blue")))
  expect_false("occluded" %in% rules_of(vl_lint(s)))
})

test_that("label_on_mark catches a label swallowing the point it names", {
  s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(circle_grob(
      x = 0.4,
      y = 0.5,
      r = vl_unit(4, "pt"),
      gp = vl_gpar(fill = "steelblue", col = NA),
      name = "pt"
    )) |>
    draw(text_grob("Berlin", x = 0.4, y = 0.5, gp = vl_gpar(fontsize = 10)))
  found <- vl_lint(s)
  expect_true("label_on_mark" %in% rules_of(found))
  expect_match(found$message[found$rule == "label_on_mark"], "vl_repel")
  # Offset clear of the marker, it is fine.
  ok <- vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(circle_grob(
      x = 0.4,
      y = 0.5,
      r = vl_unit(4, "pt"),
      gp = vl_gpar(fill = "steelblue", col = NA)
    )) |>
    draw(text_grob("Berlin", x = 0.4, y = 0.58, gp = vl_gpar(fontsize = 10)))
  expect_false("label_on_mark" %in% rules_of(vl_lint(ok)))
})

test_that("the cross-node rules stay quiet on an ordinary plot", {
  # The noise test. A panel background, bars, value labels above them and a
  # title: text over marks everywhere, and nothing wrong with any of it.
  v <- c(3, 7, 5, 9)
  xs <- seq(0.15, 0.85, length.out = 4)
  s <- vl_scene(5, 3, dpi = 96, bg = "white") |>
    draw(rect_grob(
      x = 0.5,
      y = 0.5,
      width = 0.9,
      height = 0.9,
      gp = vl_gpar(fill = "grey96", col = NA),
      name = "panel"
    )) |>
    draw(rect_grob(
      x = xs,
      y = v / 20,
      width = 0.12,
      height = v / 10,
      gp = vl_gpar(fill = "steelblue", col = NA),
      name = "bars"
    )) |>
    draw(text_grob(
      as.character(v),
      x = xs,
      y = v / 10 + 0.06,
      gp = vl_gpar(fontsize = 10)
    )) |>
    draw(text_grob("Counts", x = 0.5, y = 0.94, gp = vl_gpar(fontsize = 14)))
  expect_equal(nrow(vl_lint(s)), 0L)
})

test_that("tiny_text catches illegible labels and respects the threshold", {
  s <- vl_scene(3, 2, dpi = 100) |>
    draw(text_grob("small", gp = vl_gpar(fontsize = 2)))
  expect_true("tiny_text" %in% rules_of(vl_lint(s)))
  # Lower both floors below the rendered size and it stops firing.
  expect_false(
    "tiny_text" %in% rules_of(vl_lint(s, min_text_px = 1, min_text_pt = 1))
  )
  # Lowering only one is not enough: the rule fires on either floor.
  expect_true("tiny_text" %in% rules_of(vl_lint(s, min_text_px = 1)))
})

test_that("tiny_text catches illegible text at print resolution", {
  # 4 pt is unreadable on paper, but at 300 dpi it is 16.7 device px -- well
  # clear of the pixel floor, so only the point floor can see it.
  s <- vl_scene(3, 2, dpi = 300) |>
    draw(text_grob("4pt caption", gp = vl_gpar(fontsize = 4)))
  found <- vl_lint(s)
  expect_true("tiny_text" %in% rules_of(found))
  expect_match(found$message[found$rule == "tiny_text"], "pt legibility floor")
  # The same label at a size that reads on paper is left alone.
  ok <- vl_scene(3, 2, dpi = 300) |>
    draw(text_grob("9pt caption", gp = vl_gpar(fontsize = 9)))
  expect_false("tiny_text" %in% rules_of(vl_lint(ok)))
})

test_that("label_overlap catches colliding labels only when they collide", {
  clash <- vl_scene(3, 2, dpi = 100) |>
    draw(text_grob(
      "aaaaaaaa",
      x = 0.5,
      y = 0.5,
      gp = vl_gpar(fontsize = 20)
    )) |>
    draw(text_grob("bbbbbbbb", x = 0.52, y = 0.5, gp = vl_gpar(fontsize = 20)))
  expect_true("label_overlap" %in% rules_of(vl_lint(clash)))
  apart <- vl_scene(3, 2, dpi = 100) |>
    draw(text_grob("aaa", x = 0.15, y = 0.2, gp = vl_gpar(fontsize = 10))) |>
    draw(text_grob("bbb", x = 0.85, y = 0.8, gp = vl_gpar(fontsize = 10)))
  expect_false("label_overlap" %in% rules_of(vl_lint(apart)))
})

test_that("font_fallback catches a character no font on this machine can draw", {
  # System-dependent by nature -- that a glyph is missing *here* is the whole
  # point of the rule -- so ask the shaper first and skip where it resolves.
  s <- vl_scene(3, 1, dpi = 96) |>
    draw(text_grob("\U0002A6B2 label"))
  n <- as.data.frame(.scene_to_backend(s)$lint_table())
  skip_if(n$notdef[1] == 0L, "a font on this machine covers U+2A6B2")
  found <- vl_lint(s)
  expect_true("font_fallback" %in% rules_of(found))
  hit <- found[found$rule == "font_fallback", , drop = FALSE]
  expect_equal(hit$severity, "warning")
  expect_match(hit$message, "tofu")
  # Ordinary text is left alone.
  ok <- vl_scene(3, 1, dpi = 96) |> draw(text_grob("plain latin text"))
  expect_false("font_fallback" %in% rules_of(vl_lint(ok)))
})

test_that("the node table counts notdef glyphs per text node", {
  s <- vl_scene(3, 1, dpi = 96) |>
    draw(text_grob("ok")) |>
    draw(text_grob("\U0002A6B2 x", y = 0.2)) |>
    draw(rect_grob(width = 0.1, height = 0.1))
  n <- as.data.frame(.scene_to_backend(s)$lint_table())
  expect_equal(n$notdef[1], 0L)
  # Non-text nodes have no glyphs to be missing.
  expect_equal(n$notdef[3], 0L)
  skip_if(n$notdef[2] == 0L, "a font on this machine covers U+2A6B2")
  expect_equal(n$notdef[2], 1L)
})

bars_of <- function(cols, w = 0.06) {
  s <- vl_scene(6, 3, dpi = 96, bg = "white")
  xs <- seq(0.08, 0.92, length.out = length(cols))
  for (i in seq_along(cols)) {
    s <- draw(
      s,
      rect_grob(
        x = xs[i],
        y = 0.3,
        width = w,
        height = 0.5,
        gp = vl_gpar(fill = cols[i], col = NA)
      )
    )
  }
  s
}

test_that("cvd_collision catches a palette that collapses", {
  # ggplot2's default three-colour palette: red and green sit 0.325 apart in
  # normal vision and 0.048 apart under deuteranopia.
  found <- vl_lint(bars_of(c("#F8766D", "#00BA38", "#619CFF")))
  hit <- found[found$rule == "cvd_collision", , drop = FALSE]
  expect_equal(nrow(hit), 1L)
  expect_equal(hit$severity, "warning")
  expect_match(hit$message, "#F8766D and #00BA38")
  expect_match(hit$message, "deuteranopia")
})

test_that("cvd_collision leaves CVD-safe palettes alone", {
  # The regression that matters most: a rule that flags Okabe-Ito or viridis is
  # a rule nobody will leave switched on. Okabe-Ito's closest pair holds at
  # 0.075 under deuteranopia, viridis's at 0.212.
  okabe <- c("#E69F00", "#56B4E9", "#009E73", "#CC79A7", "#0072B2", "#D55E00")
  expect_false("cvd_collision" %in% rules_of(vl_lint(bars_of(okabe, w = 0.04))))
  viridis <- c("#440154", "#31688E", "#35B779", "#FDE725")
  expect_false("cvd_collision" %in% rules_of(vl_lint(bars_of(viridis))))
})

test_that("cvd_collision can be pointed at other deficiencies, or switched off", {
  s <- bars_of(c("#D62728", "#2CA02C"))
  expect_false("cvd_collision" %in% rules_of(vl_lint(s, cvd = "none")))
  # Red and green survive protanopia in this metric (0.207 apart) and collapse
  # under deuteranopia (0.041), so asking for both reports once.
  both <- vl_lint(s, cvd = c("deuteranopia", "protanopia"))
  expect_equal(sum(both$rule == "cvd_collision"), 1L)
  expect_error(vl_lint(s, cvd = "nope"), "Unknown")
})

test_that("cvd_collision caps a self-colliding ramp and says how many it dropped", {
  # A 40-step red-to-green diverging scale collides with itself 57 times, and 57
  # findings about one palette communicate nothing.
  ramp <- grDevices::colorRampPalette(c("#B2182B", "#F7F7F7", "#1A9850"))(40)
  found <- vl_lint(bars_of(ramp, w = 0.02))
  hit <- found[found$rule == "cvd_collision", , drop = FALSE]
  expect_equal(nrow(hit), 6L)
  expect_match(hit$message[nrow(hit)], "further colour pairs? also collapse")
})

test_that("cvd_collision ignores translucent and non-solid fills", {
  # A translucent fill's perceived colour is its composite with the backdrop,
  # which is not the value in the node table, so the rule must not guess.
  faded <- vl_scene(6, 3, dpi = 96, bg = "white") |>
    draw(rect_grob(
      x = 0.3,
      width = 0.2,
      height = 0.5,
      gp = vl_gpar(fill = "#F8766D80", col = NA)
    )) |>
    draw(rect_grob(
      x = 0.7,
      width = 0.2,
      height = 0.5,
      gp = vl_gpar(fill = "#00BA3880", col = NA)
    ))
  expect_false("cvd_collision" %in% rules_of(vl_lint(faded)))
  # A gradient has no single colour either.
  grad <- vl_scene(6, 3, dpi = 96, bg = "white") |>
    draw(rect_grob(
      x = 0.3,
      width = 0.2,
      height = 0.5,
      gp = vl_gpar(fill = linear_gradient(c("#F8766D", "#00BA38")), col = NA)
    )) |>
    draw(rect_grob(
      x = 0.7,
      width = 0.2,
      height = 0.5,
      gp = vl_gpar(fill = "#00BA38", col = NA)
    ))
  expect_false("cvd_collision" %in% rules_of(vl_lint(grad)))
})

test_that("cvd simulation in the linter matches what render() draws", {
  # The linter must not carry a second, drifting copy of the CVD matrices.
  hex <- "#F8766D"
  packed <- {
    m <- grDevices::col2rgb(hex)
    m[1] * 2^24 + m[2] * 2^16 + m[3] * 2^8 + 255
  }
  lab <- rs_cvd_oklab(packed, "deuteranopia")
  # Render a solid page of that colour with the same simulation and convert the
  # resulting pixel through the same path.
  s <- vl_scene(1, 1, dpi = 32, bg = hex)
  px <- .scene_to_backend(s)$rgba()
  rs_set_cvd_mode("deuteranopia")
  on.exit(rs_set_cvd_mode(""), add = TRUE)
  s2 <- vl_scene(1, 1, dpi = 32, bg = hex)
  px2 <- .scene_to_backend(s2)$rgba()[1:4]
  rs_set_cvd_mode("")
  drawn <- px2[1] * 2^24 + px2[2] * 2^16 + px2[3] * 2^8 + 255
  expect_equal(rs_cvd_oklab(drawn, ""), lab, tolerance = 1e-6)
  expect_false(identical(px[1:4], px2))
})

test_that("the overlap sweep agrees with the all-pairs check it replaced", {
  # The rewrite that matters: `label_overlap` used to compare every pair in
  # interpreted R. This is the equivalence test that keeps the sweep honest.
  naive <- function(txt) {
    hit <- rep(FALSE, nrow(txt))
    for (i in seq_len(nrow(txt) - 1L)) {
      for (j in seq(i + 1L, nrow(txt))) {
        if (
          txt$x0[i] < txt$x1[j] &&
            txt$x1[i] > txt$x0[j] &&
            txt$y0[i] < txt$y1[j] &&
            txt$y1[i] > txt$y0[j]
        ) {
          hit[i] <- TRUE
          hit[j] <- TRUE
        }
      }
    }
    hit
  }
  set.seed(42)
  n <- 120
  x <- runif(n)
  y <- runif(n)
  s <- vl_scene(6, 4, dpi = 96)
  for (i in seq_len(n)) {
    s <- draw(
      s,
      text_grob(
        sprintf("lbl%d", i),
        x = x[i],
        y = y[i],
        gp = vl_gpar(fontsize = 9)
      )
    )
  }
  txt <- as.data.frame(.scene_to_backend(s)$lint_table())
  pairs <- .lint_box_pairs(txt)
  swept <- rep(FALSE, nrow(txt))
  swept[unique(as.vector(pairs))] <- TRUE
  expect_identical(swept, naive(txt))
  # And the scene really does have collisions, so this is not a vacuous pass.
  expect_gt(sum(swept), 0L)
})

test_that("the overlap sweep handles edges, padding and degenerate input", {
  boxes <- function(...) as.numeric(c(...))
  # Sharing an edge exactly is not an overlap.
  expect_length(rs_box_overlaps(boxes(0, 0, 10, 10, 10, 0, 20, 10), 0), 0L)
  # Padding closes a gap.
  expect_equal(
    rs_box_overlaps(boxes(0, 0, 10, 10, 12, 0, 20, 10), 0),
    integer()
  )
  expect_equal(
    rs_box_overlaps(boxes(0, 0, 10, 10, 12, 0, 20, 10), 2),
    c(1L, 2L)
  )
  # Overlap in x but not y is not an overlap.
  expect_length(rs_box_overlaps(boxes(0, 0, 10, 10, 5, 50, 15, 60), 0), 0L)
  # Pairs come back low index first, and one box cannot collide with itself.
  expect_equal(rs_box_overlaps(boxes(5, 5, 15, 15, 0, 0, 10, 10), 0), c(1L, 2L))
  expect_length(rs_box_overlaps(boxes(0, 0, 10, 10), 0), 0L)
  expect_length(rs_box_overlaps(numeric(), 0), 0L)
  # Three mutually overlapping boxes give all three pairs.
  all3 <- rs_box_overlaps(boxes(0, 0, 10, 10, 1, 1, 11, 11, 2, 2, 12, 12), 0)
  expect_equal(length(all3), 6L)
})

test_that("low_contrast measures text against its actual backdrop", {
  faint <- vl_scene(3, 2, dpi = 100, bg = "white") |>
    draw(text_grob("faint", gp = vl_gpar(col = "#EEEEEE", fontsize = 20)))
  expect_true("low_contrast" %in% rules_of(vl_lint(faint)))
  # Same colour, dark page: now it is perfectly readable.
  ok <- vl_scene(3, 2, dpi = 100, bg = "grey10") |>
    draw(text_grob("faint", gp = vl_gpar(col = "#EEEEEE", fontsize = 20)))
  expect_false("low_contrast" %in% rules_of(vl_lint(ok)))
})

test_that("findings carry the grob name when there is one", {
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      x = 3,
      width = 0.2,
      gp = vl_gpar(fill = "red"),
      name = "stray"
    ))
  expect_true("stray" %in% vl_lint(s)$node)
})

test_that("overplotted names the layer that is too dense", {
  set.seed(1)
  # 20000 points in a panel paints an average pixel ~38 times.
  dense <- vl_scene(4, 3, dpi = 96) |>
    draw(points_grob(runif(20000), runif(20000), name = "cloud"))
  found <- vl_lint(dense)
  hit <- found[found$rule == "overplotted", , drop = FALSE]
  expect_equal(hit$node, "cloud")
  expect_match(hit$message, "datashade")
  # A few thousand well-spread points sit around 4, and are left alone.
  ok <- vl_scene(4, 3, dpi = 96) |>
    draw(points_grob(runif(2000), runif(2000)))
  expect_false("overplotted" %in% rules_of(vl_lint(ok)))
  # The threshold is the caller's to move.
  expect_true("overplotted" %in% rules_of(vl_lint(ok, max_overplot = 2)))
})

test_that("ctx$region reads a block of composited pixels", {
  withr::defer(rm("probe", envir = .lint_rules))
  seen <- NULL
  vl_lint_rule(
    "probe",
    function(scene, nodes, ctx) {
      seen <<- list(block = ctx$region(40, 40, 42, 41), one = ctx$pixel(41, 40))
      NULL
    },
    "probe"
  )
  s <- vl_scene(1, 1, dpi = 100, bg = "white") |>
    draw(rect_grob(gp = vl_gpar(fill = "black", col = NA)))
  vl_lint(s, rules = "probe")
  # 3 x 2 pixels, one row each, RGBA columns.
  expect_equal(dim(seen$block), c(6L, 4L))
  expect_equal(colnames(seen$block), c("r", "g", "b", "a"))
  # All inside the black rect, and agreeing with the single-pixel sampler.
  expect_equal(nrow(unique(seen$block)), 1L)
  expect_equal(as.numeric(seen$block[1, ]), c(0, 0, 0, 255))
  expect_equal(as.numeric(seen$one), as.numeric(seen$block[2, ]))
})

test_that("ctx$elements gives the per-element view of a batch", {
  withr::defer(rm("probe", envir = .lint_rules))
  seen <- NULL
  vl_lint_rule(
    "probe",
    function(scene, nodes, ctx) {
      seen <<- list(el = ctx$elements(), nodes = nodes)
      NULL
    },
    "probe"
  )
  s <- vl_scene(3, 2, dpi = 96) |>
    draw(points_grob(c(0.2, 0.5, 0.8), c(0.5, 0.5, 0.5)))
  vl_lint(s, rules = "probe")
  # One node, three elements.
  expect_equal(nrow(seen$nodes), 1L)
  expect_equal(nrow(seen$el), 3L)
  expect_true(all(c("node", "x0", "y1") %in% names(seen$el)))
})

test_that("a rule declaring kinds is skipped when the scene has none", {
  withr::defer(rm("hexes", envir = .lint_rules))
  ran <- FALSE
  vl_lint_rule(
    "hexes",
    function(scene, nodes, ctx) {
      ran <<- TRUE
      NULL
    },
    "hexagons only",
    kinds = "hexagon"
  )
  vl_lint(
    vl_scene(2, 2, dpi = 96) |> draw(rect_grob(width = 0.2, height = 0.2))
  )
  expect_false(ran)
  vl_lint(vl_scene(2, 2, dpi = 96) |> draw(hexagon_grob(0.5, 0.5, r = 0.2)))
  expect_true(ran)
})

test_that("vl_lint_rules reports the rule metadata", {
  meta <- vl_lint_rules()
  expect_true(all(c("kinds", "needs_pixels", "tags") %in% names(meta)))
  # `low_contrast` is the one built-in rule that has to render the scene.
  expect_true(meta$needs_pixels[meta$rule == "low_contrast"])
  expect_false(meta$needs_pixels[meta$rule == "offscreen"])
  expect_equal(meta$kinds[meta$rule == "tiny_text"], "text")
})

test_that("severity can be overridden per rule", {
  s <- vl_scene(3, 2, dpi = 100) |>
    draw(text_grob("small", gp = vl_gpar(fontsize = 2)))
  expect_equal(
    unique(vl_lint(s)$severity[vl_lint(s)$rule == "tiny_text"]),
    "warning"
  )
  quiet <- vl_lint(s, severity = c(tiny_text = "note"))
  expect_equal(quiet$severity[quiet$rule == "tiny_text"], "note")
  expect_error(
    vl_lint(s, severity = c(tiny_text = "fatal")),
    "Severity must be"
  )
  expect_error(vl_lint(s, severity = "note"), "named character vector")
})

test_that("rules can be selected, and an unknown one errors", {
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(text_grob("x", x = 3, gp = vl_gpar(fontsize = 2)))
  only <- vl_lint(s, rules = "tiny_text")
  expect_equal(rules_of(only), "tiny_text")
  expect_error(vl_lint(s, rules = "no_such_rule"), "Unknown lint rule")
})

test_that("a downstream package can register its own rule", {
  withr::defer(rm("test_rule", envir = .lint_rules))
  vl_lint_rule(
    "test_rule",
    function(scene, nodes, ctx) {
      vl_lint_finding(
        "test_rule",
        "note",
        nodes[nodes$kind == "circle", , drop = FALSE],
        "a circle was found"
      )
    },
    "test"
  )
  expect_true("test_rule" %in% vl_lint_rules()$rule)
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(circle_grob(gp = vl_gpar(fill = "red")))
  expect_true("test_rule" %in% rules_of(vl_lint(s)))
})

test_that("findings carry the node's device box", {
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      x = 3,
      width = 0.2,
      height = 0.2,
      gp = vl_gpar(fill = "red"),
      name = "stray"
    ))
  found <- vl_lint(s)
  box <- found[found$node == "stray", c("x0", "y0", "x1", "y1")][1, ]
  expect_true(all(is.finite(unlist(box))))
  # x = 3 npc of a 200 px page is 600 px, so the box is off to the right.
  expect_gt(box$x0, 200)
})

test_that("a rule that fails is reported, not fatal", {
  withr::defer(rm("boom", envir = .lint_rules))
  vl_lint_rule("boom", function(scene, nodes, ctx) stop("kaboom"), "explodes")
  s <- vl_scene(2, 2, dpi = 100) |> draw(text_grob("x", x = 5))
  found <- vl_lint(s)
  expect_true("rule_error" %in% found$rule)
  err <- found[found$rule == "rule_error", , drop = FALSE]
  expect_equal(err$node, "boom")
  expect_match(err$message, "kaboom")
  # The other rules still ran.
  expect_true("offscreen" %in% found$rule)
})

test_that("a rule returning the wrong shape is reported as a rule error", {
  withr::defer(rm("wrong", envir = .lint_rules))
  vl_lint_rule(
    "wrong",
    function(scene, nodes, ctx) data.frame(oops = 1),
    "bad shape"
  )
  found <- vl_lint(vl_scene(2, 2, dpi = 100))
  expect_true("rule_error" %in% found$rule)
  expect_match(found$message[found$rule == "rule_error"], "required column")
})

test_that("a rule can hand-build a finding without the geometry columns", {
  withr::defer(rm("bare", envir = .lint_rules))
  vl_lint_rule(
    "bare",
    function(scene, nodes, ctx) {
      data.frame(
        rule = "bare",
        severity = "note",
        node = "somewhere",
        message = "no geometry here",
        stringsAsFactors = FALSE
      )
    },
    "minimal"
  )
  found <- vl_lint(vl_scene(2, 2, dpi = 100))
  expect_equal(nrow(found), 1L)
  expect_true(is.na(found$x0))
})

test_that("exclude drops findings for a node you have accepted", {
  s <- vl_scene(3, 2, dpi = 96) |>
    draw(text_grob("off the edge", x = 1.6, y = 0.5, name = "stray")) |>
    draw(text_grob(
      "tiny",
      x = 0.5,
      y = 0.2,
      gp = vl_gpar(fontsize = 2),
      name = "small"
    ))
  expect_equal(rules_of(vl_lint(s)), c("offscreen", "tiny_text"))
  expect_equal(rules_of(vl_lint(s, exclude = "stray")), "tiny_text")
  expect_equal(nrow(vl_lint(s, exclude = c("stray", "small"))), 0L)
  # A stale exclude list looks exactly like a working one, so it says so.
  expect_warning(vl_lint(s, exclude = "strya"), "matches nothing")
})

test_that("vl_lint_assert fails on findings and passes a clean scene", {
  s <- vl_scene(3, 2, dpi = 96) |>
    draw(text_grob("off the edge", x = 1.6, y = 0.5, name = "stray"))
  expect_error(vl_lint_assert(s), "lint finding")
  expect_error(vl_lint_assert(s), "offscreen")
  expect_warning(vl_lint_assert(s, on = "warn"), "lint finding")
  # Arguments pass through to `vl_lint()`, so a suppressed scene asserts clean.
  expect_silent(vl_lint_assert(s, exclude = "stray"))
  clean <- vl_scene(3, 2, dpi = 96) |>
    draw(text_grob("fine", gp = vl_gpar(fontsize = 12)))
  expect_equal(nrow(vl_lint_assert(clean)), 0L)
})

test_that("vl_lint_assert can be made to fail on notes too", {
  # A note-only scene: a mark cropped by the page edge.
  s <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(
      x = 0.95,
      width = 0.4,
      height = 0.3,
      gp = vl_gpar(fill = "red")
    ))
  expect_equal(unique(vl_lint(s)$severity), "note")
  expect_silent(vl_lint_assert(s))
  expect_error(vl_lint_assert(s, severity = "note"), "lint finding")
})

test_that("vl_lint_assert survives a rule message containing braces", {
  # A finding's message is data, not a glue template.
  withr::defer(rm("bracey", envir = .lint_rules))
  vl_lint_rule(
    "bracey",
    function(scene, nodes, ctx) {
      vl_lint_finding(
        "bracey",
        "warning",
        nodes[1, , drop = FALSE],
        "a {brace} here"
      )
    },
    "braces"
  )
  s <- vl_scene(2, 2, dpi = 96) |> draw(rect_grob(width = 0.2, height = 0.2))
  expect_error(vl_lint_assert(s, rules = "bracey"), "brace")
})

test_that("vl_lint_overlay boxes every finding that has geometry", {
  s <- vl_scene(3, 2, dpi = 96) |>
    draw(text_grob("off the edge", x = 1.6, y = 0.5, name = "stray")) |>
    draw(text_grob(
      "tiny",
      x = 0.5,
      y = 0.2,
      gp = vl_gpar(fontsize = 2),
      name = "small"
    ))
  ov <- vl_lint_overlay(s)
  nms <- node_names(ov)
  expect_equal(sum(grepl("^lint_box_", nms)), 2L)
  expect_equal(sum(grepl("^lint_label_", nms)), 2L)
  expect_false(any(grepl(
    "^lint_label_",
    node_names(vl_lint_overlay(s, labels = FALSE))
  )))
  # It renders.
  expect_gt(length(scene_png(ov)), 0L)
})

test_that("vl_lint_overlay draws at page level, not inside a pushed viewport", {
  # A scene left inside a viewport would otherwise get the overlay in that
  # viewport's coordinates, while the boxes are in page npc.
  s <- vl_scene(3, 2, dpi = 96) |>
    push(vl_viewport(x = 0.3, y = 0.3, width = 0.3, height = 0.3)) |>
    draw(text_grob("tiny", gp = vl_gpar(fontsize = 2), name = "small"))
  n <- as.data.frame(.scene_to_backend(vl_lint_overlay(s))$lint_table())
  mark <- n[n$name == "small", , drop = FALSE]
  box <- n[n$name == "lint_box_1", , drop = FALSE]
  # Different viewports, and the box still surrounds the mark it points at.
  expect_false(box$vp == mark$vp)
  expect_lt(box$x0, mark$x0)
  expect_gt(box$x1, mark$x1)
})

test_that("vl_lint_overlay merges findings that share a box and skips geometry-free ones", {
  # One label that is both too small and too faint gets one box naming both.
  s <- vl_scene(3, 2, dpi = 96, bg = "white") |>
    draw(text_grob(
      "faint",
      gp = vl_gpar(fontsize = 4, col = "#F4F4F4"),
      name = "t"
    ))
  found <- vl_lint(s)
  expect_gt(length(unique(found$rule)), 1L)
  ov <- vl_lint_overlay(s)
  expect_equal(sum(grepl("^lint_box_", node_names(ov))), 1L)
  # A finding with no geometry has nothing to point at.
  bare <- found[1, , drop = FALSE]
  bare[, c("x0", "y0", "x1", "y1")] <- NA_real_
  expect_equal(node_names(vl_lint_overlay(s, bare)), "t")
})

test_that("the print method summarises without erroring", {
  # cli writes through conditions rather than stdout, so capture that stream
  # instead of using expect_output.
  s <- vl_scene(2, 2, dpi = 100) |> draw(text_grob("x", x = 5))
  found <- vl_lint(s)
  out <- paste(capture.output(print(found), type = "message"), collapse = " ")
  expect_match(out, "offscreen")
  clean <- paste(
    capture.output(print(vl_lint(vl_scene(1, 1))), type = "message"),
    collapse = " "
  )
  expect_match(clean, "No lint findings")
  expect_identical(print(found), found)
})
