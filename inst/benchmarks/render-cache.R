#!/usr/bin/env Rscript
# Benchmark: the object-identity render cache. Shows that re-rendering an
# unchanged scene (multi-format export, display() resize-return, animation
# replay) is cheap, while a single cold render is NOT taxed relative to the
# cache-disabled path (the failure mode of the reverted FW4 content-hash cache,
# which hashed the whole tree on every call).
#
# Run:  Rscript inst/benchmarks/render-cache.R [N] [out_dir]
#   N        grob count of the compile-bound scene (default 2000)
#   out_dir  where to write output files (default tempdir())

invisible(suppressMessages(loadNamespace("vellum")))

args <- commandArgs(trailingOnly = TRUE)
n <- if (length(args) >= 1) as.numeric(args[[1]]) else 2000
out_dir <- if (length(args) >= 2) args[[2]] else tempdir()
width <- 8
height <- 6
dpi <- 100

bench <- function(label, expr) {
  t <- system.time(force(expr))[["elapsed"]]
  cat(sprintf("  %-26s %8.3f s\n", label, t))
  invisible(t)
}

# A compile-bound scene: N individually-drawn rects (one build node + one compile
# step each), the shape the reverted cache regressed at ~2000 grobs.
build_scene <- function(n) {
  set.seed(1)
  m <- ceiling(sqrt(n))
  s <- vellum::vl_scene(width, height, dpi = dpi, bg = "white") |>
    vellum::push(vellum::viewport(xscale = c(0, 1), yscale = c(0, 1)))
  cols <- grDevices::hcl.colors(n)
  for (i in seq_len(n)) {
    cx <- ((i - 1) %% m + 0.5) / m
    cy <- ((i - 1) %/% m + 0.5) / m
    s <- vellum::draw(s, vellum::rect_grob(
      x = cx, y = cy, width = 0.8 / m, height = 0.8 / m,
      gp = vellum::gpar(fill = cols[i], col = NA)
    ))
  }
  vellum::pop(s)
}

cat(sprintf("Render cache: compile-bound scene of %s grobs (%dx%d in @ %d dpi)\n\n",
            format(n, big.mark = ",", scientific = FALSE), width, height, dpi))

s <- build_scene(n)
f_png <- file.path(out_dir, "cache.png")

# --- 1. repeat render at the same size --------------------------------------
cat("1. Repeat render, same size (compile + raster reused on warm calls):\n")
vellum::vl_clear_render_cache()
t_cold <- bench("cold (miss)", vellum::render(s, f_png))
t_warm <- bench("warm (hit)", vellum::render(s, f_png))
cat(sprintf("   speedup warm vs cold: %.0fx\n\n", t_cold / max(t_warm, 1e-6)))

# --- 2. multi-format export -------------------------------------------------
cat("2. Multi-format export of one scene (compile paid once):\n")
vellum::vl_clear_render_cache()
bench("png (miss, compile)", vellum::render(s, f_png))
bench("svg (hit, reuse compile)", vellum::render(s, file.path(out_dir, "cache.svg")))
bench("pdf (hit, reuse compile)", vellum::render(s, file.path(out_dir, "cache.pdf")))
cat("\n")

# --- 3. single-render tax control -------------------------------------------
# Each iteration renders a COLD scene (cache cleared), so the cache never serves
# a hit; this isolates the per-call keying overhead. It must be within noise of
# the cache-disabled path (the FW4 tax was ~180 ms of tree hashing here).
cat("3. Single (cold) render — cache on vs off (must be within noise):\n")
reps <- 5
on <- replicate(reps, {
  vellum::vl_clear_render_cache()
  system.time(vellum::render(s, f_png))[["elapsed"]]
})
off <- replicate(reps, {
  withr::with_options(list(vellum.cache = FALSE),
                      system.time(vellum::render(s, f_png))[["elapsed"]])
})
cat(sprintf("   cache on  (median): %8.3f s\n", stats::median(on)))
cat(sprintf("   cache off (median): %8.3f s\n", stats::median(off)))
cat(sprintf("   overhead: %+.1f%%\n\n", 100 * (stats::median(on) / stats::median(off) - 1)))

# --- 4. display() resize simulation -----------------------------------------
# display()'s makeContent does a device-only set_props(width,height,dpi) each
# draw. Two sizes cycled: return-to-a-prior-size hits; a same-size repeat is free
# (Rust pixmap memo). Uses scene_raster (the display path) to avoid file I/O.
cat("4. Resize simulation (device-only set_props, cycling two sizes):\n")
vellum::vl_clear_render_cache()
a <- S7::set_props(s, width = vellum::unit(8, "in"), height = vellum::unit(6, "in"))
b <- S7::set_props(s, width = vellum::unit(6, "in"), height = vellum::unit(4, "in"))
bench("size A (miss)", vellum::scene_raster(a))
bench("size B (miss)", vellum::scene_raster(b))
bench("size A again (hit)", vellum::scene_raster(a))
bench("size A repeat (pixmap memo)", vellum::scene_raster(a))

cat(sprintf("\n  outputs in %s\n", out_dir))
