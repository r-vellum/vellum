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

test_that("rich, tex and outline text become glyph outlines", {
  skip_if_not_installed("xml2")
  sc <- vl_scene(3, 1, dpi = 96) |>
    draw(text_grob(md("a **b**"), x = 0.3)) |>
    draw(text_grob(tex("\\frac{1}{2}"), x = 0.7))
  doc <- xml2::read_xml(.dml_fragment(sc)$xml)
  ns <- xml2::xml_ns(doc)
  expect_length(xml2::xml_find_all(doc, ".//a:t", ns), 0)
  expect_gt(length(xml2::xml_find_all(doc, ".//a:custGeom", ns)), 1)
  plain <- vl_scene(3, 1, dpi = 96) |> draw(text_grob("abc"))
  out <- xml2::read_xml(.dml_fragment(plain, text = "outline")$xml)
  expect_length(xml2::xml_find_all(out, ".//a:t", ns), 0)
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

test_that("unsupported effects are reported", {
  sc <- vl_scene(2, 1, dpi = 96) |>
    draw(rect_grob(
      gp = vl_gpar(fill = linear_gradient(c("red", "blue")))
    ))
  fr <- .dml_fragment(sc)
  expect_match(fr$warnings, "gradient", all = FALSE)
})
