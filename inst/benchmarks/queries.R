#!/usr/bin/env Rscript
# Benchmark: the QUERY entry points, not drawing -- `scene_model()`,
# `scene_svg()` and `render()` over one scene, which is the shape
# `vellumwidget::as_widget()` uses (it calls all three).
#
# This exists because a round of predicted Rust optimisations against these paths
# (memoising the viewport resolve, reserving the element-table vectors) measured
# as pure noise, and the profile showed why: at 1600 viewports `scene_model()`
# costs ~1.2 s of which the Rust `element_table()` is ~1 ms. The rest is R-side
# S7 property validation and the compile walk. Keep this benchmark pointed at the
# R side; optimising the Rust here is optimising 0.1% of it.
#
# Run:  Rscript inst/benchmarks/queries.R [n_points] [n_panels_per_side]
#   n_points            keyed points in the widget-shape scene (default 20000)
#   n_panels_per_side    m, for an m x m grid of clipped viewports (default 40)

invisible(suppressMessages(loadNamespace("vellum")))

args <- commandArgs(trailingOnly = TRUE)
n <- if (length(args) >= 1) as.numeric(args[[1]]) else 20000
m <- if (length(args) >= 2) as.integer(args[[2]]) else 40L

med <- function(label, expr, reps = 5) {
  # `expr` must be re-evaluated per rep: captured unevaluated, or `replicate()`
  # re-reads one already-forced promise and every timing reads zero.
  e <- substitute(expr)
  pf <- parent.frame()
  ts <- replicate(reps, system.time(eval(e, pf))[["elapsed"]])
  cat(sprintf("  %-42s %7.3f s\n", label, stats::median(ts)))
  invisible(stats::median(ts))
}

# --- 1. the widget shape: one scene, three consumers -------------------------
set.seed(1)
keyed <- vellum::vl_scene(8, 6, dpi = 100) |>
  vellum::push(vellum::vl_viewport(
    name = "panel",
    xscale = c(0, 1),
    yscale = c(0, 1)
  )) |>
  vellum::draw(vellum::points_grob(
    stats::runif(n),
    stats::runif(n),
    key = paste0("k", seq_len(n)),
    gp = vellum::vl_gpar(fill = "steelblue")
  )) |>
  vellum::pop()

cat(sprintf(
  "Widget shape: %s keyed points (8x6 in @ 100 dpi)\n",
  format(n, big.mark = ",", scientific = FALSE)
))
med("scene_model()", {
  vellum::vl_clear_render_cache()
  vellum::scene_model(keyed)
})
med("scene_svg()", {
  vellum::vl_clear_render_cache()
  vellum::scene_svg(keyed)
})
med("render() png", {
  vellum::vl_clear_render_cache()
  vellum::render(keyed, tempfile(fileext = ".png"))
})
med("all three (what as_widget() does)", {
  vellum::vl_clear_render_cache()
  vellum::scene_model(keyed)
  vellum::scene_svg(keyed)
  vellum::render(keyed, tempfile(fileext = ".png"))
})

# --- 2. many viewports: where a resolve-bound cost would show up -------------
facet <- local({
  s <- vellum::vl_scene(8, 6, dpi = 100)
  for (i in seq_len(m)) {
    for (j in seq_len(m)) {
      s <- vellum::push(
        s,
        vellum::vl_viewport(
          x = (i - 0.5) / m,
          y = (j - 0.5) / m,
          width = 1 / m,
          height = 1 / m,
          clip = TRUE,
          name = sprintf("p%d_%d", i, j),
          xscale = c(0, i)
        )
      )
      s <- vellum::draw(
        s,
        vellum::rect_grob(gp = vellum::vl_gpar(fill = "grey92", col = NA))
      )
      s <- vellum::pop(s)
    }
  }
  s
})

cat(sprintf(
  "\n%d x %d = %s clipped panel viewports\n",
  m,
  m,
  format(m * m, big.mark = ",", scientific = FALSE)
))
med("render() png", {
  vellum::vl_clear_render_cache()
  vellum::render(facet, tempfile(fileext = ".png"))
})
med("scene_model()", {
  vellum::vl_clear_render_cache()
  vellum::scene_model(facet)
})

# Split R-side from Rust: `element_table()` is the whole Rust contribution to
# `scene_model()`. The gap between the two is R.
vellum::vl_clear_render_cache()
b <- vellum:::.scene_to_backend(facet)
t_rust <- med("  of which Rust element_table()", b$element_table())
t_all <- med("  full scene_model()", {
  vellum::vl_clear_render_cache()
  vellum::scene_model(facet)
})
cat(sprintf(
  "\n  Rust share of scene_model(): %.1f%%  -- the rest is R-side S7\n",
  100 * t_rust / max(t_all, 1e-9)
))
