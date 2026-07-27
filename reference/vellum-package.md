# vellum: Low-Level Graphics with Device-Independent Layout and Queryable Scenes

A grid-like low-level graphics system for R. Text metrics and layout are
resolved without a graphics device, so one solved scene renders to PNG,
SVG, or PDF with the same geometry, and the finished scene can report
that geometry back element by element (a data key and a resolved
device-pixel box) or be queried by point. The scene graph, unit/layout
engine, and rendering run in a Rust backend.

## See also

Useful links:

- <https://github.com/r-vellum/vellum>

- <https://r-vellum.github.io/vellum/>

- <https://schochastics.r-universe.dev/vellum>

- Report bugs at <https://github.com/r-vellum/vellum/issues>

## Author

**Maintainer**: David Schoch <david.schoch@cynkra.com>

Authors:

- David Schoch <david.schoch@cynkra.com>
