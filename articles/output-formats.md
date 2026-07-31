# Choosing an output format

vellum now writes enough formats that the choice is a real one. This
article is the capability matrix, and — more usefully — where each
format *degrades*.

## Still pictures

``` r

render(scene, "figure.png") # raster
render(scene, "figure.svg") # vector, web
render(scene, "figure.pdf") # vector, print
```

|  | PNG | SVG | PDF |
|----|----|----|----|
| Resolution-independent | ✗ | ✓ | ✓ |
| Gradients, patterns | ✓ | ✓ | ✓ |
| Hatching ([`vl_hatch()`](https://r-vellum.github.io/vellum/reference/vl_hatch.md)) | ✓ | ✓ (as `<path>`) | ✓ |
| Selectable / searchable text | ✗ | ✓ (`text = "native"`) | ✓ |
| Screen-reader structure | ✗ | ✓ (`role`, `data-*`) | ✓ (tagged) |
| Masks | ✓ | ✓ | ✓ |
| Tiling patterns | ✓ | ✓ | degrades |
| Faithful without the author’s fonts | ✓ | only with `text = "outline"` | ✓ (embedded) |

Two rows deserve expansion.

**SVG text is a choice, not a default you can ignore.**
`text = "native"` emits real `<text>` — selectable, searchable, readable
by a screen reader — but it references system fonts, so it is only
faithful on a machine that has them. `text = "outline"` fills the same
glyph outlines the raster backend does, so it is identical everywhere
and not selectable. There is no third option yet; embedding a subset
font would give both, and is blocked on tooling (see
[`vignette("accessible-output")`](https://r-vellum.github.io/vellum/articles/accessible-output.md)).

**PDF embeds its fonts**, which is why it is the format to hand someone
when fidelity matters more than editability.

Anything a backend cannot honour is reported as a warning at render time
rather than silently dropped, so you do not have to consult this table
to find out.

## Animation

``` r

vl_render_animation(keyframes, seg, frac, "a.gif", format = "gif")
vl_render_animation(keyframes, seg, frac, "a.png", format = "apng")
vl_render_animation(keyframes, seg, frac, "a.svg", format = "svg")
vl_render_animation(keyframes, seg, frac, "frames/", format = "frames")
```

|                        | GIF        | APNG     | animated SVG   | frames   |
|------------------------|------------|----------|----------------|----------|
| Colour fidelity        | 256/frame  | lossless | exact (vector) | lossless |
| Resolution-independent | ✗          | ✗        | ✓              | ✗        |
| Size on line art       | medium     | large    | **small**      | n/a      |
| Size on dense marks    | **medium** | large    | very large     | n/a      |
| Universally viewable   | ✓          | ✓        | in a browser   | n/a      |
| Honours reduced-motion | ✗          | ✗        | ✓              | n/a      |

The size row is the one that decides it, and it is not a preference —
the animated SVG emits **every frame in full**, so its size grows with
scene complexity times frame count, while a raster format’s does not.
Measured on a 30-frame scatter animation, gzipped (which is how a
browser fetches it):

| marks | animated SVG (gzipped) | GIF        |
|-------|------------------------|------------|
| 20    | 20 KB                  | 61 KB      |
| 200   | 80 KB                  | 296 KB     |
| 2000  | **720 KB**             | **124 KB** |

So: **line art → SVG, dense marks → GIF or APNG.** An explanatory
animation of a few moving marks is the case animated SVG was worth
building for, and there it wins by a wide margin *and* stays crisp at
any size. A 2000-point cloud is 24 MB uncompressed; vellum warns above 5
MB rather than letting you find out later.

`prefers-reduced-motion` is worth noting as more than a checkbox: a
reader who has asked their system not to animate gets the first frame,
held, instead of nothing.

## Documents and batches

``` r

pdf_pages(list_of_scenes, "report.pdf") # one document, many pages
render_all(named_scenes, "figures/")    # many files, across cores
```

[`pdf_pages()`](https://r-vellum.github.io/vellum/reference/pdf_pages.md)
writes a document rather than a page: a report’s figures, one facet per
page, an animation as a contact sheet. Pages may differ in size, and
each page’s tagging survives — every tagged page becomes a top-level
figure in the document’s structure tree.

[`render_all()`](https://r-vellum.github.io/vellum/reference/render_all.md)
renders independent scenes across cores. It is embarrassingly parallel —
one whole scene per worker, nothing shared — which is exactly why it
exists while tiling a *single* raster across threads does not: that
needs synchronised access to one pixmap, and `PERFORMANCE.md` declines
it on those grounds.

The saving is worth having when the scenes are substantial and there are
several of them (about 3× on four report figures here). For a handful of
small figures the overhead dominates; `workers = 1` gets you the
sequential path without changing the call. Parallelism never changes a
pixel — the outputs are byte-identical either way, and that is asserted
in the test suite.

## Formats vellum does not write

Named because “can it?” is a reasonable question with a definite answer.

**PowerPoint / OOXML DrawingML.** The gap with the clearest audience:
`rvg` and `officer` are widely used because people need *editable*
shapes in a deck, not a picture of a plot. A resolved scene maps onto
DrawingML about as directly as onto SVG. It is not here because it needs
a new backend and a zip container writer — a phase of its own rather
than a tail item, and worth doing properly.

**EPS / PostScript.** Still demanded by some journals, and a hard
blocker for those who need it. Also a new backend: krilla writes PDF and
nothing else, so this is a PostScript writer from scratch for a
shrinking audience.

**JPEG / WebP.** No one has asked. PNG is lossless and the right default
for plots, which are flat colour and hard edges — exactly what JPEG is
worst at. Straightforward to add if a need appears.

## Where to go next

- [`vignette("accessible-output")`](https://r-vellum.github.io/vellum/articles/accessible-output.md):
  tagged PDF, and why SVG cannot yet be both faithful and selectable.
- [`vignette("scene-and-paint")`](https://r-vellum.github.io/vellum/articles/scene-and-paint.md):
  the paint features whose degradation this table summarises.
- [`vignette("scenes-as-values")`](https://r-vellum.github.io/vellum/articles/scenes-as-values.md):
  rendering is not the only thing to do with a finished scene.
