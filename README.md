# vellum

<!-- badges: start -->
<!-- badges: end -->

A low-level graphics framework for R in the spirit of **grid**, with a **Rust**
backend. The scene graph, unit/layout engine, and rendering live in Rust; R is a
thin declarative API.

This is **not** a grammar of graphics (no scales/stats/geoms/facets) — it is the
lower layer such a grammar would build on, the way grid underlies ggplot2 and
lattice. A higher-level grammar package (working name `rsplot`) is intended to
build on top of vellum later.

See [DESIGN.md](DESIGN.md) for the architecture and rationale.

## Status

Early development. **Milestones M0–M2 are complete:**

- R package + Rust crate wired together via [extendr](https://extendr.github.io/),
  vendored for offline/CRAN builds, with cross-platform CI.
- A scene graph held in Rust, rendered to PNG via
  [tiny-skia](https://github.com/RazrFalcon/tiny-skia).
- Units (`npc` / `native` / `mm` / `in` / `pt`) and primitives: rectangles,
  polylines, polygons, circles.
- **Text with font fidelity**: shaped by
  [textshaping](https://github.com/r-lib/textshaping) and resolved by
  [systemfonts](https://github.com/r-lib/systemfonts) (the same stack as
  ragg/svglite), with glyph outlines rasterized by
  [skrifa](https://github.com/googlefonts/fontations). Includes per-glyph font
  fallback, justification, and rotation.
- **Nested viewports** (a tree, via an affine transform) with rotation and
  rectangular **clipping**; a row/column **flex-layout** solver (`"null"`
  tracks); a cacheable layout pass; and **gpar inheritance** (with multiplicative
  alpha) down the viewport tree.

See `inst/examples/` for worked plots (a `cars` scatter, 2×2 small multiples).

Still to come (see the roadmap in DESIGN.md): the S7 scene API and the full
unit vector type (M3), SVG/PDF output (M4), the R graphics device shim (M5), and
interactivity (M6).

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
vellum::rs_backend_info()
#> "vellum Rust backend v0.1.0"
vellum::rs_bbox(c(3, -1, 4, 1, 5), c(9, 2, 6, 5, 3))
#> -1  5  2  9
```
