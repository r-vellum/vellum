//! The `#[extendr]` surface of `Scene`: construction, the viewport stack, the
//! primitive emitters, rendering entry points and queries, plus the helpers that
//! decode R's FFI scalars into scene types.

use super::*;

/// Build the optional text halo from the R-side `(colour, width_px)` pair.
/// Absent colour or a non-positive width means no halo, so a scene that never
/// asks for one is unchanged.
fn halo_of(col: &Robj, width_px: f64) -> Option<(Rgba, f64)> {
    if !(width_px > 0.0) {
        return None;
    }
    opt_color(col).map(|c| (c, width_px))
}

/// Zip parallel code/offset arrays from R into resolved units, tolerating a
/// short offset vector (absent offsets are 0).
fn units_of(codes: &[i32], offs: &[f64]) -> Vec<Unit> {
    codes
        .iter()
        .enumerate()
        .map(|(i, &c)| Unit::from_code_off(c, offs.get(i).copied().unwrap_or(0.0)))
        .collect()
}

#[extendr]
impl Scene {
    /// Create a scene `width` x `height` inches at `dpi`, with background `bg`
    /// (a length-4 integer RGBA vector). A root viewport covering the whole page
    /// (npc == native) is created as viewport 0.
    fn new(width: f64, height: f64, dpi: f64, bg: Robj) -> Self {
        if !(width.is_finite() && height.is_finite() && dpi.is_finite())
            || width <= 0.0
            || height <= 0.0
            || dpi <= 0.0
        {
            throw_r_error("scene width, height, and dpi must be finite and positive");
        }
        let w_px = px_dim(width * dpi);
        let h_px = px_dim(height * dpi);
        let root = ViewportNode {
            parent: None,
            children: Vec::new(),
            placement: Placement::Absolute {
                cx: 0.5,
                cy: 0.5,
                w: 1.0,
                h: 1.0,
                cxu: Unit::plain(UnitKind::Npc),
                cyu: Unit::plain(UnitKind::Npc),
                wu: Unit::plain(UnitKind::Npc),
                hu: Unit::plain(UnitKind::Npc),
            },
            xscale: (0.0, 1.0),
            yscale: (0.0, 1.0),
            angle: 0.0,
            clip: false,
            clip_path: None,
            gp: PartialGpar::from_robj(&rnull(), &rnull(), &rnull(), &rnull(), &rnull()),
            layout: None,
        };
        Scene {
            w_px,
            h_px,
            dpi,
            bg: opt_color(&bg).unwrap_or(Rgba::WHITE),
            viewports: vec![root],
            current: 0,
            nodes: Vec::new(),
            masks: Vec::new(),
            mask_target: Vec::new(),
            picks: Vec::new(),
            cur_pick: -1,
            meta: Vec::new(),
            cur_meta: NodeMeta::default(),
            raster_cache: RefCell::new(None),
            geom_cache: RefCell::new(None),
            spatial_cache: RefCell::new(None),
            text_glyphs: 0,
            a11y_title: String::new(),
            a11y_desc: String::new(),
            a11y_prefix: String::new(),
        }
    }

    /// Set the scene-level accessible name / description (a11y). Emitted by the
    /// SVG backend (`role="img"` + `<title>`/`<desc>`) and the tagged-PDF path.
    /// `prefix` uniquifies the SVG `<title>`/`<desc>` ids across a page.
    fn set_a11y(&mut self, title: &str, desc: &str, prefix: &str) {
        self.a11y_title = title.to_string();
        self.a11y_desc = desc.to_string();
        self.a11y_prefix = prefix.to_string();
    }

    /// Whether the page backend should enable the glyph-bitmap fast path for this
    /// render: mode 2 (on) always, mode 1 (auto) above the glyph threshold, mode 0
    /// (off) never. Read from the thread-local mode set by R per render.
    pub(super) fn want_bitmap_text(&self) -> bool {
        match crate::font::glyph_bitmap_mode() {
            2 => true,
            1 => self.text_glyphs >= GLYPH_BITMAP_MIN,
            _ => false,
        }
    }

    /// Set the hit-test pick id applied to subsequently-emitted primitives (one
    /// per grob; the R side assigns ids in paint order). See `hit_test`.
    fn set_pick(&mut self, id: i32) {
        self.cur_pick = id;
    }

    /// Set the semantic metadata applied to subsequently-emitted primitives (one
    /// per grob). Empty strings clear a field. Emitted by vector backends.
    fn set_meta(&mut self, id: &str, role: &str, name: &str) {
        self.cur_meta = NodeMeta {
            id: id.to_string(),
            role: role.to_string(),
            name: name.to_string(),
        };
    }

    /// Push a viewport as a child of the current one and make it current.
    /// Returns the new viewport's id. If `lrow`/`lcol` are >= 0 the viewport is
    /// placed into that (0-based) cell of the parent's layout; otherwise it is
    /// placed by centre/size in parent coordinates.
    #[allow(clippy::too_many_arguments)]
    fn push_viewport(
        &mut self,
        cx: f64,
        cy: f64,
        w: f64,
        h: f64,
        cxu: i32,
        cxoff: f64,
        cyu: i32,
        cyoff: f64,
        wu: i32,
        woff: f64,
        hu: i32,
        hoff: f64,
        xscale: &[f64],
        yscale: &[f64],
        angle: f64,
        clip: bool,
        lrow: i32,
        lcol: i32,
        lrowspan: i32,
        lcolspan: i32,
        fill: Robj,
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
    ) -> i32 {
        let placement = if lrow >= 0 && lcol >= 0 {
            // Check the cell against the parent's layout here, on the R thread.
            // Placement is resolved lazily at render time, which for an animation
            // runs on worker threads where raising an R error is not safe.
            match self.viewports[self.current].layout.as_ref() {
                None => throw_r_error(
                    "a viewport placed by row/col must be inside a viewport that has a layout",
                ),
                Some(l) if lrow as usize >= l.heights.len() || lcol as usize >= l.widths.len() => {
                    throw_r_error("layout row/col is out of range for the parent layout's tracks")
                }
                Some(_) => {}
            }
            Placement::Cell {
                row: lrow as usize,
                col: lcol as usize,
                rowspan: lrowspan.max(1) as usize,
                colspan: lcolspan.max(1) as usize,
            }
        } else {
            Placement::Absolute {
                cx,
                cy,
                w,
                h,
                cxu: Unit::from_code_off(cxu, cxoff),
                cyu: Unit::from_code_off(cyu, cyoff),
                wu: Unit::from_code_off(wu, woff),
                hu: Unit::from_code_off(hu, hoff),
            }
        };
        let id = self.viewports.len();
        self.viewports.push(ViewportNode {
            parent: Some(self.current),
            children: Vec::new(),
            placement,
            xscale: pair(xscale, (0.0, 1.0)),
            yscale: pair(yscale, (0.0, 1.0)),
            angle,
            clip,
            clip_path: None,
            gp: PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke),
            layout: None,
        });
        self.viewports[self.current].children.push(id);
        self.current = id;
        id as i32
    }

    /// Attach an arbitrary clip path (in the current viewport's coordinates) to
    /// the current viewport; `nper` gives the point count of each closed sub-path.
    fn set_clip_path(
        &mut self,
        x: &[f64],
        y: &[f64],
        xu: &[i32],
        xoff: &[f64],
        yu: &[i32],
        yoff: &[f64],
        nper: &[i32],
        evenodd: bool,
    ) {
        let spec = ClipPathSpec {
            x: x.to_vec(),
            y: y.to_vec(),
            xu: codes_off(xu, xoff),
            yu: codes_off(yu, yoff),
            nper: nper.iter().map(|&v| v.max(0) as usize).collect(),
            evenodd,
        };
        self.viewports[self.current].clip_path = Some(spec);
    }

    /// Move the cursor up `n` levels (towards the root). Stops at the root.
    fn pop_viewport(&mut self, n: i32) {
        for _ in 0..n.max(0) {
            if let Some(p) = self.viewports[self.current].parent {
                self.current = p;
            }
        }
    }

    /// Move the cursor to the root viewport.
    fn to_root(&mut self) {
        self.current = 0;
    }

    /// Attach a row/column layout to the current viewport. Tracks are given as
    /// parallel value + unit-code vectors; the unit `"null"` marks a flexible
    /// track whose value is its weight. `respect` enables grid-style aspect
    /// locking (equal physical size for a `null` width unit and a `null` height
    /// unit; see `solve_layout`).
    fn set_layout(
        &mut self,
        wvals: &[f64],
        wunits: Vec<String>,
        hvals: &[f64],
        hunits: Vec<String>,
        respect: bool,
    ) {
        let widths = build_tracks(wvals, &wunits);
        let heights = build_tracks(hvals, &hunits);
        self.viewports[self.current].layout = Some(Layout {
            widths,
            heights,
            respect,
        });
    }

    #[allow(clippy::too_many_arguments)]
    fn rect(
        &mut self,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        xu: i32,
        xoff: f64,
        yu: i32,
        yoff: f64,
        wu: i32,
        woff: f64,
        hu: i32,
        hoff: f64,
        fill: Robj,
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
    ) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Rect {
            x,
            y,
            w,
            h,
            xu: Unit::from_code_off(xu, xoff),
            yu: Unit::from_code_off(yu, yoff),
            wu: Unit::from_code_off(wu, woff),
            hu: Unit::from_code_off(hu, hoff),
            gp,
        });
    }

    #[allow(clippy::too_many_arguments)]
    fn roundrect(
        &mut self,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        r: f64,
        xu: i32,
        xoff: f64,
        yu: i32,
        yoff: f64,
        wu: i32,
        woff: f64,
        hu: i32,
        hoff: f64,
        ru: i32,
        roff: f64,
        fill: Robj,
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
        sroughness: f64,
        sbowing: f64,
        sfill_style: i32,
        sfill_weight: f64,
        shachure_angle: f64,
        shachure_gap: f64,
        scurve_tightness: f64,
        sdisable_multi: bool,
        spreserve: bool,
        sseed: f64,
        key: String,
    ) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        let sketch = sketch_from(
            sroughness,
            sbowing,
            sfill_style,
            sfill_weight,
            shachure_angle,
            shachure_gap,
            scurve_tightness,
            sdisable_multi,
            spreserve,
            sseed,
        );
        self.emit_node(Node::RoundRect {
            x,
            y,
            w,
            h,
            r,
            xu: Unit::from_code_off(xu, xoff),
            yu: Unit::from_code_off(yu, yoff),
            wu: Unit::from_code_off(wu, woff),
            hu: Unit::from_code_off(hu, hoff),
            ru: Unit::from_code_off(ru, roff),
            sketch,
            key: opt_key(key),
            gp,
        });
    }

    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_arguments)]
    fn lines(
        &mut self,
        x: &[f64],
        y: &[f64],
        xu: &[i32],
        xoff: &[f64],
        yu: &[i32],
        yoff: &[f64],
        scap: &[f64],
        ecap: &[f64],
        scapu: &[i32],
        ecapu: &[i32],
        off: &[f64],
        offu: &[i32],
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
        aangle: f64,
        alen: f64,
        aends: i32,
        aclosed: bool,
        sroughness: f64,
        sbowing: f64,
        sfill_style: i32,
        sfill_weight: f64,
        shachure_angle: f64,
        shachure_gap: f64,
        scurve_tightness: f64,
        sdisable_multi: bool,
        spreserve: bool,
        sseed: f64,
        hw: &[f64],
        key: String,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &lwd, &alpha, &stroke);
        let sketch = sketch_from(
            sroughness,
            sbowing,
            sfill_style,
            sfill_weight,
            shachure_angle,
            shachure_gap,
            scurve_tightness,
            sdisable_multi,
            spreserve,
            sseed,
        );
        // An empty `hw` is the "no profile" sentinel, so a scene that never asks
        // for a variable width encodes and renders exactly as it did before.
        let hw = if hw.is_empty() {
            None
        } else {
            Some(hw.to_vec())
        };
        self.emit_node(Node::Lines {
            x: x.to_vec(),
            y: y.to_vec(),
            xu: codes_off(xu, xoff),
            yu: codes_off(yu, yoff),
            scap: cap_scalar(scap, scapu),
            ecap: cap_scalar(ecap, ecapu),
            off: cap_scalar(off, offu),
            arrow: arrow_from(aangle, alen, aends, aclosed),
            sketch,
            hw,
            gp,
            key: opt_key(key),
        });
    }

    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_arguments)]
    fn polygon(
        &mut self,
        x: &[f64],
        y: &[f64],
        xu: &[i32],
        xoff: &[f64],
        yu: &[i32],
        yoff: &[f64],
        fill: Robj,
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
        sroughness: f64,
        sbowing: f64,
        sfill_style: i32,
        sfill_weight: f64,
        shachure_angle: f64,
        shachure_gap: f64,
        scurve_tightness: f64,
        sdisable_multi: bool,
        spreserve: bool,
        sseed: f64,
        key: String,
    ) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        let sketch = sketch_from(
            sroughness,
            sbowing,
            sfill_style,
            sfill_weight,
            shachure_angle,
            shachure_gap,
            scurve_tightness,
            sdisable_multi,
            spreserve,
            sseed,
        );
        self.emit_node(Node::Polygon {
            x: x.to_vec(),
            y: y.to_vec(),
            xu: codes_off(xu, xoff),
            yu: codes_off(yu, yoff),
            sketch,
            gp,
            key: opt_key(key),
        });
    }

    #[allow(clippy::too_many_arguments)]
    fn circle(
        &mut self,
        x: f64,
        y: f64,
        r: f64,
        xu: i32,
        xoff: f64,
        yu: i32,
        yoff: f64,
        ru: i32,
        roff: f64,
        fill: Robj,
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
    ) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Circle {
            x,
            y,
            r,
            xu: Unit::from_code_off(xu, xoff),
            yu: Unit::from_code_off(yu, yoff),
            ru: Unit::from_code_off(ru, roff),
            sketch: None,
            gp,
        });
    }

    /// A whole batch of rectangles in one call, sharing one gpar. Coordinates and
    /// per-coordinate unit codes are parallel slices.
    #[allow(clippy::too_many_arguments)]
    fn rects(
        &mut self,
        x: &[f64],
        y: &[f64],
        w: &[f64],
        h: &[f64],
        xu: &[i32],
        xoff: &[f64],
        yu: &[i32],
        yoff: &[f64],
        wu: &[i32],
        woff: &[f64],
        hu: &[i32],
        hoff: &[f64],
        fill: Robj,
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
        sroughness: f64,
        sbowing: f64,
        sfill_style: i32,
        sfill_weight: f64,
        shachure_angle: f64,
        shachure_gap: f64,
        scurve_tightness: f64,
        sdisable_multi: bool,
        spreserve: bool,
        sseed: f64,
        keys: Vec<String>,
    ) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        let sketch = sketch_from(
            sroughness,
            sbowing,
            sfill_style,
            sfill_weight,
            shachure_angle,
            shachure_gap,
            scurve_tightness,
            sdisable_multi,
            spreserve,
            sseed,
        );
        self.emit_node(Node::Rects {
            x: x.to_vec(),
            y: y.to_vec(),
            w: w.to_vec(),
            h: h.to_vec(),
            xu: codes_off(xu, xoff),
            yu: codes_off(yu, yoff),
            wu: codes_off(wu, woff),
            hu: codes_off(hu, hoff),
            sketch,
            gp,
            keys,
        });
    }

    /// A whole batch of circles in one call, sharing one gpar (also used for
    /// `points`, with the radius carrying the marker size).
    #[allow(clippy::too_many_arguments)]
    fn circles(
        &mut self,
        x: &[f64],
        y: &[f64],
        r: &[f64],
        xu: &[i32],
        xoff: &[f64],
        yu: &[i32],
        yoff: &[f64],
        ru: &[i32],
        roff: &[f64],
        fill: Robj,
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
        sroughness: f64,
        sbowing: f64,
        sfill_style: i32,
        sfill_weight: f64,
        shachure_angle: f64,
        shachure_gap: f64,
        scurve_tightness: f64,
        sdisable_multi: bool,
        spreserve: bool,
        sseed: f64,
        keys: Vec<String>,
    ) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        let sketch = sketch_from(
            sroughness,
            sbowing,
            sfill_style,
            sfill_weight,
            shachure_angle,
            shachure_gap,
            scurve_tightness,
            sdisable_multi,
            spreserve,
            sseed,
        );
        self.emit_node(Node::Circles {
            x: x.to_vec(),
            y: y.to_vec(),
            r: r.to_vec(),
            xu: codes_off(xu, xoff),
            yu: codes_off(yu, yoff),
            ru: codes_off(ru, roff),
            sketch,
            gp,
            keys,
        });
    }

    /// A batch of markers (point glyphs) sharing one gpar. Like `circles` but each
    /// element carries a `shape` code (0 circle, 1 square, 2 triangle, 3 diamond,
    /// 4 plus, 5 cross, 6 triangle_down, 7 star); `size` is the marker radius.
    /// Filled shapes fill+stroke per gpar; plus/cross are stroke-only. (circle_grob
    /// / default points use the faster `circles` path; this is for shape variety.)
    #[allow(clippy::too_many_arguments)]
    fn markers(
        &mut self,
        x: &[f64],
        y: &[f64],
        size: &[f64],
        xu: &[i32],
        xoff: &[f64],
        yu: &[i32],
        yoff: &[f64],
        su: &[i32],
        soff: &[f64],
        shape: &[i32],
        fill: Robj,
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
        sroughness: f64,
        sbowing: f64,
        sfill_style: i32,
        sfill_weight: f64,
        shachure_angle: f64,
        shachure_gap: f64,
        scurve_tightness: f64,
        sdisable_multi: bool,
        spreserve: bool,
        sseed: f64,
        keys: Vec<String>,
    ) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        let sketch = sketch_from(
            sroughness,
            sbowing,
            sfill_style,
            sfill_weight,
            shachure_angle,
            shachure_gap,
            scurve_tightness,
            sdisable_multi,
            spreserve,
            sseed,
        );
        self.emit_node(Node::Markers {
            x: x.to_vec(),
            y: y.to_vec(),
            size: size.to_vec(),
            xu: codes_off(xu, xoff),
            yu: codes_off(yu, yoff),
            su: codes_off(su, soff),
            shape: shape.iter().map(|&v| v.max(0) as u32).collect(),
            sketch,
            gp,
            keys,
        });
    }

    /// A batch of hexagons for hex-binning. `flat` picks flat-top vs pointy-top;
    /// `fill` is a flat per-hex RGBA stream (`[r,g,b,a, r,g,b,a, ...]`, one quad per
    /// hex); `col`/`lwd`/`alpha`/`stroke` give the *uniform* stroke (the gpar's fill
    /// is unused — fill is per element). Geometry: if `w`/`h` are empty each hex is
    /// regular with circumradius `size`; otherwise `w`/`h` are the per-hex full
    /// width/height (corner-to-corner along each axis), resolved per-axis so a hex
    /// can tile a non-square lattice, and `size` is ignored.
    #[allow(clippy::too_many_arguments)]
    fn hexagons(
        &mut self,
        x: &[f64],
        y: &[f64],
        size: &[f64],
        w: &[f64],
        h: &[f64],
        xu: &[i32],
        xoff: &[f64],
        yu: &[i32],
        yoff: &[f64],
        su: &[i32],
        soff: &[f64],
        wu: &[i32],
        woff: &[f64],
        hu: &[i32],
        hoff: &[f64],
        fill: &[i32],
        flat: bool,
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
        gfill: Robj,
        keys: Vec<String>,
    ) {
        let gp = PartialGpar::from_robj(&gfill, &col, &lwd, &alpha, &stroke);
        let fill = fill
            .chunks_exact(4)
            .map(|c| Rgba {
                r: c[0].clamp(0, 255) as u8,
                g: c[1].clamp(0, 255) as u8,
                b: c[2].clamp(0, 255) as u8,
                a: c[3].clamp(0, 255) as u8,
            })
            .collect();
        self.emit_node(Node::Hexagons {
            x: x.to_vec(),
            y: y.to_vec(),
            size: size.to_vec(),
            w: w.to_vec(),
            h: h.to_vec(),
            xu: codes_off(xu, xoff),
            yu: codes_off(yu, yoff),
            su: codes_off(su, soff),
            wu: codes_off(wu, woff),
            hu: codes_off(hu, hoff),
            fill,
            flat,
            gp,
            keys,
        });
    }

    /// A batch of annular sectors (pie/donut/rose wedges). `(x,y)` is the centre,
    /// `r0`/`r1` the inner/outer radius, `theta0`/`theta1` the start/end angle in
    /// **radians** (0 at 3 o'clock, CCW). `fill` is a flat per-sector RGBA stream
    /// (one quad per sector, like `hexagons`); `col`/`lwd`/`alpha`/`stroke` give the
    /// uniform stroke. `r0=0` ⇒ pie slice; `r0=r1` ⇒ an arc outline (no fill).
    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_arguments)]
    fn sectors(
        &mut self,
        x: &[f64],
        y: &[f64],
        r0: &[f64],
        r1: &[f64],
        theta0: &[f64],
        theta1: &[f64],
        xu: &[i32],
        xoff: &[f64],
        yu: &[i32],
        yoff: &[f64],
        r0u: &[i32],
        r0off: &[f64],
        r1u: &[i32],
        r1off: &[f64],
        fill: &[i32],
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
        aangle: f64,
        alen: f64,
        aends: i32,
        aclosed: bool,
        sroughness: f64,
        sbowing: f64,
        sfill_style: i32,
        sfill_weight: f64,
        shachure_angle: f64,
        shachure_gap: f64,
        scurve_tightness: f64,
        sdisable_multi: bool,
        spreserve: bool,
        sseed: f64,
        gfill: Robj,
        keys: Vec<String>,
    ) {
        let gp = PartialGpar::from_robj(&gfill, &col, &lwd, &alpha, &stroke);
        let fill = fill
            .chunks_exact(4)
            .map(|c| Rgba {
                r: c[0].clamp(0, 255) as u8,
                g: c[1].clamp(0, 255) as u8,
                b: c[2].clamp(0, 255) as u8,
                a: c[3].clamp(0, 255) as u8,
            })
            .collect();
        let sketch = sketch_from(
            sroughness,
            sbowing,
            sfill_style,
            sfill_weight,
            shachure_angle,
            shachure_gap,
            scurve_tightness,
            sdisable_multi,
            spreserve,
            sseed,
        );
        self.emit_node(Node::Sectors {
            x: x.to_vec(),
            y: y.to_vec(),
            r0: r0.to_vec(),
            r1: r1.to_vec(),
            theta0: theta0.to_vec(),
            theta1: theta1.to_vec(),
            xu: codes_off(xu, xoff),
            yu: codes_off(yu, yoff),
            r0u: codes_off(r0u, r0off),
            r1u: codes_off(r1u, r1off),
            fill,
            arrow: arrow_from(aangle, alen, aends, aclosed),
            sketch,
            gp,
            keys,
        });
    }

    /// A batch of disjoint line segments (stroke only), sharing one gpar.
    #[allow(clippy::too_many_arguments)]
    fn segments(
        &mut self,
        x0: &[f64],
        y0: &[f64],
        x1: &[f64],
        y1: &[f64],
        x0u: &[i32],
        x0off: &[f64],
        y0u: &[i32],
        y0off: &[f64],
        x1u: &[i32],
        x1off: &[f64],
        y1u: &[i32],
        y1off: &[f64],
        scap: &[f64],
        ecap: &[f64],
        scapu: &[i32],
        ecapu: &[i32],
        off: &[f64],
        offu: &[i32],
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
        aangle: f64,
        alen: f64,
        aends: i32,
        aclosed: bool,
        sroughness: f64,
        sbowing: f64,
        sfill_style: i32,
        sfill_weight: f64,
        shachure_angle: f64,
        shachure_gap: f64,
        scurve_tightness: f64,
        sdisable_multi: bool,
        spreserve: bool,
        sseed: f64,
        ecols: &[i32],
        elwds: &[f64],
        keys: Vec<String>,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &lwd, &alpha, &stroke);
        let sketch = sketch_from(
            sroughness,
            sbowing,
            sfill_style,
            sfill_weight,
            shachure_angle,
            shachure_gap,
            scurve_tightness,
            sdisable_multi,
            spreserve,
            sseed,
        );
        self.emit_node(Node::Segments {
            x0: x0.to_vec(),
            y0: y0.to_vec(),
            x1: x1.to_vec(),
            y1: y1.to_vec(),
            x0u: codes_off(x0u, x0off),
            y0u: codes_off(y0u, y0off),
            x1u: codes_off(x1u, x1off),
            y1u: codes_off(y1u, y1off),
            scap: scap.to_vec(),
            ecap: ecap.to_vec(),
            scapu: codes(scapu),
            ecapu: codes(ecapu),
            off: off.to_vec(),
            offu: codes(offu),
            arrow: arrow_from(aangle, alen, aends, aclosed),
            sketch,
            gp,
            keys,
            cols: ecols
                .chunks_exact(4)
                .map(|c| Rgba {
                    r: c[0].clamp(0, 255) as u8,
                    g: c[1].clamp(0, 255) as u8,
                    b: c[2].clamp(0, 255) as u8,
                    a: c[3].clamp(0, 255) as u8,
                })
                .collect(),
            lwds: elwds.to_vec(),
        });
    }

    /// A batch of self-loops (cubic-Bézier teardrops). See `Node::Loop`.
    #[allow(clippy::too_many_arguments)]
    fn add_loop(
        &mut self,
        x: &[f64],
        y: &[f64],
        size: &[f64],
        foot: &[f64],
        angle: &[f64],
        width: &[f64],
        xu: &[i32],
        xoff: &[f64],
        yu: &[i32],
        yoff: &[f64],
        su: &[i32],
        soff: &[f64],
        fu: &[i32],
        foff: &[f64],
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
        aangle: f64,
        alen: f64,
        aends: i32,
        aclosed: bool,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &lwd, &alpha, &stroke);
        self.emit_node(Node::Loop {
            x: x.to_vec(),
            y: y.to_vec(),
            xu: codes_off(xu, xoff),
            yu: codes_off(yu, yoff),
            size: size.to_vec(),
            su: codes_off(su, soff),
            foot: foot.to_vec(),
            fu: codes_off(fu, foff),
            angle: angle.to_vec(),
            width: width.to_vec(),
            arrow: arrow_from(aangle, alen, aends, aclosed),
            gp,
        });
    }

    /// A general path. `nper` gives the number of points in each closed sub-path
    /// (so holes are sub-paths under the even-odd or winding rule).
    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_arguments)]
    fn path(
        &mut self,
        x: &[f64],
        y: &[f64],
        xu: &[i32],
        xoff: &[f64],
        yu: &[i32],
        yoff: &[f64],
        nper: &[i32],
        evenodd: bool,
        fill: Robj,
        col: Robj,
        lwd: Robj,
        alpha: Robj,
        stroke: Robj,
        sroughness: f64,
        sbowing: f64,
        sfill_style: i32,
        sfill_weight: f64,
        shachure_angle: f64,
        shachure_gap: f64,
        scurve_tightness: f64,
        sdisable_multi: bool,
        spreserve: bool,
        sseed: f64,
        key: String,
    ) {
        let gp = PartialGpar::from_robj(&fill, &col, &lwd, &alpha, &stroke);
        let sketch = sketch_from(
            sroughness,
            sbowing,
            sfill_style,
            sfill_weight,
            shachure_angle,
            shachure_gap,
            scurve_tightness,
            sdisable_multi,
            spreserve,
            sseed,
        );
        self.emit_node(Node::Path {
            x: x.to_vec(),
            y: y.to_vec(),
            xu: codes_off(xu, xoff),
            yu: codes_off(yu, yoff),
            nper: nper.iter().map(|&v| v.max(0) as usize).collect(),
            evenodd,
            sketch,
            gp,
            key: opt_key(key),
        });
    }

    /// A raster image: `rgba` is a flat straight-RGBA integer vector (`iw` x `ih`,
    /// top-left, 4 per pixel), drawn into a `w` x `h` cell centred at `(x, y)`.
    #[allow(clippy::too_many_arguments)]
    fn image(
        &mut self,
        rgba: &[i32],
        iw: i32,
        ih: i32,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        xu: i32,
        xoff: f64,
        yu: i32,
        yoff: f64,
        wu: i32,
        woff: f64,
        hu: i32,
        hoff: f64,
        interpolate: bool,
    ) {
        let bytes: Vec<u8> = rgba.iter().map(|&v| v.clamp(0, 255) as u8).collect();
        self.emit_node(Node::Image {
            rgba: bytes,
            iw: iw.max(0) as u32,
            ih: ih.max(0) as u32,
            x,
            y,
            w,
            h,
            xu: Unit::from_code_off(xu, xoff),
            yu: Unit::from_code_off(yu, yoff),
            wu: Unit::from_code_off(wu, woff),
            hu: Unit::from_code_off(hu, hoff),
            interpolate,
        });
    }

    /// Add pre-shaped text. The R wrapper does shaping (via `textshaping`) and
    /// passes per-glyph ids/positions/fonts plus the block size.
    #[allow(clippy::too_many_arguments)]
    fn text(
        &mut self,
        x: f64,
        y: f64,
        xu: i32,
        xoff: f64,
        yu: i32,
        yoff: f64,
        rot: f64,
        hjust: f64,
        vjust: f64,
        w: f64,
        h: f64,
        gid: &[i32],
        gx: &[f64],
        gy: &[f64],
        gsize: &[f64],
        gpath: Vec<String>,
        gface: &[i32],
        label: &str,
        family: &str,
        face: &str,
        size: f64,
        col: Robj,
        alpha: Robj,
        halo_col: Robj,
        halo_width: f64,
        key: String,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &rnull(), &alpha, &rnull());
        let halo = halo_of(&halo_col, halo_width);
        self.emit_node(Node::Text {
            x,
            y,
            xu: Unit::from_code_off(xu, xoff),
            yu: Unit::from_code_off(yu, yoff),
            rot,
            hjust,
            vjust,
            w,
            h,
            gid: gid.iter().map(|&v| v.max(0) as u32).collect(),
            gx: gx.to_vec(),
            gy: gy.to_vec(),
            gsize: gsize.to_vec(),
            gpath,
            gface: gface.iter().map(|&v| v.max(0) as u32).collect(),
            gcol: Vec::new(),
            halo,
            label: label.to_string(),
            family: family.to_string(),
            face: face.to_string(),
            size,
            tpath: None,
            key: opt_key(key),
            gp,
        });
    }

    /// Add one pre-shaped label set along a polyline baseline. Identical to
    /// `text()` except that the anchor is the path rather than a point: `hjust`
    /// slides the run along it (0 = start, 1 = end) and `vjust` still positions
    /// the line box against the baseline.
    #[allow(clippy::too_many_arguments)]
    fn text_path(
        &mut self,
        px: &[f64],
        py: &[f64],
        pxu: &[i32],
        pxoff: &[f64],
        pyu: &[i32],
        pyoff: &[f64],
        offset: f64,
        hjust: f64,
        vjust: f64,
        w: f64,
        h: f64,
        gid: &[i32],
        gx: &[f64],
        gy: &[f64],
        gsize: &[f64],
        gpath: Vec<String>,
        gface: &[i32],
        label: &str,
        family: &str,
        face: &str,
        size: f64,
        col: Robj,
        alpha: Robj,
        halo_col: Robj,
        halo_width: f64,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &rnull(), &alpha, &rnull());
        let halo = halo_of(&halo_col, halo_width);
        self.emit_node(Node::Text {
            // The anchor is unused when `tpath` is set, but keep it meaningful so
            // bbox/lint queries on this node still land somewhere sensible.
            x: px.first().copied().unwrap_or(0.5),
            y: py.first().copied().unwrap_or(0.5),
            xu: units_of(pxu, pxoff)
                .first()
                .copied()
                .unwrap_or(Unit::from_code_off(0, 0.0)),
            yu: units_of(pyu, pyoff)
                .first()
                .copied()
                .unwrap_or(Unit::from_code_off(0, 0.0)),
            rot: 0.0,
            hjust,
            vjust,
            w,
            h,
            gid: gid.iter().map(|&v| v.max(0) as u32).collect(),
            gx: gx.to_vec(),
            gy: gy.to_vec(),
            gsize: gsize.to_vec(),
            gpath,
            gface: gface.iter().map(|&v| v.max(0) as u32).collect(),
            gcol: Vec::new(),
            halo,
            label: label.to_string(),
            family: family.to_string(),
            face: face.to_string(),
            size,
            key: None,
            tpath: Some(TextPath {
                px: px.to_vec(),
                py: py.to_vec(),
                pxu: units_of(pxu, pxoff),
                pyu: units_of(pyu, pyoff),
                offset,
            }),
            gp,
        });
    }

    /// Add a whole batch of pre-shaped text labels in one call (one shaping pass
    /// on the R side, one FFI here). Glyphs are flat across all labels, split by
    /// `nper` (glyph count per label); positions/sizes/rot/labels are per-label;
    /// font + just + colour are shared.
    #[allow(clippy::too_many_arguments)]
    fn texts(
        &mut self,
        x: &[f64],
        y: &[f64],
        xu: &[i32],
        xoff: &[f64],
        yu: &[i32],
        yoff: &[f64],
        rot: &[f64],
        hjust: f64,
        vjust: f64,
        w: &[f64],
        h: &[f64],
        nper: &[i32],
        gid: &[i32],
        gx: &[f64],
        gy: &[f64],
        gsize: &[f64],
        gpath: Vec<String>,
        gface: &[i32],
        label: Vec<String>,
        family: &str,
        face: &str,
        size: f64,
        col: Robj,
        alpha: Robj,
        halo_col: Robj,
        halo_width: f64,
        keys: Vec<String>,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &rnull(), &alpha, &rnull());
        let halo = halo_of(&halo_col, halo_width);
        let nlab = [
            x.len(),
            y.len(),
            xu.len(),
            yu.len(),
            rot.len(),
            w.len(),
            h.len(),
            nper.len(),
            label.len(),
        ]
        .into_iter()
        .min()
        .unwrap_or(0);
        // All glyph arrays are parallel; clamp the per-label slice to the shortest
        // so a (mis-sized, direct-FFI) call can't panic on an out-of-range slice.
        let gmax = [
            gid.len(),
            gx.len(),
            gy.len(),
            gsize.len(),
            gpath.len(),
            gface.len(),
        ]
        .into_iter()
        .min()
        .unwrap_or(0);
        let mut off = 0usize;
        for i in 0..nlab {
            let cnt = nper[i].max(0) as usize;
            let lo = off.min(gmax);
            let hi = (off + cnt).min(gmax);
            off = hi;
            self.text_glyphs += hi - lo; // drives the glyph-bitmap threshold
            self.emit_node(Node::Text {
                x: x[i],
                y: y[i],
                xu: Unit::from_code_off(xu[i], xoff.get(i).copied().unwrap_or(0.0)),
                yu: Unit::from_code_off(yu[i], yoff.get(i).copied().unwrap_or(0.0)),
                rot: rot[i],
                hjust,
                vjust,
                w: w[i],
                h: h[i],
                gid: gid[lo..hi].iter().map(|&v| v.max(0) as u32).collect(),
                gx: gx[lo..hi].to_vec(),
                gy: gy[lo..hi].to_vec(),
                gsize: gsize[lo..hi].to_vec(),
                gpath: gpath[lo..hi].to_vec(),
                gface: gface[lo..hi].iter().map(|&v| v.max(0) as u32).collect(),
                gcol: Vec::new(),
                halo,
                label: label[i].clone(),
                family: family.to_string(),
                face: face.to_string(),
                size,
                tpath: None,
                key: key_at(&keys, i).map(str::to_string),
                gp: gp.clone(),
            });
        }
    }

    /// Like `texts`, but with a **per-glyph** fill colour stream (`gcol`, a flat RGBA
    /// int stream, 4 ints per glyph, parallel to the glyph arrays). Used by rich
    /// (multi-run) labels where colour varies within a single label. Everything else
    /// matches `texts`; the shared `col` becomes the fallback only when a glyph's
    /// colour is absent (it never is here, but keeps the gpar resolve consistent).
    #[allow(clippy::too_many_arguments)]
    fn texts_rich(
        &mut self,
        x: &[f64],
        y: &[f64],
        xu: &[i32],
        xoff: &[f64],
        yu: &[i32],
        yoff: &[f64],
        rot: &[f64],
        hjust: f64,
        vjust: f64,
        w: &[f64],
        h: &[f64],
        nper: &[i32],
        gid: &[i32],
        gx: &[f64],
        gy: &[f64],
        gsize: &[f64],
        gpath: Vec<String>,
        gface: &[i32],
        gcol: &[i32],
        label: Vec<String>,
        family: &str,
        face: &str,
        size: f64,
        col: Robj,
        alpha: Robj,
        halo_col: Robj,
        halo_width: f64,
        keys: Vec<String>,
    ) {
        let gp = PartialGpar::from_robj(&rnull(), &col, &rnull(), &alpha, &rnull());
        let halo = halo_of(&halo_col, halo_width);
        let nlab = [
            x.len(),
            y.len(),
            xu.len(),
            yu.len(),
            rot.len(),
            w.len(),
            h.len(),
            nper.len(),
            label.len(),
        ]
        .into_iter()
        .min()
        .unwrap_or(0);
        let gmax = [
            gid.len(),
            gx.len(),
            gy.len(),
            gsize.len(),
            gpath.len(),
            gface.len(),
            gcol.len() / 4,
        ]
        .into_iter()
        .min()
        .unwrap_or(0);
        let mut off = 0usize;
        for i in 0..nlab {
            let cnt = nper[i].max(0) as usize;
            let lo = off.min(gmax);
            let hi = (off + cnt).min(gmax);
            off = hi;
            self.text_glyphs += hi - lo; // drives the glyph-bitmap threshold
            self.emit_node(Node::Text {
                x: x[i],
                y: y[i],
                xu: Unit::from_code_off(xu[i], xoff.get(i).copied().unwrap_or(0.0)),
                yu: Unit::from_code_off(yu[i], yoff.get(i).copied().unwrap_or(0.0)),
                rot: rot[i],
                hjust,
                vjust,
                w: w[i],
                h: h[i],
                gid: gid[lo..hi].iter().map(|&v| v.max(0) as u32).collect(),
                gx: gx[lo..hi].to_vec(),
                gy: gy[lo..hi].to_vec(),
                gsize: gsize[lo..hi].to_vec(),
                gpath: gpath[lo..hi].to_vec(),
                gface: gface[lo..hi].iter().map(|&v| v.max(0) as u32).collect(),
                gcol: gcol[lo * 4..hi * 4]
                    .chunks_exact(4)
                    .map(|c| Rgba {
                        r: c[0].clamp(0, 255) as u8,
                        g: c[1].clamp(0, 255) as u8,
                        b: c[2].clamp(0, 255) as u8,
                        a: c[3].clamp(0, 255) as u8,
                    })
                    .collect(),
                halo,
                label: label[i].clone(),
                family: family.to_string(),
                face: face.to_string(),
                size,
                tpath: None,
                key: key_at(&keys, i).map(str::to_string),
                gp: gp.clone(),
            });
        }
    }

    /// Begin collecting a mask's content for the current viewport. Until the
    /// matching `mask_end`, primitives are routed into the mask instead of the
    /// drawn scene. `kind` is 0 (alpha) or 1 (luminance). Returns its index.
    fn mask_begin(&mut self, kind: i32) -> i32 {
        let idx = self.masks.len();
        self.masks.push(MaskDef {
            kind: MaskKind::from_code(kind),
            nodes: Vec::new(),
        });
        self.mask_target.push(idx);
        idx as i32
    }

    /// Stop routing primitives into the most recent mask.
    fn mask_end(&mut self) {
        self.mask_target.pop();
    }

    /// Open an isolated compositing group, modulated by mask index `mask`
    /// (negative = no mask, just isolation), group opacity `alpha`, and blend mode
    /// `blend` (a code; 0 = normal). Routed through `emit_node` so a group nested
    /// inside a mask (a mask grob that itself masks a viewport) lands in the same
    /// node list as its content, keeping markers and content in sync.
    ///
    /// `blur` is a Gaussian radius in device px (0 = none). `shadow` is
    /// `c(dx, dy, blur, r, g, b, a)` in device px / 0-255, or empty for none.
    fn group_start(&mut self, mask: i32, alpha: f64, blend: i32, blur: f64, shadow: &[f64]) {
        let mask = if mask >= 0 { Some(mask as usize) } else { None };
        let shadow = if shadow.len() >= 7 {
            Some(Shadow {
                dx: shadow[0] as f32,
                dy: shadow[1] as f32,
                blur: shadow[2].max(0.0) as f32,
                col: Rgba {
                    r: shadow[3].clamp(0.0, 255.0) as u8,
                    g: shadow[4].clamp(0.0, 255.0) as u8,
                    b: shadow[5].clamp(0.0, 255.0) as u8,
                    a: shadow[6].clamp(0.0, 255.0) as u8,
                },
            })
        } else {
            None
        };
        self.emit_node(Node::GroupStart {
            mask,
            alpha: alpha.clamp(0.0, 1.0) as f32,
            blend: BlendKind::from_code(blend),
            effect: GroupEffect {
                blur: if blur > 0.0 { Some(blur as f32) } else { None },
                shadow,
            },
        });
    }

    /// Close the most recently opened group.
    fn group_end(&mut self) {
        self.emit_node(Node::GroupEnd);
    }

    /// Open a named panel group around the following nodes (paired with
    /// `end_panel`). The SVG backend wraps them in `<g data-vellum-panel="name">`;
    /// other backends ignore it. Emitted by the R compiler for named viewports.
    fn begin_panel(&mut self, name: String, pannable: bool) {
        self.emit_node(Node::PanelStart { name, pannable });
    }

    /// Close the most recently opened panel group.
    fn end_panel(&mut self) {
        self.emit_node(Node::PanelEnd);
    }

    /// Open a repaint boundary for the current subtree, tagged with content id
    /// `nid` (a per-subtree token from R). See `Node::SubrasterStart`.
    fn subraster_start(&mut self, nid: f64) {
        self.emit_node(Node::SubrasterStart { nid });
    }

    /// Close the most recently opened repaint boundary.
    fn subraster_end(&mut self) {
        self.emit_node(Node::SubrasterEnd);
    }

    /// Number of primitives currently in the scene.
    fn len(&self) -> i32 {
        self.nodes.len() as i32
    }

    /// Device dimensions in pixels, `c(width, height)`.
    fn dim(&self) -> Vec<i32> {
        vec![self.w_px as i32, self.h_px as i32]
    }

    /// Device resolution in dots per inch.
    fn dpi(&self) -> f64 {
        self.dpi
    }

    /// Render the scene to a PNG file. Returns any degradation warnings (none for
    /// the raster backend today; uniform with the SVG/PDF signatures).
    fn render_png(&self, path: &str) -> Vec<String> {
        // Reuse the memoised pixmap when present (a repeat render of a cached
        // Scene); otherwise rasterise — capturing degradation warnings — and fill
        // the memo. On a hit the warnings were already surfaced by the cold call.
        if self.raster_cache.borrow().is_some() {
            let out = self.output_pixmap();
            if let Err(e) = out.save_png(path) {
                throw_r_error(format!("failed to write PNG: {e}"));
            }
            return Vec::new();
        }
        check_raster_area(self.w_px, self.h_px);
        let mut b = RasterBackend::new(self.w_px, self.h_px, self.bg);
        b.set_bitmap_text(self.want_bitmap_text());
        let warnings = self.render_to(&mut b);
        let pm = b.into_pixmap();
        // Cache the clean raster, write the (possibly simulated) one.
        let out = self.simulate(pm.clone());
        if let Err(e) = out.save_png(path) {
            throw_r_error(format!("failed to write PNG: {e}"));
        }
        *self.raster_cache.borrow_mut() = Some(pm);
        warnings
    }

    /// Render the scene and return the PNG bytes rather than writing a file.
    /// `list(bytes = <raw>, warnings = <character>)` -- warnings are returned
    /// rather than dropped so the caller can surface them exactly as `render()`
    /// does. Shares the memoised pixmap with `render_png`.
    fn render_png_raw(&self) -> List {
        let (pm, warnings) = if self.raster_cache.borrow().is_some() {
            (
                self.raster_cache.borrow().as_ref().unwrap().clone(),
                Vec::new(),
            )
        } else {
            check_raster_area(self.w_px, self.h_px);
            let mut b = RasterBackend::new(self.w_px, self.h_px, self.bg);
            b.set_bitmap_text(self.want_bitmap_text());
            let warnings = self.render_to(&mut b);
            let pm = b.into_pixmap();
            *self.raster_cache.borrow_mut() = Some(pm.clone());
            (pm, warnings)
        };
        let pm = self.simulate(pm);
        let bytes = match pm.encode_png() {
            Ok(b) => b,
            Err(e) => throw_r_error(format!("failed to encode PNG: {e}")),
        };
        list!(bytes = Raw::from_bytes(&bytes), warnings = warnings)
    }

    /// Render the scene and return the PDF bytes rather than writing a file.
    /// Same shape as `render_png_raw`.
    fn render_pdf_raw(&self) -> List {
        let (bytes, warnings) = self.pdf_bytes();
        list!(bytes = Raw::from_bytes(&bytes), warnings = warnings)
    }

    /// Render the scene to an SVG file. `outline_text` emits glyph outlines
    /// instead of selectable `<text>` (pixel-faithful, matches raster/PDF).
    /// Returns any degradation warnings.
    fn render_svg(&self, path: &str, outline_text: bool) -> Vec<String> {
        let mut b = SvgBackend::new(self.w_px, self.h_px, self.bg, outline_text);
        b.set_a11y(&self.a11y_title, &self.a11y_desc, &self.a11y_prefix);
        let warnings = self.render_to(&mut b);
        if let Err(e) = std::fs::write(path, b.into_string()) {
            throw_r_error(format!("failed to write SVG: {e}"));
        }
        warnings
    }

    /// Render the scene and return the SVG document as a string (rather than
    /// writing it to a file). Same output as `render_svg`; the interactivity
    /// layer needs the markup in-memory to embed it in an htmlwidget, and tests
    /// use it to assert on emitted attributes. Degradation warnings are dropped
    /// here (the file path surfaces them); callers wanting them use `render_svg`.
    fn render_svg_string(&self, outline_text: bool) -> String {
        let mut b = SvgBackend::new(self.w_px, self.h_px, self.bg, outline_text);
        b.set_a11y(&self.a11y_title, &self.a11y_desc, &self.a11y_prefix);
        let _warnings = self.render_to(&mut b);
        b.into_string()
    }

    /// Render the scene to a PDF file. Returns any degradation warnings (e.g. a
    /// tiling pattern or mask the PDF walk could not honour).
    fn render_pdf(&self, path: &str) -> Vec<String> {
        let (bytes, warnings) = self.pdf_bytes();
        if let Err(e) = std::fs::write(path, bytes) {
            throw_r_error(format!("failed to write PDF: {e}"));
        }
        warnings
    }

    /// Render and return the whole image as row-major RGBA bytes
    /// `[r, g, b, a, ...]` (top-left origin, x fastest).
    fn rgba(&self) -> Vec<i32> {
        let pm = self.output_pixmap();
        let mut out = Vec::with_capacity((self.w_px as usize) * (self.h_px as usize) * 4);
        for p in pm.pixels() {
            let c = p.demultiply();
            out.push(c.red() as i32);
            out.push(c.green() as i32);
            out.push(c.blue() as i32);
            out.push(c.alpha() as i32);
        }
        out
    }

    /// Render and return the tight bounding box of non-transparent content as
    /// `c(min_x, min_y, max_x, max_y)` (device px, inclusive), or an empty vector
    /// if nothing was drawn. Used to measure a grob's extent (grobwidth/height).
    fn content_bbox(&self) -> Vec<i32> {
        self.build_content_bbox()
    }

    /// Resolved per-viewport geometry for the debug overlay / `why_size()`. Runs
    /// the layout pass and returns, per viewport (row = viewport id), its parent
    /// id, local pixel size, affine transform (`c(sx, ky, kx, sy, tx, ty)` mapping
    /// local px -> device px), solved layout track edges (local px, plus the
    /// `respect` centering offset), and the device-px bbox of its innermost clip.
    /// R joins this with the viewport names it recorded during compilation.
    fn resolved_geometry(&self) -> List {
        self.build_resolved_geometry()
    }

    /// Per-node facts a linter needs, in paint order: one row per drawn node
    /// (not per element -- the rules that matter are about a whole mark).
    ///
    /// Everything here is measured from the *resolved* scene, which is the point:
    /// a linter built on top of the drawing code can say "this text is 4 px tall"
    /// or "this mark is entirely off-canvas" with the same numbers the renderer
    /// used, rather than re-deriving geometry and drifting from it.
    fn lint_table(&self) -> List {
        self.build_lint_table()
    }

    /// Node identity for the profiler: kind, name, and element count, in node
    /// order -- the same order `rs_take_node_times()` reports.
    fn node_index(&self) -> List {
        self.build_node_index()
    }

    /// Exact distance from a device-px point to every keyed element, and the
    /// element's true geometry.
    ///
    /// `scene_model()` reports bounding boxes, which is the right thing for a
    /// rectangular brush and misleading for anything diagonal or thin: a
    /// segment's bbox is the whole rectangle its endpoints span. This walks the
    /// same elements and reports the distance to their actual geometry, plus the
    /// geometry itself (flat `gx`/`gy` split by `gn`) so a client that must
    /// hit-test locally can do it exactly rather than asking per event.
    ///
    /// Filled shapes contain their interior — a point inside a polygon is at
    /// distance zero, so clicking the middle of a choropleth region hits it.
    fn pick_table(&self, px: f64, py: f64) -> List {
        self.build_pick_table(px, py)
    }

    /// The `n` keyed elements nearest device px `(px, py)` within `max_dist`
    /// px: `key`, `kind`, `dist`, nearest first, ties in paint order. Answers
    /// from a uniform-grid spatial index built once per scene (and dropped when
    /// it is drawn into), so a hover-rate caller does not rebuild the pick
    /// table per probe. Same rows as `pick_table()` sorted by `dist`.
    fn nearest_table(&self, px: f64, py: f64, n: i32, max_dist: f64) -> List {
        self.build_nearest_table(px, py, n.max(0) as usize, max_dist)
    }

    /// The keyed elements meeting the device-px rectangle with corners
    /// `(x0, y0)`, `(x1, y1)`: `key`, `kind`, in paint order. `mode` is
    /// `"intersect"`, `"contain"` or `"centre"` (see `spatial::Region`).
    fn brush_table(&self, x0: f64, y0: f64, x1: f64, y1: f64, mode: &str) -> List {
        let m = Region::parse(mode).unwrap_or_else(|| throw_r_error("unknown region mode"));
        self.build_region_table(&[x0, x1], &[y0, y1], true, m)
    }

    /// The keyed elements meeting the device-px polygon `(xs, ys)` (closed
    /// implicitly, even-odd rule): `key`, `kind`, in paint order.
    fn lasso_table(&self, xs: Vec<f64>, ys: Vec<f64>, mode: &str) -> List {
        let m = Region::parse(mode).unwrap_or_else(|| throw_r_error("unknown region mode"));
        self.build_region_table(&xs, &ys, false, m)
    }

    /// The font files this scene's text actually resolved to.
    ///
    /// Read off the shaped glyphs rather than re-resolved from family names, so
    /// it reports what was *used*, not what would be picked if asked again.
    /// Returns `path`, `index` (face within a collection) and `glyphs` (how many
    /// glyphs came from that face).
    fn font_table(&self) -> List {
        self.build_font_table()
    }

    /// Per-element device-px bounding boxes for the batched mark nodes (the ones
    /// that can carry data keys): rects, circles, points/markers, hexagons,
    /// sectors, segments. Rows are emitted in paint order (the compiler's DFS),
    /// one per drawn element — the same order and count the R grammar enumerates,
    /// so `scene_model()` zips this with R-side semantics positionally (and
    /// cross-checks the `key` column). Columns: `key` ("" = none), enclosing
    /// `panel` ("" = none), and device-px bbox `x0,y0,x1,y1` (y-down). Each box is
    /// the extent of the element's recorded outline, so a sector's box is its
    /// wedge (centre included for a pie slice), not the outer-radius disc.
    fn element_table(&self) -> List {
        self.build_element_table()
    }

    /// Render and return the RGBA of device pixel `(x, y)` as `c(r, g, b, a)`.
    fn pixel(&self, x: i32, y: i32) -> Vec<i32> {
        if x < 0 || y < 0 || x as u32 >= self.w_px || y as u32 >= self.h_px {
            throw_r_error("pixel out of bounds");
        }
        let pm = self.cached_pixmap();
        match pm.pixel(x as u32, y as u32) {
            Some(p) => {
                let c = p.demultiply();
                vec![
                    c.red() as i32,
                    c.green() as i32,
                    c.blue() as i32,
                    c.alpha() as i32,
                ]
            }
            None => throw_r_error("pixel out of bounds"),
        }
    }

    /// Hit-test: return the pick id of the topmost primitive covering device pixel
    /// `(x, y)`, or -1 if none. Reads the recorded geometry (see `recording`):
    /// nodes are tested topmost-first, a fill by its fill rule, a round mark by
    /// its disc, a text label by its (rotated) box, and a line or segment by a
    /// band of half its stroke width (at least 2 px, so a hairline stays
    /// clickable). A candidate counts only if the pixel survives its viewport's
    /// clip, tested with the same aliased clip mask the renderer builds.
    fn hit_test(&self, x: i32, y: i32) -> i32 {
        self.build_hit_test(x, y)
    }
}

/// Build an arrow from FFI scalars, or `None` when there is no head (`len <= 0`).
fn arrow_from(angle: f64, len_in: f64, ends: i32, closed: bool) -> Option<Arrow> {
    if !(len_in > 0.0) || !len_in.is_finite() {
        return None;
    }
    Some(Arrow {
        angle,
        len: len_in,
        ends: (ends.clamp(0, 3)) as u8,
        closed,
    })
}

/// Decode the per-grob sketch options from FFI scalars, or `None` when there is
/// no sketch (sentinel: `roughness < 0`). Mirrors `arrow_from`. `fill_weight` and
/// `hachure_gap` arrive in "lwd" units (1 == 1/96 inch), or `<= 0` for auto; they
/// are resolved to device px per-render in [`resolve_sketch`].
#[allow(clippy::too_many_arguments)]
fn sketch_from(
    roughness: f64,
    bowing: f64,
    fill_style: i32,
    fill_weight: f64,
    hachure_angle: f64,
    hachure_gap: f64,
    curve_tightness: f64,
    disable_multi: bool,
    preserve: bool,
    seed: f64,
) -> Option<crate::sketch::SketchOpts> {
    if !(roughness >= 0.0) || !roughness.is_finite() {
        return None;
    }
    Some(crate::sketch::SketchOpts {
        roughness,
        bowing,
        fill_style: crate::sketch::FillStyle::from_code(fill_style.max(0) as u32),
        fill_weight,
        hachure_angle,
        hachure_gap,
        curve_tightness,
        curve_step_count: 9.0,
        disable_multi_stroke: disable_multi,
        preserve_vertices: preserve,
        max_offset: 2.0,
        seed: if seed.is_finite() && seed >= 0.0 {
            seed as u64
        } else {
            1
        },
    })
}

pub(super) fn pair(s: &[f64], default: (f64, f64)) -> (f64, f64) {
    if s.len() >= 2 && s[0].is_finite() && s[1].is_finite() && s[0] != s[1] {
        (s[0], s[1])
    } else {
        // A missing, non-finite, or zero-span scale would yield NaN/degenerate
        // native coordinates (which silently vanish); fall back to the default.
        default
    }
}

/// An R `NULL` as an `Robj` (used to mean "inherit" for gpar fields).
fn rnull() -> Robj {
    Robj::from(NULL)
}

/// Decode a slice of integer unit codes from R into `Unit`s (per element).
pub(super) fn codes(c: &[i32]) -> Vec<Unit> {
    c.iter().map(|&v| Unit::from_code(v)).collect()
}

/// Like `codes`, but carrying a parallel per-element absolute-mm offset stream.
fn codes_off(c: &[i32], off: &[f64]) -> Vec<Unit> {
    c.iter()
        .enumerate()
        .map(|(i, &v)| Unit::from_code_off(v, off.get(i).copied().unwrap_or(0.0)))
        .collect()
}

/// A single-element node's optional data key: an empty string (the "no key" FFI
/// sentinel) becomes `None`.
fn opt_key(key: String) -> Option<String> {
    if key.is_empty() {
        None
    } else {
        Some(key)
    }
}

/// Decode a scalar cap (value + code) from the parallel FFI streams: `None` when
/// empty (no cap), else the first element. Used by `lines` (whole-path caps).
fn cap_scalar(value: &[f64], code: &[i32]) -> Option<(f64, Unit)> {
    value.first().map(|&v| {
        (
            v,
            code.first()
                .map(|&c| Unit::from_code(c))
                .unwrap_or(Unit::plain(UnitKind::Mm)),
        )
    })
}

/// Most pixels a raster render may hold: 2^28 (16384 x 16384), a 1 GiB RGBA
/// page. `px_dim` caps each side at 30000 px, which still allows a 3.6 GB page,
/// and every isolated group, mask or blur layer allocates another page-sized
/// pixmap on top. An allocation that size can fail, and a failed allocation
/// aborts the R session rather than raising an error, so refuse it up front.
/// Vector output (SVG, PDF) allocates no page and is not limited.
pub(super) const MAX_RASTER_PX: u64 = 1 << 28;

/// Throw an R error when a `w` x `h` raster exceeds [`MAX_RASTER_PX`]. Call only
/// on the R main thread (an FFI entry point), never from a render worker.
pub(super) fn check_raster_area(w: u32, h: u32) {
    if w as u64 * h as u64 > MAX_RASTER_PX {
        throw_r_error(format!(
            "raster too large: {w} x {h} px exceeds the {MAX_RASTER_PX} px limit; \
             lower the dpi or size, or render to SVG/PDF"
        ));
    }
}

/// Convert a (finite, positive) dimension in pixels to a `u32`, at least 1 and
/// capped so we never attempt an absurd allocation. Callers validate finiteness.
fn px_dim(v: f64) -> u32 {
    let r = v.round().max(1.0);
    const MAX_DIM: f64 = 30000.0;
    if r > MAX_DIM {
        throw_r_error("scene dimension too large (max 30000 px per side)");
    }
    r as u32
}

// Registered from here rather than `mod.rs`: `impl Scene;` refers to the
// metadata function the `#[extendr]` impl above generates in this module.
extendr_module! {
    mod scene;
    impl Scene;
    use tween;
}
