#!/usr/bin/env Rscript
# Benchmark: high-distinct-label text — the case the glyph-bitmap cache targets.
# Many UNIQUE short strings (so the shape/outline caches don't help via
# repetition) but a small reused glyph alphabet. Compares vellum with the
# glyph-bitmap cache ON vs OFF, and base `grid`, drawing N labels end-to-end.
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

# --- vellum, glyph-bitmap OFF (exact outline fill) --------------------------
t_off <- bench("vellum (bitmap off)", {
  withr::with_options(list(vellum.glyph_bitmap = "off"), {
    vellum::vl_clear_render_cache()
    vellum::render(vellum_scene(), out)
  })
})

# --- vellum, glyph-bitmap ON (sprite cache) ---------------------------------
t_on <- bench("vellum (bitmap on)", {
  withr::with_options(list(vellum.glyph_bitmap = "on"), {
    vellum::vl_clear_render_cache()
    vellum::render(vellum_scene(), out)
  })
})

cat(sprintf("\n  glyph-bitmap speedup (off / on): %.1fx\n", t_off / max(t_on, 1e-6)))
cat(sprintf("  vs grid: off %.2fx, on %.2fx  (>1 = vellum faster)\n", t_grid / t_off, t_grid / t_on))
cat(sprintf("  wrote %s\n        %s\n", grid_png, out))
