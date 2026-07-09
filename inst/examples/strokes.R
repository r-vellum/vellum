# A worked vellum example: stroke fidelity (P2).
#
# Line types (lty), end caps (lineend), and corner joins (linejoin) — all
# inheritable gpar fields, rendered across PNG/SVG/PDF. Dash lengths scale with
# the line width, following grid's convention.
#
# Run with:  Rscript inst/examples/strokes.R  [output.png|.svg|.pdf]

library(vellum)

types <- c("solid", "dashed", "dotted", "dotdash", "longdash", "twodash")

s <- vl_scene(width = 7, height = 4, dpi = 150, bg = "white")

# Left half: each line type as a labelled dashed stroke.
for (i in seq_along(types)) {
  y <- 1 - (i - 0.5) / length(types)
  s <- s |>
    draw(lines_grob(vl_unit(c(0.04, 0.40), "npc"), vl_unit(c(y, y), "npc"),
                    gp = vl_gpar(col = "#1f4e79", lwd = 3, lty = types[i]))) |>
    draw(text_grob(types[i], x = 0.43, y = y, just = c("left", "centre"),
                   gp = vl_gpar(fontsize = 12)))
}

# Right half: caps and joins on a thick angled stroke (an open "V" path shows
# the join; the free ends show the cap).
vee <- function(x0) {
  lines_grob(vl_unit(x0 + c(0, 0.06, 0.12), "npc"), vl_unit(c(0.62, 0.78, 0.62), "npc"),
             gp = vl_gpar(col = "firebrick", lwd = 12, lineend = cap, linejoin = join))
}
caps  <- c("butt", "round", "square")
joins <- c("mitre", "round", "bevel")
for (j in seq_along(caps)) {
  cap <- caps[j]; join <- joins[j]
  x0 <- 0.58 + (j - 1) * 0.14
  s <- s |>
    draw(vee(x0)) |>
    draw(text_grob(paste0(cap, "/", join), x = x0 + 0.06, y = 0.5,
                   just = c("centre", "top"), gp = vl_gpar(fontsize = 11)))
}
s <- s |> draw(text_grob("line types", x = 0.22, y = 0.97, gp = vl_gpar(fontface = "bold"))) |>
  draw(text_grob("caps / joins", x = 0.72, y = 0.97, gp = vl_gpar(fontface = "bold")))

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else file.path(tempdir(), "vellum-strokes.png")
render(s, out)
message("wrote ", out)
