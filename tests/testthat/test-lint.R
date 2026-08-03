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
