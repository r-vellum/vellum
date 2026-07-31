# Phase 14 -- output reach: animated SVG, multi-page PDF, batch rendering.
#
# Three new destinations for a finished scene. None of them is a new backend:
# each reuses machinery that already existed (the tween, the PDF page writer,
# `render()`), which is why they were worth doing before the formats that need
# a writer of their own.

library(vellum)

# --- 1. animated SVG ---------------------------------------------------------
#
# The same keyframe schedule `vl_render_animation()` already takes, emitted as
# vector markup instead of pixels.

wave <- lapply(seq(0, 2 * pi, length.out = 9)[-9], function(phase) {
  x <- seq(0.05, 0.95, length.out = 80)
  vl_scene(5, 2.4, dpi = 96, bg = "white") |>
    push(vl_viewport(name = "panel", width = 0.9, height = 0.8)) |>
    draw(lines_grob(x, 0.5 + 0.3 * sin(x * 4 * pi + phase),
                    gp = vl_gpar(col = "#2C6FA6", lwd = 2.5))) |>
    draw(lines_grob(x, 0.5 + 0.3 * sin(x * 4 * pi + phase + pi / 2),
                    gp = vl_gpar(col = "#C0392B", lwd = 2.5))) |>
    pop()
})
wave <- lapply(wave, describe,
               title = "Two travelling waves",
               desc = "Two sine waves a quarter-cycle apart, moving rightward.")

n_kf <- length(wave)
per <- 6
seg <- rep(seq_len(n_kf - 1), each = per)
frac <- rep(seq(0, 1, length.out = per), n_kf - 1)

vl_render_animation(wave, seg, frac, "output-wave.svg", format = "svg", fps = 24)
vl_render_animation(wave, seg, frac, "output-wave.gif", format = "gif", fps = 24)

svg_raw <- file.size("output-wave.svg")
svg_gz <- length(memCompress(readBin("output-wave.svg", "raw", svg_raw), "gzip"))
cat(sprintf("line art, %d frames:  SVG %5.0f KB (gz %4.0f KB)   GIF %5.0f KB\n",
            length(seg), svg_raw / 1024, svg_gz / 1024,
            file.size("output-wave.gif") / 1024))

# Every frame is emitted in full, so size scales with scene complexity in a way
# a raster format's does not. That makes the choice a real one rather than a
# preference. Measured on a 30-frame scatter animation, gzipped:
#
#     marks | animated SVG (gz) | GIF
#        20 |             20 KB | 61 KB
#       200 |             80 KB | 296 KB
#      2000 |            720 KB | 124 KB
#
# Line art wins clearly; a dense scatter does not. What the SVG gives you either
# way is resolution independence -- the same file is crisp in a slide, on a
# retina screen and in print -- which no raster format offers at any size.
#
# Serve it gzipped. And note it honours `prefers-reduced-motion`: a reader who
# has asked their system not to animate sees the first frame, held.

# The same schedule, at 2000 marks, is where the trade-off flips:
set.seed(1)
cloud <- lapply(c(0.2, 1), function(t) {
  vl_scene(4, 3, dpi = 96, bg = "white") |>
    draw(points_grob(runif(2000), runif(2000) * t, size = vl_unit(1.2, "mm"),
                     gp = vl_gpar(fill = "#7FB2E5", col = NA)))
})
vl_render_animation(cloud, rep(1, 30), seq(0, 1, length.out = 30),
                    "output-cloud.svg", format = "svg", fps = 25)
vl_render_animation(cloud, rep(1, 30), seq(0, 1, length.out = 30),
                    "output-cloud.gif", format = "gif", fps = 25)
csvg <- file.size("output-cloud.svg")
cat(sprintf("2000 marks, 30 frames: SVG %5.0f KB (gz %4.0f KB)   GIF %5.0f KB  <- use the GIF\n",
            csvg / 1024,
            length(memCompress(readBin("output-cloud.svg", "raw", csvg), "gzip")) / 1024,
            file.size("output-cloud.gif") / 1024))

# --- 2. multi-page PDF -------------------------------------------------------
#
# `render()` writes one page. `pdf_pages()` writes a document.

regions <- c("North", "South", "East", "West")
set.seed(4)
report <- lapply(regions, function(r) {
  v <- cumsum(rnorm(24, 2, 6))
  describe(
    vl_scene(6, 3.5, dpi = 150, bg = "white") |>
      draw(text_grob(paste("Monthly trend —", r), y = 0.93,
                     gp = vl_gpar(fontsize = 13),
                     role = "heading", name = paste("Monthly trend —", r))) |>
      push(vl_viewport(name = "panel", y = 0.45, width = 0.86, height = 0.66,
                       xscale = c(1, 24), yscale = range(v))) |>
      draw(rect_grob(gp = vl_gpar(fill = "grey97", col = "grey85"),
                     role = "presentation", name = "panel")) |>
      draw(lines_grob(vl_unit(1:24, "native"), vl_unit(v, "native"),
                      gp = vl_gpar(col = "#2C6FA6", lwd = 2),
                      role = "img", name = sprintf("%s: 24 months of values", r))) |>
      pop(),
    title = paste(r, "monthly trend"),
    desc = sprintf("A line chart of 24 monthly values for %s.", r)
  )
})
pdf_pages(report, "output-report.pdf")
cat("report pages:", length(report), " bytes:", file.size("output-report.pdf"), "\n")

# Pages carry their own page box, so sizes may differ within one document --
# a landscape figure between two portrait ones is fine.
#
# Tagging is per page and survives: each page becomes a top-level figure in the
# document's structure tree, with its marks beneath it. There is exactly one
# tree per document, which is why pages hand their groups up rather than each
# setting a tree of their own.

# `pdf_pages(scenes)` with no path returns the bytes, for the same reason
# `scene_pdf()` does: writing to a temp file and reading it back is not an API.
bytes <- pdf_pages(report)
cat("as raw:", length(bytes), "bytes, starts with", rawToChar(bytes[1:4]), "\n")

# --- 3. batch rendering ------------------------------------------------------
#
# A report's worth of figures, rendered across cores. Embarrassingly parallel:
# one whole scene per worker, nothing shared. That is precisely why it exists
# while tiling a *single* raster across threads does not -- that needs
# synchronised access to one pixmap, and PERFORMANCE.md declines it.

figures <- stats::setNames(
  lapply(seq_along(regions), function(i) report[[i]]),
  tolower(regions)
)

dir.create("figures", showWarnings = FALSE)
render_all(figures, "figures") # named scenes + a directory = named files
cat("wrote:", paste(basename(list.files("figures")), collapse = ", "), "\n")

# Or give explicit paths, and pass anything `render()` takes:
render_all(figures, file.path("figures", paste0(names(figures), "@2x.png")), scale = 2)

# The saving is real when the scenes are substantial and there are several. For
# a handful of small figures the overhead dominates and a plain loop is as fast;
# `workers = 1` gets you that without changing the call.
t_par <- system.time(render_all(figures, file.path("figures", paste0(names(figures), "-p.png"))))
t_seq <- system.time(render_all(figures, file.path("figures", paste0(names(figures), "-s.png")),
                                workers = 1))
cat(sprintf("parallel %.2fs vs sequential %.2fs (%d figures)\n",
            t_par[["elapsed"]], t_seq[["elapsed"]], length(figures)))

# Parallelism must not change a pixel, and does not: the files are identical.
same <- identical(
  readBin("figures/north-p.png", "raw", file.size("figures/north-p.png")),
  readBin("figures/north-s.png", "raw", file.size("figures/north-s.png"))
)
cat("parallel output identical to sequential:", same, "\n")
