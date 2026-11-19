//! The SVG backend and its serialization helpers.

use super::*;

pub struct SvgBackend {
    w: u32,
    h: u32,
    defs: String,
    body: String,
    /// A stack of open group buffers; drawing appends to the top (or `body` when
    /// empty). `end_group` pops one and wraps it in a `<g>` (with its mask).
    groups: Vec<String>,
    group_masks: Vec<Option<MaskLayer>>,
    group_alpha: Vec<f32>,
    group_blend: Vec<BlendKind>,
    group_effect: Vec<GroupEffect>,
    clip_attrs: HashMap<usize, String>,
    /// Deduplicates gradient/pattern `<defs>` by content signature so repeated
    /// identical fills reference one def instead of emitting N copies.
    def_ids: HashMap<String, String>,
    next_clip: u32,
    next_grad: u32,
    /// Prepended to every generated `<defs>` id (`c0`, `g0`, `fx0`): the
    /// document-id token ([`ID_TOKEN`]) and a dash, so a standalone document's ids
    /// read `vl1a2b3c4d-c0` once [`resolve_ids`] fills the token in. The
    /// animated-SVG builder adds a per-frame part (`f3-`): all its frames live in
    /// ONE document, so without it every frame would define the same `c0` and all
    /// 48 `url(#…c0)` references would resolve to the first — which sits inside a
    /// `visibility:hidden` group, and a hidden `<clipPath>` child contributes no
    /// geometry, so the clip empties and the panel disappears.
    id_prefix: String,
    /// Whether `into_string` resolves the document-id token itself (a standalone
    /// document) or leaves it for the caller that splices this render into a
    /// larger document (an animation frame; see `set_id_prefix`).
    resolve_ids: bool,
    /// When true, text is emitted as filled glyph `<path>` outlines (pixel-faithful,
    /// matching raster/PDF) instead of selectable `<text>` (renderer-shaped).
    outline_text: bool,
    /// Per-node metadata buffers (`begin_node`/`end_node`): a stack of partial
    /// buffers that drawing appends to, and a parallel stack of the wrapping `<g>`
    /// attributes (`None` = this node carried no metadata, so no buffer was pushed).
    node_stack: Vec<String>,
    node_open: Vec<Option<String>>,
    /// Pannable-panel state (clip-stable pan group). `panel_pannable` records, per
    /// open panel, whether it is pannable (so `end_panel` closes one group or two).
    /// While inside a pannable panel, the first clipped element's clip is hoisted
    /// onto the outer panel group (`pan_clip_id`) and suppressed on the elements
    /// (which live in the inner, transformable group). `pan_active` guards against
    /// nested pannable panels (the inner one falls back to an ordinary panel).
    panel_pannable: Vec<bool>,
    pan_active: bool,
    pan_clip_pending: bool,
    pan_clip_id: Option<usize>,
    /// Per-element data key for the next primitive (`set_element_key`); spliced
    /// into the emitted element as `data-key="…"`. `None` = no attribute. Held as
    /// `Rc<str>` so `emit` (called once per fill and once per stroke of an element)
    /// can take a cheap refcount-bump clone rather than copying the key each time.
    cur_element_key: Option<Rc<str>>,
    /// Memoised `fill="…" fill-opacity="…"` for the last solid paint. A batched
    /// primitive resolves one paint for the whole run, so this hits on every
    /// element after the first — skipping a per-element `rgb_hex` + `format!`.
    last_solid_fill: Option<(Rgba, String)>,
    /// Scene-level accessible name / long description (a11y). When either is set,
    /// the root `<svg>` gains `role="img"` + `aria-labelledby` and emits
    /// `<title>`/`<desc>` children. `a11y_prefix`, when non-empty, is the
    /// document's id prefix (for the title/desc and every `<defs>` id); empty, the
    /// prefix is derived from the document's content (see [`resolve_ids`]).
    a11y_title: Option<String>,
    a11y_desc: Option<String>,
    a11y_prefix: String,
}

impl SvgBackend {
    pub fn new(w: u32, h: u32, bg: Rgba, outline_text: bool) -> Self {
        let mut body = String::new();
        if bg.a > 0 {
            body.push_str(&format!(
                "<rect width=\"{w}\" height=\"{h}\" fill=\"{}\" fill-opacity=\"{}\"/>",
                rgb_hex(bg),
                opacity(bg)
            ));
        }
        SvgBackend {
            w,
            h,
            defs: String::new(),
            body,
            groups: Vec::new(),
            group_masks: Vec::new(),
            group_alpha: Vec::new(),
            group_blend: Vec::new(),
            group_effect: Vec::new(),
            clip_attrs: HashMap::new(),
            def_ids: HashMap::new(),
            next_clip: 0,
            next_grad: 0,
            id_prefix: format!("{ID_TOKEN}-"),
            resolve_ids: true,
            outline_text,
            node_stack: Vec::new(),
            node_open: Vec::new(),
            panel_pannable: Vec::new(),
            pan_active: false,
            pan_clip_pending: false,
            pan_clip_id: None,
            cur_element_key: None,
            last_solid_fill: None,
            a11y_title: None,
            a11y_desc: None,
            a11y_prefix: String::new(),
        }
    }

    /// Set the scene-level accessible name (`title`) and long description
    /// (`desc`), and an explicit document id `prefix`. Empty strings are treated
    /// as absent (an empty prefix is derived from the content).
    pub fn set_a11y(&mut self, title: &str, desc: &str, prefix: &str) {
        self.a11y_title = if title.is_empty() {
            None
        } else {
            Some(title.to_string())
        };
        self.a11y_desc = if desc.is_empty() {
            None
        } else {
            Some(desc.to_string())
        };
        self.a11y_prefix = prefix.to_string();
    }

    /// Namespace this backend's generated `<defs>` ids, for when its output is
    /// spliced into a document alongside other renders (animation frames). The
    /// document-id token is then left in place: the caller resolves it once, over
    /// the whole document, with [`resolve_ids`].
    pub fn set_id_prefix(&mut self, prefix: &str) {
        self.id_prefix = format!("{ID_TOKEN}-{prefix}");
        self.resolve_ids = false;
    }

    /// Return the id of a `<defs>` entry with signature `key`, emitting it via
    /// `make(id)` the first time and reusing it afterwards.
    ///
    /// The `key` is a `format!` string (callers include the serialized stops /
    /// tile-`Rc` pointer + geometry). A struct/`Rc`-keyed map would avoid the string
    /// alloc, but the key cost is dwarfed by the surrounding SVG serialization, so it
    /// is intentionally left as-is.
    fn intern_def(&mut self, key: String, make: impl FnOnce(&str) -> String) -> String {
        if let Some(id) = self.def_ids.get(&key) {
            return id.clone();
        }
        let id = format!("{}g{}", self.id_prefix, self.next_grad);
        self.next_grad += 1;
        let def = make(&id);
        self.defs.push_str(&def);
        self.def_ids.insert(key, id.clone());
        id
    }

    /// The buffer currently receiving output: an open per-node metadata buffer
    /// (innermost), else the innermost open compositing group, else the body.
    fn out(&mut self) -> &mut String {
        if !self.node_stack.is_empty() {
            self.node_stack.last_mut().unwrap()
        } else if !self.groups.is_empty() {
            self.groups.last_mut().unwrap()
        } else {
            &mut self.body
        }
    }

    /// The `fill="..."` attributes for a resolved paint (registers a gradient def
    /// when needed). Gradient coords are local px (`userSpaceOnUse`); the element's
    /// own `transform` maps them to device, exactly like the path geometry.
    fn svg_fill(&mut self, paint: &ResolvedPaint) -> String {
        match paint {
            // Expanded to stroked spans by the walk; nothing to reference here.
            ResolvedPaint::Hatch { .. } => String::from("fill=\"none\""),
            ResolvedPaint::Solid(c) => {
                if let Some((pc, s)) = &self.last_solid_fill {
                    if pc == c {
                        return s.clone();
                    }
                }
                let s = format!(
                    "fill=\"{}\"{}",
                    rgb_hex(*c),
                    opacity_attr("fill-opacity", *c)
                );
                self.last_solid_fill = Some((*c, s.clone()));
                s
            }
            ResolvedPaint::Linear {
                x1,
                y1,
                x2,
                y2,
                stops,
                extend,
            } => {
                let stops_xml = svg_stops(stops);
                let s = svg_spread(*extend);
                let key = format!("L|{x1}|{y1}|{x2}|{y2}|{s}|{stops_xml}");
                let id = self.intern_def(key, |id| {
                    format!(
                        "<linearGradient id=\"{id}\" gradientUnits=\"userSpaceOnUse\" \
                         x1=\"{x1}\" y1=\"{y1}\" x2=\"{x2}\" y2=\"{y2}\" spreadMethod=\"{s}\">{stops_xml}</linearGradient>"
                    )
                });
                format!("fill=\"url(#{id})\"")
            }
            ResolvedPaint::Radial {
                cx,
                cy,
                r,
                fx,
                fy,
                fr,
                stops,
                extend,
            } => {
                let stops_xml = svg_stops(stops);
                let s = svg_spread(*extend);
                // SVG's `fx`/`fy` default to `cx`/`cy` and `fr` to 0, so a concentric
                // gradient omits them — keeping its output byte-identical to before.
                let focal = if *fr != 0.0 || *fx != *cx || *fy != *cy {
                    format!(" fx=\"{fx}\" fy=\"{fy}\" fr=\"{fr}\"")
                } else {
                    String::new()
                };
                let key = format!("R|{cx}|{cy}|{r}|{focal}|{s}|{stops_xml}");
                let id = self.intern_def(key, |id| {
                    format!(
                        "<radialGradient id=\"{id}\" gradientUnits=\"userSpaceOnUse\" \
                         cx=\"{cx}\" cy=\"{cy}\" r=\"{r}\"{focal} spreadMethod=\"{s}\">{stops_xml}</radialGradient>"
                    )
                });
                format!("fill=\"url(#{id})\"")
            }
            ResolvedPaint::Pattern {
                tile,
                tw,
                th,
                x,
                y,
                w,
                h,
                opacity,
                ..
            } => {
                // The tile is embedded as a PNG data URI and stretched over a
                // userSpaceOnUse cell; the element's own transform maps it to
                // device, like the path. (SVG patterns tile by repeat; the
                // reflect/pad extend modes degrade to repeat here.) Dedup by the
                // tile's `Rc` identity + geometry so we don't re-encode the PNG.
                let (px, py) = (x - w / 2.0, y - h / 2.0);
                let key = format!("P|{:p}|{px}|{py}|{w}|{h}", Arc::as_ptr(tile));
                let id = match self.def_ids.get(&key) {
                    Some(id) => id.clone(),
                    None => {
                        let png = straight_png(tile, *tw, *th);
                        let href = match png {
                            Some(bytes) => format!("data:image/png;base64,{}", b64(&bytes)),
                            None => return String::from("fill=\"none\""),
                        };
                        let id = format!("{}g{}", self.id_prefix, self.next_grad);
                        self.next_grad += 1;
                        self.defs.push_str(&format!(
                            "<pattern id=\"{id}\" patternUnits=\"userSpaceOnUse\" \
                             x=\"{px}\" y=\"{py}\" width=\"{w}\" height=\"{h}\">\
                             <image href=\"{href}\" x=\"0\" y=\"0\" width=\"{w}\" height=\"{h}\" \
                             preserveAspectRatio=\"none\"/></pattern>"
                        ));
                        self.def_ids.insert(key, id.clone());
                        id
                    }
                };
                let op = if *opacity < 1.0 {
                    format!(" fill-opacity=\"{opacity}\"")
                } else {
                    String::new()
                };
                format!("fill=\"url(#{id})\"{op}")
            }
        }
    }

    pub fn into_string(self) -> String {
        // Accessibility: when a scene name/description is set, mark the root as an
        // image with an accessible name+description via `role="img"` +
        // `aria-labelledby`, and emit `<title>`/`<desc>` as the first children
        // (the placement AT expects). Absent => byte-identical to before.
        let mut svg_attrs = String::new();
        let mut a11y_head = String::new();
        if self.a11y_title.is_some() || self.a11y_desc.is_some() {
            // The document-id token; `resolve_ids` replaces it with the prefix.
            let p = ID_TOKEN;
            let mut ids: Vec<String> = Vec::new();
            if let Some(t) = &self.a11y_title {
                ids.push(format!("{p}-t"));
                a11y_head.push_str(&format!("<title id=\"{p}-t\">{}</title>", xml_escape(t)));
            }
            if let Some(d) = &self.a11y_desc {
                ids.push(format!("{p}-d"));
                a11y_head.push_str(&format!("<desc id=\"{p}-d\">{}</desc>", xml_escape(d)));
            }
            svg_attrs = format!(" role=\"img\" aria-labelledby=\"{}\"", ids.join(" "));
        }
        let doc = format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
             <svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{w}\" height=\"{h}\" \
             viewBox=\"0 0 {w} {h}\"{a}>{head}<defs>{defs}</defs>{body}</svg>\n",
            w = self.w,
            h = self.h,
            a = svg_attrs,
            head = a11y_head,
            defs = self.defs,
            body = self.body
        );
        if self.resolve_ids {
            resolve_ids(doc, &self.a11y_prefix)
        } else {
            doc
        }
    }

    /// Append `element`, wrapped in a clipping `<g>` when a clip applies. The
    /// clip group carries no transform, so its `userSpaceOnUse` clipPath (device
    /// coords) and the element's own `transform` both resolve in device space
    /// and stay aligned — putting `clip-path` directly on a transformed element
    /// would double-transform the clip region.
    fn emit(&mut self, element: &str, clip: &Clip) {
        let mut attr = self.clip_attr(clip);
        // Pannable panel: hoist the first clipped element's clip onto the outer
        // panel group (so it stays put under the inner group's transform), and
        // suppress that clip on the elements themselves. The outer frame is the one
        // below the inner `data-vellum-pan` frame on the open-frame stack.
        if self.pan_active && !attr.is_empty() {
            if self.pan_clip_pending {
                let n = self.node_open.len();
                if n >= 2 {
                    if let Some(outer) = self.node_open[n - 2].as_mut() {
                        outer.push_str(&attr);
                    }
                }
                self.pan_clip_id = Some(clip.id);
                self.pan_clip_pending = false;
            }
            if self.pan_clip_id == Some(clip.id) {
                attr = String::new(); // hoisted to the outer group; don't re-clip here
            }
        }
        let has_clip = !attr.is_empty();
        // A per-element `data-key` is spliced into the shape's opening tag when set
        // (kept, not cleared, so a fill+stroke pair for one element both carry it;
        // the batched render loop clears it when the node ends). Writing straight
        // into the output buffer avoids copying the whole `element` string (and, when
        // keyed, the extra splice buffer) that the previous formatting approach did.
        let key = self.cur_element_key.clone(); // cheap Rc refcount bump when set
        let out = self.out();
        if has_clip {
            out.push_str("<g");
            out.push_str(&attr);
            out.push('>');
        }
        match &key {
            Some(k) => push_data_keyed(out, element, k),
            None => out.push_str(element),
        }
        if has_clip {
            out.push_str("</g>");
        }
    }

    /// A ` clip-path="url(#…)"` attribute for this clip (empty string = none).
    /// Nested `<clipPath>` elements (each referencing the previous) intersect.
    fn clip_attr(&mut self, clip: &Clip) -> String {
        if clip.shapes.is_empty() {
            return String::new();
        }
        if let Some(a) = self.clip_attrs.get(&clip.id) {
            return a.clone();
        }
        let mut parent_ref = String::new();
        let mut last = String::new();
        for shape in clip.shapes {
            let id = format!("{}c{}", self.id_prefix, self.next_clip);
            self.next_clip += 1;
            // Clip geometry is baked to device coords (userSpaceOnUse) so the
            // wrapping `<g>` carries no transform.
            let rule = matches!(shape, ClipShape::Path { evenodd: true, .. });
            let rule_attr = if rule { " clip-rule=\"evenodd\"" } else { "" };
            self.defs.push_str(&format!(
                "<clipPath id=\"{id}\" clipPathUnits=\"userSpaceOnUse\"{parent_ref}><path d=\"{d}\"{rule_attr}/></clipPath>",
                d = clip_shape_d(shape),
            ));
            parent_ref = format!(" clip-path=\"url(#{id})\"");
            last = id;
        }
        let attr = format!(" clip-path=\"url(#{last})\"");
        self.clip_attrs.insert(clip.id, attr.clone());
        attr
    }
}

impl RenderBackend for SvgBackend {
    fn fill_path(
        &mut self,
        path: &Path,
        transform: Transform,
        paint: &ResolvedPaint,
        rule: FillRule,
        clip: &Clip,
    ) {
        let fill = self.svg_fill(paint);
        let rule_attr = match rule {
            FillRule::EvenOdd => " fill-rule=\"evenodd\"",
            FillRule::Winding => "",
        };
        // A solid fill looks the same however the geometry reaches device space,
        // so its transform is baked into the coordinates (no per-element
        // `transform`), and a circle is written as a `<circle>`. A gradient or
        // pattern is laid out in local px, so it keeps local geometry and the
        // element's own `transform`.
        let element = if matches!(paint, ResolvedPaint::Solid(_)) {
            match circle_of(path).and_then(|c| bake_circle(c, transform)) {
                Some((cx, cy, r)) => format!("<circle {} {fill}/>", circle_attrs(cx, cy, r)),
                None => format!(
                    "<path d=\"{}\" {fill}{rule_attr}/>",
                    path_to_d(path, Some(transform), Some(COORD_DECIMALS)),
                ),
            }
        } else {
            format!(
                "<path d=\"{}\" {fill}{rule_attr}{}/>",
                path_to_d(path, None, Some(coord_decimals(transform))),
                transform_attr(transform),
            )
        };
        self.emit(&element, clip);
    }

    fn stroke_path(
        &mut self,
        path: &Path,
        transform: Transform,
        color: Rgba,
        stroke: &StrokeStyle,
        clip: &Clip,
    ) {
        if stroke.width <= 0.0 {
            return;
        }
        // A solid stroke under a similarity transform (uniform scale, rotation,
        // translation) is baked into device coordinates, with the width and dash
        // scaled by the same factor: the outline it strokes is the same. Anything
        // else (a gradient/pattern stroke laid out in local px, or a non-uniform
        // scale that would stretch the pen) keeps local geometry + `transform`.
        let bake = match &stroke.paint {
            None => similarity_scale(transform),
            Some(_) => None,
        };
        // Lengths in the element's own units: scaled (and rounded) when baked,
        // otherwise written exactly as before.
        let len = |v: f32| -> String {
            match bake {
                Some(k) if k != 1.0 => {
                    let mut o = String::new();
                    push_num(&mut o, v as f64 * k, 3);
                    o
                }
                _ => v.to_string(),
            }
        };
        let dash = if stroke.dash.is_empty() {
            String::new()
        } else {
            let arr: Vec<String> = stroke.dash.iter().map(|d| len(*d)).collect();
            let off = if stroke.phase != 0.0 {
                format!(" stroke-dashoffset=\"{}\"", len(stroke.phase))
            } else {
                String::new()
            };
            format!(" stroke-dasharray=\"{}\"{off}", arr.join(","))
        };
        // A gradient/pattern stroke reuses the fill machinery: `svg_fill` already
        // emits the <defs> entry and returns `fill="url(#id)"` (plus a pattern's
        // `fill-opacity`), so rewrite the attribute names.
        let stroke_attr = match &stroke.paint {
            Some(p) => self
                .svg_fill(p)
                .replace("fill-opacity=", "stroke-opacity=")
                .replace("fill=", "stroke="),
            None => format!(
                "stroke=\"{}\"{}",
                rgb_hex(color),
                opacity_attr("stroke-opacity", color)
            ),
        };
        // The miter limit only shapes miter joins; a round join ignores it.
        let miter = match stroke.join {
            LineJoin::Round => String::new(),
            _ => format!(" stroke-miterlimit=\"{}\"", stroke.miter),
        };
        let paint = format!(
            "fill=\"none\" {} stroke-width=\"{}\" stroke-linecap=\"{}\" stroke-linejoin=\"{}\"{miter}{dash}",
            stroke_attr,
            len(stroke.width),
            svg_cap(stroke.cap),
            svg_join(stroke.join),
        );
        let element = match bake {
            Some(_) => {
                // An undashed circle becomes a `<circle>`: it starts at the same
                // east point and runs the same way, but a dash would expose the
                // tiny length difference from the quadratic approximation.
                let circle = if stroke.dash.is_empty() {
                    circle_of(path).and_then(|c| bake_circle(c, transform))
                } else {
                    None
                };
                match circle {
                    Some((cx, cy, r)) => format!("<circle {} {paint}/>", circle_attrs(cx, cy, r)),
                    None => format!(
                        "<path d=\"{}\" {paint}/>",
                        path_to_d(path, Some(transform), Some(COORD_DECIMALS)),
                    ),
                }
            }
            None => format!(
                "<path d=\"{}\" {paint}{}/>",
                path_to_d(path, None, Some(coord_decimals(transform))),
                transform_attr(transform),
            ),
        };
        self.emit(&element, clip);
    }

    fn draw_text(&mut self, run: &TextRun, transform: Transform, clip: &Clip) {
        if run.label.is_empty() {
            return;
        }
        // A rich (per-glyph colour) label can't be a single `<text>` element, so it
        // always takes the outline path even when native text is otherwise preferred.
        let rich = !run.gcolor.is_empty();
        // Glyph runs grouped into lines by a change of baseline. SVG `<text>`
        // ignores newlines outright, so a multi-line run emitted as one element
        // would silently collapse onto one line -- which it did until wrapped
        // text made that a headline feature rather than a corner case.
        let lines = line_runs(run);
        let label_lines: Vec<&str> = run.label.split('\n').collect();
        // Per-line native text needs the label split to agree with the glyph
        // grouping. When it doesn't, outlines are the honest fallback: they carry
        // no such assumption and already place every glyph by its own baseline.
        let multiline_ok = lines.len() == label_lines.len();
        if self.outline_text || rich || (lines.len() > 1 && !multiline_ok) {
            // Glyph-faithful: fill the same skrifa outlines the raster backend uses,
            // each placed by the shared glyph transform — so SVG matches raster/PDF
            // exactly (no dependence on the viewer's fonts).
            let base = if run.rot != 0.0 {
                transform.pre_concat(rotation_about(run.rot, run.ax, run.ay))
            } else {
                transform
            };
            let n = run
                .gid
                .len()
                .min(run.gx.len())
                .min(run.gy.len())
                .min(run.gsize.len())
                .min(run.gpath.len())
                .min(run.gface.len());
            let mut paths = String::new();
            // Halo first, as a complete pass: all outlines stroked before any is
            // filled, so a wide halo cannot paint over an already-filled neighbour.
            if let Some((hcol, hw)) = run.halo {
                for i in 0..n {
                    let outline = match glyph_outline_cached(
                        &run.gpath[i],
                        run.gface[i],
                        run.gid[i],
                        run.gsize[i] as f32,
                    ) {
                        Some(p) => p,
                        None => continue,
                    };
                    let ox = run.ax + run.gx[i] - run.hjust * run.w;
                    let oy = run.ay - (run.gy[i] - run.vjust * run.h);
                    let place = base.pre_concat(Transform::from_row(
                        1.0, 0.0, 0.0, -1.0, ox as f32, oy as f32,
                    ));
                    // `hw * 2` for the same reason as the raster backend: the stroke
                    // is centred, so half is hidden under the fill.
                    paths.push_str(&format!(
                        "<path d=\"{}\" fill=\"none\" stroke=\"{}\" stroke-opacity=\"{}\" \
                         stroke-width=\"{}\" stroke-linejoin=\"round\" stroke-linecap=\"round\"{}/>",
                        path_to_d(outline.as_ref(), None, None), rgb_hex(hcol), opacity(hcol), hw * 2.0,
                        transform_attr(place)
                    ));
                }
            }
            for i in 0..n {
                let outline = match glyph_outline_cached(
                    &run.gpath[i],
                    run.gface[i],
                    run.gid[i],
                    run.gsize[i] as f32,
                ) {
                    Some(p) => p,
                    None => continue,
                };
                let ox = run.ax + run.gx[i] - run.hjust * run.w;
                let oy = run.ay - (run.gy[i] - run.vjust * run.h);
                let place = base.pre_concat(Transform::from_row(
                    1.0, 0.0, 0.0, -1.0, ox as f32, oy as f32,
                ));
                // Per-glyph fill for rich labels; otherwise inherit the group's fill.
                let fill_attr = match run.gcolor.get(i) {
                    Some(&c) => format!(" fill=\"{}\" fill-opacity=\"{}\"", rgb_hex(c), opacity(c)),
                    None => String::new(),
                };
                paths.push_str(&format!(
                    "<path d=\"{}\"{}{}/>",
                    path_to_d(outline.as_ref(), None, None),
                    fill_attr,
                    transform_attr(place)
                ));
            }
            if !paths.is_empty() {
                let element = format!(
                    "<g fill=\"{col}\" fill-opacity=\"{op}\">{paths}</g>",
                    col = rgb_hex(run.color),
                    op = opacity(run.color),
                );
                self.emit(&element, clip);
            }
            return;
        }
        let anchor = match run.hjust {
            h if h <= 0.0 => "start",
            h if h >= 1.0 => "end",
            _ => "middle",
        };
        let baseline = match run.vjust {
            v if v <= 0.0 => "text-after-edge",
            v if v >= 1.0 => "text-before-edge",
            _ => "central",
        };
        // Local-px font size (the viewport transform is isometric, so 1 local
        // unit == 1 device px); shape_text size is in points.
        let font_px = run.size * run.dpi / 72.0;
        let weight = if run.face.contains("bold") {
            " font-weight=\"bold\""
        } else {
            ""
        };
        let style = if run.face.contains("italic") || run.face.contains("oblique") {
            " font-style=\"italic\""
        } else {
            ""
        };
        let rot = if run.rot != 0.0 {
            // SVG rotate is clockwise in the y-down frame; grid angle is CCW.
            format!(" rotate({} {} {})", -run.rot, run.ax, run.ay)
        } else {
            String::new()
        };
        let family = if run.family.is_empty() {
            "sans-serif"
        } else {
            run.family
        };
        // `paint-order="stroke fill"` is exactly the two-pass halo the raster and
        // outline paths do by hand, and it keeps the text selectable.
        let halo_attr = match run.halo {
            Some((hcol, hw)) => format!(
                " paint-order=\"stroke fill\" stroke=\"{}\" stroke-opacity=\"{}\" \
                 stroke-width=\"{}\" stroke-linejoin=\"round\"",
                rgb_hex(hcol),
                opacity(hcol),
                hw * 2.0
            ),
            None => String::new(),
        };
        // Multi-line: one `<text>` per line, positioned from that line's own
        // glyphs. Anchoring is explicit (`start` / alphabetic baseline) rather
        // than inherited from hjust/vjust, because the per-line geometry has
        // already applied both -- including any `align` shift, which is baked
        // into the glyph offsets and would be lost by re-anchoring here.
        if lines.len() > 1 {
            let mut out = String::new();
            for (li, &(lo, hi)) in lines.iter().enumerate() {
                let text = label_lines[li];
                if text.is_empty() || lo >= hi {
                    continue; // a blank line has no glyphs and needs no element
                }
                out.push_str(&format!(
                    "<text x=\"{x}\" y=\"{y}\" transform=\"{t}{rot}\" fill=\"{col}\" \
                     fill-opacity=\"{op}\" font-family=\"{fam}\" font-size=\"{size}\" \
                     text-anchor=\"start\" dominant-baseline=\"alphabetic\"\
                     {weight}{style}{halo}>{label}</text>",
                    x = run.ax + run.gx[lo] - run.hjust * run.w,
                    y = run.ay - (run.gy[lo] - run.vjust * run.h),
                    t = matrix_str(transform),
                    col = rgb_hex(run.color),
                    op = opacity(run.color),
                    fam = xml_escape(family),
                    size = font_px,
                    halo = halo_attr,
                    label = xml_escape(text),
                ));
            }
            if !out.is_empty() {
                self.emit(&out, clip);
            }
            return;
        }
        let element = format!(
            "<text x=\"{x}\" y=\"{y}\" transform=\"{t}{rot}\" fill=\"{col}\" fill-opacity=\"{op}\" \
             font-family=\"{fam}\" font-size=\"{size}\" text-anchor=\"{anchor}\" \
             dominant-baseline=\"{baseline}\"{weight}{style}{halo}>{label}</text>",
            x = run.ax,
            y = run.ay,
            t = matrix_str(transform),
            col = rgb_hex(run.color),
            op = opacity(run.color),
            fam = xml_escape(family),
            size = font_px,
            halo = halo_attr,
            label = xml_escape(run.label),
        );
        self.emit(&element, clip);
    }

    fn begin_group(
        &mut self,
        mask: Option<MaskLayer>,
        alpha: f32,
        blend: BlendKind,
        effect: GroupEffect,
    ) {
        self.groups.push(String::new());
        self.group_masks.push(mask);
        self.group_alpha.push(alpha);
        self.group_blend.push(blend);
        self.group_effect.push(effect);
    }

    fn end_group(&mut self) {
        let mask = self.group_masks.pop().flatten();
        let alpha = self.group_alpha.pop().unwrap_or(1.0);
        let blend = self.group_blend.pop().unwrap_or(BlendKind::Normal);
        let effect = self.group_effect.pop().unwrap_or_default();
        let inner = self.groups.pop().unwrap_or_default();
        // Blur and drop shadow are native SVG filter primitives, so the viewer
        // does the work and the group stays vector. The filter region is widened
        // past the default -10%/120% box, which clips a wide blur or a far offset.
        let filter_attr = if effect.is_none() {
            String::new()
        } else {
            let id = format!("{}fx{}", self.id_prefix, self.next_grad);
            self.next_grad += 1;
            let mut prims = String::new();
            if let Some(sh) = effect.shadow {
                prims.push_str(&format!(
                    "<feDropShadow dx=\"{dx}\" dy=\"{dy}\" stdDeviation=\"{sd}\" \
                     flood-color=\"{col}\" flood-opacity=\"{op}\"/>",
                    dx = sh.dx,
                    dy = sh.dy,
                    sd = sh.blur,
                    col = rgb_hex(sh.col),
                    op = opacity(sh.col),
                ));
            }
            if let Some(r) = effect.blur {
                prims.push_str(&format!("<feGaussianBlur stdDeviation=\"{r}\"/>"));
            }
            self.defs.push_str(&format!(
                "<filter id=\"{id}\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\">{prims}</filter>"
            ));
            format!(" filter=\"url(#{id})\"")
        };
        // SVG masks are luminance-based; bake the chosen coverage into a grayscale
        // image (gray == coverage) so a single luminance mask serves both kinds.
        // Group opacity is a `<g opacity>` (applies to the composited layer).
        let mask_attr = match mask.and_then(|ml| mask_png(&ml.pixmap, ml.kind)) {
            Some(png) => {
                let id = format!("{}g{}", self.id_prefix, self.next_grad);
                self.next_grad += 1;
                self.defs.push_str(&format!(
                    "<mask id=\"{id}\" maskUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" \
                     width=\"{w}\" height=\"{h}\"><image href=\"data:image/png;base64,{b}\" \
                     x=\"0\" y=\"0\" width=\"{w}\" height=\"{h}\" preserveAspectRatio=\"none\"/></mask>",
                    w = self.w,
                    h = self.h,
                    b = b64(&png),
                ));
                format!(" mask=\"url(#{id})\"")
            }
            None => String::new(),
        };
        let opacity_attr = if alpha < 1.0 {
            format!(" opacity=\"{alpha}\"")
        } else {
            String::new()
        };
        // Group blend is CSS `mix-blend-mode` (blends the group against the backdrop).
        let blend_attr = match blend.svg() {
            Some(mode) => format!(" style=\"mix-blend-mode:{mode}\""),
            None => String::new(),
        };
        self.out().push_str(&format!(
            "<g{mask_attr}{opacity_attr}{blend_attr}{filter_attr}>{inner}</g>"
        ));
    }

    fn draw_image(
        &mut self,
        rgba: &[u8],
        iw: u32,
        ih: u32,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        interpolate: bool,
        transform: Transform,
        clip: &Clip,
    ) {
        let png = match straight_png(rgba, iw, ih) {
            Some(b) => b,
            None => return,
        };
        let rendering = if interpolate {
            ""
        } else {
            " image-rendering=\"pixelated\""
        };
        let element = format!(
            "<image href=\"data:image/png;base64,{b}\" x=\"{px}\" y=\"{py}\" width=\"{w}\" height=\"{h}\" \
             preserveAspectRatio=\"none\"{rendering}{tr}/>",
            b = b64(&png),
            px = x - w / 2.0,
            py = y - h / 2.0,
            tr = transform_attr(transform),
        );
        self.emit(&element, clip);
    }

    // Per-node semantic metadata: route this node's elements into a fresh buffer,
    // then wrap them in a `<g …>` carrying the attributes. A node with no metadata
    // pushes `None` (no buffer) so the common case is free of an extra group.
    fn begin_node(&mut self, meta: &NodeMeta) {
        let attrs = meta.svg_attrs();
        if attrs.is_empty() {
            self.node_open.push(None);
        } else {
            self.node_stack.push(String::new());
            self.node_open.push(Some(attrs));
        }
    }

    fn wants_node_meta(&self) -> bool {
        true
    }

    fn end_node(&mut self) {
        if let Some(Some(attrs)) = self.node_open.pop() {
            let inner = self.node_stack.pop().unwrap_or_default();
            self.out().push_str(&format!("<g {attrs}>{inner}</g>"));
        }
    }

    fn set_element_key(&mut self, key: Option<&str>) {
        self.cur_element_key = key.map(Rc::from);
    }

    fn wants_element_keys(&self) -> bool {
        true
    }

    // A named panel group: route the enclosed nodes into a fresh buffer, then wrap
    // them in `<g data-vellum-panel="…">`. Reuses the node-metadata buffer stack
    // (identical mechanism), so panels and per-node `<g>`s nest correctly. The
    // wrapper carries no transform — elements keep their baked device-space
    // transforms, matching the clip-`<g>` invariant.
    fn begin_panel(&mut self, name: &str, pannable: bool) {
        // A pannable panel (and not already inside one) emits TWO nested frames: an
        // outer `<g data-vellum-panel>` that will carry the hoisted clip (added
        // lazily from the first clipped element, in `emit`) and stays untransformed,
        // and an inner `<g data-vellum-pan>` a host can transform. Otherwise a single
        // `<g data-vellum-panel>` as before.
        let pan = pannable && !self.pan_active;
        self.node_stack.push(String::new());
        self.node_open
            .push(Some(format!("data-vellum-panel=\"{}\"", xml_escape(name))));
        if pan {
            self.node_stack.push(String::new());
            self.node_open
                .push(Some(format!("data-vellum-pan=\"{}\"", xml_escape(name))));
            self.pan_active = true;
            self.pan_clip_pending = true;
            self.pan_clip_id = None;
        }
        self.panel_pannable.push(pan);
    }

    fn end_panel(&mut self) {
        let pan = self.panel_pannable.pop().unwrap_or(false);
        // Close the (inner, if pannable) group into its parent frame.
        if let Some(Some(attrs)) = self.node_open.pop() {
            let inner = self.node_stack.pop().unwrap_or_default();
            self.out().push_str(&format!("<g {attrs}>{inner}</g>"));
        }
        if pan {
            // Close the outer panel group (its attrs may have gained clip-path).
            if let Some(Some(attrs)) = self.node_open.pop() {
                let outer = self.node_stack.pop().unwrap_or_default();
                self.out().push_str(&format!("<g {attrs}>{outer}</g>"));
            }
            self.pan_active = false;
            self.pan_clip_pending = false;
            self.pan_clip_id = None;
        }
    }
}

/// Append `element` to `out` with a `data-key="…"` attribute spliced into its
/// opening tag, right after the tag name (so it lands inside `<tag …>`). Writes
/// directly into the output buffer — no intermediate element/attribute Strings.
/// Used by `SvgBackend::emit` to tag individual elements of a batched primitive.
fn push_data_keyed(out: &mut String, element: &str, key: &str) {
    // The opening tag name runs from the leading `<` to the first space, `/`, or
    // `>`; splice the attribute there.
    let at = element.find([' ', '/', '>']).unwrap_or(element.len());
    out.push_str(&element[..at]);
    out.push_str(" data-key=\"");
    out.push_str(xml_escape(key).as_ref());
    out.push('"');
    out.push_str(&element[at..]);
}

/// Encode a mask raster as an opaque grayscale PNG where each pixel's gray level
/// is its coverage (alpha or luminance), for use as an SVG luminance `<mask>`.
pub(super) fn mask_png(pm: &Pixmap, kind: MaskKind) -> Option<Vec<u8>> {
    let mut out = Pixmap::new(pm.width(), pm.height())?;
    let src = pm.pixels();
    let dst = out.pixels_mut();
    for (s, d) in src.iter().zip(dst.iter_mut()) {
        let cov = mask_coverage(s.demultiply(), kind);
        *d = tiny_skia::ColorU8::from_rgba(cov, cov, cov, 255).premultiply();
    }
    out.encode_png().ok()
}

fn rgb_hex(c: Rgba) -> String {
    format!("#{:02x}{:02x}{:02x}", c.r, c.g, c.b)
}

fn b64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn svg_spread(extend: Extend) -> &'static str {
    match extend {
        Extend::Pad => "pad",
        Extend::Repeat => "repeat",
        Extend::Reflect => "reflect",
    }
}

fn svg_cap(c: LineCap) -> &'static str {
    match c {
        LineCap::Round => "round",
        LineCap::Butt => "butt",
        LineCap::Square => "square",
    }
}

fn svg_join(j: LineJoin) -> &'static str {
    match j {
        LineJoin::Round => "round",
        LineJoin::Mitre => "miter",
        LineJoin::Bevel => "bevel",
    }
}

fn svg_stops(stops: &[Stop]) -> String {
    stops
        .iter()
        .map(|s| {
            format!(
                "<stop offset=\"{}\" stop-color=\"{}\" stop-opacity=\"{}\"/>",
                s.offset,
                rgb_hex(s.color),
                opacity(s.color)
            )
        })
        .collect()
}

pub(super) fn opacity(c: Rgba) -> f32 {
    c.a as f32 / 255.0
}

fn matrix_str(t: Transform) -> String {
    format!(
        "matrix({} {} {} {} {} {})",
        t.sx, t.ky, t.kx, t.sy, t.tx, t.ty
    )
}

fn transform_attr(t: Transform) -> String {
    if t.sx == 1.0 && t.ky == 0.0 && t.kx == 0.0 && t.sy == 1.0 && t.tx == 0.0 && t.ty == 0.0 {
        String::new()
    } else {
        format!(" transform=\"{}\"", matrix_str(t))
    }
}

/// Coordinate precision for geometry already in device px (SVG user units):
/// half a hundredth of a pixel at most, far below what any rasteriser resolves.
const COORD_DECIMALS: u32 = 2;

/// Decimal places for local coordinates drawn under `t`: enough that the
/// rounding error stays at [`COORD_DECIMALS`] once `t` scales it up (a unit
/// circle placed by `matrix(r 0 0 r …)` needs more digits than device px do).
fn coord_decimals(t: Transform) -> u32 {
    let s = (t.sx as f64)
        .hypot(t.ky as f64)
        .max((t.kx as f64).hypot(t.sy as f64));
    if !s.is_finite() || s <= 1.0 {
        return COORD_DECIMALS;
    }
    (COORD_DECIMALS as f64 + s.log10().ceil()).min(9.0) as u32
}

/// Append `v` rounded to `dec` decimal places, with trailing zeros (and a bare
/// `.`) dropped and `-0` written as `0`. Non-finite or huge values fall back to
/// the plain shortest form.
fn push_num(out: &mut String, v: f64, dec: u32) {
    use std::fmt::Write;
    let p = 10u64.pow(dec);
    let m = (v * p as f64).round();
    if !m.is_finite() || m.abs() >= 9.0e15 {
        let _ = write!(out, "{v}");
        return;
    }
    let m = m as i64;
    if m < 0 {
        out.push('-');
    }
    let a = m.unsigned_abs();
    let (ip, mut fp) = (a / p, a % p);
    let _ = write!(out, "{ip}");
    if fp != 0 {
        let mut d = dec as usize;
        while fp % 10 == 0 {
            fp /= 10;
            d -= 1;
        }
        let _ = write!(out, ".{fp:0d$}");
    }
}

/// ` name="a"` for a colour's alpha, or nothing when it is opaque (SVG's
/// default opacity is 1).
fn opacity_attr(name: &str, c: Rgba) -> String {
    if c.a == 255 {
        String::new()
    } else {
        format!(" {name}=\"{}\"", opacity(c))
    }
}

/// The scale factor of `t` when it is a similarity without reflection (uniform
/// scale, rotation, translation), so a stroke drawn under it can be baked into
/// device coordinates with its width scaled by that factor.
fn similarity_scale(t: Transform) -> Option<f64> {
    let (sx, ky, kx, sy) = (t.sx as f64, t.ky as f64, t.kx as f64, t.sy as f64);
    let s = sx.hypot(ky);
    let tol = 1e-6 * s;
    if s > 0.0 && s.is_finite() && (sx - sy).abs() <= tol && (kx + ky).abs() <= tol {
        Some(s)
    } else {
        None
    }
}

/// `(cx, cy, r)` when `path` is exactly the circle tiny-skia's `push_circle`
/// builds: a move to the east point, eight quadratic arcs running clockwise (in
/// y-down device space) through every 45 degrees, and a close. Checking every
/// on- and off-curve point keeps an arbitrary eight-quad path from passing.
fn circle_of(path: &Path) -> Option<(f64, f64, f64)> {
    use tiny_skia::PathSegment;
    let mut segs = path.segments();
    let start = match segs.next()? {
        PathSegment::MoveTo(p) => p,
        _ => return None,
    };
    let mut quads = [(start, start); 8];
    for q in quads.iter_mut() {
        match segs.next()? {
            PathSegment::QuadTo(c, p) => *q = (c, p),
            _ => return None,
        }
    }
    if !matches!(segs.next(), Some(PathSegment::Close)) || segs.next().is_some() {
        return None;
    }
    // The west point (after four arcs) and the east start fix the centre/radius.
    let west = quads[3].1;
    let (cx, cy) = (
        (start.x as f64 + west.x as f64) / 2.0,
        (start.y as f64 + west.y as f64) / 2.0,
    );
    let r = (start.x as f64 - west.x as f64) / 2.0;
    if !r.is_finite() || r <= 0.0 || !cx.is_finite() || !cy.is_finite() {
        return None;
    }
    let tol = r * 1e-4 + 1e-5;
    let near = |p: tiny_skia::Point, ang: f64, rad: f64| {
        (p.x as f64 - (cx + rad * ang.cos())).abs() <= tol
            && (p.y as f64 - (cy + rad * ang.sin())).abs() <= tol
    };
    let step = std::f64::consts::FRAC_PI_4;
    let rc = r / (step / 2.0).cos(); // control points sit on the tangents' crossing
    if !near(start, 0.0, r) {
        return None;
    }
    for (k, (c, p)) in quads.iter().enumerate() {
        let k = k as f64;
        if !near(*c, (k + 0.5) * step, rc) || !near(*p, (k + 1.0) * step, r) {
            return None;
        }
    }
    Some((cx, cy, r))
}

/// Map a local circle to device space when `t` is a similarity (else `None`:
/// a non-uniform scale would make it an ellipse).
fn bake_circle((cx, cy, r): (f64, f64, f64), t: Transform) -> Option<(f64, f64, f64)> {
    let s = similarity_scale(t)?;
    let (sx, ky, kx, sy) = (t.sx as f64, t.ky as f64, t.kx as f64, t.sy as f64);
    Some((
        sx * cx + kx * cy + t.tx as f64,
        ky * cx + sy * cy + t.ty as f64,
        r * s,
    ))
}

/// `cx="…" cy="…" r="…"` in device px.
fn circle_attrs(cx: f64, cy: f64, r: f64) -> String {
    let mut o = String::with_capacity(40);
    o.push_str("cx=\"");
    push_num(&mut o, cx, COORD_DECIMALS);
    o.push_str("\" cy=\"");
    push_num(&mut o, cy, COORD_DECIMALS);
    o.push_str("\" r=\"");
    push_num(&mut o, r, COORD_DECIMALS);
    o.push('"');
    o
}

/// A path's `d`. `map` bakes a transform into the coordinates; `dec` rounds them
/// to that many decimals (`None` keeps the shortest exact `f32` form, which the
/// glyph outlines and clip paths still use).
fn path_to_d(path: &Path, map: Option<Transform>, dec: Option<u32>) -> String {
    use std::fmt::Write;
    use tiny_skia::PathSegment;
    let mut d = String::with_capacity(path.len() * 14);
    let pt = |d: &mut String, p: tiny_skia::Point| {
        let (x, y) = match map {
            Some(t) => {
                let (x, y) = (p.x as f64, p.y as f64);
                (
                    t.sx as f64 * x + t.kx as f64 * y + t.tx as f64,
                    t.ky as f64 * x + t.sy as f64 * y + t.ty as f64,
                )
            }
            None => (p.x as f64, p.y as f64),
        };
        match dec {
            Some(n) => {
                push_num(d, x, n);
                d.push(' ');
                push_num(d, y, n);
            }
            // Unrounded: the shortest exact `f32` form, as before.
            None => {
                let _ = write!(d, "{} {}", x as f32, y as f32);
            }
        }
    };
    // Each non-close segment leaves exactly one trailing space; dropped below.
    for seg in path.segments() {
        match seg {
            PathSegment::MoveTo(p) => {
                d.push('M');
                pt(&mut d, p);
                d.push(' ');
            }
            PathSegment::LineTo(p) => {
                d.push('L');
                pt(&mut d, p);
                d.push(' ');
            }
            PathSegment::QuadTo(c, p) => {
                d.push('Q');
                pt(&mut d, c);
                d.push(' ');
                pt(&mut d, p);
                d.push(' ');
            }
            PathSegment::CubicTo(c1, c2, p) => {
                d.push('C');
                pt(&mut d, c1);
                d.push(' ');
                pt(&mut d, c2);
                d.push(' ');
                pt(&mut d, p);
                d.push(' ');
            }
            PathSegment::Close => d.push('Z'),
        }
    }
    if d.ends_with(' ') {
        d.pop();
    }
    d
}

/// A clip shape as a closed SVG path `d` in device coords (transform baked in).
pub(super) fn clip_shape_d(shape: &ClipShape) -> String {
    match shape {
        ClipShape::Rect { w, h, transform } => {
            let [(x0, y0), (x1, y1), (x2, y2), (x3, y3)] = rect_corners(*w, *h, *transform);
            format!("M{x0} {y0} L{x1} {y1} L{x2} {y2} L{x3} {y3} Z")
        }
        ClipShape::Path {
            path, transform, ..
        } => match path.clone().transform(*transform) {
            Some(p) => path_to_d(&p, None, None),
            None => String::new(),
        },
    }
}

// Escape a string for XML text or a double-quoted attribute value. Shared with
// the scene (`NodeMeta::svg_attrs`, the SVG identity attributes) so the two can't drift.
/// Stands in for the document's id prefix while the document is written. R
/// strings cannot hold NUL, so no user text (labels, keys, metadata) contains it.
pub(crate) const ID_TOKEN: char = '\0';

/// Replace the document-id token in a finished SVG document with its id prefix:
/// `prefix` when given, else `vl` + a hash of the document itself. Rendering the
/// same scene twice therefore gives byte-identical SVG (ids no longer come from
/// a session counter), while different scenes embedded in one HTML page still
/// get distinct ids. The id counters (`c0`, `g1`, ...) restart at 0 in every
/// render.
pub(crate) fn resolve_ids(doc: String, prefix: &str) -> String {
    if !doc.contains(ID_TOKEN) {
        return doc;
    }
    let p = if prefix.is_empty() {
        format!("vl{:08x}", content_hash(doc.as_bytes()))
    } else {
        // Interpolated into `id`/`url(#…)`/`aria-labelledby` values.
        xml_escape(prefix).into_owned()
    };
    doc.replace(ID_TOKEN, &p)
}

/// FNV-1a (64-bit) folded to 32 bits: a stable, platform-independent content
/// hash for the id prefix (not cryptographic).
fn content_hash(bytes: &[u8]) -> u32 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for &b in bytes {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    (h ^ (h >> 32)) as u32
}

pub(crate) fn xml_escape(s: &str) -> Cow<'_, str> {
    // Fast path: the overwhelming majority of keys / ids / labels contain none of
    // the XML metacharacters, so return the input untouched (no allocation).
    if !s.bytes().any(|b| matches!(b, b'&' | b'<' | b'>' | b'"')) {
        return Cow::Borrowed(s);
    }
    let mut out = String::with_capacity(s.len() + 8);
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            _ => out.push(c),
        }
    }
    Cow::Owned(out)
}

// --- PDF backend (krilla) ---------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn num(v: f64, dec: u32) -> String {
        let mut s = String::new();
        push_num(&mut s, v, dec);
        s
    }

    #[test]
    fn push_num_rounds_and_trims() {
        assert_eq!(num(57.530643, 2), "57.53");
        assert_eq!(num(1.0, 2), "1");
        assert_eq!(num(0.5, 2), "0.5");
        assert_eq!(num(0.0049, 2), "0");
        assert_eq!(num(-0.0049, 2), "0");
        assert_eq!(num(-3.456, 2), "-3.46");
        assert_eq!(num(0.04, 2), "0.04");
        assert_eq!(num(12.3, 0), "12");
        assert_eq!(num(f64::NAN, 2), "NaN");
    }

    #[test]
    fn coord_decimals_follow_the_scale() {
        assert_eq!(coord_decimals(Transform::identity()), 2);
        assert_eq!(coord_decimals(Transform::from_translate(5.0, 7.0)), 2);
        assert_eq!(coord_decimals(Transform::from_scale(3.78, 3.78)), 3);
        assert_eq!(coord_decimals(Transform::from_scale(250.0, 1.0)), 5);
    }

    #[test]
    fn circle_of_recognises_push_circle_only() {
        let mut pb = PathBuilder::new();
        pb.push_circle(53.75, 285.9, 3.78);
        let c = circle_of(&pb.finish().unwrap()).unwrap();
        assert!((c.0 - 53.75).abs() < 1e-4 && (c.1 - 285.9).abs() < 1e-4);
        assert!((c.2 - 3.78).abs() < 1e-4);
        // an ellipse, a rect and a polygon are not circles
        let mut pb = PathBuilder::new();
        pb.push_oval(tiny_skia::Rect::from_xywh(0.0, 0.0, 10.0, 6.0).unwrap());
        assert!(circle_of(&pb.finish().unwrap()).is_none());
        let mut pb = PathBuilder::new();
        pb.push_rect(tiny_skia::Rect::from_xywh(0.0, 0.0, 4.0, 4.0).unwrap());
        assert!(circle_of(&pb.finish().unwrap()).is_none());
    }

    #[test]
    fn circles_bake_only_under_similarities() {
        let c = (0.0, 0.0, 1.0);
        let t = Transform::from_row(3.0, 0.0, 0.0, 3.0, 10.0, 20.0);
        assert_eq!(bake_circle(c, t), Some((10.0, 20.0, 3.0)));
        assert!(bake_circle(c, Transform::from_scale(3.0, 2.0)).is_none());
        assert!(bake_circle(c, Transform::from_scale(-1.0, 1.0)).is_none());
    }
}
