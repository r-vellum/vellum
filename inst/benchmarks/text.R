#!/usr/bin/env Rscript
# Benchmark: high-distinct-label text — the case the glyph-bitmap cache targets.
# Many UNIQUE short strings (so the shape/outline caches don't help via
# repetition) but a small reused glyph alphabet. Compares vellum with the
# glyph-bitmap cache ON vs OFF vs AUTO, and base `grid`, drawing N labels.
#
# IMPORTANT (measurement bias, fixed 2026-07-30): shaping results are memoised
# process-wide in `.shape_cache`, so whichever mode runs FIRST pays the whole
# cold-shaping cost and every later mode runs warm. Timing off-then-on in one
# process therefore reports the shape cache warming up, not the glyph-bitmap
# cache — that is where this file's earlier "8.7x" came from. The shape cache is
# now pre-warmed before any mode is timed, and the cold cost is reported
# separately as its own line.
#
# Run:  Rscript inst/benchmarks/text.R [N] [out_dir]
#   N        number of distinct labels (default 5000)
#   out_dir  where to write PNGs (default tempdir())

invisible(suppressMessages(loadNamespace("grid")))
invisible(suppressMessages(loadNamespace("vellum")))

args <- commandArgs(trailingOnly = TRUE)
n <- if (length(args) >= 1) as.numeric(args[[1]]) else 5000
out_dir <- if (length(args) >= 2) args[[2]] else tempdir()
width <- 8
height <- 6
dpi <- 100
fontsize <- 9

set.seed(1)
labs <- format(seq_len(n)) # distinct strings, small glyph alphabet (digits)
x <- runif(n)
y <- runif(n)

bench <- function(label, expr) {
  t <- system.time(force(expr))[["elapsed"]]
  cat(sprintf("  %-26s %8.3f s\n", label, t))
  invisible(t)
}

cat(sprintf("Text: %s distinct labels @ %dpt (%dx%d in @ %d dpi)\n\n",
            format(n, big.mark = ",", scientific = FALSE), fontsize, width, height, dpi))

# --- grid -------------------------------------------------------------------
grid_png <- file.path(out_dir, "text-grid.png")
t_grid <- bench("grid", {
  grDevices::png(grid_png, width = width * dpi, height = height * dpi, res = dpi)
  grid::grid.newpage()
  grid::grid.text(labs, x = x, y = y, gp = grid::gpar(fontsize = fontsize))
  grDevices::dev.off()
})

vellum_scene <- function() {
  vellum::vl_scene(width, height, dpi = dpi, bg = "white") |>
    vellum::draw(vellum::text_grob(labs, x = x, y = y,
                                   gp = vellum::vl_gpar(fontsize = fontsize, col = "black")))
}
out <- file.path(out_dir, "text-vellum.png")

# --- vellum, COLD: first render in this process (shaping included) ----------
# This is what a script that draws one text-heavy plot actually pays. It also
# pre-warms `.shape_cache`, which is what makes the per-mode timings below
# comparable to each other.
t_cold <- bench("vellum (cold, incl. shaping)", {
  withr::with_options(list(vellum.glyph_bitmap = "auto"), {
    vellum::vl_clear_render_cache()
    vellum::render(vellum_scene(), out)
  })
})

# --- vellum, WARM: shape cache populated; isolates the raster glyph path -----
render_mode <- function(mode) {
  withr::with_options(list(vellum.glyph_bitmap = mode), {
    vellum::vl_clear_render_cache()
    vellum::render(vellum_scene(), out)
  })
}
t_off <- bench("vellum (warm, bitmap off)", render_mode("off"))
t_on <- bench("vellum (warm, bitmap on)", render_mode("on"))
t_auto <- bench("vellum (warm, bitmap auto)", render_mode("auto"))

cat(sprintf("\n  shaping share of the cold render: %.0f%% (%.3f s of %.3f s)\n",
            100 * (t_cold - t_auto) / max(t_cold, 1e-6), t_cold - t_auto, t_cold))
cat(sprintf("  glyph-bitmap speedup, warm (off / on): %.1fx\n", t_off / max(t_on, 1e-6)))
cat(sprintf("  auto engaged? %s (auto/on = %.2f; auto should track on above the\n",
            if (abs(t_auto - t_on) < 0.25 * t_on) "yes" else "NO", t_auto / max(t_on, 1e-6)))
cat("                2000-glyph threshold, and off below it)\n")
cat(sprintf("  vs grid: cold %.2fx, warm-on %.2fx  (>1 = vellum faster)\n",
            t_grid / t_cold, t_grid / t_on))
cat(sprintf("  wrote %s\n        %s\n", grid_png, out))
