# Phase 13 -- accessible output and reproducible fonts.
#
# Two things that are not features so much as promises being kept: a PDF that a
# screen reader can navigate, and a check on the one part of vellum's
# determinism claim that vellum does not control.

library(vellum)

# --- 1. tagged PDF -----------------------------------------------------------
#
# vellum has carried per-mark `id`/`role`/`name` for a while, and has emitted it
# into SVG. Routing the same channel into a PDF structure tree makes the marks
# navigable rather than a flat picture.

set.seed(2)
region <- c("North", "South", "East", "West")
sales <- c(42, 31, 55, 28)

plot <- vl_scene(5, 3.2, dpi = 150, bg = "white") |>
  # Decorative: `role = "presentation"` marks it an artifact, so a screen reader
  # skips it. A gridline announced aloud is noise.
  draw(rect_grob(
    y = 0.55,
    height = 0.72,
    gp = vl_gpar(fill = "grey97", col = NA),
    role = "presentation",
    name = "panel background"
  )) |>
  draw(text_grob(
    "Sales by region",
    y = 0.94,
    gp = vl_gpar(fontsize = 13),
    role = "heading",
    name = "Sales by region"
  ))

for (i in seq_along(region)) {
  plot <- plot |>
    draw(rect_grob(
      x = (i - 0.5) / 4,
      y = 0.2 + sales[i] / 200,
      width = 0.14,
      height = sales[i] / 100,
      gp = vl_gpar(fill = "#2C6FA6", col = NA),
      role = "img",
      # `name` becomes the mark's alt text, so make it a sentence a
      # screen reader can read out, not an internal identifier.
      name = sprintf("%s: %d units", region[i], sales[i])
    )) |>
    draw(text_grob(
      region[i],
      x = (i - 0.5) / 4,
      y = 0.1,
      gp = vl_gpar(fontsize = 9, col = "grey35"),
      role = "presentation",
      name = region[i]
    ))
}

# `describe()` supplies the alt text for the figure as a whole.
plot <- describe(
  plot,
  title = "Sales by region",
  desc = paste(
    "A bar chart of unit sales across four regions. East is highest",
    "at 55 units; West is lowest at 28."
  )
)

render(plot, "accessible-sales.pdf")
render(plot, "accessible-sales.svg") # the same metadata, as data-* and role
render(plot, "accessible-sales.png")

# What lands in the PDF: a StructTreeRoot, a Figure for the whole plot carrying
# the `describe()` text, and one structure element per marked-up mark, in draw
# order -- which for a graphic IS reading order, since it is the order the
# author put the marks in.
pdf <- scene_pdf(plot)
cat("tagged:", length(grepRaw("StructTreeRoot", pdf, fixed = TRUE)) > 0, "\n")

# Roles map onto PDF structure types. Anything unrecognised becomes a Figure,
# which is the right default for a mark and the one PDF/UA requires alt text
# for:
#
#   "heading"                     -> H1 (title from `name`)
#   "paragraph" / "text"          -> P
#   "caption"                     -> Caption
#   "listitem"                    -> LI
#   "presentation" / "none"       -> Artifact (skipped by assistive tech)
#   anything else                 -> Figure with Alt from `name`
#
# Tagging is metadata: the rendered pixels are untouched, and a scene with no
# marked-up nodes produces exactly the PDF it always did.

# --- 2. reproducible fonts ---------------------------------------------------
#
# `DESIGN.md` claims identical pixels on every OS and in CI. Layout, shaping and
# rasterisation deliver that. Turning a family name into a *file* does not:
# "sans" is Helvetica here and DejaVu Sans on a CI runner, and the pixels differ
# for a reason the claim does not cover.

print(scene_fonts(plot))

# A pin records what was used. Store it next to a reference image, and a failing
# comparison can be attributed rather than guessed at.
pin <- font_pin(plot)
print(pin)
saveRDS(pin, "accessible-fonts.rds")

# Later, on another machine or in CI:
diffs <- font_check(plot, pin, on_mismatch = "ignore")
if (nrow(diffs)) {
  cat("fonts moved:\n")
  print(diffs)
} else {
  cat("fonts match the pin\n")
}

# In a test, this is the assertion that makes a pixel comparison meaningful:
#
#   test_that("the figure is unchanged", {
#     expect_equal(nrow(font_check(my_plot(), readRDS("fonts.rds"))), 0)
#     expect_snapshot_file(render(my_plot(), "plot.png"))
#   })
#
# Without the first line, the second fails on any machine with different fonts
# and tells you nothing about your change.
#
# Note what this deliberately does NOT do: bundle the font. vellum resolves
# fonts through systemfonts so that it agrees with the rest of R's graphics
# stack, and embedding files would break that agreement and raise licensing
# questions vellum should not answer for you. When you need a guarantee rather
# than a check, register the exact file with `systemfonts::register_font()` and
# pin that.
