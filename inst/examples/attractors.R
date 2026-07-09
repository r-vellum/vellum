# Random strange-attractor gallery, in the spirit of https://datashader.org — a
# grid of chaotic maps with RANDOM parameters, each iterated for millions of
# points, then drawn with `datashade()` (aggregate-then-shade) under a random
# colormap. Every run is different.
#
# The recipe mirrors what makes datashader fast: a tight compiled kernel produces
# the orbit (here a Rust kernel, `vellum:::rs_attractor`, ~0.25 s for 10M points),
# then `datashade()` bins the cloud to a canvas-sized grid in one O(N) pass and
# colour-maps it with histogram equalisation (`eq_hist`) so structure across many
# orders of density magnitude stays visible. Panels are composited into a
# `grid_layout` — so this also exercises vellum's viewport/layout engine.
#
# Random parameters mostly produce a *point* or a divergence, not a pretty
# attractor, so each panel is found by rejection sampling: draw random params,
# keep only orbits that fill a fair fraction of the canvas.
#
# Run with:  Rscript inst/examples/attractors.R [output.png] [N] [seed]
#   output.png  where to write (default: attractors.png in the working dir)
#   N           points per attractor (default 1e7 = 10 million; lower for speed)
#   seed        integer for a reproducible gallery (default: a fresh random one,
#               printed so you can reproduce a run you liked)

library(vellum)

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else "attractors.png"
N <- if (length(args) >= 2) as.numeric(args[[2]]) else 1e7
seed <- if (length(args) >= 3) {
  as.integer(args[[3]])
} else {
  sample.int(.Machine$integer.max, 1)
}
set.seed(seed)
message(
  "seed: ",
  seed,
  "  (pass as the 3rd argument to reproduce this gallery)"
)

# --- the attractor cloud (Rust kernel) --------------------------------------
# The map is sequential (each point depends on the previous), so it can't be
# vectorised in R — the Rust kernel is what makes 10M points practical. The kernel
# also supports "bedhead"/"hopalong"/"gumowski_mira", but those need hand-tuned
# parameters, so the random gallery samples only the families below.
attractor <- function(kind, p, n = N, x0 = 0.1, y0 = 0.1) {
  n <- as.integer(n)
  v <- vellum:::rs_attractor(kind, n, p[1], p[2], p[3], p[4], x0, y0)
  list(x = v[seq_len(n)], y = v[n + seq_len(n)])
}

# Families that yield interesting attractors across wide random ranges, with the
# uniform range each of their four parameters is drawn from.
families <- list(
  clifford = c(-2, 2),
  dejong = c(-3, 3),
  svensson = c(-3, 3),
  fractal_dream = c(-2, 2)
)

# Square data window centred on the orbit (so a square cell maps without
# distortion), with a small margin.
window <- function(x, y) {
  xr <- range(x)
  yr <- range(y)
  half <- max(diff(xr), diff(yr)) / 2 * 1.05
  list(
    xlim = mean(xr) + c(-half, half),
    ylim = mean(yr) + c(-half, half),
    half = half
  )
}

# Is this orbit worth drawing? Generate a cheap test orbit and reject a point, a
# short cycle, or a divergence: require it to occupy a fair fraction of the grid.
is_interesting <- function(kind, p, n = 1e5, g = 96L) {
  pts <- attractor(kind, p, n = n)
  x <- pts$x
  y <- pts$y
  if (!all(is.finite(x)) || !all(is.finite(y))) {
    return(FALSE)
  }
  if (
    diff(range(x)) < 1e-2 ||
      diff(range(y)) < 1e-2 ||
      diff(range(x)) > 1e4 ||
      diff(range(y)) > 1e4
  ) {
    return(FALSE)
  }
  w <- window(x, y)
  occ <- mean(
    vellum:::rs_aggregate_2d(
      x,
      y,
      NULL,
      g,
      g,
      w$xlim[1],
      w$xlim[2],
      w$ylim[1],
      w$ylim[2]
    ) >
      0
  )
  occ >= 0.09 && occ <= 0.98 # reject point-collapse, short cycles, and thin streaks
}

# Draw a random interesting (family, parameters) pair.
random_attractor <- function() {
  for (try in seq_len(500)) {
    kind <- sample(names(families), 1)
    rng <- families[[kind]]
    p <- runif(4, rng[1], rng[2])
    if (is_interesting(kind, p)) {
      return(list(kind = kind, p = p))
    }
  }
  stop("no interesting attractor found in 500 tries (unlucky seed) — re-run")
}

# Random colormaps: a curated set of light -> dark ramps, so on the white page
# low-density regions fade into the background and dense filaments are saturated.
palettes <- list(
  blues = c("#ffffff", "#c6dbef", "#6baed6", "#2171b5", "#08306b"),
  reds = c("#ffffff", "#fcbba1", "#fb6a4a", "#cb181d", "#67000d"),
  greens = c("#ffffff", "#c7e9c0", "#74c476", "#238b45", "#00441b"),
  purples = c("#ffffff", "#dadaeb", "#9e9ac8", "#6a51a3", "#3f007d"),
  oranges = c("#ffffff", "#fdd0a2", "#fd8d3c", "#d94801", "#7f2704"),
  magma = c("#ffffff", "#fca50a", "#dd513a", "#932667", "#000004"),
  ocean = c("#ffffff", "#a9e3f2", "#3fa0d6", "#1c63a8", "#040613"),
  forest = c("#ffffff", "#9be564", "#2e8b2e", "#0b3d0b", "#000000"),
  teal = c("#ffffff", "#b2e2e2", "#66c2a4", "#238b8d", "#00441b"),
  gold = c("#ffffff", "#fee391", "#fec44f", "#d95f0e", "#662506"),
  berry = c("#ffffff", "#f1b6da", "#de77ae", "#c51b7d", "#49006a")
)
random_palette <- function() palettes[[sample(length(palettes), 1)]]

# --- gallery layout ---------------------------------------------------------
# Square cells (the data window above is square): pick the columns, size the page
# height to match.
panels <- 12
ncol <- 4
nrow <- ceiling(panels / ncol)
W <- 12
dpi <- 100
H <- W * nrow / ncol
cell_px <- round(W * dpi / ncol) # datashade canvas = cell pixel size (crisp)

s <- vl_scene(width = W, height = H, dpi = dpi, bg = "white") |>
  push(vl_viewport(
    layout = grid_layout(
      widths = vl_unit(rep(1, ncol), "null"),
      heights = vl_unit(rep(1, nrow), "null")
    )
  ))

for (i in seq_len(panels)) {
  a <- random_attractor()
  message(sprintf(
    "[%2d/%d] %-13s a=%+.3f b=%+.3f c=%+.3f d=%+.3f",
    i,
    panels,
    a$kind,
    a$p[1],
    a$p[2],
    a$p[3],
    a$p[4]
  ))
  pts <- attractor(a$kind, a$p) # full N points
  w <- window(pts$x, pts$y)

  img <- datashade(
    pts$x,
    pts$y,
    width = cell_px,
    height = cell_px,
    xlim = w$xlim,
    ylim = w$ylim,
    colors = random_palette(),
    how = "eq_hist"
  )

  row <- (i - 1) %/% ncol + 1
  col <- (i - 1) %% ncol + 1
  s <- s |>
    push(vl_viewport(row = row, col = col)) |>
    draw(img) |>
    pop()
}

render(s, out)
message("wrote ", out)
