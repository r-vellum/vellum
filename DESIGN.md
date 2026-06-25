# rsplot — design

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

`rsplot` targets the **low-level layer** — a grid replacement. It provides drawing primitives, a coordinate/viewport model, a unit system, a retained tree of graphical objects, inherited graphical parameters, and a layout engine. It does **not** provide a grammar of graphics: no data binding, aesthetic mappings, statistical transforms, scales, geoms, facets, guides, or themes. Those belong to a grammar layer built *on top* of rsplot, exactly as ggplot2 and lattice are built on grid.

The difference from grid is where the work happens. In grid, the scene, the units, and the layout solver all live in interpreted R, and rendering is delegated to a separate graphics device. In rsplot, **the scene graph, unit resolution, layout, and rendering all live in Rust**, and R is a thin declarative API that describes what to draw.

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

There are two genuinely different things "a grid-like framework with a Rust backend" can mean. We need to be explicit about which one rsplot is, because it shapes everything.

**Option A — be an R graphics device** (the ragg / svglite / vellogd model). R's engine and grid stay in charge; Rust only rasterizes the primitives the engine hands down via the `DevDesc` callback table. Low risk, proven in Rust (`vellogd-r`, `wgpugd`), and the whole existing ecosystem renders through you for free. But it does **not** give you a new grid — you have only reimplemented a device, and you inherit all of grid's layout/unit/replay costs because grid is still doing that work upstream.

**Option B — reimplement the grid model in Rust** (scene graph, units, viewports, layout, rendering), exposing a thin declarative R API and rendering directly to PNG/SVG/PDF. This is the literal reading of "a framework like grid," and it is the only option that actually fixes the pain points above. Higher risk, more surface area, and it does not automatically inherit ggplot2/lattice.

**rsplot chooses B as the primary architecture, and keeps A as a secondary interop mode.**

- The **core** is a Rust scene graph + unit/layout engine + render backend, driven by an S7-based R API. This is the product.
- A separate, optional **device adapter** lets rsplot register as a standard R graphics device (filling a `DevDesc` and forwarding engine primitives into the same Rust renderer). That gives a migration path and lets existing R graphics — including ggplot2 — render onto rsplot's rasterizer without us reimplementing the grammar. It is an adapter over the same rendering core, not a separate codebase.

So: one Rust rendering/scene core, two front doors — the native rsplot API (the focus) and an R-device shim (for ecosystem reach).

```
┌─────────────────────────── R ───────────────────────────┐
│  rsplot native API (S7)            R graphics device shim │
│  viewport(), rect(), text() …      (DevDesc callbacks)    │
└───────────────┬───────────────────────────┬──────────────┘
                │            extendr          │
┌───────────────▼───────────────────────────▼──────────────┐
│                       Rust core                            │
│  scene graph  →  unit/layout solver  →  render backend     │
│  (kurbo geometry · skrifa+harfrust text · tiny-skia raster)│
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
| SVG output | **hand-rolled** via `xmlwriter` | typst's approach; dedup glyph outlines into `<defs>`. Optionally emit `<text>` to match svglite. |
| PDF output | **krilla** | The PDF backend typst shipped in 0.14. Path fill/stroke, OpenType embedding + subsetting, gradients/patterns, clip paths, masks, blend modes, images, PDF/A + tagged PDF. |
| Color | **palette** | Broad color science incl. Oklab/Oklch for correct gradient interpolation. |

Caveat: several of these are pre-1.0 (kurbo, krilla, parley, fontique). Pin versions and budget periodic upgrades.

### A note on text (font fidelity is a requirement)

Text is the genuinely hard part and the main reason we control the stack. R needs four things from text: string width, font metrics (ascent/descent/units-per-em), rasterized glyphs, and glyph **outlines** for vector output. Because rendering runs in-process, text is measurable at construction time — the property that lets us do eager layout.

We want output whose text *matches the rest of the R ecosystem* — the same font chosen, and the same glyph positions, as ggplot-via-ragg. That has a direct architectural consequence: **fidelity means reusing R's font stack, not reimplementing it.** R's sources of truth are two C/C++ packages with stable callable APIs:

- **`systemfonts`** — resolution: `(family, face ∈ {plain, bold, italic, bolditalic})` → `{font file, face index}`, backed by CoreText / Fontconfig / the Windows registry. This is *the* authority for which file R uses.
- **`textshaping`** — shaping/metrics: string + font → positioned glyphs (ids + advances), via HarfBuzz + FriBidi + FreeType. This is the authority for widths and glyph positions.

A pure-Rust path (`fontique` resolution + `harfrust` shaping) would be *close*, but "close" is not fidelity — font selection and glyph positions would drift from ragg/svglite. So:

- **Primary text path (fidelity):** link `systemfonts` and `textshaping` via their registered C callables (`R_GetCCallable`, `LinkingTo`, shared `FontSettings` struct — exactly how ragg and svglite stay mutually consistent). They hand us a resolved `{file, index}` and positioned glyph runs; **`skrifa`** then loads that file and produces the glyph **outlines** we fill (tiny-skia) or embed (SVG/PDF). This is the ragg architecture with the rasterizer swapped for Rust.
- **Fallback text path (self-contained):** **`skrifa` + `harfrust` + `parley`/`fontique`**, all pure-Rust and headless, for environments without those packages (or where we want zero R-side font deps). Configured to mirror R's family/face resolution rules as closely as possible, and held to the primary path by tests.

Net: glyph rasterization and outline extraction are always `skrifa` (one code path for both text routes); only resolution + shaping differ between the fidelity and self-contained routes. Fidelity is verified by snapshot tests comparing rsplot text geometry against `textshaping::shape_text()` / `systemfonts` output for a fixed corpus.

---

## 4. Core model

### 4.1 Scene graph (retained, immutable)

The scene is a tree of **inert data nodes** — no drawing code lives in a node (the lesson from Qt's Graphics-View → Qt-Quick evolution). A node carries: identity/name, a local affine transform, geometry, a pick-shape for hit-testing, resolved style, and children. The tree is held in Rust; R holds lightweight handles.

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

Rendering is a visitor over the resolved scene, behind a single trait, so PNG/SVG/PDF/device-shim share one walk:

```rust
trait RenderBackend {
    fn begin_page(&mut self, size: Size, bg: Color);
    fn save(&mut self);                 // push transform + clip + style state
    fn restore(&mut self);
    fn set_clip(&mut self, clip: &Clip); // rect or path
    fn fill_path(&mut self, path: &BezPath, rule: FillRule, paint: &Paint);
    fn stroke_path(&mut self, path: &BezPath, stroke: &Stroke, paint: &Paint);
    fn draw_glyphs(&mut self, run: &GlyphRun, paint: &Paint); // positioned glyph ids + font
    fn draw_image(&mut self, img: &Image, transform: Affine, interpolate: bool);
    fn begin_group(&mut self, op: CompositeOp);   // isolated group / compositing
    fn end_group(&mut self, mask: Option<&Mask>);
    fn end_page(&mut self) -> Output;
}
```

This is a stateful immediate-mode rasterizer model (CTM + save/restore + path-then-paint) — the PostScript/Canvas core that R's engine already embodies. tiny-skia, the SVG writer, and krilla each implement it; the device shim implements it too, forwarding into tiny-skia.

### 4.6 Hit-testing and events (designed in, built later)

Because resolved geometry is retained per node, we can build a pluggable spatial index (none for fully-dynamic frames; a BSP/grid index for large static scenes — Qt's model) and a real event/hit-test model from the start, walking reverse-paint order and transforming the query point through the same transform paint uses. This is the gap grid never closed (`grid.locator()` only). Not in the first milestone, but the scene graph is shaped to allow it without rework.

---

## 5. R API sketch

Idiomatic modern R: **S7** for the value-facing object model (the direction ggplot2 4.0 and base R are taking — multiple dispatch, validated properties, value semantics), and **vctrs** for the `unit` vector type (a vectorized record that behaves correctly under `c()`, `[`, and in data frames). S7 is still 0.2.x/experimental and cannot extend S4 — pin it, wrap it behind our own constructors, and avoid designs needing S4 inheritance.

Two usage styles over the same core: a **retained** style (build a scene, edit it, draw it) and an **immediate** style (draw straight to a device) layered on top.

```r
library(rsplot)

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

A thin adapter registers rsplot as a standard R graphics device using extendr's `graphics::DeviceDriver` trait (which wraps `GEcreateDevDesc` / `GEaddDevice2` and the `pDevDesc` callbacks). The engine hands down primitives in device coordinates with an `R_GE_gcontext`; the shim forwards them straight into the Rust render core.

```r
rs_png("out.png", width = 800, height = 600)   # rsplot rasterizer as a device
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
rsplot/                      R package root
├── DESCRIPTION              SystemRequirements: Cargo (Rust's package manager), rustc
├── R/                       S7 classes, unit (vctrs), public API, device entry points
├── src/
│   ├── Makevars[.win]       built by rextendr; -j 2 to respect CRAN's job cap
│   ├── entrypoint.c
│   └── rust/
│       ├── Cargo.toml
│       └── src/
│           ├── lib.rs       extendr exports
│           ├── scene/       node types, immutable tree, edit ops
│           ├── units/       unit kinds + resolver
│           ├── layout/      flex/constraint solver, relayout boundaries
│           ├── text/        skrifa + harfrust + parley/fontique
│           ├── render/      RenderBackend trait + paint state
│           │   ├── raster.rs   tiny-skia
│           │   ├── svg.rs      xmlwriter
│           │   └── pdf.rs      krilla
│           └── device/      extendr DeviceDriver shim (panic-guarded)
├── vendor/ + vendor.tar.xz  cargo vendor output (rextendr::vendor_pkgs())
└── tests/                   testthat + snapshot/visual regression
```

### CRAN packaging (plan early)

- **Vendor everything** — `cargo vendor` into `vendor/` + `vendor.tar.xz`; no network at build time. `rextendr::vendor_pkgs()` automates it.
- `SystemRequirements: Cargo (Rust's package manager), rustc`; declare copyright of vendored crates in `DESCRIPTION`.
- Cap cargo parallelism (`-j 2`) in `Makevars`; build offline; test against an older toolchain (cargo ≥ ~2–4 years old).

---

## 8. Phased roadmap

**M0 — skeleton.** `rextendr::use_extendr()` scaffold; CI that builds Rust + R on Linux/macOS/Windows; vendoring; one trivial extendr call round-tripped. Decide nothing else until this is green.

**M1 — raster vertical slice.** Scene graph + a handful of primitives (rect, lines, polygon, circle, text), `npc`/`native`/absolute units, a single viewport with a scale, tiny-skia → PNG. No layout, no editing yet. Goal: a hand-built scene renders correct, deterministic pixels. Establish visual-regression snapshots here.

**M2 — units, viewports, layout.** Full unit set incl. `strwidth`/`grobwidth` and the flex `null` replacement; nested viewports with rotation and clipping; the row/column layout solver; gpar inheritance; the cacheable layout pass.

**M3 — the S7/vctrs R API.** The retained API (`push`/`draw`/`edit_node`/`render`), the `unit` vctrs type, named nodes and querying/editing. This is when it becomes pleasant to use from R.

**M4 — vector outputs.** SVG (hand-rolled) and PDF (krilla) backends over the shared `RenderBackend` trait. Gradients, patterns, clip paths, masks.

**M5 — device-shim mode.** Register as an R graphics device via `DeviceDriver`; implement the minimal callback set, then climb the capability ladder (patterns → groups/compositing → glyphs). Panic-guard every callback. Validate by rendering ggplot2/lattice output.

**M6 — interactivity.** Spatial index, hit-testing, event model. The scene graph already supports it; this milestone exposes it.

---

## 9. Open questions / risks

- **Scope: confirmed B.** This design commits to a native scene-graph framework (B) with a device shim (A) as interop, not to a device-only "ragg in Rust."
- **Font fidelity: confirmed a requirement.** The primary text path reuses `systemfonts` + `textshaping` (see §3) so font selection and glyph positions agree with the rest of the R ecosystem; the pure-Rust path is a held-to-spec fallback. Open sub-question: how far the fallback can match the primary path without R present, and whether to gate it behind a feature flag. Tension to manage: the fidelity path adds `LinkingTo` deps (and their HarfBuzz/FreeType/Fontconfig chain), partly trading away the "self-contained, headless" benefit — acceptable, since those packages are standard wherever R graphics already run.
- **Pre-1.0 dependencies.** kurbo, krilla, parley, fontique are pre-1.0. Pin and budget upgrades; krilla in particular has breaking minors.
- **Panic safety at the C boundary** (device mode) is the top correctness hazard. Non-negotiable discipline; mirror `vellogd-r`.
- **S7 maturity** — experimental, no S4 inheritance. Isolate behind our constructors.
- **Visual regression** — determinism is a headline benefit, so snapshot testing of rendered output (and text geometry vs `textshaping`) is part of the build from M1, not an afterthought.

---

## 10. Reference prior art

- **R internals**: `R_ext/GraphicsDevice.h`, `R_ext/GraphicsEngine.h`; R-Internals §6 "Graphics"; Paul Murrell's grid vignettes and R Journal articles; the R graphics-engine update reports (gradients, patterns, paths, groups, glyphs).
- **Rust devices in R**: `yutannihilation/vellogd-r` (Vello device, reference for the extendr `DeviceDriver` path) and the archived `wgpugd`.
- **The render stack**: typst (production user of kurbo + tiny-skia + skrifa/harfrust + krilla); resvg/usvg.
- **Modern R fast-graphics stack to interoperate with**: `ragg`, `svglite`, `systemfonts`, `textshaping`, `farver`, gtable, and ggplot2's S7 migration.
- **Scene-graph design**: Qt Quick's `QSGNode` (inert nodes + separate renderer), Flutter's layer tree + relayout/repaint boundaries, the Chromium compositor's property trees.
