# PowerPoint (DrawingML) output (F-24).

dml_scene <- function() {
  vl_scene(2, 1, dpi = 96, bg = "white") |>
    draw(rect_grob(
      x = 0.25,
      width = 0.3,
      height = 0.6,
      gp = vl_gpar(fill = "tomato", col = "black", lwd = 2)
    )) |>
    draw(circle_grob(
      x = 0.7,
      r = 0.2,
      gp = vl_gpar(fill = adjustcolor("steelblue", 0.5), col = NA)
    )) |>
    draw(lines_grob(
      x = c(0.1, 0.5, 0.9),
      y = c(0.1, 0.3, 0.1),
      gp = vl_gpar(col = "darkgreen", lwd = 3, lty = 2, lineend = "round")
    ))
}

test_that("the DrawingML fragment of a text-free scene is byte-stable", {
  fr <- .dml_fragment(dml_scene())
  expect_length(fr$warnings, 0)
  expect_length(fr$files, 0)
  expect_snapshot(cat(fr$xml))
  # rendering twice gives the same bytes
  expect_identical(.dml_fragment(dml_scene())$xml, fr$xml)
})

test_that("the fragment is well-formed DrawingML, offset to its location", {
  skip_if_not_installed("xml2")
  fr <- .dml_fragment(dml_scene(), left = 1, top = 0.5)
  doc <- xml2::read_xml(fr$xml)
  ns <- xml2::xml_ns(doc)
  expect_identical(xml2::xml_name(doc), "grpSp")
  off <- xml2::xml_find_first(doc, "p:grpSpPr/a:xfrm/a:off", ns)
  expect_identical(xml2::xml_attr(off, "x"), "914400")
  expect_identical(xml2::xml_attr(off, "y"), "457200")
  # background, rect, circle, line
  sps <- xml2::xml_find_all(doc, "p:sp", ns)
  expect_length(sps, 4)
  geoms <- xml2::xml_attr(xml2::xml_find_all(doc, ".//a:prstGeom", ns), "prst")
  expect_identical(geoms, c("rect", "rect", "ellipse"))
  # every child lies inside the scene's box on the slide
  offs <- xml2::xml_find_all(doc, "p:sp/p:spPr/a:xfrm/a:off", ns)
  x <- as.numeric(xml2::xml_attr(offs, "x"))
  expect_true(all(x >= 914400 & x <= 914400 + 2 * 914400))
  ln <- xml2::xml_find_first(doc, ".//a:ln[a:custDash]", ns)
  expect_identical(xml2::xml_attr(ln, "cap"), "rnd")
})

test_that("text is a native, editable run sized to vellum's measurement", {
  skip_if_not_installed("xml2")
  sc <- vl_scene(3, 1, dpi = 96) |>
    draw(text_grob(
      "Hello & <world>",
      x = 0.1,
      just = "left",
      rot = 30,
      gp = vl_gpar(fontsize = 18, fontface = "bold.italic", col = "purple")
    ))
  fr <- .dml_fragment(sc)
  doc <- xml2::read_xml(fr$xml)
  ns <- xml2::xml_ns(doc)
  sp <- xml2::xml_find_first(doc, "p:sp[p:nvSpPr/p:cNvSpPr/@txBox='1']", ns)
  expect_false(inherits(sp, "xml_missing"))
  expect_identical(
    xml2::xml_text(xml2::xml_find_first(sp, ".//a:t", ns)),
    "Hello & <world>"
  )
  rpr <- xml2::xml_find_first(sp, ".//a:rPr", ns)
  expect_identical(xml2::xml_attr(rpr, "sz"), "1800")
  expect_identical(xml2::xml_attr(rpr, "b"), "1")
  expect_identical(xml2::xml_attr(rpr, "i"), "1")
  body <- xml2::xml_find_first(sp, ".//a:bodyPr", ns)
  expect_identical(xml2::xml_attr(body, "wrap"), "none")
  expect_identical(xml2::xml_attr(body, "anchor"), "ctr")
  expect_identical(
    xml2::xml_attr(xml2::xml_find_first(sp, ".//a:pPr", ns), "algn"),
    "l"
  )
  # 30 degrees counter-clockwise is 330 degrees clockwise
  xfrm <- xml2::xml_find_first(sp, "p:spPr/a:xfrm", ns)
  expect_identical(xml2::xml_attr(xfrm, "rot"), "19800000")
  # the box is vellum's measured width
  ext <- xml2::xml_find_first(xfrm, "a:ext", ns)
  w_in <- vl_strwidth("Hello & <world>", fontsize = 18, fontface = "bold.italic")
  expect_equal(
    as.numeric(xml2::xml_attr(ext, "cx")) / 914400,
    w_in,
    tolerance = 0.02
  )
})

test_that("math, tex and outline text become glyph outlines", {
  skip_if_not_installed("xml2")
  sc <- vl_scene(3, 1, dpi = 96) |>
    draw(text_grob(md("mass $m_e$ in **kg**"), x = 0.3)) |>
    draw(text_grob(tex("\\frac{1}{2}"), x = 0.7))
  doc <- xml2::read_xml(.dml_fragment(sc)$xml)
  ns <- xml2::xml_ns(doc)
  expect_length(xml2::xml_find_all(doc, ".//a:t", ns), 0)
  expect_gt(length(xml2::xml_find_all(doc, ".//a:custGeom", ns)), 1)
  plain <- vl_scene(3, 1, dpi = 96) |> draw(text_grob("abc"))
  out <- xml2::read_xml(.dml_fragment(plain, text = "outline")$xml)
  expect_length(xml2::xml_find_all(out, ".//a:t", ns), 0)
  rich <- vl_scene(3, 1, dpi = 96) |> draw(text_grob(md("a **b**")))
  out <- xml2::read_xml(.dml_fragment(rich, text = "outline")$xml)
  expect_length(xml2::xml_find_all(out, ".//a:t", ns), 0)
})

test_that("md() labels become one editable run per span (VR-40)", {
  skip_if_not_installed("xml2")
  sc <- vl_scene(4, 2, dpi = 96) |>
    draw(text_grob(
      md("R^2^ = **0.91** *it* [red]{#c00} x~i~\nnext **line**"),
      gp = vl_gpar(fontsize = 20, col = "grey20", alpha = 0.5)
    ))
  doc <- xml2::read_xml(.dml_fragment(sc)$xml)
  ns <- xml2::xml_ns(doc)
  expect_length(xml2::xml_find_all(doc, ".//a:custGeom", ns), 0)
  sp <- xml2::xml_find_all(doc, "p:sp[p:nvSpPr/p:cNvSpPr/@txBox='1']", ns)
  expect_length(sp, 1)
  paras <- xml2::xml_find_all(sp, ".//a:p", ns)
  expect_length(paras, 2)
  runs <- xml2::xml_find_all(paras[[1]], "a:r", ns)
  expect_identical(
    xml2::xml_text(runs),
    c("R", "2", " = ", "0.91", " ", "it", " ", "red", " x", "i")
  )
  attr_of <- function(a) {
    xml2::xml_attr(xml2::xml_find_first(runs, "a:rPr", ns), a)
  }
  # bold and italic runs
  expect_identical(attr_of("b")[4], "1")
  expect_identical(attr_of("i")[6], "1")
  expect_true(all(is.na(attr_of("b")[-4])))
  # a raised or lowered run keeps the size around it and shifts its baseline
  # (applications shrink it themselves)
  expect_identical(unique(attr_of("sz")), "2000")
  # at its real height: the 0.7x run's box bottom sits higher than the base
  # run's, so a superscript rises about 80% of its 0.35 em offset
  base <- as.numeric(attr_of("baseline")[c(2, 10)])
  sp <- .md_compose(md("R^2^ x~i~"), "sans", "plain", 20, "black")$spans
  rise <- sp$dy[sp$dy != 0]
  expect_equal(base, round(rise / 20 * 1e5))
  expect_true(base[1] > 0 && base[1] < 35000)
  expect_true(base[2] < 0 && base[2] > -35000)
  expect_true(all(is.na(attr_of("baseline")[-c(2, 10)])))
  # the colour span, and the label's alpha on every run
  cols <- xml2::xml_attr(
    xml2::xml_find_first(runs, "a:rPr/a:solidFill/a:srgbClr", ns),
    "val"
  )
  expect_identical(cols[8], "CC0000")
  expect_identical(unique(cols[-8]), "333333")
  alpha <- xml2::xml_find_all(runs, "a:rPr/a:solidFill/a:srgbClr/a:alpha", ns)
  expect_length(alpha, length(runs))
  # the second line, at vellum's line pitch (1.2 x 20 pt)
  expect_identical(
    xml2::xml_text(xml2::xml_find_all(paras[[2]], "a:r", ns)),
    c("next ", "line")
  )
  expect_identical(
    xml2::xml_attr(xml2::xml_find_first(paras[[1]], ".//a:spcPts", ns), "val"),
    "2400"
  )
})

test_that("rasters become pictures, written to the media directory", {
  skip_if_not_installed("xml2")
  img <- matrix(c("red", "blue", "green", "white"), 2)
  sc <- vl_scene(2, 2, dpi = 96) |>
    draw(raster_grob(img, interpolate = FALSE))
  dir <- withr::local_tempdir()
  fr <- .dml_fragment(sc, media_dir = dir)
  expect_length(fr$files, 1)
  expect_true(file.exists(fr$files))
  doc <- xml2::read_xml(fr$xml)
  ns <- xml2::xml_ns(doc)
  blip <- xml2::xml_find_first(doc, ".//p:pic//a:blip", ns)
  expect_identical(xml2::xml_attr(blip, "embed"), fr$files)
  # a pixelated raster is enlarged so smoothing cannot blur it
  skip_if_not_installed("png")
  expect_gt(dim(png::readPNG(fr$files))[1], 2)
})

test_that("gradients become gradFill, patterns a tiled picture fill", {
  skip_if_not_installed("xml2")
  sc <- vl_scene(3, 1, dpi = 96, bg = NA) |>
    draw(rect_grob(
      x = 0.2,
      width = 0.3,
      gp = vl_gpar(col = NA, fill = linear_gradient(c("red", "blue")))
    )) |>
    draw(rect_grob(
      x = 0.5,
      width = 0.2,
      gp = vl_gpar(col = NA, fill = radial_gradient(c("white", "navy"), fx = 0.4))
    )) |>
    draw(rect_grob(
      x = 0.8,
      width = 0.3,
      gp = vl_gpar(
        col = NA,
        fill = vl_pattern(circle_grob(gp = vl_gpar(fill = "red")), 0.1, 0.1)
      )
    ))
  fr <- .dml_fragment(sc)
  expect_match(fr$warnings, "focal point", all = FALSE)
  doc <- xml2::read_xml(fr$xml)
  ns <- xml2::xml_ns(doc)
  expect_length(xml2::xml_find_all(doc, ".//a:gradFill/a:lin", ns), 1)
  expect_length(xml2::xml_find_all(doc, ".//a:gradFill/a:path[@path='circle']", ns), 1)
  tile <- xml2::xml_find_first(doc, ".//a:blipFill/a:tile", ns)
  expect_identical(xml2::xml_attr(tile, "sx"), "100000")
  expect_length(fr$files, 1)
})

test_that("masks and blend modes become pictures of their region", {
  skip_if_not_installed("xml2")
  dots <- function(sc) {
    sc |>
      draw(circle_grob(x = 0.4, r = 0.3, gp = vl_gpar(fill = "cyan", col = NA))) |>
      draw(circle_grob(x = 0.6, r = 0.3, gp = vl_gpar(fill = "magenta", col = NA)))
  }
  sc <- vl_scene(2, 1, dpi = 96) |>
    push(vl_viewport(blend = "multiply")) |>
    dots() |>
    pop()
  fr <- .dml_fragment(sc)
  expect_match(fr$warnings, "blend modes are drawn as a picture", all = FALSE)
  doc <- xml2::read_xml(fr$xml)
  ns <- xml2::xml_ns(doc)
  expect_length(xml2::xml_find_all(doc, ".//p:pic", ns), 1)
  expect_length(xml2::xml_find_all(doc, ".//a:prstGeom[@prst='ellipse']", ns), 0)
  # opacity over overlapping shapes: a picture; over disjoint ones: folded in
  over <- vl_scene(2, 1, dpi = 96) |>
    push(vl_viewport(alpha = 0.5)) |>
    dots() |>
    pop()
  expect_match(.dml_fragment(over)$warnings, "group opacity", all = FALSE)
  apart <- vl_scene(2, 1, dpi = 96, bg = NA) |>
    push(vl_viewport(alpha = 0.5)) |>
    draw(circle_grob(x = 0.2, r = 0.2, gp = vl_gpar(fill = "red", col = NA))) |>
    draw(circle_grob(x = 0.8, r = 0.2, gp = vl_gpar(fill = "blue", col = NA))) |>
    pop()
  fa <- .dml_fragment(apart)
  expect_length(fa$warnings, 0)
  expect_identical(
    lengths(regmatches(fa$xml, gregexpr('<a:alpha val="50000"/>', fa$xml))),
    2L
  )
  # overlaps inside a nested group or inside one shape still count
  nested <- vl_scene(2, 1, dpi = 96) |>
    push(vl_viewport(alpha = 0.5)) |>
    push(vl_viewport(name = "inner")) |>
    dots() |>
    pop() |>
    pop()
  expect_match(.dml_fragment(nested)$warnings, "group opacity", all = FALSE)
  outlined <- vl_scene(2, 1, dpi = 96) |>
    push(vl_viewport(alpha = 0.5)) |>
    draw(circle_grob(r = 0.3, gp = vl_gpar(fill = "red", col = "black", lwd = 4))) |>
    pop()
  expect_match(.dml_fragment(outlined)$warnings, "group opacity", all = FALSE)
  halo <- vl_scene(4, 2, dpi = 96) |>
    push(vl_viewport(alpha = 0.5)) |>
    draw(text_grob("HALO", gp = vl_gpar(fontsize = 60, halo_col = "red", halo_width = 6))) |>
    pop()
  expect_match(.dml_fragment(halo)$warnings, "group opacity", all = FALSE)
  # a nested opacity over disjoint shapes folds both opacities in
  twice <- vl_scene(2, 1, dpi = 96, bg = NA) |>
    push(vl_viewport(alpha = 0.5)) |>
    push(vl_viewport(alpha = 0.5)) |>
    draw(circle_grob(x = 0.2, r = 0.2, gp = vl_gpar(fill = "red", col = NA))) |>
    draw(circle_grob(x = 0.8, r = 0.2, gp = vl_gpar(fill = "blue", col = NA))) |>
    pop() |>
    pop()
  ft <- .dml_fragment(twice)
  expect_length(ft$warnings, 0)
  expect_identical(
    lengths(regmatches(ft$xml, gregexpr('<a:alpha val="25000"/>', ft$xml))),
    2L
  )
  # a nested blend names the real reason
  blended <- vl_scene(2, 1, dpi = 96) |>
    push(vl_viewport(alpha = 0.5)) |>
    push(vl_viewport(blend = "multiply")) |>
    draw(circle_grob(x = 0.2, r = 0.2, gp = vl_gpar(fill = "red", col = NA))) |>
    pop() |>
    pop()
  fb <- .dml_fragment(blended)$warnings
  expect_match(fb, "blend modes", all = FALSE)
  expect_no_match(fb, "overlapping")
})

test_that("control characters cannot break the XML", {
  skip_if_not_installed("xml2")
  sc <- S7::set_props(vl_scene(2, 1, dpi = 96), title = "t\001itle") |>
    draw(text_grob("x\001yz"))
  fr <- .dml_fragment(sc)
  doc <- xml2::read_xml(fr$xml)
  ns <- xml2::xml_ns(doc)
  expect_identical(xml2::xml_text(xml2::xml_find_first(doc, ".//a:t", ns)), "xyz")
  cnv <- xml2::xml_find_first(doc, "p:nvGrpSpPr/p:cNvPr", ns)
  expect_identical(xml2::xml_attr(cnv, "name"), "title")
  # a halo label's group name too
  halo <- vl_scene(2, 1, dpi = 96) |>
    draw(text_grob("a\002b", gp = vl_gpar(halo_col = "white", halo_width = 2)))
  expect_no_error(xml2::read_xml(.dml_fragment(halo)$xml))
})

test_that("coordinates stay inside DrawingML's range", {
  skip_if_not_installed("xml2")
  sc <- vl_scene(3, 1, dpi = 96, bg = NA) |>
    draw(lines_grob(x = c(0.1, 1e12, 0.9), y = c(0.1, 0.5, 0.9))) |>
    draw(rect_grob(x = 1e9, width = 1e9, gp = vl_gpar(fill = "red")))
  fr <- .dml_fragment(sc)
  doc <- xml2::read_xml(fr$xml)
  ns <- xml2::xml_ns(doc)
  # the off-page rectangle is dropped, the line kept
  expect_length(xml2::xml_find_all(doc, ".//p:sp", ns), 1)
  num <- function(xp, a) {
    as.numeric(xml2::xml_attr(xml2::xml_find_all(doc, xp, ns), a))
  }
  v <- c(
    num(".//a:off", "x"),
    num(".//a:off", "y"),
    num(".//a:ext", "cx"),
    num(".//a:ext", "cy"),
    num(".//a:pt", "x"),
    num(".//a:pt", "y")
  )
  expect_true(all(abs(v) <= 27273042316900))
  expect_true(all(num(".//a:ext", "cx") >= 0))
})

test_that("a layer of points becomes a few multi-path shapes (VR-39)", {
  skip_if_not_installed("xml2")
  set.seed(1)
  n <- 400L
  x <- runif(n)
  y <- runif(n)
  pts <- function(shape, gp = vl_gpar(fill = "steelblue", col = NA)) {
    vl_scene(4, 3, dpi = 96, bg = NA) |>
      draw(points_grob(x, y, size = vl_unit(1.5, "mm"), shape = shape, gp = gp))
  }
  count <- function(sc) {
    doc <- xml2::read_xml(.dml_fragment(sc)$xml)
    ns <- xml2::xml_ns(doc)
    sps <- xml2::xml_find_all(doc, ".//p:sp", ns)
    # every point is still drawn: one path in a merged shape, or a shape
    marks <- vapply(
      sps,
      function(sp) {
        k <- length(xml2::xml_find_all(sp, ".//a:path", ns))
        if (k == 0L) 1L else k
      },
      integer(1)
    )
    c(shapes = length(sps), marks = sum(marks))
  }
  # circles (a Circles batch), squares and outlined triangles (markers)
  circ <- count(pts("circle"))
  expect_identical(circ[["marks"]], n)
  expect_lt(circ[["shapes"]], n / 4)
  sq <- count(pts("square"))
  expect_identical(sq[["marks"]], n)
  expect_lt(sq[["shapes"]], n / 4)
  tri <- count(pts("triangle", vl_gpar(fill = "gold", col = "black")))
  expect_identical(tri[["marks"]], n)
  expect_lt(tri[["shapes"]], n / 4)
  # a merged circle is two half arcs, not curves
  doc <- xml2::read_xml(.dml_fragment(pts("circle"))$xml)
  ns <- xml2::xml_ns(doc)
  expect_length(xml2::xml_find_all(doc, ".//a:cubicBezTo", ns), 0)
  expect_gt(length(xml2::xml_find_all(doc, ".//a:arcTo", ns)), n)
})

test_that("merged points keep the stacking order of overlapping points", {
  skip_if_not_installed("xml2")
  # Two disjoint red points, then a blue one over the first: the reds merge
  # into one shape drawn first, and blue stays above the red it covers.
  sc <- vl_scene(3, 1, dpi = 96, bg = NA) |>
    draw(points_grob(c(0.2, 0.8), 0.5, gp = vl_gpar(fill = "red", col = NA))) |>
    draw(points_grob(0.21, 0.5, gp = vl_gpar(fill = "blue", col = NA)))
  doc <- xml2::read_xml(.dml_fragment(sc)$xml)
  ns <- xml2::xml_ns(doc)
  cols <- xml2::xml_attr(
    xml2::xml_find_all(doc, ".//p:sp/p:spPr/a:solidFill/a:srgbClr", ns),
    "val"
  )
  expect_identical(cols, c("FF0000", "0000FF"))
  expect_length(xml2::xml_find_all(doc, ".//p:sp[1]//a:path", ns), 2)
})

test_that("a leading superscript or subscript keeps the md() line pitch", {
  skip_if_not_installed("xml2")
  pitch <- function(lab) {
    sc <- vl_scene(4, 2, dpi = 96) |> draw(text_grob(lab))
    doc <- xml2::read_xml(.dml_fragment(sc)$xml)
    ns <- xml2::xml_ns(doc)
    unique(xml2::xml_attr(xml2::xml_find_all(doc, ".//a:spcPts", ns), "val"))
  }
  # 1.2 x the default 12 pt, as a plain label gets
  expect_identical(pitch("up line1\nline2"), "1440")
  expect_identical(pitch(md("^up^ line1\nline2")), "1440")
  expect_identical(pitch(md("line1\n~dn~ line2")), "1440")
  expect_identical(pitch(md("line1\n^up^ line2")), "1440")
  expect_identical(pitch(md("~a~\n^b^")), "1440")
  expect_identical(pitch(md("**A**\n\n*b*")), "1440")
})

test_that("a label with one text line among blank ones keeps the line pitch (VR-51)", {
  skip_if_not_installed("xml2")
  box <- function(lab) {
    sc <- vl_scene(4, 2, dpi = 96) |> draw(text_grob(lab))
    doc <- xml2::read_xml(.dml_fragment(sc)$xml)
    ns <- xml2::xml_ns(doc)
    sp <- xml2::xml_find_first(doc, ".//p:sp[.//p:txBody]", ns)
    ps <- xml2::xml_find_all(sp, ".//p:txBody/a:p", ns)
    list(
      spc = vapply(
        ps,
        function(p) {
          v <- xml2::xml_find_first(p, "a:pPr/a:lnSpc/a:spcPts", ns)
          xml2::xml_attr(v, "val")
        },
        ""
      ),
      text = xml2::xml_text(ps),
      cy = as.numeric(xml2::xml_attr(xml2::xml_find_first(sp, ".//a:ext", ns), "cy"))
    )
  }
  # every paragraph gets 1.2 x the default 12 pt, as "a\nb" does
  expect_identical(box("\nabc")$spc, c("1440", "1440"))
  expect_identical(box("\n\nabc")$spc, rep("1440", 3))
  expect_identical(box("a\n\nb")$spc, rep("1440", 3))
  # a single line needs none
  expect_identical(box("abc")$spc, NA_character_)
  # vellum sets "abc\n" as one line (as strsplit() splits it), so is it here
  expect_identical(box("abc\n"), box("abc"))
  # an md() label's box leaves out blank lines before and after its text, so
  # they are not written either, and the box is the text line's
  one <- box(md("**abc**"))
  expect_identical(box(md("\n**abc**")), one)
  expect_identical(box(md("\n\n**abc**")), one)
  expect_identical(box(md("**abc**\n\n")), one)
  # unequal blank lines on both ends
  expect_identical(box(md("\n**abc**\n\n\n")), one)
  expect_identical(box(md("\n\n**abc**\n\n\n\n")), one)
  # a blank line between text lines stays
  expect_identical(box(md("**a**\n\n*b*"))$spc, rep("1440", 3))
})

test_that("a CRLF line break is one break in PowerPoint", {
  skip_if_not_installed("xml2")
  paras <- function(lab) {
    sc <- vl_scene(4, 2, dpi = 96) |> draw(text_grob(lab))
    doc <- xml2::read_xml(.dml_fragment(sc)$xml)
    ns <- xml2::xml_ns(doc)
    xml2::xml_text(xml2::xml_find_all(doc, ".//p:txBody/a:p", ns))
  }
  expect_identical(paras("a\r\nb"), c("a", "b"))
  expect_identical(paras("a\r\n\r\nb"), c("a", "", "b"))
  expect_identical(paras(md("**a**\r\n*b*")), c("a", "b"))
  expect_identical(paras(md("\r\n**a**")), "a")
})

test_that("a blank line keeps a label native", {
  skip_if_not_installed("xml2")
  sc <- vl_scene(2, 2, dpi = 96) |> draw(text_grob("a\n\nb"))
  doc <- xml2::read_xml(.dml_fragment(sc)$xml)
  ns <- xml2::xml_ns(doc)
  expect_length(xml2::xml_find_all(doc, ".//p:txBody/a:p", ns), 3)
  expect_identical(
    xml2::xml_text(xml2::xml_find_all(doc, ".//a:t", ns)),
    c("a", "b")
  )
})

test_that("as_dml() validates and prints", {
  d <- as_dml(dml_scene(), text = "outline")
  expect_s3_class(d, "vellum_dml")
  expect_output(print(d), "2 x 1 in scene, text = \"outline\"")
  expect_error(as_dml(dml_scene(), resize = NA), "resize")
})

test_that("the scene's title and description become the group's alt text", {
  skip_if_not_installed("xml2")
  sc <- S7::set_props(dml_scene(), title = "A chart", desc = "Bars & a line")
  doc <- xml2::read_xml(.dml_fragment(sc)$xml)
  cnv <- xml2::xml_find_first(doc, "p:nvGrpSpPr/p:cNvPr", xml2::xml_ns(doc))
  expect_identical(xml2::xml_attr(cnv, "name"), "A chart")
  expect_identical(xml2::xml_attr(cnv, "descr"), "Bars & a line")
  # control characters in the description cannot break the XML
  bad <- S7::set_props(dml_scene(), desc = "x\"y\001")
  doc <- xml2::read_xml(.dml_fragment(bad)$xml)
  cnv <- xml2::xml_find_first(doc, "p:nvGrpSpPr/p:cNvPr", xml2::xml_ns(doc))
  expect_identical(xml2::xml_attr(cnv, "descr"), "x\"y")
})

test_that("ph_with() puts a scene on a slide as editable shapes", {
  skip_if_not_installed("officer")
  skip_if_not_installed("xml2")
  sc <- dml_scene() |>
    draw(text_grob("label", x = 0.5, y = 0.9)) |>
    draw(raster_grob(
      matrix(c("red", "blue"), 1),
      x = 0.9,
      width = 0.1,
      height = 0.1
    ))
  doc <- officer::read_pptx()
  doc <- officer::add_slide(doc, layout = "Blank", master = "Office Theme")
  loc <- officer::ph_location(left = 1, top = 2, width = 4, height = 2)
  doc <- officer::ph_with(doc, sc, location = loc)
  doc <- officer::add_slide(doc, layout = "Blank", master = "Office Theme")
  doc <- officer::ph_with(doc, as_dml(sc, resize = FALSE), location = loc)
  f <- withr::local_tempfile(fileext = ".pptx")
  print(doc, target = f)

  s <- officer::pptx_summary(officer::read_pptx(f))
  expect_true("label" %in% s$text)
  # the raster was copied into the package
  files <- utils::unzip(f, list = TRUE)$Name
  expect_true(any(grepl("^ppt/media/.*\\.png$", files)))

  dir <- withr::local_tempdir()
  utils::unzip(f, exdir = dir)
  slide <- xml2::read_xml(file.path(dir, "ppt/slides/slide1.xml"))
  ns <- xml2::xml_ns(slide)
  grp <- xml2::xml_find_first(slide, "//p:spTree/p:grpSp", ns)
  off <- xml2::xml_find_first(grp, "p:grpSpPr/a:xfrm/a:off", ns)
  expect_identical(xml2::xml_attr(off, "x"), "914400")
  ext <- xml2::xml_find_first(grp, "p:grpSpPr/a:xfrm/a:ext", ns)
  expect_identical(xml2::xml_attr(ext, "cx"), "3657600")
  # resized to the location: the background spans the 4 in width
  bg <- xml2::xml_find_first(grp, "p:sp/p:spPr/a:xfrm/a:ext", ns)
  expect_identical(xml2::xml_attr(bg, "cx"), "3657600")
  # every child shape lies inside the location
  offs <- xml2::xml_find_all(grp, ".//p:sp/p:spPr/a:xfrm/a:off", ns)
  x <- as.numeric(xml2::xml_attr(offs, "x"))
  y <- as.numeric(xml2::xml_attr(offs, "y"))
  expect_true(all(x >= 914400 & x < 5 * 914400))
  expect_true(all(y >= 2 * 914400 & y < 4 * 914400))
  # the picture references the package part, not a file path
  embed <- xml2::xml_attr(xml2::xml_find_first(grp, ".//a:blip", ns), "embed")
  expect_match(embed, "^rId[0-9]+$")

  # resize = FALSE keeps the scene's own 2 x 1 in size
  slide2 <- xml2::read_xml(file.path(dir, "ppt/slides/slide2.xml"))
  bg2 <- xml2::xml_find_first(slide2, "//p:grpSp/p:sp/p:spPr/a:xfrm/a:ext", ns)
  expect_identical(xml2::xml_attr(bg2, "cx"), "1828800")
})

test_that("clipped geometry is cut to the clip region in advance", {
  skip_if_not_installed("xml2")
  # a 1 x 1 in clip viewport centred on a 2 x 2 in page: x, y in [0.5, 1.5] in
  sc <- vl_scene(2, 2, dpi = 96, bg = NA) |>
    push(vl_viewport(width = 0.5, height = 0.5, clip = TRUE)) |>
    draw(lines_grob(x = c(-1, 2), y = c(0.5, 0.5))) |>
    draw(rect_grob(x = 0.9, width = 0.6, gp = vl_gpar(fill = "red", col = NA))) |>
    draw(circle_grob(x = 5, r = 0.1, gp = vl_gpar(fill = "blue")))
  fr <- .dml_fragment(sc)
  expect_length(fr$warnings, 0)
  doc <- xml2::read_xml(fr$xml)
  ns <- xml2::xml_ns(doc)
  xf <- xml2::xml_find_all(doc, ".//p:sp/p:spPr/a:xfrm", ns)
  # the off-page circle is gone: the line and the cut rect remain
  expect_length(xf, 2)
  num <- function(path, attr) {
    as.numeric(xml2::xml_attr(xml2::xml_find_all(xf, path, ns), attr)) / 914400
  }
  x0 <- num("a:off", "x")
  x1 <- x0 + num("a:ext", "cx")
  expect_true(all(x0 >= 0.5 - 1e-3 & x1 <= 1.5 + 1e-3))
  # the cut rectangle is still a rectangle
  expect_length(xml2::xml_find_all(doc, ".//a:prstGeom[@prst='rect']", ns), 1)
})

test_that("native text crossing a clip edge is drawn whole, with a warning", {
  sc <- vl_scene(2, 2, dpi = 96) |>
    push(vl_viewport(width = 0.5, height = 0.5, clip = TRUE)) |>
    draw(text_grob("a long label that overflows", x = 0.9, just = "left"))
  fr <- .dml_fragment(sc)
  expect_match(fr$warnings, "clip edge", all = FALSE)
  expect_match(fr$xml, "a long label that overflows", fixed = TRUE)
  # as outlines it is cut exactly instead
  expect_length(.dml_fragment(sc, text = "outline")$warnings, 0)
})

test_that("render() writes a standalone, deterministic .pptx", {
  skip_if_not_installed("xml2")
  sc <- S7::set_props(dml_scene(), title = "Deck") |>
    draw(text_grob("hello", y = 0.9)) |>
    draw(raster_grob(matrix(c("red", "blue"), 1), x = 0.9, width = 0.1, height = 0.2))
  f1 <- withr::local_tempfile(fileext = ".pptx")
  f2 <- withr::local_tempfile(fileext = ".pptx")
  render(sc, f1)
  render(sc, f2)
  expect_identical(unname(tools::md5sum(f1)), unname(tools::md5sum(f2)))
  parts <- utils::unzip(f1, list = TRUE)$Name
  expect_identical(parts[1], "[Content_Types].xml")
  expect_true(all(
    c(
      "ppt/presentation.xml",
      "ppt/slides/slide1.xml",
      "ppt/slideMasters/slideMaster1.xml",
      "ppt/theme/theme1.xml",
      "ppt/media/image1.png"
    ) %in%
      parts
  ))
  dir <- withr::local_tempdir()
  utils::unzip(f1, exdir = dir)
  pres <- xml2::read_xml(file.path(dir, "ppt/presentation.xml"))
  sz <- xml2::xml_find_first(pres, "//p:sldSz", xml2::xml_ns(pres))
  expect_identical(xml2::xml_attr(sz, "cx"), "1828800")
  expect_identical(xml2::xml_attr(sz, "cy"), "914400")
  core <- readLines(file.path(dir, "docProps/core.xml"), warn = FALSE)
  expect_false(any(grepl("dcterms:(created|modified)|lastModifiedBy|creator", core)))
  expect_true(any(grepl("<dc:title>Deck</dc:title>", core, fixed = TRUE)))
  slide <- xml2::read_xml(file.path(dir, "ppt/slides/slide1.xml"))
  ids <- xml2::xml_attr(xml2::xml_find_all(slide, "//p:cNvPr", xml2::xml_ns(slide)), "id")
  expect_false(anyDuplicated(ids) > 0)
  embed <- xml2::xml_attr(xml2::xml_find_first(slide, "//a:blip", xml2::xml_ns(slide)), "embed")
  rels <- xml2::read_xml(file.path(dir, "ppt/slides/_rels/slide1.xml.rels"))
  rel <- xml2::xml_find_first(rels, sprintf("//*[@Id='%s']", embed))
  expect_identical(xml2::xml_attr(rel, "Target"), "../media/image1.png")
})

test_that("pptx_pages() writes a deck officer can read", {
  skip_if_not_installed("officer")
  slides <- list(
    vl_scene(4, 3, dpi = 96) |> draw(text_grob("one")),
    vl_scene(6, 2, dpi = 96) |> draw(text_grob("two"))
  )
  f <- withr::local_tempfile(fileext = ".pptx")
  expect_identical(pptx_pages(slides, f), f)
  deck <- officer::read_pptx(f)
  expect_identical(length(deck), 2L)
  s <- officer::pptx_summary(deck)
  expect_true(all(c("one", "two") %in% s$text))
  # the deck takes the largest page; the bytes come back when path = NULL
  expect_identical(officer::slide_size(deck), list(width = 6, height = 3))
  expect_type(pptx_pages(slides), "raw")
  expect_error(pptx_pages(list()), "non-empty")
})

test_that("pptx_pages() checks the title whether or not it writes a file", {
  slides <- list(vl_scene(2, 1, dpi = 96))
  f <- withr::local_tempfile(fileext = ".pptx")
  expect_error(pptx_pages(slides, title = 1), "title")
  expect_error(pptx_pages(slides, f, title = c("a", "b")), "title")
  expect_false(file.exists(f))
})

test_that("a control character in the title leaves the package readable", {
  skip_if_not_installed("xml2")
  f <- withr::local_tempfile(fileext = ".pptx")
  pptx_pages(list(vl_scene(2, 1, dpi = 96)), f, title = "a\001b")
  d <- withr::local_tempdir()
  utils::unzip(f, files = "docProps/core.xml", exdir = d)
  core <- xml2::read_xml(file.path(d, "docProps", "core.xml"))
  expect_identical(xml2::xml_text(xml2::xml_find_first(core, ".//dc:title")), "ab")
})

# Schema validation needs xmllint and the ECMA-376 transitional schemas, which
# are too large to ship: point VELLUM_PML_XSD at a local pml.xsd to run it.
test_that("the package's parts validate against the PresentationML schema", {
  skip_on_cran()
  xsd <- Sys.getenv("VELLUM_PML_XSD")
  skip_if(!nzchar(xsd) || !file.exists(xsd), "VELLUM_PML_XSD not set")
  skip_if(!nzchar(Sys.which("xmllint")), "xmllint not available")
  stripes <- linear_gradient(c("red", "blue"), x1 = 0, y1 = 0, x2 = 1, y2 = 1)
  sc <- vl_scene(4, 3, dpi = 96, bg = "white") |>
    push(vl_viewport(name = "panel", clip = TRUE, width = 0.8, height = 0.8)) |>
    draw(rect_grob(gp = vl_gpar(fill = stripes, col = "black", lty = "dashed"))) |>
    draw(circle_grob(r = 0.7, gp = vl_gpar(fill = "orange", alpha = 0.5))) |>
    draw(text_grob("a\001b\nc", rot = 30, gp = vl_gpar(fontsize = 20))) |>
    draw(points_grob(
      c(0.1, 0.3, 0.32, 0.6),
      0.2,
      shape = "triangle",
      gp = vl_gpar(fill = "gold", col = "black")
    )) |>
    draw(points_grob(c(0.1, 0.5, 0.52), 0.8, gp = vl_gpar(col = NA))) |>
    draw(text_grob(md("R^2^ **b** *c* [d]{red}\nx~i~"), y = 0.2)) |>
    pop() |>
    push(vl_viewport(blend = "multiply")) |>
    draw(rect_grob(width = 0.3, gp = vl_gpar(fill = "steelblue"))) |>
    pop()
  f <- withr::local_tempfile(fileext = ".pptx")
  suppressWarnings(pptx_pages(list(sc, sc), f))
  d <- withr::local_tempdir()
  utils::unzip(f, exdir = d)
  parts <- list.files(file.path(d, "ppt"), "\\.xml$", recursive = TRUE, full.names = TRUE)
  out <- suppressWarnings(system2(
    "xmllint",
    c("--noout", "--schema", shQuote(xsd), shQuote(parts)),
    stdout = TRUE,
    stderr = TRUE
  ))
  expect_identical(out[!grepl(" validates$", out)], character())
})
