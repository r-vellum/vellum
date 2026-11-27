# Numeric font weights (F-26): `vl_gpar(fontweight =)` picks the face file of
# a multi-weight family, and leaves unweighted text exactly as it was.

# An installed family with separate light, regular and bold upright faces, or
# NULL. The candidates are common on macOS, Linux and CI images.
multi_weight_family <- function() {
  fams <- c(
    "Helvetica Neue",
    "Inter",
    "Lato",
    "Source Sans 3",
    "Source Sans Pro",
    "Roboto",
    "Open Sans",
    "Noto Sans",
    "DejaVu Sans"
  )
  sf <- systemfonts::system_fonts()
  for (f in fams) {
    w <- sf$weight[sf$family == f & !sf$italic]
    if (all(c("light", "normal", "bold") %in% as.character(w))) {
      return(f)
    }
  }
  NULL
}

shaped_face <- function(family, weight) {
  sh <- textshaping::shape_text("Hamburg", family = family, weight = weight)
  paste(unique(sh$shape$font_path), unique(sh$shape$font_index))
}

text_scene <- function(gp) {
  vl_scene(2, 1) |> draw(text_grob("Hamburg", gp = gp))
}

test_that("fontweight validates and normalises names to numbers", {
  expect_null(vl_gpar()@fontweight)
  expect_identical(vl_gpar(fontweight = 300)@fontweight, 300L)
  expect_identical(vl_gpar(fontweight = "semi-bold")@fontweight, 600L)
  expect_identical(vl_gpar(fontweight = "SemiBold")@fontweight, 600L)
  expect_identical(vl_gpar(fontweight = "light")@fontweight, 300L)
  expect_identical(style(fontweight = "black")@fontweight, 900L)
  expect_error(vl_gpar(fontweight = 350), "steps of 100")
  expect_error(vl_gpar(fontweight = 350), class = "vellum_error_fontweight")
  expect_error(vl_gpar(fontweight = 1000), "steps of 100")
  expect_error(vl_gpar(fontweight = "chunky"), "weight name")
  expect_error(vl_gpar(fontweight = c(300, 400)), "single weight")
})

test_that("the face string carries the weight only when one is set", {
  expect_identical(vellum:::.gp_face(vl_gpar()), "plain")
  expect_identical(vellum:::.gp_face(vl_gpar(fontface = "bold")), "bold")
  expect_identical(
    vellum:::.gp_face(vl_gpar(fontface = "italic", fontweight = 300)),
    "italic@300"
  )
  expect_identical(
    vellum:::.rs_face("italic@300"),
    list(italic = TRUE, weight = 300L)
  )
  # the weight replaces the bold a face name implies
  expect_identical(vellum:::.rs_face("bold@300")$weight, 300L)
  expect_identical(
    vellum:::.rs_face("bold.italic"),
    list(italic = TRUE, weight = "bold")
  )
})

test_that("a bold markdown run is at least 700 over a weighted base", {
  f <- vellum:::.md_run_face
  expect_identical(f("plain@300", list(bold = TRUE)), "plain@700")
  expect_identical(f("plain@900", list(bold = TRUE)), "plain@900")
  expect_identical(f("plain@300", list(italic = TRUE)), "italic@300")
  expect_identical(f("bold@300", list()), "plain@300")
  # unweighted faces behave as before
  expect_identical(f("plain", list(bold = TRUE)), "bold")
})

test_that("unweighted text renders byte-identically", {
  # fontweight = NULL must not change the scene, its serialization or its SVG
  a <- text_scene(vl_gpar(fontsize = 14))
  expect_false(grepl("@", scene_svg(a), fixed = TRUE))
  spec <- paste(utils::capture.output(str(as_scene_spec(a))), collapse = "\n")
  expect_false(grepl("fontweight", spec, fixed = TRUE))
})

test_that("native SVG text carries the numeric weight", {
  s <- scene_svg(text_scene(vl_gpar(fontweight = 300)))
  expect_match(s, 'font-weight="300"', fixed = TRUE)
  s <- scene_svg(text_scene(vl_gpar(fontface = "bold")))
  expect_match(s, 'font-weight="bold"', fixed = TRUE)
})

test_that("a weight resolves to that face file of a multi-weight family", {
  fam <- multi_weight_family()
  skip_if(is.null(fam), "no family with light, regular and bold faces")
  light <- shaped_face(fam, 300L)
  regular <- shaped_face(fam, "normal")
  expect_false(identical(light, regular))
  # the glyphs the renderer draws come from the light face: its outlines
  # differ from the regular ones and match an explicit "light" weight
  outline <- function(gp) scene_svg(text_scene(gp), text = "outline")
  o_light <- outline(vl_gpar(fontfamily = fam, fontweight = 300))
  expect_false(identical(o_light, outline(vl_gpar(fontfamily = fam))))
  expect_identical(o_light, outline(vl_gpar(fontfamily = fam, fontweight = "light")))
  expect_identical(
    outline(vl_gpar(fontfamily = fam, fontweight = 700)),
    outline(vl_gpar(fontfamily = fam, fontface = "bold"))
  )
  # measurement follows the weight (light, regular and bold differ in width)
  w <- vapply(
    list(300, 400, 700),
    function(wt) vl_strwidth("Hamburg", family = fam, fontweight = wt),
    numeric(1)
  )
  expect_identical(length(unique(w)), 3L)
  expect_identical(
    vl_strwidth("Hamburg", family = fam, fontweight = 700),
    vl_strwidth("Hamburg", family = fam, fontface = "bold")
  )
  # grobwidth of a weighted text grob uses the weight too
  g_light <- text_grob("Hamburg", gp = vl_gpar(fontfamily = fam, fontweight = 300))
  g_reg <- text_grob("Hamburg", gp = vl_gpar(fontfamily = fam))
  expect_lt(
    vellum:::.grob_extent(g_light)[1],
    vellum:::.grob_extent(g_reg)[1]
  )
})

test_that("rich labels take the weight as their base", {
  fam <- multi_weight_family()
  skip_if(is.null(fam), "no family with light, regular and bold faces")
  w_light <- vl_strwidth(md("Ham**burg**"), family = fam, fontweight = 300)
  w_reg <- vl_strwidth(md("Ham**burg**"), family = fam)
  expect_false(identical(w_light, w_reg))
})

test_that("a weight the family lacks snaps to its nearest face", {
  # A font added for the session matches only its exact weights in
  # systemfonts; without snapping, weight 300 fell back to the default family.
  skip_if_not_installed("systemfonts", "1.2.0")
  otf <- system.file("fonts", "STIXTwoMath-Regular.otf", package = "vellum")
  skip_if(!nzchar(otf), "bundled STIX Two Math not found")
  fam <- "STIX Two Math"
  if (!fam %in% systemfonts::system_fonts()$family) {
    # not there yet: the weight passes through, and is memoised...
    expect_identical(vellum:::.snap_weight(fam, FALSE, 300L), 300L)
  }
  systemfonts::add_fonts(otf)
  # ...but the memo notices the newly added face (the matched file changed)
  skip_if(
    !fam %in% systemfonts::system_fonts()$family,
    "added font not listed by system_fonts()"
  )
  expect_identical(vellum:::.snap_weight(fam, FALSE, 300L), 400L)
  expect_identical(vellum:::.snap_weight(fam, FALSE, 900L), 400L)
  expect_identical(vellum:::.snap_weight(fam, FALSE, "bold"), "bold")
  expect_identical(vellum:::.snap_weight("No Such Family", FALSE, 300L), 300L)
  expect_identical(
    vl_strwidth("Hamburg", family = fam, fontweight = 300),
    vl_strwidth("Hamburg", family = fam)
  )
})

test_that("adding a heavier face of a family re-snaps a cached weight", {
  # Uses Aller from hexSticker when installed (regular, light and bold files).
  skip_if_not_installed("systemfonts", "1.2.0")
  dir <- system.file("fonts", "Aller", package = "hexSticker")
  skip_if(!nzchar(dir), "hexSticker's Aller fonts not installed")
  skip_if("Aller" %in% systemfonts::system_fonts()$family, "Aller already listed")
  systemfonts::add_fonts(file.path(dir, "Aller_Rg.ttf"))
  expect_identical(vellum:::.snap_weight("Aller", FALSE, 700L), 400L)
  systemfonts::add_fonts(file.path(dir, "Aller_Bd.ttf"))
  expect_identical(vellum:::.snap_weight("Aller", FALSE, 700L), 700L)
  expect_identical(
    vl_strwidth("Hamburg", family = "Aller", fontweight = 700),
    vl_strwidth("Hamburg", family = "Aller", fontface = "bold")
  )
})

test_that("a weight snaps to a normal-width face first (VL-20)", {
  wl <- c(
    "thin", "ultralight", "light", "normal", "medium", "semibold", "bold",
    "ultrabold", "heavy"
  )
  wd <- c(
    "ultracondensed", "extracondensed", "condensed", "semicondensed",
    "normal", "semiexpanded", "expanded", "extraexpanded", "ultraexpanded"
  )
  faces <- function(weight, width, italic = FALSE, style = NULL) {
    # a style name that says the width, as real faces' names do
    style <- style %||% ifelse(is.na(width) | width == "normal", "Regular", "Condensed")
    data.frame(
      weight = factor(weight, levels = wl, ordered = TRUE),
      width = factor(width, levels = wd, ordered = TRUE),
      italic = rep(italic, length(weight)),
      style = rep(style, length.out = length(weight))
    )
  }
  # Helvetica Neue's upright faces on macOS: the only 900 is condensed
  hn <- faces(
    c("thin", "ultralight", "light", "normal", "medium", "bold", "bold", "heavy"),
    c(rep("normal", 6), "semicondensed", "semicondensed"),
    style = c(
      "UltraLight", "Thin", "Light", "Regular", "Medium", "Bold",
      "Condensed Bold", "Condensed Black"
    )
  )
  expect_identical(.pick_weight(hn, FALSE, 900L), 700L)
  expect_identical(.pick_weight(hn, FALSE, 800L), 700L)
  expect_identical(.pick_weight(hn, FALSE, 300L), 300L)
  # no normal-width face: every width counts
  cond <- faces(c("normal", "heavy"), "condensed")
  expect_identical(.pick_weight(cond, FALSE, 900L), 900L)
  # no width information: every face counts
  nowd <- faces(c("normal", "heavy"), NA)
  expect_identical(.pick_weight(nowd, FALSE, 800L), 900L)
  # the style filter still comes first, and a tie still goes heavier
  mixed <- rbind(
    faces(c("normal", "bold"), "normal"),
    faces("heavy", "normal", italic = TRUE)
  )
  expect_identical(.pick_weight(mixed, TRUE, 400L), 900L)
  expect_identical(.pick_weight(mixed, FALSE, 550L), 700L)
  expect_identical(.pick_weight(faces(character(), character()), FALSE, 500L), 500L)
  # a width tag the style name does not back is ignored: Sukhumvit Set's
  # Thin is tagged semicondensed, and must stay reachable
  sk <- faces(
    c("thin", "light", "normal", "medium", "semibold", "bold"),
    c("semicondensed", rep("normal", 5)),
    style = c("Thin", "Light", "Text", "Medium", "SemiBold", "Bold")
  )
  expect_identical(.pick_weight(sk, FALSE, 100L), 100L)
  # "SemiCondensed" and "Extra Expanded" styles count as other widths
  sc <- faces(
    c("normal", "heavy", "heavy"),
    c("normal", "semicondensed", "extraexpanded"),
    style = c("Regular", "SemiCondensed Black", "Extra Expanded Black")
  )
  expect_identical(.pick_weight(sc, FALSE, 900L), 400L)
})

test_that("Helvetica Neue at weight 900 is not the condensed face (VL-20)", {
  sf <- systemfonts::system_fonts()
  hn <- sf[sf$family == "Helvetica Neue" & !sf$italic, ]
  skip_if(
    !any(hn$weight == "heavy" & hn$width != "normal") ||
      !any(hn$weight == "bold" & hn$width == "normal"),
    "Helvetica Neue with a condensed black face not installed"
  )
  expect_identical(
    vl_strwidth("Hamburg", family = "Helvetica Neue", fontweight = 900),
    vl_strwidth("Hamburg", family = "Helvetica Neue", fontweight = 700)
  )
})
