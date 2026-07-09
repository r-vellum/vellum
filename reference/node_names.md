# Inspect and edit a scene by node name

`node_names()` lists the names in a scene. `get_node()` returns the
first node with a given name. `edit_node()` returns a new scene with
that node's properties updated (copy-on-modify).

## Usage

``` r
node_names(scene)

get_node(scene, name)

edit_node(scene, name, ...)
```

## Arguments

- scene:

  A
  [`vl_scene()`](https://r-vellum.github.io/vellum/reference/vl_scene.md).

- name:

  A node name (set via the `name` argument of a grob/viewport).

- ...:

  Properties to set, e.g. `gp = vl_gpar(col = "red")`.

## Value

`node_names()`: character. `get_node()`: a node. `edit_node()`: a
`vellum_scene`.
