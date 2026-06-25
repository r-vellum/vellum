# rsplot

<!-- badges: start -->
<!-- badges: end -->

A low-level graphics framework for R in the spirit of **grid**, with a **Rust**
backend. The scene graph, unit/layout engine, and rendering live in Rust; R is a
thin declarative API.

This is **not** a grammar of graphics (no scales/stats/geoms/facets) — it is the
lower layer such a grammar would build on, like grid is for ggplot2 and lattice.

See [DESIGN.md](DESIGN.md) for the architecture and rationale.

## Status

Early development. **Milestone M0 (skeleton) is complete:**

- R package + Rust crate wired together via [extendr](https://extendr.github.io/).
- Cross-platform CI (`R CMD check` on Linux/macOS/Windows, with an explicit Rust
  toolchain and the Windows GNU target).
- Cargo dependencies vendored for offline/CRAN builds.
- A round-trip across the R↔Rust boundary, exercised by tests.

Nothing renders yet — that begins in M1 (see the roadmap in DESIGN.md).

## Development

Requires R and a Rust toolchain (`cargo`, `rustc`).

```r
# compile the Rust backend and regenerate R wrappers
rextendr::document()

# run tests
devtools::test()

# refresh vendored crates after changing Rust dependencies
rextendr::vendor_crates()
```

```r
# the M0 round-trip
rsplot::rs_backend_info()
#> "rsplot Rust backend v0.1.0"
rsplot::rs_bbox(c(3, -1, 4, 1, 5), c(9, 2, 6, 5, 3))
#> -1  5  2  9
```
