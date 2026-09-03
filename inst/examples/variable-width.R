# Variable-width strokes — a line whose width follows the data.
#
# Two routes to the same geometry, and the choice between them is about WHEN it
# resolves:
#
#   lines_grob(lwd_profile = )  builds the ribbon at render, inside the grob's
#                               viewport. Needs no page size, so it survives
#                               being laid out and tapers correctly at any size.
#   stroke_to_path(lwd_profile = , along = )
#                               bakes an outline at a page size you supply, and
#                               hands back a fillable shape -- so it composes
#                               with gradients, boolean ops and hatching, and it
#                               can spread a profile by ARC LENGTH.
#
# Both use the same generator: external common tangents, so a taper reaches its
# point rather than waisting, with one non-zero self-union to clean up tight
# bends and the inner side of each join.
#
# A varying-width stroke is an outline that gets filled (no backend can stroke
# one path at several widths), so the stroke colour paints the ribbon, `lty`
# does not apply, and PNG/SVG/PDF all get the same geometry.
#
# Run with:  Rscript inst/examples/variable-width.R  [output.png|.svg|.pdf]

library(vellum)

out <- commandArgs(trailingOnly = TRUE)[1]
if (is.na(out)) {
  out <- "variable-width.png"
}

lab <- function(t, y) {
  text_grob(
    t,
    x = 0.02,
    y = y,
    just = "left",
    gp = vl_gpar(fontsize = 9, col = "grey35")
  )
}
xs <- function(n) seq(0.16, 0.97, length.out = n)

n <- 48
th <- seq(0, 4 * pi, length.out = n)

s <- vl_scene(vl_unit(8, "in"), vl_unit(5, "in"), dpi = 150, bg = "white") |>
  push(vl_viewport())

# 1. A taper to a point: the usual reason to want this. A zero width is legal.
s <- s |>
  draw(lab("taper", 0.90)) |>
  draw(lines_grob(
    xs(n),
    rep(0.90, n),
    gp = vl_gpar(col = "grey20", lwd = 13),
    lwd_profile = seq(1, 0, length.out = n)
  ))

# 2. A leaf: swells in the middle, symmetric.
s <- s |>
  draw(lab("leaf", 0.74)) |>
  draw(lines_grob(
    xs(n),
    rep(0.74, n),
    gp = vl_gpar(col = "seagreen", lwd = 13),
    lwd_profile = sin(seq(0, pi, length.out = n))
  ))

# 3. Data-driven width on a wiggly path — the flow-map shape: one width per
#    vertex, coming from a value attached to that vertex.
s <- s |>
  draw(lab("per-vertex", 0.58)) |>
  draw(lines_grob(
    xs(n),
    0.58 + sin(th) / 26,
    gp = vl_gpar(col = "steelblue", lwd = 15),
    lwd_profile = 0.25 + abs(cos(th))
  ))

# 4. Sharp corners, to show the joins: a mitre on a tapered bend is where a
#    naive perpendicular offset would pinch or leave a spur.
s <- s |>
  draw(lab("joins", 0.40)) |>
  draw(lines_grob(
    c(0.16, 0.36, 0.56, 0.76, 0.97),
    c(0.34, 0.48, 0.30, 0.48, 0.36),
    gp = vl_gpar(col = "#7B4FA8", lwd = 17, linejoin = "mitre"),
    lwd_profile = c(0.25, 1.4, 0.45, 1.4, 0.3)
  ))

# 5. A gradient stroke paint: the ribbon is filled, so a paint on `col` ramps
#    along it the way it would along the stroke.
s <- s |>
  draw(lab("gradient col", 0.20)) |>
  draw(lines_grob(
    xs(n),
    0.20 + sin(th) / 30,
    gp = vl_gpar(col = linear_gradient(c("tomato", "gold")), lwd = 15),
    lwd_profile = 0.3 + abs(sin(th / 2))
  ))

# 6. The construction-time route, for contrast: an outline is a SHAPE, so it can
#    be filled with something the stroke could not carry -- and `along` can
#    spread the profile by arc length instead of per vertex.
band <- lines_grob(
  c(0.16, 0.36, 0.56, 0.76, 0.97),
  rep(0.06, 5),
  gp = vl_gpar(col = "black", lwd = 16)
)
s <- s |>
  draw(lab("stroke_to_path (arclength)", 0.115)) |>
  draw(S7::set_props(
    stroke_to_path(
      band,
      width = 8,
      height = 5,
      lwd_profile = c(0.1, 1, 0.1),
      along = "arclength"
    ),
    gp = vl_gpar(
      fill = linear_gradient(c("#2C5F8A", "#8AC6F2")),
      col = "grey25",
      lwd = 0.5
    )
  ))

render(pop(s), out)
cat("wrote", out, "\n")
