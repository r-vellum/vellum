# Test probes: compile an S7 scene to the backend and read it back. Tests build
# scenes with the public API (vl_scene |> push |> draw |> pop) and assert on
# rendered pixels via these helpers.

px <- function(scene, x, y) .scene_to_backend(scene)$pixel(as.integer(x), as.integer(y))

# `scene_raster()` is now an exported package function (channels x x y array);
# tests use it directly.

scene_dim <- function(scene) .scene_to_backend(scene)$dim()

# Number of primitives the scene compiles to (drawing reaches the backend).
scene_len <- function(scene) .scene_to_backend(scene)$len()
