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
    draw(rect_grob(x = 2.5, width = 0.2, height = 0.2, gp = vl_gpar(fill = "red")))
  expect_true("offscreen" %in% rules_of(vl_lint(s)))
})

test_that("clipped_away catches a mark outside its viewport's clip", {
  s <- vl_scene(2, 2, dpi = 100) |>
    push(vl_viewport(x = 0.25, width = 0.3, height = 0.3, clip = TRUE)) |>
    # x = 2 npc of a viewport spanning 20..80 px puts it at ~140 px: still on a
    # 200 px page, but well outside the clip. (x = 4 would be off-page too, and
    # would be reported by `offscreen` instead.)
    draw(rect_grob(x = 2, width = 0.2, height = 0.2, gp = vl_gpar(fill = "red"))) |>
    pop()
  found <- rules_of(vl_lint(s))
  expect_true("clipped_away" %in% found)
  # It is on the page, so it is not also reported as offscreen.
  expect_false("offscreen" %in% found)
})

test_that("invisible catches elements nothing will paint", {
  none <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(width = 0.5, height = 0.5, gp = vl_gpar(fill = NA, col = NA)))
  expect_true("invisible" %in% rules_of(vl_lint(none)))
  zero <- vl_scene(2, 2, dpi = 100) |>
    draw(rect_grob(width = 0.5, height = 0.5, gp = vl_gpar(fill = "red", alpha = 0)))
  expect_true("invisible" %in% rules_of(vl_lint(zero)))
})

test_that("tiny_text catches illegible labels and respects the threshold", {
  s <- vl_scene(3, 2, dpi = 100) |>
    draw(text_grob("small", gp = vl_gpar(fontsize = 2)))
  expect_true("tiny_text" %in% rules_of(vl_lint(s)))
  # Lower the floor below the rendered size and it stops firing.
  expect_false("tiny_text" %in% rules_of(vl_lint(s, min_text_px = 1)))
})

test_that("label_overlap catches colliding labels only when they collide", {
  clash <- vl_scene(3, 2, dpi = 100) |>
    draw(text_grob("aaaaaaaa", x = 0.5, y = 0.5, gp = vl_gpar(fontsize = 20))) |>
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
    draw(rect_grob(x = 3, width = 0.2, gp = vl_gpar(fill = "red"), name = "stray"))
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
  withr::defer(rm("test_rule", envir = vellum:::.lint_rules))
  vl_lint_rule("test_rule", function(scene, nodes, ctx) {
    vl_lint_finding("test_rule", "note", nodes[nodes$kind == "circle", , drop = FALSE],
                    "a circle was found")
  }, "test")
  expect_true("test_rule" %in% vl_lint_rules()$rule)
  s <- vl_scene(2, 2, dpi = 100) |> draw(circle_grob(gp = vl_gpar(fill = "red")))
  expect_true("test_rule" %in% rules_of(vl_lint(s)))
})

test_that("the print method summarises without erroring", {
  # cli writes through conditions rather than stdout, so capture that stream
  # instead of using expect_output.
  s <- vl_scene(2, 2, dpi = 100) |> draw(text_grob("x", x = 5))
  found <- vl_lint(s)
  out <- paste(capture.output(print(found), type = "message"), collapse = " ")
  expect_match(out, "offscreen")
  clean <- paste(capture.output(print(vl_lint(vl_scene(1, 1))), type = "message"),
                 collapse = " ")
  expect_match(clean, "No lint findings")
  expect_identical(print(found), found)
})
