//! A math font: the file bytes, its `MATH` table, and the per-glyph metrics
//! the layout asks for (cmap, advances, ink bounds, `ssty` alternates).
//!
//! Fonts are loaded once per `(path, face)` and cached for the session, like
//! the glyph-outline cache in `font.rs`.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use skrifa::instance::{LocationRef, Size};
use skrifa::outline::{DrawSettings, OutlinePen};
use skrifa::raw::tables::gsub::SubstitutionSubtables;
use skrifa::raw::types::Tag;
use skrifa::raw::TableProvider;
use skrifa::{FontRef, GlyphId, MetadataProvider};

use super::table::MathTable;

/// Ink bounds of a glyph in font units: `(x_min, y_min, x_max, y_max)`.
/// A blank glyph (a space) has all four at zero.
pub type Bounds = (f64, f64, f64, f64);

pub struct MathFont {
    pub face: u32,
    bytes: Vec<u8>,
    pub upem: f64,
    pub math: MathTable,
    /// `ssty` alternates: glyph -> [script, scriptscript] (one entry may repeat).
    ssty: HashMap<u16, Vec<u16>>,
    bounds: RefCell<HashMap<u16, Bounds>>,
}

impl MathFont {
    /// Load `path`/`face`. `Err` names what is wrong (unreadable file, not a
    /// font, or a font without a `MATH` table).
    pub fn load(path: &str, face: u32) -> Result<MathFont, String> {
        let bytes = std::fs::read(path).map_err(|e| format!("can't read font file: {e}"))?;
        let font =
            FontRef::from_index(&bytes, face).map_err(|_| "not a readable font".to_string())?;
        let raw = font
            .table_data(Tag::new(b"MATH"))
            .ok_or_else(|| "the font has no OpenType MATH table".to_string())?;
        let math = MathTable::parse(raw.as_bytes())
            .ok_or_else(|| "the font's MATH table is unreadable".to_string())?;
        let upem = font
            .head()
            .map(|h| h.units_per_em() as f64)
            .unwrap_or(1000.0);
        let ssty = read_ssty(&font);
        Ok(MathFont {
            face,
            bytes,
            upem,
            math,
            ssty,
            bounds: RefCell::new(HashMap::new()),
        })
    }

    fn font(&self) -> FontRef<'_> {
        FontRef::from_index(&self.bytes, self.face).expect("validated at load")
    }

    /// Nominal glyph for `ch`, if the font maps it.
    pub fn glyph(&self, ch: char) -> Option<u16> {
        let g = self.font().charmap().map(ch)?;
        let id = g.to_u32();
        if id == 0 || id > u16::MAX as u32 {
            None
        } else {
            Some(id as u16)
        }
    }

    /// Horizontal advance in font units.
    pub fn advance(&self, gid: u16) -> f64 {
        self.font()
            .glyph_metrics(Size::unscaled(), LocationRef::default())
            .advance_width(GlyphId::new(gid as u32))
            .unwrap_or(0.0) as f64
    }

    /// Exact ink bounds in font units (curve extrema, not control points).
    pub fn bounds(&self, gid: u16) -> Bounds {
        if let Some(b) = self.bounds.borrow().get(&gid) {
            return *b;
        }
        let mut pen = BoundsPen::default();
        let font = self.font();
        let outlines = font.outline_glyphs();
        if let Some(g) = outlines.get(GlyphId::new(gid as u32)) {
            let settings = DrawSettings::unhinted(Size::unscaled(), LocationRef::default());
            let _ = g.draw(settings, &mut pen);
        }
        let b = pen.bounds();
        self.bounds.borrow_mut().insert(gid, b);
        b
    }

    /// The `ssty` alternate for script (`level` 1) or scriptscript (2) style;
    /// the glyph itself when the font has none.
    pub fn script_variant(&self, gid: u16, level: u8) -> u16 {
        match (level, self.ssty.get(&gid)) {
            (0, _) | (_, None) => gid,
            (l, Some(alts)) => {
                let k = (l as usize - 1).min(alts.len().saturating_sub(1));
                alts.get(k).copied().unwrap_or(gid)
            }
        }
    }
}

/// Collect the `ssty` alternate-substitution lookups into a glyph map. A
/// font without GSUB or without `ssty` gives an empty map.
fn read_ssty(font: &FontRef) -> HashMap<u16, Vec<u16>> {
    let mut out = HashMap::new();
    let Ok(gsub) = font.gsub() else {
        return out;
    };
    let (Ok(features), Ok(lookups)) = (gsub.feature_list(), gsub.lookup_list()) else {
        return out;
    };
    let tag = Tag::new(b"ssty");
    let mut indices: Vec<u16> = Vec::new();
    for rec in features.feature_records() {
        if rec.feature_tag() != tag {
            continue;
        }
        if let Ok(feat) = rec.feature(features.offset_data()) {
            indices.extend(feat.lookup_list_indices().iter().map(|v| v.get()));
        }
    }
    indices.sort_unstable();
    indices.dedup();
    for li in indices {
        let Ok(lookup) = lookups.lookups().get(li as usize) else {
            continue;
        };
        let Ok(subtables) = lookup.subtables() else {
            continue;
        };
        match subtables {
            SubstitutionSubtables::Alternate(st) => {
                for sub in st.iter().flatten() {
                    let (Ok(cov), sets) = (sub.coverage(), sub.alternate_sets()) else {
                        continue;
                    };
                    for (k, g) in cov.iter().enumerate() {
                        if let Ok(set) = sets.get(k) {
                            let alts: Vec<u16> = set
                                .alternate_glyph_ids()
                                .iter()
                                .map(|a| a.get().to_u16())
                                .collect();
                            if !alts.is_empty() {
                                out.entry(g.to_u16()).or_insert(alts);
                            }
                        }
                    }
                }
            }
            SubstitutionSubtables::Single(st) => {
                for sub in st.iter().flatten() {
                    let cov = match &sub {
                        skrifa::raw::tables::gsub::SingleSubst::Format1(f) => f.coverage(),
                        skrifa::raw::tables::gsub::SingleSubst::Format2(f) => f.coverage(),
                    };
                    let Ok(cov) = cov else { continue };
                    for g in cov.iter() {
                        if let Some(to) = single_subst(&sub, g.to_u16()) {
                            out.entry(g.to_u16()).or_insert(vec![to]);
                        }
                    }
                }
            }
            _ => {}
        }
    }
    out
}

fn single_subst(sub: &skrifa::raw::tables::gsub::SingleSubst, g: u16) -> Option<u16> {
    use skrifa::raw::tables::gsub::SingleSubst;
    match sub {
        SingleSubst::Format1(f) => {
            let d = f.delta_glyph_id() as i32;
            Some(((g as i32 + d).rem_euclid(65536)) as u16)
        }
        SingleSubst::Format2(f) => {
            let idx = f.coverage().ok()?.get(GlyphId::new(g as u32))? as usize;
            f.substitute_glyph_ids().get(idx).map(|v| v.get().to_u16())
        }
    }
}

/// Outline pen that tracks exact ink bounds: on-curve points plus the extrema
/// of each quadratic/cubic segment, so a bowl's control points don't inflate
/// the box.
#[derive(Default)]
struct BoundsPen {
    cur: (f64, f64),
    b: Option<Bounds>,
}

impl BoundsPen {
    fn add(&mut self, x: f64, y: f64) {
        self.b = Some(match self.b {
            None => (x, y, x, y),
            Some((x0, y0, x1, y1)) => (x0.min(x), y0.min(y), x1.max(x), y1.max(y)),
        });
    }
    fn bounds(&self) -> Bounds {
        self.b.unwrap_or((0.0, 0.0, 0.0, 0.0))
    }
}

/// Parameters in (0, 1) where a cubic Bézier coordinate has a zero derivative.
fn cubic_extrema(p0: f64, p1: f64, p2: f64, p3: f64) -> Vec<f64> {
    // B'(t)/3 = a t^2 + b t + c
    let a = -p0 + 3.0 * p1 - 3.0 * p2 + p3;
    let b = 2.0 * (p0 - 2.0 * p1 + p2);
    let c = p1 - p0;
    let mut ts = Vec::new();
    if a.abs() < 1e-12 {
        if b.abs() > 1e-12 {
            ts.push(-c / b);
        }
    } else {
        let disc = b * b - 4.0 * a * c;
        if disc >= 0.0 {
            let s = disc.sqrt();
            ts.push((-b + s) / (2.0 * a));
            ts.push((-b - s) / (2.0 * a));
        }
    }
    ts.retain(|t| *t > 0.0 && *t < 1.0);
    ts
}

fn cubic_at(p0: f64, p1: f64, p2: f64, p3: f64, t: f64) -> f64 {
    let u = 1.0 - t;
    u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3
}

impl OutlinePen for BoundsPen {
    fn move_to(&mut self, x: f32, y: f32) {
        self.cur = (x as f64, y as f64);
        self.add(x as f64, y as f64);
    }
    fn line_to(&mut self, x: f32, y: f32) {
        self.cur = (x as f64, y as f64);
        self.add(x as f64, y as f64);
    }
    fn quad_to(&mut self, cx: f32, cy: f32, x: f32, y: f32) {
        // Elevate to a cubic and reuse the cubic extrema.
        let (x0, y0) = self.cur;
        let (cx, cy, x, y) = (cx as f64, cy as f64, x as f64, y as f64);
        let c1 = (x0 + 2.0 / 3.0 * (cx - x0), y0 + 2.0 / 3.0 * (cy - y0));
        let c2 = (x + 2.0 / 3.0 * (cx - x), y + 2.0 / 3.0 * (cy - y));
        self.cubic(c1, c2, (x, y));
    }
    fn curve_to(&mut self, c0x: f32, c0y: f32, c1x: f32, c1y: f32, x: f32, y: f32) {
        self.cubic(
            (c0x as f64, c0y as f64),
            (c1x as f64, c1y as f64),
            (x as f64, y as f64),
        );
    }
    fn close(&mut self) {}
}

impl BoundsPen {
    fn cubic(&mut self, c1: (f64, f64), c2: (f64, f64), p: (f64, f64)) {
        let p0 = self.cur;
        for t in cubic_extrema(p0.0, c1.0, c2.0, p.0) {
            let x = cubic_at(p0.0, c1.0, c2.0, p.0, t);
            let y = cubic_at(p0.1, c1.1, c2.1, p.1, t);
            self.add(x, y);
        }
        for t in cubic_extrema(p0.1, c1.1, c2.1, p.1) {
            let x = cubic_at(p0.0, c1.0, c2.0, p.0, t);
            let y = cubic_at(p0.1, c1.1, c2.1, p.1, t);
            self.add(x, y);
        }
        self.add(p.0, p.1);
        self.cur = p;
    }
}

thread_local! {
    static FONTS: RefCell<HashMap<(String, u32), Rc<MathFont>>> = RefCell::new(HashMap::new());
}

/// A cached math font. Failures are not cached, so fixing a path and
/// retrying works within a session.
pub fn math_font(path: &str, face: u32) -> Result<Rc<MathFont>, String> {
    let key = (path.to_string(), face);
    if let Some(f) = FONTS.with(|m| m.borrow().get(&key).cloned()) {
        return Ok(f);
    }
    let f = Rc::new(MathFont::load(path, face)?);
    FONTS.with(|m| m.borrow_mut().insert(key, f.clone()));
    Ok(f)
}
