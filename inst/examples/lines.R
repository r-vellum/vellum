# Line/edge datashading, in the spirit of https://datashader.org — the line
# analogue of inst/examples/attractors.R. Two kinds of data that overplot into a
# useless blob when drawn as vector paths, rendered instead by aggregating the
# lines into a canvas-sized density grid in one pass:
#
#   1. A dense bundle of random-walk timeseries (`datashade_lines()`): hundreds of
#      traces sharing a time axis, packed into ONE call via a `group` id. The grid
#      records where the walks concentrate, which an opaque band of vertices hides.
#   2. A network hairball (`datashade_segments()`): tens of thousands of edges over
#      a two-cluster node layout, aggregated into an edge-DENSITY field showing
#      where the edges actually run rather than a solid mass.
#
# Both use the same aggregate-then-shade engine as points: an anti-aliased line
# rasteriser accumulates coverage per cell (overlapping lines ADD), then histogram
# equalisation (`eq_hist`) keeps structure visible across orders of density
# magnitude. `dynspread()` bolds the thin edge raster so sparse regions stay
# legible. Panels are composited with `grid_layout`.
#
# Run with:  Rscript inst/examples/lines.R [output.png] [scale] [seed]
#   output.png  where to write (default: lines.png in the working dir)
#   scale       multiplier on the data size (default 1; try 4 for a stress test)
#   seed        integer for a reproducible figure (default: a fresh random one,
#               printed so you can reproduce a run you liked)

library(vellum)

args <- commandArgs(trailingOnly = TRUE)
out <- if (length(args) >= 1) args[[1]] else "lines.png"
scale <- if (length(args) >= 2) as.numeric(args[[2]]) else 1
seed <- if (length(args) >= 3) as.integer(args[[3]]) else sample.int(.Machine$integer.max, 1)
set.seed(seed)
message("seed: ", seed, "  (pass as the 3rd argument to reproduce this figure)")

# --- 1. dense random-walk timeseries ----------------------------------------
# k independent random walks of m samples each, concatenated into flat x/y/group
# vectors. The walk is a cumulative sum (each sample depends on the last), so the
# traces fan out over time from a shared origin.
k <- round(600 * scale) # series
m <- 800                # samples each
message(sprintf("timeseries: %d walks x %d samples = %s vertices", k, m, format(k * m, big.mark = ",")))

walks <- apply(matrix(rnorm(k * m, sd = 0.4), m, k), 2, cumsum)
t <- rep(seq_len(m), times = k)
y <- as.vector(walks)
grp <- rep(seq_len(k), each = m)

ts_panel <- datashade_lines(
  t, y, group = grp,
  width = 700, height = 500,
  colors = c("#ffffff", "#fdd0a2", "#fd8d3c", "#d94801", "#7f2704"),
  how = "eq_hist"
)

# --- 2. network hairball -----------------------------------------------------
# A toy layout: two loose clusters of nodes, with many random edges. Drawn as
# vectors this is an unreadable mass; aggregated it is an edge-density field.
n_nodes <- round(400 * scale)
node_x <- c(rnorm(n_nodes %/% 2, -1), rnorm(n_nodes - n_nodes %/% 2, 1))
node_y <- rnorm(n_nodes)
n_edges <- round(12000 * scale)
message(sprintf("network: %d nodes, %s edges", n_nodes, format(n_edges, big.mark = ",")))

ea <- sample(n_nodes, n_edges, replace = TRUE)
eb <- sample(n_nodes, n_edges, replace = TRUE)

net_panel <- datashade_segments(
  node_x[ea], node_y[ea], node_x[eb], node_y[eb],
  width = 700, height = 500,
  colors = c("#ffffff", "#c6dbef", "#6baed6", "#2171b5", "#08306b"),
  how = "eq_hist",
  spread = "auto" # dynspread: bold the thin edges so sparse regions stay visible
)

# --- compose -----------------------------------------------------------------
W <- 14
H <- 5
dpi <- 100

s <- vl_scene(width = W, height = H, dpi = dpi, bg = "white") |>
  push(vl_viewport(layout = grid_layout(
    widths = vl_unit(c(1, 1), "null"),
    heights = vl_unit(1, "null")
  ))) |>
  push(vl_viewport(row = 1, col = 1, xscale = range(t), yscale = range(y))) |>
  draw(ts_panel) |>
  pop() |>
  push(vl_viewport(row = 1, col = 2, xscale = range(node_x), yscale = range(node_y))) |>
  draw(net_panel) |>
  pop()

render(s, out)
message("wrote ", out)
