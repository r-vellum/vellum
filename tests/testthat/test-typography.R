# Phase 10: the typography layer -- width-constrained text and text on a path.

# Column indices of inked pixels (anything materially darker than the white
# page), and the row groups they fall in. Used to assert layout rather than
# exact glyph rendering, which is font-dependent.
inked <- function(scene, thresh = 200) {
  r <- scene_raster(scene)
  r[1, , ] < thresh
}
# Row bands occupied by text, as contiguous runs of inked rows.
#
# Only good enough for counting bands. Do NOT use it to locate individual lines:
# a descender can form a band of its own, which made an earlier version of the
# alignment tests pass on macOS and fail on Linux.
row_bands <- function(scene) {
  rows <- which(apply(inked(scene), 2, any))
  if (!length(rows)) {
    return(list())
  }
  unname(split(rows, cumsum(c(1, diff(rows) > 1))))
}
# Leftmost inked column in each band. Pass `bands` explicitly when comparing
# alignments: they share identical line breaks and vertical positions, so the
# bands must come from one reference render or the vectors will not line up
# (descenders can fuse two lines into one band in some alignments and not
# others, which silently recycles the comparison).
line_starts <- function(scene, bands = row_bands(scene)) {
  d <- inked(scene)
  vapply(bands, function(rr) {
    hit <- which(apply(d[, rr, drop = FALSE], 1, any))
    if (length(hit)) min(hit) else NA_integer_
  }, integer(1), USE.NAMES = FALSE)
}
ink_box <- function(scene) {
  d <- inked(scene)
  cols <- which(apply(d, 1, any))
  rows <- which(apply(d, 2, any))
  if (!length(cols)) {
    return(c(NA, NA, NA, NA))
  }
  c(min(cols), max(cols), min(rows), max(rows))
}

LONG <- "The quick brown fox jumps over the lazy dog and keeps on running"
wrapped <- function(...) {
  vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(text_grob(LONG, gp = vl_gpar(fontsize = 10), ...))
}

test_that("width wraps a label onto several lines inside the box", {
  plain <- vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(text_grob(LONG, gp = vl_gpar(fontsize = 10)))
  w <- wrapped(width = vl_unit(50, "mm"))

  # Unwrapped, the label is wider than the 4in page and runs off both edges.
  # Wrapped, it fits inside 50mm (189px at 96dpi) with room to spare.
  expect_gt(diff(ink_box(plain)[1:2]), 370)
  expect_lt(diff(ink_box(w)[1:2]), 189)
  # ...and gains lines: taller than a single line, shorter than the page.
  expect_gt(diff(ink_box(w)[3:4]), diff(ink_box(plain)[3:4]))
  expect_gt(length(line_starts(w)), 1L)
})

test_that("a wrapped label never renders wider than the width it was given", {
  # The break decision is made on shaped widths, so this is a guarantee, not a
  # tendency. Check it across sizes and widths.
  for (mm in c(25, 40, 60)) {
    for (fs in c(8, 12, 18)) {
      s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
        draw(text_grob(LONG, gp = vl_gpar(fontsize = fs), width = vl_unit(mm, "mm"),
                       just = c("left", "top"), x = 0.02, y = 0.98))
      px <- mm / 25.4 * 96
      expect_lte(diff(ink_box(s)[1:2]), px + 2,
                 label = sprintf("width %gmm at %gpt", mm, fs))
    }
  }
})

test_that("align places a line against the right edge of the box", {
  # Deliberately a SINGLE short line in a wide box, so this tests alignment and
  # nothing else. The earlier version measured per-line ink of a wrapped
  # paragraph, which depended on where the font happened to break the lines and
  # on a row-banding heuristic that a descender could split -- it passed on
  # macOS and failed on Linux for reasons that had nothing to do with alignment.
  box_mm <- 60
  box_px <- box_mm / 25.4 * 96
  one <- function(align) {
    s <- vl_scene(4, 1.2, dpi = 96, bg = "white") |>
      draw(text_grob("xx", x = 0.5, y = 0.5, width = vl_unit(box_mm, "mm"),
                     align = align, gp = vl_gpar(fontsize = 12)))
    ink_box(s)[1:2]
  }
  page_mid <- 4 * 96 / 2
  box_lo <- page_mid - box_px / 2
  box_hi <- page_mid + box_px / 2
  tol <- 4 # glyph side bearings differ between fonts

  l <- one("left")
  r <- one("right")
  c_ <- one("centre")
  expect_lt(abs(l[1] - box_lo), tol) # flush left
  expect_lt(abs(r[2] - box_hi), tol) # flush right
  expect_lt(abs(mean(c_) - page_mid), tol) # centred
  # And they are genuinely different placements, in the expected order.
  expect_lt(l[1], c_[1])
  expect_lt(c_[1], r[1])
})

test_that("align is applied per line, not to the block", {
  # Hard newlines, so the line partition is fixed whatever the font does. A
  # left-aligned block of unequal lines is ragged on the right; a right-aligned
  # one is ragged on the left. Compare the two renders rather than trying to
  # locate individual lines in the pixels.
  lab <- "x\nxxxx\nxxxxxxxx"
  mk <- function(align) {
    vl_scene(4, 1.6, dpi = 96, bg = "white") |>
      draw(text_grob(lab, width = vl_unit(50, "mm"), align = align,
                     gp = vl_gpar(fontsize = 12)))
  }
  expect_false(identical(scene_png(mk("left")), scene_png(mk("right"))))
  expect_false(identical(scene_png(mk("left")), scene_png(mk("centre"))))
  # The longest line is the same width in all three, so the block's total ink
  # width matches; only its position within the box changes.
  wl <- diff(ink_box(mk("left"))[1:2])
  wr <- diff(ink_box(mk("right"))[1:2])
  expect_equal(wl, wr, tolerance = 0.02)
  # Left-aligned starts further left than right-aligned.
  expect_lt(ink_box(mk("left"))[1], ink_box(mk("right"))[1])

  # "center" is a synonym, not a separate layout.
  expect_identical(scene_png(mk("center")), scene_png(mk("centre")))
})

test_that("justify stretches short lines to the full measure", {
  # Hard newlines and deliberately short lines: left-aligned they occupy a
  # fraction of the box, justified the non-final ones must reach both edges. The
  # signal is the block's total ink width, which needs no per-line banding.
  lab <- "a b\nc d\ne"
  box_mm <- 60
  mk <- function(align) {
    vl_scene(4, 1.6, dpi = 96, bg = "white") |>
      draw(text_grob(lab, width = vl_unit(box_mm, "mm"), align = align,
                     gp = vl_gpar(fontsize = 12)))
  }
  box_px <- box_mm / 25.4 * 96
  w_left <- diff(ink_box(mk("left"))[1:2])
  w_just <- diff(ink_box(mk("justify"))[1:2])
  expect_lt(w_left, box_px / 2) # nowhere near filling the box
  expect_gt(w_just, box_px - 6) # stretched to it
  expect_false(identical(scene_png(mk("justify")), scene_png(mk("left"))))
})

test_that("fit shrinks the font until the block fits, and never grows it", {
  box <- list(width = vl_unit(40, "mm"), height = vl_unit(12, "mm"))
  big <- vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(text_grob(LONG, gp = vl_gpar(fontsize = 20), width = box$width,
                   height = box$height, fit = TRUE))
  expect_lte(diff(ink_box(big)[3:4]), 12 / 25.4 * 96 + 2)
  expect_lte(diff(ink_box(big)[1:2]), 40 / 25.4 * 96 + 2)

  # A label that already fits is left at its requested size: identical bytes to
  # the same scene without `fit`.
  short <- "ok"
  expect_identical(
    scene_png(vl_scene(4, 2, dpi = 96, bg = "white") |>
      draw(text_grob(short, gp = vl_gpar(fontsize = 10), width = box$width,
                     height = box$height, fit = TRUE))),
    scene_png(vl_scene(4, 2, dpi = 96, bg = "white") |>
      draw(text_grob(short, gp = vl_gpar(fontsize = 10), width = box$width,
                     height = box$height)))
  )
})

test_that("hard newlines survive wrapping, including blank lines", {
  # A blank line is a paragraph break and must not be swallowed -- the same
  # `x[[""]]` trap that bit the multi-line batch path.
  s <- vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(text_grob("first\n\nthird", gp = vl_gpar(fontsize = 12),
                   width = vl_unit(60, "mm")))
  # At least two inked bands with a gap between. Not an exact count: a
  # descender can split a band on some fonts, which is why the alignment tests
  # above stopped relying on banding altogether.
  expect_gte(length(line_starts(s)), 2L)
  gap <- vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(text_grob("first\nthird", gp = vl_gpar(fontsize = 12),
                   width = vl_unit(60, "mm")))
  # The blank line pushes them further apart than a single newline does.
  expect_gt(diff(ink_box(s)[3:4]), diff(ink_box(gap)[3:4]))
})

test_that("a word wider than the box overflows rather than vanishing", {
  s <- vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(text_grob("Antidisestablishmentarianism", gp = vl_gpar(fontsize = 16),
                   width = vl_unit(10, "mm")))
  expect_gt(sum(inked(s)), 100) # it is drawn, not silently dropped
})

test_that("relative widths are rejected with an explanation", {
  expect_error(text_grob("x", width = 0.5), "absolute unit")
  expect_error(text_grob("x", width = vl_unit(0.5, "npc")), "absolute unit")
  expect_error(text_grob("x", fit = TRUE), "width")
})

test_that("text without a width takes the unmodified path", {
  # Guards the whole feature against regressing ordinary labels.
  s <- function() vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(text_grob(c("alpha", "beta\ngamma"), x = c(0.3, 0.7), gp = vl_gpar(fontsize = 14)))
  expect_identical(scene_png(s()), scene_png(s()))
  expect_null(.text_wrap(text_grob("x")))
})

test_that("a multi-line block is centred on its anchor, whatever its line count", {
  # Regression: the renderer offsets a glyph by `vjust * h` with `h` the whole
  # block height, so per-line offsets centred about zero double-counted it and
  # an n-line block hung (n-1)*lead/2 too low -- a 6-line block at 12pt was 75px
  # low at 150dpi. Every line count must now land on the anchor.
  centre <- function(lab) {
    d <- inked(vl_scene(4, 2, dpi = 150, bg = "white") |>
      draw(text_grob(lab, gp = vl_gpar(fontsize = 12))))
    mean(range(which(apply(d, 2, any))))
  }
  page_mid <- 150 # 2in at 150dpi
  for (lab in c("one line", "two\nlines", "a\nb\nc\nd\ne\nf")) {
    expect_lt(abs(centre(lab) - page_mid), 4, label = sprintf("centre of %s", dQuote(lab)))
  }
})

test_that("SVG keeps multi-line text as one <text> per line", {
  # SVG <text> ignores newlines, so a multi-line run emitted as a single element
  # silently collapses onto one line. Harmless while multi-line was a corner
  # case; not harmless once wrapping exists.
  ntext <- function(s) lengths(regmatches(s, gregexpr("<text", s)))
  svg1 <- scene_svg(vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(text_grob("single", gp = vl_gpar(fontsize = 14))))
  svg3 <- scene_svg(vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(text_grob("one\ntwo\nthree", gp = vl_gpar(fontsize = 14))))
  expect_equal(ntext(svg1), 1L)
  expect_equal(ntext(svg3), 3L)

  # A wrapped label reaches SVG as the lines it was broken into, not as the
  # original string -- the label is metadata describing what was drawn.
  svgw <- scene_svg(vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(text_grob(LONG, width = vl_unit(40, "mm"), gp = vl_gpar(fontsize = 10))))
  parts <- regmatches(svgw, gregexpr("(?<=>)[^<>]+(?=</text>)", svgw, perl = TRUE))[[1]]
  expect_gt(length(parts), 1L)
  expect_equal(paste(parts, collapse = " "), LONG)
})

test_that("a blank line falls back to outlines rather than mis-set native text", {
  # Blank lines produce no glyphs, so the label split cannot be matched against
  # the glyph baselines. Outlines carry no such assumption.
  svg <- scene_svg(vl_scene(4, 2, dpi = 96, bg = "white") |>
    draw(text_grob("a\n\nb", gp = vl_gpar(fontsize = 14))))
  expect_equal(lengths(regmatches(svg, gregexpr("<text", svg))), 0L)
  expect_gt(lengths(regmatches(svg, gregexpr("<path", svg))), 0L)
})

test_that("top and bottom justification anchor the block's outer edge", {
  # The other half of the same fix: with vjust at an extreme, an n-line block's
  # outer edge should sit where a one-line block's does.
  edge <- function(lab, just, which) {
    d <- inked(vl_scene(4, 2.6, dpi = 150, bg = "white") |>
      draw(text_grob(lab, y = 0.5, just = c("centre", just), gp = vl_gpar(fontsize = 12))))
    which(apply(d, 2, any))[if (which == "top") 1L else sum(apply(d, 2, any))]
  }
  expect_lt(abs(edge("a\nb\nc", "top", "top") - edge("a", "top", "top")), 4)
  expect_lt(abs(edge("a\nb\nc", "bottom", "bottom") - edge("a", "bottom", "bottom")), 4)
})

# --- text on a path ---------------------------------------------------------

ARC <- local({
  th <- seq(pi, 0, length.out = 60)
  list(x = 0.5 + 0.42 * cos(th), y = 0.15 + 0.7 * sin(th))
})
on_path <- function(...) {
  vl_scene(4, 2.2, dpi = 96, bg = "white") |>
    draw(text_path_grob("following a curve", x = ARC$x, y = ARC$y,
                        gp = vl_gpar(fontsize = 13), ...))
}

test_that("text on a path draws, and follows the curve rather than a line", {
  expect_gt(sum(inked(on_path())), 200)
  # A straight label occupies a band a line tall. Anchored at the start of this
  # arc the run climbs its steep left flank, so it spans many times that. (Left-
  # anchored on purpose: centred, the run sits on the flat top of the arc and
  # legitimately spans almost as little as flat text does.)
  flat <- vl_scene(4, 2.2, dpi = 96, bg = "white") |>
    draw(text_grob("following a curve", gp = vl_gpar(fontsize = 13)))
  expect_gt(diff(ink_box(on_path(just = "left"))[3:4]), 3 * diff(ink_box(flat)[3:4]))
})

test_that("offset moves the baseline perpendicular to the path", {
  a <- ink_box(on_path(offset = 0))
  b <- ink_box(on_path(offset = 8))
  # Standing off to the left of travel lifts the run on this left-to-right arc.
  expect_lt(b[3], a[3])
  expect_false(identical(scene_png(on_path(offset = 0)), scene_png(on_path(offset = 8))))
})

test_that("just slides the run along the path", {
  l <- ink_box(on_path(just = "left"))
  r <- ink_box(on_path(just = "right"))
  expect_lt(l[1], r[1]) # the run starts further along when right-anchored
})

test_that("text on a path reaches every backend", {
  s <- on_path()
  expect_gt(length(scene_png(s)), 100)
  expect_gt(length(scene_pdf(s)), 100)
  svg <- scene_svg(s)
  # One <text> per glyph: the run is fanned out, so vector output stays real
  # text rather than becoming outlines.
  expect_gt(lengths(regmatches(svg, gregexpr("<text", svg))), 10)
})

test_that("degenerate paths draw nothing instead of erroring", {
  blank <- function(g) {
    sum(inked(vl_scene(2, 1, dpi = 96, bg = "white") |> draw(g)))
  }
  expect_equal(blank(text_path_grob("hi", x = 0.5, y = 0.5)), 0) # single point
  expect_equal(blank(text_path_grob("hi", x = c(0.5, 0.5), y = c(0.5, 0.5))), 0) # zero length
  expect_equal(blank(text_path_grob("", x = c(0.1, 0.9), y = c(0.5, 0.5))), 0)
})

test_that("a straight path reproduces ordinary left-aligned text closely", {
  # The strongest available check that glyph placement along the path uses the
  # same pen positions shaping produced: on a horizontal baseline, on-path text
  # should land where a plain left-justified label lands.
  lab <- "straight"
  a <- vl_scene(3, 1, dpi = 96, bg = "white") |>
    draw(text_path_grob(lab, x = c(0.1, 0.9), y = c(0.5, 0.5), just = "left",
                        gp = vl_gpar(fontsize = 14)))
  b <- vl_scene(3, 1, dpi = 96, bg = "white") |>
    draw(text_grob(lab, x = 0.1, y = 0.5, just = c("left", "centre"),
                   gp = vl_gpar(fontsize = 14)))
  expect_equal(ink_box(a), ink_box(b), tolerance = 0.02)
})

test_that("halo and OpenType features carry through to on-path text", {
  plain <- on_path()
  haloed <- vl_scene(4, 2.2, dpi = 96, bg = "white") |>
    draw(text_path_grob("following a curve", x = ARC$x, y = ARC$y,
                        gp = vl_gpar(fontsize = 13, col = "white",
                                     halo_col = "black", halo_width = 2)))
  expect_false(identical(scene_png(plain), scene_png(haloed)))
  expect_gt(sum(inked(haloed)), 200)
})

test_that("a halo does not eat the neighbouring glyphs on a path", {
  # Regression: fanning the run out into one draw per glyph broke the invariant
  # that every glyph is stroked before ANY is filled, so each glyph's halo
  # painted over the previous glyph's fill and visibly chewed the letters.
  #
  # Rendered with the halo the same colour as the background, the halo is
  # invisible, so the white ink must match the unhaloed render closely. With the
  # bug it was substantially eroded.
  bg <- "#20304A"
  mk <- function(...) {
    vl_scene(5, 1.6, dpi = 96, bg = bg) |>
      draw(text_path_grob("ammmmmmmma", x = seq(0.05, 0.95, length.out = 60),
                          y = 0.5, just = "left",
                          gp = vl_gpar(fontsize = 15, col = "white", ...)))
  }
  white <- function(s) sum(scene_raster(s)[1, , ] > 200)
  plain <- white(mk())
  haloed <- white(mk(halo_col = bg, halo_width = 3))
  expect_gt(plain, 100)
  expect_gt(haloed, plain * 0.9)
})

test_that("an on-path halo still renders", {
  # ...and the fix did not simply disable it: a contrasting halo must add ink.
  mk <- function(...) {
    vl_scene(5, 1.6, dpi = 96, bg = "white") |>
      draw(text_path_grob("halo here", x = seq(0.05, 0.95, length.out = 60),
                          y = 0.5, just = "left",
                          gp = vl_gpar(fontsize = 15, col = "white", ...)))
  }
  ink <- function(s) sum(scene_raster(s)[1, , ] < 200)
  expect_equal(ink(mk()), 0) # white on white draws nothing visible
  expect_gt(ink(mk(halo_col = "black", halo_width = 3)), 200)
})

test_that("text_path_grob takes exactly one label", {
  expect_error(text_path_grob(c("a", "b"), x = c(0, 1), y = c(0, 1)), "single string")
})
