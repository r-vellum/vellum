# Test probes: compile an S7 scene to the backend and read it back. Tests build
# scenes with the public API (vl_scene |> push |> draw |> pop) and assert on
# rendered pixels via these helpers.

px <- function(scene, x, y) .scene_to_backend(scene)$pixel(as.integer(x), as.integer(y))

# Whole image as an integer array, dim c(4, width, height) (channels, x, y).
scene_raster <- function(scene) {
  s <- .scene_to_backend(scene)
  d <- s$dim()
  array(s$rgba(), dim = c(4L, d[1], d[2]))
}

scene_dim <- function(scene) .scene_to_backend(scene)$dim()

# Number of primitives the scene compiles to (drawing reaches the backend).
scene_len <- function(scene) .scene_to_backend(scene)$len()
