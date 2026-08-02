# A worked vellum example: static analysis for graphics.
#
#   * `vl_lint(scene)`      -- find the mistakes you would otherwise find by
#                              squinting at the output.
#   * `scene_stats(scene)`  -- ink coverage and an overplotting index.
#   * `profile_render(s)`   -- which marks cost the render time.
#
# All three work because vellum resolves layout and text metrics BEFORE drawing.
# A layer on top of grid cannot ask "how many pixels tall is this label" --
# the answer does not exist until a device is open.
#
# Run with:  Rscript inst/examples/linting.R  [output.png]

library(vellum)

out <- commandArgs(trailingOnly = TRUE)
out <- if (length(out)) out[[1]] else "linting.png"

set.seed(1)

# --- a plot with four planted defects ---------------------------------------
bad <- vl_scene(5, 3, dpi = 130, bg = "white") |>
  push(vl_viewport(
    name = "panel",
    x = 0.5,
    y = 0.55,
    width = 0.85,
    height = 0.7,
    xscale = c(0, 1),
    yscale = c(0, 1),
    clip = TRUE
  )) |>
  draw(rect_grob(gp = vl_gpar(fill = "grey96", col = "grey70"))) |>
  draw(points_grob(
    runif(120),
    runif(120),
    size = vl_unit(1.6, "mm"),
    gp = vl_gpar(fill = "#7FB2E5", col = NA),
    name = "cloud"
  )) |>
  # 1. a mark placed outside the panel's clip -- silently never drawn
  draw(points_grob(
    2.4,
    0.5,
    size = vl_unit(3, "mm"),
    gp = vl_gpar(fill = "tomato", col = NA),
    name = "stray_point"
  )) |>
  # 2. a label too small to read
  draw(text_grob(
    "n = 120",
    x = 0.06,
    y = 0.93,
    just = c("left", "top"),
    gp = vl_gpar(fontsize = 2.5),
    name = "n_label"
  )) |>
  # 3. a label that will not contrast with the panel behind it
  draw(text_grob(
    "watermark",
    x = 0.5,
    y = 0.5,
    gp = vl_gpar(fontsize = 22, col = "#F2F2F2"),
    name = "watermark"
  )) |>
  # 4. an annotation nothing will ever paint
  draw(rect_grob(
    x = 0.8,
    y = 0.2,
    width = 0.2,
    height = 0.1,
    gp = vl_gpar(fill = NA, col = NA),
    name = "empty_box"
  )) |>
  pop() |>
  draw(text_grob(
    "A plot with four planted defects",
    y = 0.94,
    gp = vl_gpar(fontsize = 13, fontface = "bold")
  ))

cat("== vl_lint() ==\n")
print(vl_lint(bad))

cat("\n== the rules that ran ==\n")
print(vl_lint_rules())

# --- a custom rule -----------------------------------------------------------
# The registry is the extension point: vellum supplies geometric rules, and a
# layer above can add rules that know about its own semantics.
vl_lint_rule(
  "wide_marks",
  function(scene, nodes, ctx) {
    wide <- nodes[(nodes$x1 - nodes$x0) > 0.8 * ctx$w, , drop = FALSE]
    vl_lint_finding(
      "wide_marks",
      "note",
      wide,
      "spans almost the whole page width"
    )
  },
  "A mark spans nearly the full page."
)

cat("\n== with a custom rule registered ==\n")
print(vl_lint(bad, rules = c("wide_marks", "tiny_text")))

# --- ink and overplotting ----------------------------------------------------
# `overplot` is the honest "should this be datashaded?" signal: a mark count
# says nothing about whether the marks land on top of each other.
cat("\n== scene_stats(): count vs crowding ==\n")
cloud <- function(n, sd) {
  xy <- if (is.na(sd)) {
    list(runif(n), runif(n))
  } else {
    list(rnorm(n, .5, sd), rnorm(n, .5, sd))
  }
  vl_scene(4, 3, dpi = 100) |>
    draw(points_grob(
      xy[[1]],
      xy[[2]],
      gp = vl_gpar(fill = "steelblue", col = NA)
    ))
}
stats <- rbind(
  `2000 scattered` = scene_stats(cloud(2000, NA)),
  `2000 clustered` = scene_stats(cloud(2000, 0.03))
)
print(round(stats, 3))
cat("Same element count; the clustered one is far more overplotted.\n")

# --- where the time goes -----------------------------------------------------
cat("\n== profile_render() ==\n")
heavy <- vl_scene(6, 4, dpi = 100) |>
  draw(points_grob(runif(20000), runif(20000), name = "points")) |>
  draw(segments_grob(
    runif(2000),
    runif(2000),
    runif(2000),
    runif(2000),
    name = "edges"
  )) |>
  draw(text_grob(
    format(1:200),
    x = runif(200),
    y = runif(200),
    gp = vl_gpar(fontsize = 8),
    name = "labels"
  ))
print(profile_render(heavy, reps = 2))

render(bad, out)
cat(sprintf("\nwrote %s\n", out))
