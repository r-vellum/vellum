# Input validation at the public entry points (VL-4/5/8/9/11/12/13). Every
# error must name the offending argument *and* the user-facing function.

# Expect a cli error from `expr` whose message mentions `arg` in backticks and
# whose call is `fn()`.
expect_entry_error <- function(expr, fn, arg, regexp = NULL) {
  cnd <- tryCatch(
    {
      force(expr)
      NULL
    },
    error = identity
  )
  expect_s3_class(cnd, "rlang_error")
  if (is.null(cnd)) {
    return(invisible())
  }
  msg <- conditionMessage(cnd)
  expect_match(msg, paste0("`", arg, "`"), fixed = TRUE)
  if (!is.null(regexp)) {
    expect_match(msg, regexp)
  }
  expect_identical(as.character(cnd$call[[1]]), fn)
  invisible(cnd)
}

svg_of <- function(s) {
  f <- tempfile(fileext = ".svg")
  on.exit(unlink(f))
  render(s, f)
  readLines(f, warn = FALSE)
}

# --- VL-4 ---------------------------------------------------------------------

test_that("unary minus negates a compound unit's offset", {
  u <- -(vl_unit(1, "native") + vl_unit(2, "mm"))
  expect_identical(format(u), "-1native-2mm")
  expect_equal(vctrs::field(u, "offset"), -2)
  expect_equal(-u, vl_unit(1, "native") + vl_unit(2, "mm"))
  expect_identical(format(-vl_unit(3, "mm")), "-3mm")
})

# --- VL-5 ---------------------------------------------------------------------

test_that("key and meta longer than the element count are errors", {
  expect_entry_error(
    points_grob(1:2 / 3, 0.5, key = c("a", "b", "c")),
    "points_grob",
    "key",
    "length 1 or 2"
  )
  expect_entry_error(
    rect_grob(1:2 / 3, 0.5, meta = list(1, 2, 3)),
    "rect_grob",
    "meta",
    "length 1 or 2"
  )
  expect_length(points_grob(1:2 / 3, 0.5, key = "a")@keys, 2L)
})

# --- VL-8 ---------------------------------------------------------------------

test_that("hit_test() and vl_nearest() validate the probe", {
  s <- vl_scene(2, 2) |> draw(rect_grob(key = "a", name = "r"))
  expect_entry_error(hit_test(s, NA, 0.5), "hit_test", "x")
  expect_entry_error(hit_test(s, 0.5, c(1, 2)), "hit_test", "y")
  expect_entry_error(hit_test(s, "a", 0.5), "hit_test", "x")
  expect_entry_error(hit_test(s, 0.5, 0.5, units = "in"), "hit_test", "units")
  expect_identical(hit_test(s, 0.5, 0.5), "r")

  expect_entry_error(vl_nearest(s, NA, 0.5), "vl_nearest", "x")
  expect_entry_error(vl_nearest(s, 0.5, 0.5, n = NA), "vl_nearest", "n")
  expect_entry_error(vl_nearest(s, 0.5, 0.5, n = 1.5), "vl_nearest", "n")
  expect_entry_error(vl_nearest(s, 0.5, 0.5, n = -1), "vl_nearest", "n")
  expect_entry_error(
    vl_nearest(s, 0.5, 0.5, max_dist = -1),
    "vl_nearest",
    "max_dist"
  )
  expect_entry_error(
    vl_nearest(s, 0.5, 0.5, max_dist = NA),
    "vl_nearest",
    "max_dist"
  )
  expect_identical(vl_nearest(s, 0.5, 0.5, max_dist = Inf)$key, "a")
})

test_that("vl_arrow() validates its arguments", {
  expect_entry_error(vl_arrow(angle = NA), "vl_arrow", "angle")
  expect_entry_error(vl_arrow(angle = c(20, 30)), "vl_arrow", "angle")
  expect_entry_error(vl_arrow(angle = 0), "vl_arrow", "angle")
  expect_entry_error(vl_arrow(ends = "middle"), "vl_arrow", "ends")
  expect_entry_error(vl_arrow(type = "filled"), "vl_arrow", "type")
  expect_s3_class(vl_arrow(length = 0.1), "vellum_arrow")
})

test_that("vl_viewport() validates its arguments", {
  expect_entry_error(vl_viewport(angle = NA), "vl_viewport", "angle")
  expect_entry_error(vl_viewport(angle = c(1, 2)), "vl_viewport", "angle")
  expect_entry_error(vl_viewport(rowspan = NA), "vl_viewport", "rowspan")
  expect_entry_error(vl_viewport(colspan = 0), "vl_viewport", "colspan")
  expect_entry_error(vl_viewport(row = 0), "vl_viewport", "row")
  expect_entry_error(vl_viewport(blur = "a"), "vl_viewport", "blur")
  expect_entry_error(vl_viewport(blur = -1), "vl_viewport", "blur")
  expect_entry_error(vl_viewport(pannable = NA), "vl_viewport", "pannable")
  expect_entry_error(vl_viewport(clip = "yes"), "vl_viewport", "clip")
  expect_entry_error(vl_viewport(blend = "mul"), "vl_viewport", "blend")
  expect_entry_error(vl_viewport(alpha = "a"), "vl_viewport", "alpha")
})

test_that("vl_scene() validates its arguments", {
  expect_entry_error(vl_scene(NA, 2), "vl_scene", "width")
  expect_entry_error(vl_scene(c(2, 3), 2), "vl_scene", "width")
  expect_entry_error(vl_scene(2, vl_unit(1, "npc")), "vl_scene", "height")
  expect_entry_error(vl_scene(dpi = NA), "vl_scene", "dpi")
  expect_entry_error(vl_scene(dpi = "a"), "vl_scene", "dpi")
  expect_entry_error(vl_scene(bg = c("red", "blue")), "vl_scene", "bg")
  expect_entry_error(vl_scene(bg = "nope"), "vl_scene", "bg")
  expect_entry_error(vl_scene(title = 1), "vl_scene", "title")
  expect_entry_error(vl_scene(desc = c("a", "b")), "vl_scene", "desc")
  expect_entry_error(vl_scene(clip = NA), "vl_scene", "clip")
  expect_entry_error(vl_scene(xscale = c(1, NA)), "vl_scene", "xscale")
  expect_entry_error(describe(vl_scene(), title = 1), "describe", "title")
  # Legitimate inputs still work.
  expect_no_error(vl_scene(bg = NA))
  expect_no_error(vl_scene(width = vl_unit(50, "mm"), title = "t"))
})

test_that("vl_gpar() accepts grid's numeric fontface and checks names", {
  expect_identical(vl_gpar(fontface = 2)@fontface, "bold")
  expect_identical(vl_gpar(fontface = 1:4)@fontface, .fontfaces[1:4])
  s <- vl_scene(2, 2) |> draw(text_grob("a", gp = vl_gpar(fontface = 2)))
  expect_true(any(grepl("bold", svg_of(s))))
  expect_entry_error(vl_gpar(fontface = "heavy"), "vl_gpar", "fontface")
  expect_entry_error(vl_gpar(fontface = 5), "vl_gpar", "fontface")
  expect_entry_error(vl_gpar(fontface = NA), "vl_gpar", "fontface")
  expect_identical(vl_gpar(fontface = "bold.italic")@fontface, "bold.italic")
})

# --- VL-9 ---------------------------------------------------------------------

test_that("draw() refuses anything that is not a grob or a list of grobs", {
  s <- vl_scene(2, 2)
  expect_entry_error(draw(s, 1), "draw", "grob")
  expect_entry_error(draw(s, "rect"), "draw", "grob")
  expect_entry_error(draw(s, list(rect_grob(), 1)), "draw", "grob", "Element 2")
  expect_no_error(draw(s, list(rect_grob(), circle_grob())))
  expect_no_error(draw(s, gtree(children = list(rect_grob()))))
})

# --- VL-11 --------------------------------------------------------------------

test_that("sector_grob() supports a per-sector gp$fill vector", {
  s <- vl_scene(1, 1, dpi = 40, bg = "white") |>
    draw(sector_grob(
      theta0 = c(0, pi),
      theta1 = c(pi, 2 * pi),
      r1 = 0.5,
      gp = vl_gpar(fill = c("red", "blue"), col = NA)
    ))
  px <- scene_raster(s)
  expect_equal(px[1:3, 20, 10], c(255L, 0L, 0L)) # top half (theta 0..pi) red
  expect_equal(px[1:3, 20, 30], c(0L, 0L, 255L)) # bottom half blue
  expect_entry_error(
    sector_grob(theta1 = 1:2, gp = vl_gpar(fill = c("red", "blue", "green"))),
    "sector_grob",
    "gp$fill"
  )
  expect_entry_error(
    sector_grob(theta1 = 1:2, fill = c("red", "blue", "green")),
    "sector_grob",
    "fill"
  )
})

test_that("hexagon_grob() also takes a per-hexagon gp$fill vector", {
  s <- vl_scene(1, 1, dpi = 40) |>
    draw(hexagon_grob(
      c(0.3, 0.7),
      0.5,
      gp = vl_gpar(fill = c("red", "blue"))
    ))
  expect_no_error(scene_raster(s))
})

test_that("vl_arrow() rejects relative and negative lengths at construction", {
  expect_entry_error(
    vl_arrow(length = vl_unit(0.1, "npc")),
    "vl_arrow",
    "length",
    "absolute"
  )
  expect_entry_error(
    vl_arrow(length = vl_unit(-1, "mm")),
    "vl_arrow",
    "length",
    "non-negative"
  )
  expect_entry_error(
    vl_arrow(length = vl_unit(1:2, "mm")),
    "vl_arrow",
    "length",
    "single"
  )
})

test_that("text_grob() width/height must be one absolute length", {
  expect_entry_error(
    text_grob("x", width = vl_unit(c(10, 50), "mm")),
    "text_grob",
    "width",
    "single"
  )
  expect_entry_error(
    text_grob("x", height = vl_unit(c(10, 50), "mm")),
    "text_grob",
    "height",
    "single"
  )
  expect_entry_error(
    text_grob("x", width = vl_unit(0.5, "npc")),
    "text_grob",
    "width",
    "absolute"
  )
  expect_equal(text_grob("x", width = vl_unit(1, "in"))@width, 25.4)
})

test_that(".to_inches() validates instead of reading the first element", {
  expect_equal(.to_inches(vl_unit(72, "pt")), 1)
  expect_error(.to_inches(vl_unit(1:2, "in")), "single")
  expect_error(.to_inches(vl_unit(1, "npc")), "absolute")
})

# --- VL-12 --------------------------------------------------------------------

test_that("vl_gpar() range-checks lwd, fontsize and colours", {
  expect_entry_error(vl_gpar(lwd = -1), "vl_gpar", "lwd")
  expect_entry_error(vl_gpar(fontsize = 0), "vl_gpar", "fontsize")
  expect_entry_error(vl_gpar(fontsize = -3), "vl_gpar", "fontsize")
  expect_entry_error(vl_gpar(fontsize = NA), "vl_gpar", "fontsize")
  expect_entry_error(vl_gpar(col = character(0)), "vl_gpar", "col", "empty")
  expect_entry_error(vl_gpar(fill = character(0)), "vl_gpar", "fill", "empty")
  expect_entry_error(vl_gpar(fill = "notacolour"), "vl_gpar", "fill")
  # Legitimate edge values pass.
  expect_no_error(vl_gpar(lwd = 0))
  expect_no_error(vl_gpar(lwd = NA))
  expect_no_error(vl_gpar(col = NA, fill = c("red", NA)))
  expect_no_error(vl_gpar(fill = linear_gradient(c("red", "blue"))))
})

test_that("sector_grob() refuses r0 > r1 and negative radii", {
  expect_entry_error(sector_grob(r0 = 0.5, r1 = 0.2), "sector_grob", "r0")
  expect_entry_error(
    sector_grob(r0 = c(0, 0.4), r1 = c(0.5, 0.3)),
    "sector_grob",
    "r0",
    "Element 2"
  )
  expect_entry_error(sector_grob(r1 = -1), "sector_grob", "r1")
  # Mixed units are not comparable before render, so they pass.
  expect_no_error(sector_grob(r0 = vl_unit(5, "mm"), r1 = 0.1))
  expect_no_error(sector_grob(r0 = 0.3, r1 = 0.3)) # an open arc
})

test_that("loop_grob() refuses a negative width", {
  expect_entry_error(loop_grob(width = -1), "loop_grob", "width")
  expect_entry_error(loop_grob(width = NA), "loop_grob", "width")
  expect_no_error(loop_grob(width = 0))
})

# --- VL-13 --------------------------------------------------------------------

test_that("strwidth units recycle a vector label element-wise", {
  u <- vl_unit(c(1, 1), "strwidth", data = list(label = c("i", "MMMM")))
  w <- vctrs::field(u, "value")
  expect_length(w, 2L)
  expect_gt(w[2], w[1])
  expect_equal(w[1], vl_strwidth("i", unit = "mm"))
  # A scalar label still applies to every value.
  u1 <- vl_unit(1:2, "strwidth", data = list(label = "ab"))
  expect_equal(vctrs::field(u1, "value")[2], 2 * vctrs::field(u1, "value")[1])
  # Mixed with a core unit, the label lines up with the original positions.
  u2 <- vl_unit(c(5, 1), c("mm", "strheight"), data = list(label = c("x", "y")))
  expect_equal(vctrs::field(u2, "value")[1], 5)
  expect_error(
    vl_unit(1:3, "strwidth", data = list(label = c("a", "b"))),
    "length 1 or 3"
  )
})
