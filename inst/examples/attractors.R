# Strange-attractor gallery, in the spirit of https://datashader.org — a grid of
# chaotic maps, each iterated for *millions* of points, then drawn with
# `datashade()` (aggregate-then-shade) under a randomly chosen colormap.
#
# The recipe mirrors what makes datashader fast: a tight compiled kernel produces
# the orbit (here a Rust kernel, `vellum:::rs_attractor`, ~0.25 s for 10M points),
# then `datashade()` bins the cloud to a canvas-sized grid in one O(N) pass and
# colour-maps it with histogram equalisation (`eq_hist`) so structure across many
# orders of density magnitude stays visible. Each panel is composited into a
# `grid_layout` cell — so this also exercises vellum's viewport/layout engine.
#
# Run with:  Rscript inst/examples/attractors.R [output.png] [N]
#   output.png  where to write (default: attractors.png in the working dir)
#   N           points per attractor (default 1e7 = 10 million; lower for speed)
#
# Colormaps are random per run, so each render looks different. Re-run for more.

library(vellum)

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else "attractors.png"
N <- if (length(args) >= 2) as.numeric(args[[2]]) else 1e7

# --- the attractor cloud (Rust kernel) --------------------------------------
# Returns the orbit as list(x, y). The map is sequential (each point depends on
# the previous), so it can't be vectorised in R — the Rust kernel is what makes
# 10M points practical. Supported `kind`s: "clifford", "dejong", "svensson",
# "bedhead", "fractal_dream", "hopalong", "gumowski_mira".
attractor <- function(kind, a, b, c = 0, d = 0, n = N, x0 = 0.1, y0 = 0.1) {
  n <- as.integer(n)
  v <- vellum:::rs_attractor(kind, n, a, b, c, d, x0, y0)
  list(x = v[seq_len(n)], y = v[n + seq_len(n)])
}

# A diverse set of well-known parameter sets across the attractor families.
# (`x0`/`y0` default to 0.1; Gumowski-Mira needs a non-trivial start.)
specs <- list(
  list(kind = "clifford",      a = -1.4,      b = 1.6,       c = 1.0,      d = 0.7),
  list(kind = "clifford",      a = -1.7,      b = 1.8,       c = -1.9,     d = -0.4),
  list(kind = "dejong",        a = -2.0,      b = -2.0,      c = -1.2,     d = 2.0),
  list(kind = "dejong",        a = 1.4,       b = -2.3,      c = 2.4,      d = -2.1),
  list(kind = "dejong",        a = -2.7,      b = -0.09,     c = -0.86,    d = -2.2),
  list(kind = "svensson",      a = 1.5,       b = -1.8,      c = 1.6,      d = 0.9),
  list(kind = "bedhead",       a = -0.81,     b = -0.92),
  list(kind = "fractal_dream", a = -0.966918, b = -2.879879, c = 0.765145, d = 0.744728),
  list(kind = "fractal_dream", a = -2.8276,   b = 1.2813,    c = 1.9655,   d = 0.597),
  list(kind = "hopalong",      a = 2.0,       b = 1.0,       c = 0.0),
  list(kind = "hopalong",      a = -11.0,     b = 0.5,       c = 0.5),
  list(kind = "gumowski_mira", a = 0.0083,    b = 0.9998,    x0 = 0.5,     y0 = 0.5)
)

# Random colormaps: a curated set of light -> dark ramps, so on the white page
# low-density regions fade into the background and dense filaments are saturated.
# One per panel, picked at random.
palettes <- list(
  blues   = c("#ffffff", "#c6dbef", "#6baed6", "#2171b5", "#08306b"),
  reds    = c("#ffffff", "#fcbba1", "#fb6a4a", "#cb181d", "#67000d"),
  greens  = c("#ffffff", "#c7e9c0", "#74c476", "#238b45", "#00441b"),
  purples = c("#ffffff", "#dadaeb", "#9e9ac8", "#6a51a3", "#3f007d"),
  oranges = c("#ffffff", "#fdd0a2", "#fd8d3c", "#d94801", "#7f2704"),
  magma   = c("#ffffff", "#fca50a", "#dd513a", "#932667", "#000004"),
  ocean   = c("#ffffff", "#a9e3f2", "#3fa0d6", "#1c63a8", "#040613"),
  forest  = c("#ffffff", "#9be564", "#2e8b2e", "#0b3d0b", "#000000")
)
random_palette <- function() palettes[[sample(length(palettes), 1)]]

# --- gallery layout ---------------------------------------------------------
# A grid derived from the number of attractors, with square cells (so the square
# data window below maps without distortion): pick the columns, then size the page
# height to match.
ncol <- 4
nrow <- ceiling(length(specs) / ncol)
W <- 12
dpi <- 100
H <- W * nrow / ncol # square cells
cell_px <- round(W * dpi / ncol) # datashade canvas = cell pixel size (crisp)

s <- vl_scene(width = W, height = H, dpi = dpi, bg = "white") |>
  push(viewport(layout = grid_layout(
    widths = unit(rep(1, ncol), "null"), heights = unit(rep(1, nrow), "null")
  )))

for (i in seq_along(specs)) {
  sp <- specs[[i]]
  message(sprintf("[%d/%d] %s: %s points...", i, length(specs), sp$kind,
                  format(N, big.mark = ",", scientific = FALSE)))
  pts <- attractor(
    sp$kind, sp$a, sp$b,
    c = if (is.null(sp$c)) 0 else sp$c, d = if (is.null(sp$d)) 0 else sp$d,
    x0 = if (is.null(sp$x0)) 0.1 else sp$x0, y0 = if (is.null(sp$y0)) 0.1 else sp$y0
  )

  # A square data window centred on the orbit (no aspect distortion in a square
  # cell), with a small margin.
  xr <- range(pts$x)
  yr <- range(pts$y)
  half <- max(diff(xr), diff(yr)) / 2 * 1.05
  cx <- mean(xr)
  cy <- mean(yr)
  xlim <- c(cx - half, cx + half)
  ylim <- c(cy - half, cy + half)

  img <- datashade(
    pts$x, pts$y,
    width = cell_px, height = cell_px,
    xlim = xlim, ylim = ylim,
    colors = random_palette(), how = "eq_hist"
  )

  row <- (i - 1) %/% ncol + 1
  col <- (i - 1) %% ncol + 1
  s <- s |>
    push(viewport(row = row, col = col)) |>
    draw(img) |>
    pop()
}

render(s, out)
message("wrote ", out)
