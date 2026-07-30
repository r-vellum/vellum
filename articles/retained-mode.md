# Asking a scene what it drew: read-back, picking, and editing

A vellum scene is a value, and once it has been through the layout solve
it can answer questions about itself: where did each element end up, and
what is drawn at this point? That read-back is the capability with no
counterpart in grid, and it is what an interactive host, an
accessibility layer, or a test suite binds to. This vignette covers it,
and the editing API that goes with it.

Being retained is not the interesting part. grid retains its scene too:
a `gTree` is a value,
[`editGrob()`](https://rdrr.io/r/grid/grid.edit.html) derives a modified
copy, and a drawn plot’s display list can be walked and rewritten with
[`grid.ls()`](https://rdrr.io/r/grid/grid.ls.html),
[`grid.get()`](https://rdrr.io/r/grid/grid.get.html), and
[`grid.edit()`](https://rdrr.io/r/grid/grid.edit.html). Naming and
editing nodes below will look familiar for that reason. What grid leaves
to you is everything in the first paragraph, because its resolved
geometry exists only during a draw and is gone when the draw ends.

## Naming nodes

Every grob and viewport takes an optional `name`. A name turns a node
into something you can look up and modify later.

``` r

dots <- vl_scene(5, 3, bg = "white") |>
  draw(circle_grob(x = 0.25, y = 0.5, r = 0.16, name = "a",
                   gp = vl_gpar(fill = "#bdc3c7", col = NA))) |>
  draw(circle_grob(x = 0.55, y = 0.5, r = 0.16, name = "b",
                   gp = vl_gpar(fill = "#bdc3c7", col = NA))) |>
  draw(circle_grob(x = 0.85, y = 0.5, r = 0.16, name = "c",
                   gp = vl_gpar(fill = "#bdc3c7", col = NA)))

node_names(dots)
#> [1] "a" "b" "c"
```

[`node_names()`](https://r-vellum.github.io/vellum/reference/node_names.md)
lists the names in paint order, and
[`get_node()`](https://r-vellum.github.io/vellum/reference/node_names.md)
returns the node itself, so you can inspect a value you built earlier.

``` r

get_node(dots, "b")
#> <vellum::grob_circle>
#>  @ name  : chr "b"
#>  @ gp    : <vellum::vl_gpar>
#>  .. @ col       : logi NA
#>  .. @ fill      : chr "#bdc3c7"
#>  .. @ lwd       : NULL
#>  .. @ alpha     : NULL
#>  .. @ lty       : NULL
#>  .. @ lineend   : NULL
#>  .. @ linejoin  : NULL
#>  .. @ linemitre : NULL
#>  .. @ fontfamily: NULL
#>  .. @ fontface  : NULL
#>  .. @ fontsize  : NULL
#>  .. @ cex       : NULL
#>  .. @ lineheight: NULL
#>  .. @ halo_col  : NULL
#>  .. @ halo_width: NULL
#>  .. @ features  : NULL
#>  .. @ antialias : NULL
#>  .. @ crisp     : NULL
#>  @ vp    : NULL
#>  @ id    : NULL
#>  @ role  : NULL
#>  @ keys  : NULL
#>  @ meta  : NULL
#>  @ x     : unit [1:1] 0.55npc
#>  @ y     : unit [1:1] 0.5npc
#>  @ r     : unit [1:1] 0.16npc
#>  @ sketch: NULL
```

## Editing a node

[`edit_node()`](https://r-vellum.github.io/vellum/reference/node_names.md)
returns a *new* scene with one node’s properties changed. It is
copy-on-modify: the original scene value is untouched, so you can derive
variants without disturbing the source.
[`editGrob()`](https://rdrr.io/r/grid/grid.edit.html) gives you the same
guarantee in grid; what
[`edit_node()`](https://r-vellum.github.io/vellum/reference/node_names.md)
adds is that untouched subtrees keep their internal node ids, which is
what the repaint-boundary cache keys on. Both walk the tree to find the
node, but neither copies a subtree it did not touch: on a scene of
20,000 named sibling grobs an edit costs about 14 ms here against about
430 ms for [`editGrob()`](https://rdrr.io/r/grid/grid.edit.html),
because grid’s copy duplicates the siblings and this one does not. Here
we highlight the middle dot.

``` r

highlighted <- edit_node(dots, "b", gp = vl_gpar(fill = "#e74c3c", col = NA))
highlighted
```

![](retained-mode_files/figure-html/edit-1.png)

The original is unchanged:

``` r

dots
```

![](retained-mode_files/figure-html/original-1.png)

This is the mechanism a host uses for hover and selection: keep one
scene, and on an interaction re-derive it with the touched node
restyled, then re-render. Flagging that node’s viewport with
`cache = TRUE` (a repaint boundary) makes the re-render cheap, since
only the changed subtree is re-rasterised.

## Hit-testing

[`hit_test()`](https://r-vellum.github.io/vellum/reference/hit_test.md)
answers the inverse question: given a point, which node is drawn on top
there? grid ships
[`grid.locator()`](https://rdrr.io/r/grid/grid.locator.html), which
waits for one interactive click and returns coordinates rather than a
node; you can build a picker on top of
[`grobPoints()`](https://rdrr.io/r/grid/grobCoords.html) and a
point-in-polygon test, or tag exported SVG elements the way gridSVG and
ggiraph do. vellum compiles the retained scene into a colour pick-buffer
instead, through the same transform, clipping, and paint-order code that
drew it, so the answer is exact with respect to geometry, clipping, and
paint order rather than coming from a second geometry implementation you
have to keep in sync. It is also an ordinary function call: no device,
no user, callable as often as you like. Coordinates default to `"npc"`
(`0..1`, y up); pass `units = "px"` for device pixels.

``` r

hit_test(dots, x = 0.25, y = 0.5) # over dot "a"
#> [1] "a"
hit_test(dots, x = 0.55, y = 0.5) # over dot "b"
#> [1] "b"
hit_test(dots, x = 0.05, y = 0.1) # empty space
#> NULL
```

A point over a named grob returns its name; over an unnamed grob it
returns `NA`; over blank canvas it returns `NULL`. That is enough to
route a click back to the datum that drew the mark.

## A per-element model of the scene

[`hit_test()`](https://r-vellum.github.io/vellum/reference/hit_test.md)
picks one node;
[`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)
returns the whole picture. It walks a rendered scene and returns one row
per drawn element of the *keyable* marks (points, circles, rects,
hexagons, sectors, segments), pairing each element’s identity with its
resolved device-pixel bounding box.

``` r

sm <- scene_model(dots)
str(sm, max.level = 1)
#> List of 2
#>  $ elements:'data.frame':    3 obs. of  14 variables:
#>  $ panels  :'data.frame':    0 obs. of  14 variables:
sm$elements[, c("mark", "name", "x", "y", "w", "h")]
#>     mark name   x   y     w     h
#> 1 circle    a 120 144 92.16 92.16
#> 2 circle    b 264 144 92.16 92.16
#> 3 circle    c 408 144 92.16 92.16
```

The real power shows up when marks carry a data `key` (and optional
free-form `meta`), which the batched grobs accept per element. The `key`
is emitted by the SVG backend as `data-key` on each element and surfaced
here, so a host can render the SVG once
([`scene_svg()`](https://r-vellum.github.io/vellum/reference/scene_svg.md)),
then use this table to map a DOM event back to the originating row of
data.

``` r

keyed <- vl_scene(5, 3, bg = "white") |>
  draw(points_grob(
    x = vl_unit(c(0.25, 0.55, 0.85), "npc"), y = 0.5,
    size = vl_unit(6, "mm"),
    key = c("row-1", "row-2", "row-3"),
    gp = vl_gpar(fill = "#3a7bd5", col = NA)
  ))

scene_model(keyed)$elements[, c("mark", "key", "x", "y")]
#>    mark   key   x   y
#> 1 point row-1 120 144
#> 2 point row-2 264 144
#> 3 point row-3 408 144
```

## Why this matters

Ranked by how much of it you cannot get elsewhere:

- the scene can be read back as a **table of elements with keys and
  geometry**
  ([`scene_model()`](https://r-vellum.github.io/vellum/reference/scene_model.md)),
  which is the host-agnostic bridge an interactive layer, a
  screen-reader description, or a positional test binds to;
- **any point can be picked** back to the node that drew it
  ([`hit_test()`](https://r-vellum.github.io/vellum/reference/hit_test.md)),
  through the same compile path that rendered the scene, so the answer
  agrees with the picture by construction;
- nodes can be **named, inspected, and edited**
  ([`node_names()`](https://r-vellum.github.io/vellum/reference/node_names.md),
  [`get_node()`](https://r-vellum.github.io/vellum/reference/node_names.md),
  [`edit_node()`](https://r-vellum.github.io/vellum/reference/node_names.md))
  — as they can in grid, the difference being that you are editing a
  value rather than device state.

The first two are what `vellumwidget` is built on. It adds no drawing
code of its own: it renders the scene’s SVG, reads this table, and
attaches behaviour. \`\`\`
