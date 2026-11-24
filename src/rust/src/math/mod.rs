//! Native math typesetting for `tex()` labels (F-22).
//!
//! A TeX-subset parser (`parse`), a reader for the OpenType `MATH` table
//! (`table`), and a TeX-style layout over it (`layout`). The output is the
//! same positioned-glyph form `md()` labels hand to `texts_rich`, plus a list
//! of rules (fraction bars, radical overbars), so every backend draws math
//! with the glyph path it already has.
//!
//! Units: points, y up, baseline at y = 0.

use extendr_api::prelude::*;

pub mod font;
pub mod layout;
pub mod parse;
pub mod symbols;
pub mod table;

use font::MathFont;
use layout::{Ctx, Glyph, Rule, Style};
pub use parse::ParseError;

/// A laid-out formula. `ascent`/`depth` are the ink extents above/below the
/// baseline (what is drawn); `box_height`/`box_depth` are TeX's box extents
/// (which include the font's extra ascender above bars and radicals) for
/// callers that align math with surrounding text.
#[derive(Debug)]
pub struct Formula {
    pub glyphs: Vec<Glyph>,
    pub rules: Vec<Rule>,
    pub width: f64,
    pub ascent: f64,
    pub depth: f64,
    pub box_height: f64,
    pub box_depth: f64,
}

/// Parse and lay out `src` at `size` points in `font`.
pub fn typeset(
    src: &str,
    font: &MathFont,
    size: f64,
    display: bool,
) -> Result<Formula, ParseError> {
    let nodes = parse::parse(src)?;
    let ctx = Ctx { font, size };
    let b = ctx.hlist(&nodes, Style::new(display));
    // Ink extents over every glyph outline and rule.
    let mut top = f64::NEG_INFINITY;
    let mut bot = f64::INFINITY;
    for g in &b.glyphs {
        let (_, y0, _, y1) = font.bounds(g.gid);
        if y0 == 0.0 && y1 == 0.0 {
            continue; // blank glyph
        }
        let k = g.size / font.upem;
        top = top.max(g.y + y1 * k);
        bot = bot.min(g.y + y0 * k);
    }
    for r in &b.rules {
        top = top.max(r.y + r.h);
        bot = bot.min(r.y);
    }
    let (ascent, depth) = if top.is_finite() {
        (top, -bot)
    } else {
        (0.0, 0.0)
    };
    Ok(Formula {
        glyphs: b.glyphs,
        rules: b.rules,
        width: b.w,
        ascent,
        depth,
        box_height: b.h,
        box_depth: b.d,
    })
}

/// Parse only (no font needed): `NULL` when `src` is valid, else
/// `list(message, position)`.
/// @keywords internal
#[extendr]
fn rs_math_check(src: &str) -> Robj {
    match parse::parse(src) {
        Ok(_) => r!(NULL),
        Err(e) => list!(message = e.msg, position = e.pos as i32).into(),
    }
}

/// `""` when the font at `path`/`face` can typeset math, else why not.
/// @keywords internal
#[extendr]
fn rs_math_font_check(path: &str, face: i32) -> String {
    match font::math_font(path, face.max(0) as u32) {
        Ok(_) => String::new(),
        Err(e) => e,
    }
}

/// Lay out a formula. Returns the glyph and rule arrays (points, y up,
/// baseline 0) and the extents, or `list(message, position)` on a parse
/// error (`position` NA for a font error).
/// @keywords internal
#[extendr]
fn rs_math_layout(src: &str, path: &str, face: i32, size: f64, display: bool) -> Robj {
    let f = match font::math_font(path, face.max(0) as u32) {
        Ok(f) => f,
        Err(e) => return list!(message = e, position = NA_INTEGER).into(),
    };
    match typeset(src, &f, size, display) {
        Err(e) => list!(message = e.msg, position = e.pos as i32).into(),
        Ok(m) => {
            let gid: Vec<i32> = m.glyphs.iter().map(|g| g.gid as i32).collect();
            let gx: Vec<f64> = m.glyphs.iter().map(|g| g.x).collect();
            let gy: Vec<f64> = m.glyphs.iter().map(|g| g.y).collect();
            let gsize: Vec<f64> = m.glyphs.iter().map(|g| g.size).collect();
            let text: String = m.glyphs.iter().map(|g| g.ch).collect();
            let rx: Vec<f64> = m.rules.iter().map(|r| r.x).collect();
            let ry: Vec<f64> = m.rules.iter().map(|r| r.y).collect();
            let rw: Vec<f64> = m.rules.iter().map(|r| r.w).collect();
            let rh: Vec<f64> = m.rules.iter().map(|r| r.h).collect();
            list!(
                gid = gid,
                gx = gx,
                gy = gy,
                gsize = gsize,
                text = text,
                rx = rx,
                ry = ry,
                rw = rw,
                rh = rh,
                width = m.width,
                ascent = m.ascent,
                depth = m.depth,
                box_height = m.box_height,
                box_depth = m.box_depth
            )
            .into()
        }
    }
}

extendr_module! {
    mod math;
    fn rs_math_check;
    fn rs_math_font_check;
    fn rs_math_layout;
}

#[cfg(test)]
mod tests;
