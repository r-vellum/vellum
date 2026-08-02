# Phase 10 -- the typography layer: width-constrained text and text on a path.
#
# Both features exist because vellum measures text when the scene is *built*,
# not when it is drawn. Wrapping needs to know how wide a candidate line shapes
# to; setting text on a curve needs to know each glyph's pen position. In grid
# neither number exists before a device is open.

library(vellum)

CAPTION <- paste(
  "Text that has to fit a fixed measure is the ordinary case for a subtitle,",
  "a caption, or an annotation pinned to a panel. Breaking it by hand is",
  "guesswork, because the right break depends on the font, the size and the",
  "OpenType features actually in force."
)

# --- 1. wrapping and alignment ----------------------------------------------
#
# `width` must be an absolute unit. That is deliberate: the label is wrapped
# when the grob is built, and a viewport's size in npc/native is not known until
# render time. Pass the physical measure you want to wrap to.

box <- function(scene, x, align) {
  scene |>
    draw(rect_grob(
      x = x,
      y = 0.5,
      width = vl_unit(46, "mm"),
      height = vl_unit(52, "mm"),
      gp = vl_gpar(fill = "grey97", col = "grey85")
    )) |>
    draw(text_grob(
      sprintf('align = "%s"', align),
      x = x,
      y = 0.9,
      gp = vl_gpar(fontsize = 9, col = "grey40")
    )) |>
    draw(text_grob(
      CAPTION,
      x = x,
      y = 0.5,
      width = vl_unit(42, "mm"),
      align = align,
      gp = vl_gpar(fontsize = 7.5)
    ))
}

alignment <- vl_scene(7.6, 2.6, dpi = 150, bg = "white") |>
  box(0.14, "left") |>
  box(0.38, "centre") |>
  box(0.62, "right") |>
  box(0.86, "justify")

render(alignment, "typography-wrapping.png")

# The block is a *box* of exactly the requested width, so `just` anchors the
# box rather than the longest line -- which is what makes a right-aligned
# caption line up with a panel edge.

# --- 2. auto-fit -------------------------------------------------------------
#
# `fit = TRUE` shrinks the font -- never grows it -- until the wrapped block
# fits width x height. Each probe re-wraps, because the line breaks depend on
# the size. One size is chosen for the whole grob: a row of labels at four
# different sizes is a defect, not a feature.

fitted <- vl_scene(6, 2.4, dpi = 150, bg = "white")
for (i in seq_along(hs <- c(34, 22, 14))) {
  x <- c(0.18, 0.5, 0.82)[i]
  fitted <- fitted |>
    draw(rect_grob(
      x = x,
      y = 0.45,
      width = vl_unit(40, "mm"),
      height = vl_unit(hs[i], "mm"),
      gp = vl_gpar(fill = NA, col = "grey80", lty = "dashed")
    )) |>
    draw(text_grob(
      CAPTION,
      x = x,
      y = 0.45,
      width = vl_unit(38, "mm"),
      height = vl_unit(hs[i] - 2, "mm"),
      fit = TRUE,
      align = "justify",
      gp = vl_gpar(fontsize = 11)
    )) |>
    draw(text_grob(
      paste0("height = ", hs[i], "mm"),
      x = x,
      y = 0.9,
      gp = vl_gpar(fontsize = 9, col = "grey40")
    ))
}
render(fitted, "typography-autofit.png")

# --- 3. text on a path -------------------------------------------------------
#
# Each glyph keeps the pen position shaping gave it and is placed that far along
# the baseline, rotated to the local tangent. Arc length is measured on the
# *rendered* path, which is why this cannot happen R-side.

arc <- function(from, to, r, cx = 0.5, cy = 0.5, n = 120) {
  th <- seq(from, to, length.out = n)
  list(x = cx + r * cos(th), y = cy + r * sin(th))
}

upper <- arc(pi, 0, 0.34)
lower <- arc(pi, 2 * pi, 0.34) # reversed, so the lower label reads the right way up

seal <- vl_scene(3.2, 3.2, dpi = 150, bg = "white") |>
  draw(circle_grob(
    r = 0.4,
    gp = vl_gpar(fill = NA, col = "grey75", lwd = 1.5)
  )) |>
  draw(circle_grob(r = 0.26, gp = vl_gpar(fill = "grey96", col = NA))) |>
  draw(text_path_grob(
    "MEASURED AT CONSTRUCTION",
    x = upper$x,
    y = upper$y,
    offset = 5,
    gp = vl_gpar(fontsize = 10.5)
  )) |>
  draw(text_path_grob(
    "NOT AT DRAW TIME",
    x = lower$x,
    y = lower$y,
    offset = -13,
    gp = vl_gpar(fontsize = 10.5)
  )) |>
  draw(text_grob("vellum", gp = vl_gpar(fontsize = 15, col = "grey35")))

render(seal, "typography-textpath.png")

# Glyphs follow the tangent, exactly as SVG `textPath` does. A label on the
# underside of a closed curve therefore reads upside-down; the fix is to reverse
# the *path*, as `lower` does above, not to flip the glyphs -- flipping them
# individually turns the run into mirror-writing.

# On-path text is an ordinary text node with a baseline attached, so everything
# else still applies: halos, OpenType features, colour, and all three backends.

wave <- local({
  x <- seq(0.04, 0.96, length.out = 200)
  vl_scene(6, 1.8, dpi = 150, bg = "#20304A") |>
    draw(text_path_grob(
      "a halo keeps a label legible wherever the curve takes it",
      x = x,
      y = 0.5 + 0.22 * sin(x * 3 * pi),
      just = "left",
      offset = 3,
      gp = vl_gpar(
        fontsize = 13,
        col = "white",
        halo_col = "#20304A",
        halo_width = 2.5
      )
    ))
})
render(wave, "typography-onpath-halo.png")
render(wave, "typography-onpath-halo.svg") # real <text>, one element per glyph
