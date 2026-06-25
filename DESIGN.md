# vellum — design

A low-level graphics framework for R in the spirit of **grid**, with a **Rust** computational and rendering backend.

Status: initial design. Nothing is built yet. This document records the architecture, the reasoning behind it, and a phased plan.

---

## 1. What this is (and is not)

R has three layers of graphics:

```
grammar layer      ggplot2, lattice        data, scales, stats, geoms, facets, themes
low-level layer    grid                    primitives, viewports, units, grobs, gpar, layout
engine + device    grDevices, ragg, …      clipping, colour, display list; DevDesc rasterizers
```

`vellum` targets the **low-level layer** — a grid replacement. It provides drawing primitives, a coordinate/viewport model, a unit system, a retained tree of graphical objects, inherited graphical parameters, and a layout engine. It does **not** provide a grammar of graphics: no data binding, aesthetic mappings, statistical transforms, scales, geoms, facets, guides, or themes. Those belong to a grammar layer built *on top* of vellum (a future package, working name `rsplot`), exactly as ggplot2 and lattice are built on grid.

The difference from grid is where the work happens. In grid, the scene, the units, and the layout solver all live in interpreted R, and rendering is delegated to a separate graphics device. In vellum, **the scene graph, unit resolution, layout, and rendering all live in Rust**, and R is a thin declarative API that describes what to draw.

### Why a Rust backend at all

Almost every well-known grid pain point traces to one root cause: *a graphical object's size and content cannot be known until a device and a viewport exist at draw time.* Text has no measurable width before `plot.new()`; `native` units need a viewport scale; `null` units need a layout context. That single constraint is what forces grid's lazy units, its multi-method deferred grob protocol, and its full display-list replay on every resize.

A Rust backend with **device-independent font metrics** (we ship the shaper and font tables in-process) and an **explicit, cacheable layout pass** removes that constraint. Text is measurable at construction time; layout can be solved ahead of drawing and cached; resize becomes relayout + re-raster instead of replaying interpreted R. Performance, determinism, and a cleaner API all fall out of that one change.

Concretely the backend buys us:

- **Speed** — the scene is held and traversed in Rust, not as thousands of heavyweight R objects. (ggplot2 today is ~4× base graphics, dominated by grob construction and traversal.)
- **Determinism** — identical pixels on every OS and in CI, because we control the rasterizer and the fonts rather than deferring to whatever device is current.
- **Self-contained text** — shaping and metrics without an open device and without a system font stack on the hot path.
- **Multiple outputs from one scene** — PNG, SVG, and PDF from the same resolved scene graph.

---

## 2. The central architectural decision

There are two genuinely different things "a grid-like framework with a Rust backend" can mean. We need to be explicit about which one vellum is, because it shapes everything.

**Option A — be an R graphics device** (the ragg / svglite / vellogd model). R's engine and grid stay in charge; Rust only rasterizes the primitives the engine hands down via the `DevDesc` callback table. Low risk, proven in Rust (`vellogd-r`, `wgpugd`), and the whole existing ecosystem renders through you for free. But it does **not** give you a new grid — you have only reimplemented a device, and you inherit all of grid's layout/unit/replay costs because grid is still doing that work upstream.

**Option B — reimplement the grid model in Rust** (scene graph, units, viewports, layout, rendering), exposing a thin declarative R API and rendering directly to PNG/SVG/PDF. This is the literal reading of "a framework like grid," and it is the only option that actually fixes the pain points above. Higher risk, more surface area, and it does not automatically inherit ggplot2/lattice.

**vellum chooses B as the primary architecture, and keeps A as a secondary interop mode.**

- The **core** is a Rust scene graph + unit/layout engine + render backend, driven by an S7-based R API. This is the product.
- A separate, optional **device adapter** lets vellum register as a standard R graphics device (filling a `DevDesc` and forwarding engine primitives into the same Rust renderer). That gives a migration path and lets existing R graphics — including ggplot2 — render onto vellum's rasterizer without us reimplementing the grammar. It is an adapter over the same rendering core, not a separate codebase.

So: one Rust rendering/scene core, two front doors — the native vellum API (the focus) and an R-device shim (for ecosystem reach).

```
┌─────────────────────────── R ───────────────────────────┐
│  vellum native API (S7)            R graphics device shim │
│  viewport(), rect(), text() …      (DevDesc callbacks)    │
└───────────────┬───────────────────────────┬──────────────┘
                │            extendr          │
┌───────────────▼───────────────────────────▼──────────────┐
│                       Rust core                            │
│  scene graph  →  unit/layout solver  →  render backend     │
│  (tiny-skia geometry · skrifa glyph outlines · R-side shaping)│
└───────────────┬──────────────┬──────────────┬─────────────┘
                ▼              ▼              ▼
              PNG/raster     SVG            PDF
             (tiny-skia)  (hand-rolled)   (krilla)
```

---

## 3. Component choices

All Rust crates below are pure-Rust, headless (no GPU, no system libraries required), and permissively licensed. This is the same stack **typst** ships in production, which is the strongest maintenance and correctness signal available. We deliberately avoid GPU rendering (vello/wgpu) as the primary backend: on a GPU-less server it degrades to a software-Vulkan shim that is slower than a native CPU rasterizer and an operational liability.

| Concern | Choice | Notes |
|---|---|---|
| R ↔ Rust binding | **extendr** | Only binding with a maintained, safe graphics-device abstraction (`DeviceDriver`) and real Rust device prior art. Use `rextendr` for build/vendoring. |
| Raster output (PNG) | **tiny-skia** | Pure-Rust Skia subset: path fill/stroke, caps/joins, linear/radial/sweep gradients, pattern fills, rect + path clipping, Porter-Duff + blend modes, masks, AA, dashing. No text by design — we supply glyphs. |
| Geometry / curves | **kurbo** | Bézier math, affine transforms, arclength, stroke expansion. Internal geometry representation. |
| Glyph outlines / metrics / raster | **skrifa** (fontations) | FreeType replacement: outlines, metrics, advances, cmap, hinting, variable fonts, COLR/bitmap. `forbid(unsafe)`. Used by **both** text paths. |
| Resolution + shaping (primary, fidelity) | **`systemfonts` + `textshaping`** | Reused via C callables for exact agreement with ragg/svglite (see §3). |
| Resolution + shaping (fallback, pure-Rust) | **harfrust** + **parley**/**fontique** | HarfBuzz port + headless layout/fallback for environments without the R packages. |
| SVG output | **hand-rolled** (no XML dep, M4a) | `<path>` + nested `<clipPath>` + selectable `<text>` referencing system fonts (svglite-style). Outline-dedup into `<defs>` and embedded fonts are future work. |
| PDF output | **krilla** `=0.8.2` (M4b) | OpenType subset + embed, path fill/stroke, clip paths, opacity; `default-features = false` (no raster-images/simple-text). Embedded selectable text via `draw_glyphs`. Wraps `tiny-skia-path` 0.12 in its own newtypes, so we convert at the boundary (no tiny-skia bump). |
| Color | **palette** | Broad color science incl. Oklab/Oklch for correct gradient interpolation. |

Caveat: the Rust render stack is pre-1.0 (tiny-skia 0.11, skrifa 0.31, krilla pinned
`=0.8.2`). Pin versions and budget periodic upgrades — krilla in particular breaks on
minor bumps. (`kurbo`/`parley`/`fontique`/`palette` are listed as design references
but not currently used — text/colour are resolved on the R side and geometry stays in
tiny-skia's path types.)

### A note on text (font fidelity is a requirement)

Text is the genuinely hard part and the main reason we control the stack. R needs four things from text: string width, font metrics (ascent/descent/units-per-em), rasterized glyphs, and glyph **outlines** for vector output. Because rendering runs in-process, text is measurable at construction time — the property that lets us do eager layout.

We want output whose text *matches the rest of the R ecosystem* — the same font chosen, and the same glyph positions, as ggplot-via-ragg. That has a direct architectural consequence: **fidelity means reusing R's font stack, not reimplementing it.** R's sources of truth are two C/C++ packages with stable callable APIs:

- **`systemfonts`** — resolution: `(family, face ∈ {plain, bold, italic, bolditalic})` → `{font file, face index}`, backed by CoreText / Fontconfig / the Windows registry. This is *the* authority for which file R uses.
- **`textshaping`** — shaping/metrics: string + font → positioned glyphs (ids + advances), via HarfBuzz + FriBidi + FreeType. This is the authority for widths and glyph positions.

A pure-Rust path (`fontique` resolution + `harfrust` shaping) would be *close*, but "close" is not fidelity — font selection and glyph positions would drift from ragg/svglite. So:

- **Primary text path (fidelity):** link `systemfonts` and `textshaping` via their registered C callables (`R_GetCCallable`, `LinkingTo`, shared `FontSettings` struct — exactly how ragg and svglite stay mutually consistent). They hand us a resolved `{file, index}` and positioned glyph runs; **`skrifa`** then loads that file and produces the glyph **outlines** we fill (tiny-skia) or embed (SVG/PDF). This is the ragg architecture with the rasterizer swapped for Rust.
- **Fallback text path (self-contained):** **`skrifa` + `harfrust` + `parley`/`fontique`**, all pure-Rust and headless, for environments without those packages (or where we want zero R-side font deps). Configured to mirror R's family/face resolution rules as closely as possible, and held to the primary path by tests.

Net: glyph rasterization and outline extraction are always `skrifa` (one code path for both text routes); only resolution + shaping differ between the fidelity and self-contained routes. Fidelity is verified by snapshot tests comparing vellum text geometry against `textshaping::shape_text()` / `systemfonts` output for a fixed corpus.

---

## 4. Core model

### 4.1 Scene graph (retained, immutable)

The scene is a tree of **inert data nodes** — no drawing code lives in a node (the lesson from Qt's Graphics-View → Qt-Quick evolution). A node carries: identity/name, a local affine transform, geometry, a pick-shape for hit-testing, resolved style, and children.

> **Where the tree lives (settled in M3).** The original plan was to hold the tree in Rust with R holding handles. As built, the **retained tree lives in R as immutable S7 values**, and `render()` replays it onto a fresh, write-only Rust `Scene` (the imperative engine from M1–M2). This makes `render()` a pure function of the tree, makes `edit_node()` plain R copy-on-modify (structural sharing for free), and avoids a cross-FFI edit/invalidate protocol — the right trade for a build → render → edit workflow. A future interactive/hit-testing layer (M6) can still ask the backend for resolved geometry without changing this.

Node kinds:

- **Viewport** — a rectangular region defining its own coordinate systems (position, width/height, optional rotation, `xscale`/`yscale` for native coordinates, optional clip and layout). The container that establishes coordinate context for its children.
- **Primitive** — lines, polylines, segments, rect, circle, polygon, path (with winding / even-odd fill rule), curve/Bézier, text, raster image.
- **Group** — a named subtree (grid's gTree): the unit of editing, querying, compositing, and repaint-boundary caching.

Nodes are **immutable values**; "editing" produces a new tree with structural sharing, which keeps edits cheap and makes the scene trivially introspectable (no `grid.force()` equivalent needed). A node carries its **resolved** world transform and style after the layout pass; there is no stateful "current viewport" global. One shared transform function serves paint, hit-testing, and coordinate conversion so they can never disagree.

### 4.2 Units

A unit is a `(value, coordinate-space)` pair, vectorized. We keep a small, principled set of spaces rather than grid's sprawling list:

- **Normalized**: `npc` (0–1 within the viewport), `snpc` (proportion of the smaller dimension, for aspect-stable sizing).
- **Absolute**: `mm`, `cm`, `inch`, `pt`, `bigpt`.
- **User-scale**: `native` (relative to the viewport's `xscale`/`yscale`).
- **Font-relative**: `char`, `line` (depend on fontsize and lineheight).
- **Object-relative**: `strwidth`, `strheight`, `grobwidth`, `grobheight` — resolvable at construction because metrics are available.
- **Flex**: `null` replaced by a principled flexible-length type (CSS `fr`-style weights) for layout, not a relative unit bolted onto the absolute type.

Unit resolution happens in an explicit **layout pass** keyed on (device size, viewport scales), and the result is cached. Units are flat numeric + enum data, not arithmetic-expression objects, so resolution is cheap and re-runnable on resize.

### 4.3 Layout

A viewport may carry a row/column layout with track sizes that mix absolute units and flex weights, solved by a small constraint/flex solver (not grid's ad-hoc `null` semantics). Children place into cells, optionally spanning. Layout adopts **relayout boundaries** (tight constraints stop propagation) and **repaint boundaries** (a subtree owns a cached sub-raster), so resize and animation stay cheap.

### 4.4 Graphical parameters (gpar-equivalent)

Style — `col`, `fill` (solid / linear / radial gradient / tiling pattern), `alpha`, `lwd`, `lty`, `lineend`, `linejoin`, `linemitre`, `fontsize`, `cex`, `fontfamily`, `fontface`, `lineheight` — is attached to viewports and nodes and **inherits down the tree**, more-specific overriding less-specific. Resolution is explicit and produces a concrete style on each node during the layout pass. This maps directly onto the rasterizer's paint state and onto R's engine `R_GE_gcontext` for the device-shim mode.

### 4.5 Render backend (pluggable)

Rendering is a visitor over the resolved scene behind a single trait, so PNG/SVG/PDF
share one walk. As built (M4), the walk resolves each node to geometry +
absolute transform + clip + colour and emits through:

```rust
trait RenderBackend {
    fn fill_path(&mut self, path: &Path, t: Transform, paint: &ResolvedPaint, clip: &Clip);
    fn stroke_path(&mut self, path: &Path, t: Transform, color: Rgba, w_px: f32, clip: &Clip);
    fn draw_text(&mut self, run: &TextRun, t: Transform, clip: &Clip);
    fn begin_group(&mut self);                          // F3: isolated layer
    fn end_group(&mut self, mask: Option<MaskLayer>);   // F3: composite (+ mask)
    fn draw_circles(&mut self, …, transform, clip);     // P1: batched markers; default = per-element,
                                                        // raster overrides with sprite stamping
}
```

Geometry is `tiny_skia::Path` + `Transform` (krilla converts at its boundary). A
`Clip` is a backend-agnostic chain of viewport rects: the raster backend builds a
`Mask`, SVG emits a nested `<clipPath>`, PDF pushes clip paths. `TextRun` carries the
pre-shaped glyph run **and** the source label + font descriptor, so raster fills
glyph outlines, PDF embeds glyphs, and SVG emits `<text>`. Three impls today
(`RasterBackend`, `SvgBackend`, `PdfBackend`); the device shim (M5) will be a fourth.

**Fill is a `Paint`, not just a colour (F1/F2).** `gpar.fill` carries a
`Paint` (`Solid` / `Linear` / `Radial` / `Pattern`) through the gpar fold; gradient
and pattern geometry is stored unresolved as `(value, unit)` and the gpar `alpha`
folds into every stop (or, for a pattern, into the tile's alpha channel). The scene
walk resolves that geometry against the viewport into **local pixels** and hands the
backend a `ResolvedPaint`. Each backend builds its native fill from local-px geometry
+ an **identity** paint transform, relying on the primitive's own draw transform to
map fill and outline together (tiny-skia post-concats the CTM into the shader/pattern;
krilla into the gradient; SVG via `gradientUnits`/`patternUnits="userSpaceOnUse"` on a
transformed element) — the same "don't transform twice" discipline as the clip fix.
`col`/stroke and text stay solid `Rgba`.

**Patterns (F2)** tile a grob. R renders the tile grob to an RGBA raster (via a
throwaway sub-`Scene` sized from `width`/`height` at the scene dpi, using one
reference dimension so the tile's aspect is `width:height`), then passes the pixels +
cell geometry. The backend tiles that image: tiny-skia `Pattern`, SVG
`<pattern><image href="data:image/png;base64,…">`. The PDF backend has no image
support (krilla's `raster-images` feature needs extra vendored codecs), so a pattern
**degrades to its mean colour** there — a documented first-cut limitation. The new
`b64`/`pixmap_from_straight`/`average_rgba` helpers and the `base64` crate (already
vendored via krilla) support this; no re-vendor was needed.

**Masks & isolated groups (F3).** The trait gained `begin_group`/`end_group(mask)`:
between them, drawing targets an isolated layer that `end_group` composites back,
optionally through a mask. A masked `viewport(mask = …)` compiles to a `GroupStart`
… content … `GroupEnd{mask}` bracket in the flat node stream (the mask grob's own
nodes are routed to a side buffer during compilation). The mask is **always
rasterized** — the walk renders its nodes through a fresh `RasterBackend` to a
page-sized `Pixmap` regardless of output format — and each backend applies it: raster
pushes a layer `Pixmap` (a target stack) and composites with a tiny-skia `Mask`
(`Alpha`/`Luminance`); SVG buffers the group's elements (a buffer stack) and wraps
them in `<g mask="url(#m)">`, the mask embedded as a grayscale-coverage PNG `<mask>`;
PDF renders the group **unmasked** (krilla masks need the un-vendored `raster-images`
path) — a documented limitation alongside F2's pattern fallback.

Still simpler than a full immediate-mode model: no `save`/`restore` and no general
`draw_image` op yet — each draw call carries its own absolute transform and clip
(paint order is the flat node list); group brackets are the one nesting construct.

### 4.6 Hit-testing and events (designed in, built later)

Because resolved geometry is retained per node, we can build a pluggable spatial index (none for fully-dynamic frames; a BSP/grid index for large static scenes — Qt's model) and a real event/hit-test model from the start, walking reverse-paint order and transforming the query point through the same transform paint uses. This is the gap grid never closed (`grid.locator()` only). Not in the first milestone, but the scene graph is shaped to allow it without rework.

---

## 5. R API sketch

Idiomatic modern R: **S7** for the value-facing object model (the direction ggplot2 4.0 and base R are taking — multiple dispatch, validated properties, value semantics), and **vctrs** for the `unit` vector type (a vectorized record that behaves correctly under `c()`, `[`, and in data frames). S7 is still 0.2.x/experimental and cannot extend S4 — pin it, wrap it behind our own constructors, and avoid designs needing S4 inheritance.

Two usage styles over the same core: a **retained** style (build a scene, edit it, draw it) and an **immediate** style (draw straight to a device) layered on top.

```r
library(vellum)

# A device-independent scene, drawn to several outputs
scene <- rs_scene(width = unit(6, "inch"), height = unit(4, "inch"))

vp <- viewport(
  x = unit(0.5, "npc"), y = unit(0.5, "npc"),
  width = unit(1, "npc"), height = unit(1, "npc"),
  xscale = c(0, 10), yscale = c(0, 100),
  layout = grid_layout(
    nrow = 2, ncol = 1,
    heights = unit.c(unit(1, "line"), unit(1, "null"))  # title row + flex panel
  )
)

scene <- scene |>
  push(vp) |>
  draw(rect(gp = gpar(fill = "grey95", col = NA))) |>
  draw(lines(
    x = unit(1:9, "native"), y = unit(c(10, 40, 35, 80, 60, 90, 55, 70, 30), "native"),
    gp = gpar(col = "steelblue", lwd = 2)
  )) |>
  draw(text("Example", x = unit(0.5, "npc"), y = unit(1, "npc"),
            just = c("centre", "top"), gp = gpar(fontface = "bold")))

render(scene, "plot.png")            # tiny-skia
render(scene, "plot.svg")            # hand-rolled SVG
render(scene, "plot.pdf")            # krilla

# Editing a retained scene by name, then re-rendering
scene <- edit_node(scene, "title", gp = gpar(col = "firebrick"))
```

Key API properties, contrasted with grid:

- **No stateful viewport stack required.** `push()`/`draw()` thread context functionally; navigation is by name, not by global "current viewport." (A stateful convenience layer can wrap this.)
- **One declarative extension API.** A custom element is a function returning concrete child primitives once, at construction — there is no `makeContext`/`makeContent`/`drawDetails`/`widthDetails` multi-hook protocol, because metrics are available up front.
- **Coordinate debugging is first-class**, not an add-on package.

---

## 6. The device-shim mode

A thin adapter registers vellum as a standard R graphics device using extendr's `graphics::DeviceDriver` trait (which wraps `GEcreateDevDesc` / `GEaddDevice2` and the `pDevDesc` callbacks). The engine hands down primitives in device coordinates with an `R_GE_gcontext`; the shim forwards them straight into the Rust render core.

```r
rs_png("out.png", width = 800, height = 600)   # vellum rasterizer as a device
print(ggplot(mpg, aes(displ, hwy)) + geom_point())
dev.off()
```

We declare a `deviceVersion` and implement the capability ladder incrementally:

| Engine ver | R | Features |
|---|---|---|
| 13 | 4.1 | gradients, tiling patterns, clip paths, alpha masks |
| 14 | 4.1 | device-level clipping |
| 15 | 4.2 | isolated groups + compositing operators, affine transforms, stroke/fill paths, luminance masks |
| 16 | 4.3 | typeset **glyph** API — positioned glyph ids + explicit font (our cleanest text seam) |
| 17 | 4.6 | variable fonts |

A minimal device is ~12 callbacks (`line`, `polyline`, `polygon`, `rect`, `circle`, `text`, `strWidth`, `metricInfo`, `newPage`, `close`, `mode`, `size`); the engine emulates the rest until we implement them, and `capabilities()`/`deviceVersion` advertise what we support. The v16 glyph callback maps 1:1 onto our `draw_glyphs` and is the preferred text path.

**The single biggest crash risk:** a Rust `panic!` inside a device callback unwinds across the C boundary and aborts R. Every callback body must catch panics and convert them to a no-op or an R error. (extendr provides the seam; we add the discipline. `vellogd-r` is the reference implementation to mirror.)

---

## 7. Crate / package layout

```
vellum/                      R package root
├── DESCRIPTION              SystemRequirements: Cargo (Rust's package manager), rustc
├── R/                       S7 classes, unit (vctrs), public API, device entry points
├── src/
│   ├── Makevars[.win]       built by rextendr; -j 2 to respect CRAN's job cap
│   ├── entrypoint.c
│   └── rust/
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs       extendr exports (free fns + Scene module)
│           ├── scene.rs     viewport arena, layout/flex solver, the render walk
│           ├── units.rs     unit kinds + resolver (per-coordinate codes)
│           ├── color.rs     Rgba + gpar inheritance
│           ├── font.rs      skrifa glyph outlines + font-bytes cache
│           ├── render.rs    RenderBackend trait + Raster/Svg/Pdf backends
│           └── (device shim — M5 — extendr DeviceDriver, panic-guarded)
├── vendor/ + vendor.tar.xz  cargo vendor output (rextendr::vendor_crates())
└── tests/                   testthat + snapshot/visual regression
```

### CRAN packaging (plan early)

- **Vendor everything** — `cargo vendor` into `vendor/` + `vendor.tar.xz`; no network at build time. `rextendr::vendor_pkgs()` automates it.
- `SystemRequirements: Cargo (Rust's package manager), rustc`; declare copyright of vendored crates in `DESCRIPTION`.
- Cap cargo parallelism (`-j 2`) in `Makevars`; build offline; test against an older toolchain (cargo ≥ ~2–4 years old).

---

## 8. Phased roadmap

**M0 — skeleton. ✅ done.** `rextendr::use_extendr()` scaffold; cross-platform CI (with the Windows GNU Rust target); cargo vendoring; an R↔Rust round-trip. As built: extendr 0.9, tiny-skia 0.11, skrifa 0.31.

**M1 — raster vertical slice. ✅ done.** Scene graph + primitives (rect, lines, polygon, circle, text), `npc`/`native`/absolute units, a single viewport with a scale, tiny-skia → PNG. Text shipped with **font fidelity** (textshaping + systemfonts shaping/resolution, skrifa glyph outlines, per-glyph fallback, justification, rotation). Deterministic pixel-probe tests via `rs_pixel`/`rs_raster`.

**M2 — viewports, layout, clipping, gpar. ✅ done.** Viewport tree (arena) with each resolved viewport an affine transform (local px → device px) so nesting + rotation compose; rectangular clipping via tiny-skia `Mask::intersect_path`; the row/column flex-layout solver (absolute + `null` tracks, spanning); a cacheable DFS layout pass (pure in `(page px, dpi, tree)` → clean resize); gpar inheritance with multiplicative alpha applied once at draw. **Scoped down from the original M2 plan:** per-axis units, `strwidth`/`strheight`, and per-element unit vectors were deferred to M3; `grobwidth`/`grobheight` remain deferred (need a grob-sizing protocol). The flex `null` lives only as a layout track size, not a primitive coordinate unit. Bug fixed in passing: native *position* must use `(v − scale.lo)/span`, not `v/span` (M1 only worked because scales started at 0).

**M3 — the S7/vctrs R API. ✅ done.** Delivered in two halves. **M3a**: a vctrs `unit` type (a `(value, integer-code)` record; codes aligned 1:1 with the Rust `Unit` enum), font/string-relative kinds resolved to absolute mm at construction, and **per-element / per-axis units** threaded through the backend (primitives/viewports take per-coordinate code slices). **M3b**: an **S7** value-object model (`gpar`, abstract `grob` + concrete grobs, `viewport`, `grid_layout`, `gtree`, `vellum_scene`); a `compile` generic (multiple dispatch, one method per grob) that replays the tree onto a fresh Rust `Scene`; a functional builder (`vl_scene |> push() |> draw() |> pop() |> render()`) over an immutable R-side tree; and by-name editing (`node_names`/`get_node`/`edit_node`). The imperative `rs_*` API was demoted to internal — S7 is the only public surface. **The retained tree lives in R** (see the dedicated note above), not in Rust. Registration gotchas resolved: `vctrs::s3_register()` for double-dispatch and `S7::methods_register()` in `.onLoad` (dispatch after install), `@include` for class collation. Vectorised primitives done (grob constructors recycle); `grobwidth`/`grobheight` still deferred.

**M4 — vector outputs. ✅ done.** A `RenderBackend` trait (`fill_path`/`stroke_path`/`draw_text`, with clips as a backend-agnostic chain of viewport rects) over the shared scene walk; tiny-skia raster refactored onto it with byte-identical PNGs. **M4a**: hand-rolled **SVG** (no XML dep) — `<path>`, `matrix(...)` transforms, nested `<clipPath>` applied on a wrapping `<g>` (so a device-space clip isn't double-transformed by the element matrix), selectable `<text>` referencing system fonts (svglite-style, renderer-shaped). **M4b**: **PDF** via `krilla =0.8.2` (default-features off) — paths/transforms converted to krilla's tiny-skia-path newtypes (no tiny-skia bump), a single px→pt root transform, clip via `push_clip_path`, alpha via opacity, and **embedded selectable text** through `draw_glyphs` (font subset/embed; per-glyph text ranges for ToUnicode). `render()` dispatches on file extension. Gradients/patterns/masks remain future work (the scene can't express them yet). `render()` rebuilds a fresh backend each call (the tree lives in R).

**F1 — gradient fills. ✅ done.** Introduced the `Paint` model (see §4.5): `gpar(fill =)` accepts `linear_gradient()` / `radial_gradient()` (colours + optional stops, geometry in any unit, `extend = pad/repeat/reflect`). `fill` is now an `Option<Paint>` through the gpar fold (alpha folds into stops); the scene walk resolves gradient geometry against the viewport into local px and the `fill_path` trait takes a `&ResolvedPaint`. All three backends build native gradients from local-px geometry + identity gradient transform (tiny-skia `LinearGradient`/`RadialGradient`, krilla ditto, SVG `<linearGradient>`/`<radialGradient gradientUnits="userSpaceOnUse">`), so fill and outline share one coordinate space. Verified pixel-identical across raster/rasterized-SVG/rasterized-PDF (±2/255). No new crates. (The device-shim fork below was declined as optional interop.)

**F2 — tiling patterns. ✅ done.** `pattern(grob, width, height, x, y, units, extend)` (a grob or list of grobs) added to the `Paint` model. R renders the tile grob to an RGBA raster via a throwaway sub-`Scene` (sized from `width`/`height` at the scene dpi using one reference dimension, so the tile aspect is `width:height` and only the genuine viewport aspect stretches it), then the backend tiles the image: raster tiny-skia `Pattern`, SVG `<pattern>` + base64-PNG `<image>` (both verified pixel-identical via rsvg-convert). The PDF backend lacks image support (krilla `raster-images` needs un-vendored codecs), so a pattern degrades to its **mean colour** — a documented first-cut limitation. Added the `base64` crate (already vendored transitively via krilla → no re-vendor) plus `pixmap_from_straight`/`average_rgba` helpers; also guarded `parse_paint` to `$`-index only lists (atomic colour vectors error on `$`). `test-pattern.R`, `inst/examples/patterns.R`.

**F3 — masks. ✅ done.** `as_mask(grob, type = "alpha"|"luminance")` + `viewport(mask = …)`. Introduced the isolated compositing group the trait had deferred: `begin_group`/`end_group(mask)`, with masked content compiled to a `GroupStart`…`GroupEnd{mask}` bracket and the mask grob's nodes routed to a side buffer (see §4.5). The mask is always rasterized via a nested `RasterBackend`; raster composites through a tiny-skia `Mask` (alpha/luminance) over a draw-target stack, SVG wraps a buffered group in `<g mask>` with a grayscale-coverage `<mask>` image, PDF renders unmasked (documented, like F2). Verified raster and rasterized-SVG agree (alpha disc, luminance black/white contrast, soft gradient mask). `test-mask.R`, `inst/examples/masks.R`. **The fills/compositing milestone (F1–F3: gradients, patterns, masks) is complete.**

### Scale & fidelity (pre-interactivity, phases P1–P5)

Before interactivity (M6), make the engine scale to large datasets and close the
static-rendering gaps a grammar layer needs. Phases: **P1** batched primitives, **P2**
stroke fidelity (lty/caps/joins), **P3** segments + general path, **P4** raster image
(`draw_image`) + native PDF images/patterns/masks, **P5** polish (text vectorisation,
grob sizing, arbitrary clip).

**P1 — batched primitives & marker fast-path. ✅ done.** The scaling bottleneck was the
per-element R→Rust FFI loop in `compile(grob_rect/circle/points)` (one call + one cloned
`PartialGpar` per element). Now each grob makes **one batched call** (`Scene::rects`/
`circles`) storing a single `Node::Rects`/`Node::Circles` with **one shared gpar**; the
walk resolves gpar/paint once per batch. Rects use a unit-rect + per-element transform for
the solid-no-stroke case (build per-element only when stroked/gradient). Circles go through
a `RenderBackend::draw_circles` method: the default places one unit circle per element
(SVG/PDF, and stroked/gradient cases); the **raster backend overrides it to stamp a cached
AA sprite** for large (≥10k) uniform-radius solid-fill clouds (`circle_sprite` +
`draw_pixmap`, pixel-snapped — imperceptible at that density; viewport transforms are rigid
isometries so the device radius equals the local radius). Measured: **1M points ~7s → 0.76s,
500k → 0.38s, compile 2.2s → 0.01s**; small N keeps the per-element path (pixel-identical).
`test-batch.R`. **Note:** a densely *self-intersecting* polyline is superlinear to stroke
(tiny-skia's stroke→fill of a self-overlapping outline: 100k random verts ≈ 18s) — a
realistic monotone line of 500k verts is ~0.65s, so this is a pathological-input cost, not
a general limit; revisit with decimation if needed.

**M5 — device-shim mode (optional, deferred).** Register as an R graphics device via `DeviceDriver`; implement the minimal callback set, then climb the capability ladder (patterns → groups/compositing → glyphs). Panic-guard every callback. Validate by rendering ggplot2/lattice output. Deferred in favour of filling out the native engine (gradients/patterns/masks); this is interop, not on the Option-B critical path.

**M6 — interactivity.** Spatial index, hit-testing, event model. The scene graph already supports it; this milestone exposes it.

---

## 9. Open questions / risks

- **Scope: confirmed B.** This design commits to a native scene-graph framework (B) with a device shim (A) as interop, not to a device-only "ragg in Rust."
- **Font fidelity: confirmed a requirement.** The primary text path reuses `systemfonts` + `textshaping` (see §3) so font selection and glyph positions agree with the rest of the R ecosystem; the pure-Rust path is a held-to-spec fallback. Open sub-question: how far the fallback can match the primary path without R present, and whether to gate it behind a feature flag. Tension to manage: the fidelity path adds `LinkingTo` deps (and their HarfBuzz/FreeType/Fontconfig chain), partly trading away the "self-contained, headless" benefit — acceptable, since those packages are standard wherever R graphics already run.
- **Pre-1.0 dependencies.** The render stack (tiny-skia, skrifa, krilla) is pre-1.0. Pin and budget upgrades; krilla in particular has breaking minors (pinned `=0.8.2`). krilla bumps the MSRV to rustc 1.92.
- **Panic safety at the C boundary** (device mode) is the top correctness hazard. Non-negotiable discipline; mirror `vellogd-r`.
- **S7 maturity** — experimental, no S4 inheritance. Isolate behind our constructors.
- **Visual regression** — determinism is a headline benefit, so snapshot testing of rendered output (and text geometry vs `textshaping`) is part of the build from M1, not an afterthought.

### Hardening backlog (from the post-M2 review)

Robustness fixes already applied (M2): scene dimensions validated finite/positive and capped (no `Pixmap` panic / runaway alloc); `rgba()` capacity computed in `usize`; per-glyph text vectors length-clamped before indexing; glyph ids carried as `u32` (no `u16` truncation); `x`/`y` length checked in `rs_lines`/`rs_polygon`; gpar colour/number args enforced length-1. (`systemfonts` is not a direct dependency — it is pulled in transitively by `textshaping`, which does the shaping/resolution; declaring it directly would be an unused-import NOTE.)

Addressed in M3: per-element coordinate vectors and **vectorised grob constructors** (recycling via vctrs); the public S7 API replaced the scalar `rs_*` surface. `colour`/`label` are still scalar *per grob*, but a grob is now vectorised over its coordinates (N rects/points from one `rect_grob`/`points_grob`).

Addressed in the post-M4 tidy: the extendr `Scene` object is now **internal** (not exported — S7 is the only public surface); the M0 `rs_bbox` demo was removed and `rs_backend_info` made internal; a PDF-text panic (`gy[0]` indexed without bounding `n` by `gy.len()`) was fixed.

Still open:
- **Text vectorisation.** `text_grob`/`rs_strwidth` still take `label[1]`. A vectorised multi-label text grob (one per position) is future work.
- **Broader input validation.** `width`/`height`/`r` > 0, `alpha ∈ [0,1]` (currently clamped silently in Rust), and out-of-range / missing-layout cells (currently collapse to a 0-size viewport silently) deserve R-side checks with named-argument errors.
- **Render caching.** `render()` rebuilds the whole backend `Scene` and re-reads fonts each call (the tree lives in R). Memoize the backend `Scene`/`Pixmap` or persist the `FontCache` if it becomes a cost; today it is cheap relative to rasterization.
- **Public naming.** `rs_strwidth`/`rs_strheight` keep the internal-looking `rs_` prefix while being public; consider renaming before any release. The internal `rs_*` imperative wrappers still generate (internal) Rd.
- **Clip-mask memory.** Each clipping viewport clones a page-sized `Mask`; fine now, revisit for deep clip trees on large pages.
- **SVG text fidelity.** SVG `<text>` is renderer-shaped (not glyph-faithful). Gradients (F1), tiling patterns (F2), and masks (F3) now exist across the backends; a general `draw_image` primitive and a native PDF image path (patterns/masks; needs krilla's `raster-images`) remain future work.

Addressed in the post-F3 review: a nested-mask routing desync (`group_start`/`group_end` now go through `emit_node`, so a mask grob that itself masks a viewport keeps markers and content in the same node list); pattern `alpha` no longer clones the shared tile (folded into a `PatternFill.opacity` scalar → tiny-skia `Pattern` opacity / SVG `fill-opacity` / PDF fallback alpha); SVG gradient/pattern `<defs>` are deduplicated by content signature (patterns keyed by tile `Rc` identity, so the PNG isn't re-encoded); `RasterBackend::new` skips the full-page clear for transparent backdrops (every rasterized mask); non-finite or zero-span viewport scales fall back to the default instead of producing silently-vanishing NaN geometry; and `viewport()` rejects non-positive `row`/`col`.

Minor issues still open (from the post-F3 review):
- **PDF pattern/mask fidelity.** Patterns degrade to their tile's *unweighted* mean colour and masked groups render unmasked (krilla `raster-images` is off). Alpha-weighting the mean and, eventually, a real image path would improve this.
- **Transparent-texel colour loss.** SVG pattern/mask images round-trip through a premultiplied `Pixmap` (`encode_png`), so RGB under fully transparent texels is discarded. Harmless for display; encode straight bytes if fidelity ever matters.
- **Text colour inheritance.** `compile(grob_text)` passes `col %||% "black"`, so a `NULL` (inherit) text colour is forced black rather than inheriting from the enclosing viewport.
- **Root viewport properties.** `.scene_to_backend` applies only the root viewport's `layout`; its `gp`/`clip`/scales/`mask` are ignored (latent — `vl_scene` always builds a default root).
- **Gradient stop order.** Custom `stops` are clamped to `[0, 1]` but not checked monotonic; out-of-order offsets yield an undefined gradient. Validate/sort.
- **Over-range layout cells.** A `row`/`col` beyond the layout's track count still collapses to a 0-size viewport silently (now at least rejected for `< 1`); a track-count check with a named error is the remaining piece.
- **Full-page mask buffers.** Each masked group allocates page-sized layer + mask pixmaps; inherent to the `draw_pixmap`-masking approach (the mask must match the page-aligned target), so a bounding-box optimisation would require relaxing the page-sized-clip-mask invariant.

---

## 10. Reference prior art

- **R internals**: `R_ext/GraphicsDevice.h`, `R_ext/GraphicsEngine.h`; R-Internals §6 "Graphics"; Paul Murrell's grid vignettes and R Journal articles; the R graphics-engine update reports (gradients, patterns, paths, groups, glyphs).
- **Rust devices in R**: `yutannihilation/vellogd-r` (Vello device, reference for the extendr `DeviceDriver` path) and the archived `wgpugd`.
- **The render stack**: typst (production user of kurbo + tiny-skia + skrifa/harfrust + krilla); resvg/usvg.
- **Modern R fast-graphics stack to interoperate with**: `ragg`, `svglite`, `systemfonts`, `textshaping`, `farver`, gtable, and ggplot2's S7 migration.
- **Scene-graph design**: Qt Quick's `QSGNode` (inert nodes + separate renderer), Flutter's layer tree + relayout/repaint boundaries, the Chromium compositor's property trees.
