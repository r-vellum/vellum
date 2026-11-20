//! Encoding the marks-only display list (`render::DisplayList`) as the R list
//! `scene_display_list()` returns: numeric columns as base64 little-endian typed
//! arrays, with constant and arithmetic-sequence columns collapsed. See the R
//! documentation for the field list; the format is private to vellumwidget.

use super::*;
use crate::render::{DisplayList, DisplayListBackend};

/// A named column descriptor (`type` is a reserved word for `list!`).
fn col(ty: &str, n: i32, field: &str, value: Robj) -> Robj {
    List::from_names_and_values(["type", "n", field], [Robj::from(ty), Robj::from(n), value])
        .expect("column descriptor")
        .into()
}

fn b64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// Run-length form `list(values, lengths)` when a column has few runs (at
/// most one per 8 values), else `None`.
fn runs<T: Copy + PartialEq>(v: &[T], to_f64: impl Fn(T) -> f64) -> Option<Robj> {
    let mut values: Vec<f64> = Vec::new();
    let mut lengths: Vec<f64> = Vec::new();
    let mut prev: Option<T> = None;
    for &x in v {
        if prev == Some(x) {
            *lengths.last_mut().unwrap() += 1.0;
        } else {
            if values.len() * 8 >= v.len() {
                return None;
            }
            values.push(to_f64(x));
            lengths.push(1.0);
            prev = Some(x);
        }
    }
    Some(
        List::from_names_and_values(
            ["values", "lengths"],
            [Robj::from(values), Robj::from(lengths)],
        )
        .expect("rle")
        .into(),
    )
}

/// `list(type = "f32", n, data = <base64>)`, or `const = v` when every value
/// is the same, or `rle = list(values, lengths)` when there are few runs.
fn col_f32(v: &[f32]) -> Robj {
    let n = v.len() as i32;
    if let Some(&c) = v.first() {
        if v.iter().all(|&x| x.to_bits() == c.to_bits()) {
            return col("f32", n, "const", Robj::from(c as f64));
        }
        // Compare bit patterns so NaN runs collapse too.
        let bits: Vec<u32> = v.iter().map(|x| x.to_bits()).collect();
        if let Some(r) = runs(&bits, |b| f32::from_bits(b) as f64) {
            return col("f32", n, "rle", r);
        }
    }
    let mut bytes = Vec::with_capacity(v.len() * 4);
    for x in v {
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    col("f32", n, "data", Robj::from(b64(&bytes)))
}

/// An unsigned integer column in the narrowest of u8/u16/u32. A constant
/// column is `const = v`, an arithmetic sequence `seq = c(start, step)`, and a
/// column of few runs `rle = list(values, lengths)`.
fn col_uint(v: &[u32]) -> Robj {
    let n = v.len() as i32;
    let max = v.iter().copied().max().unwrap_or(0);
    let ty = if max <= u8::MAX as u32 {
        "u8"
    } else if max <= u16::MAX as u32 {
        "u16"
    } else {
        "u32"
    };
    if let Some(&c) = v.first() {
        if v.iter().all(|&x| x == c) {
            return col(ty, n, "const", Robj::from(c as f64));
        }
        if v.len() > 2 {
            let step = v[1] as i64 - c as i64;
            if v.iter()
                .enumerate()
                .all(|(i, &x)| x as i64 == c as i64 + step * i as i64)
            {
                return col(ty, n, "seq", Robj::from(vec![c as f64, step as f64]));
            }
        }
        if let Some(r) = runs(v, |x| x as f64) {
            return col(ty, n, "rle", r);
        }
    }
    let mut bytes = Vec::with_capacity(v.len() * 4);
    for &x in v {
        match ty {
            "u8" => bytes.push(x as u8),
            "u16" => bytes.extend_from_slice(&(x as u16).to_le_bytes()),
            _ => bytes.extend_from_slice(&x.to_le_bytes()),
        }
    }
    col(ty, n, "data", Robj::from(b64(&bytes)))
}

fn col_u8(v: &[u8]) -> Robj {
    col_uint(&v.iter().map(|&x| x as u32).collect::<Vec<_>>())
}

fn hex(c: Option<u32>) -> Option<String> {
    c.map(|c| format!("#{c:08x}"))
}

/// A key that survives a round trip through `u32` as decimal text.
fn int_key(k: &str) -> Option<u32> {
    let v: u32 = k.parse().ok()?;
    (v.to_string() == k).then_some(v)
}

pub(super) fn encode(dl: DisplayList, w: f64, h: f64) -> List {
    // Paints, interned in first-use order.
    let mut paint_ix: HashMap<_, u32> = HashMap::new();
    let mut paints = Vec::new();
    let mut kind = Vec::with_capacity(dl.recs.len());
    let mut paint = Vec::with_capacity(dl.recs.len());
    let mut key = Vec::with_capacity(dl.recs.len());
    let mut flags = Vec::with_capacity(dl.recs.len());
    let mut clip = Vec::with_capacity(dl.recs.len());
    let mut panel = Vec::with_capacity(dl.recs.len());
    for r in &dl.recs {
        let pi = *paint_ix.entry(r.paint.clone()).or_insert_with(|| {
            paints.push(r.paint.clone());
            (paints.len() - 1) as u32
        });
        kind.push(r.kind);
        paint.push(pi);
        key.push(r.key);
        flags.push(r.flags);
        clip.push(r.clip);
        panel.push(r.panel);
    }
    let caps = ["butt", "round", "square"];
    let joins = ["mitre", "round", "bevel"];
    let paint_df = list!(
        fill = Robj::from(paints.iter().map(|p| hex(p.fill)).collect::<Vec<_>>()),
        stroke = Robj::from(paints.iter().map(|p| hex(p.stroke)).collect::<Vec<_>>()),
        stroke_width = paints
            .iter()
            .map(|p| f32::from_bits(p.width) as f64)
            .collect::<Vec<f64>>(),
        dash = Robj::from(
            paints
                .iter()
                .map(|p| {
                    (!p.dash.is_empty()).then(|| {
                        p.dash
                            .iter()
                            .map(|d| format!("{}", f32::from_bits(*d)))
                            .collect::<Vec<_>>()
                            .join(",")
                    })
                })
                .collect::<Vec<_>>()
        ),
        linecap = paints
            .iter()
            .map(|p| caps[p.cap as usize % 3])
            .collect::<Strings>(),
        linejoin = paints
            .iter()
            .map(|p| joins[p.join as usize % 3])
            .collect::<Strings>()
    );
    let clip_df = list!(
        x0 = dl.clips.iter().map(|c| c[0]).collect::<Vec<f64>>(),
        y0 = dl.clips.iter().map(|c| c[1]).collect::<Vec<f64>>(),
        x1 = dl.clips.iter().map(|c| c[2]).collect::<Vec<f64>>(),
        y1 = dl.clips.iter().map(|c| c[3]).collect::<Vec<f64>>()
    );
    // Keys: integer-valued keys (the common `data_id = row`) ship as a number
    // column -- usually a `seq` -- rather than as text.
    let ints: Option<Vec<u32>> = dl.keys.iter().map(|k| int_key(k)).collect();
    let keys: Robj = match ints {
        Some(v) if !v.is_empty() => col_uint(&v),
        _ => dl
            .keys
            .iter()
            .map(|s| s.as_str())
            .collect::<Strings>()
            .into(),
    };
    list!(
        format = "vellum-display-list",
        version = 1,
        width = w,
        height = h,
        n = dl.recs.len() as i32,
        record = list!(
            kind = col_u8(&kind),
            paint = col_uint(&paint),
            key = col_uint(&key),
            flags = col_u8(&flags),
            clip = col_uint(&clip),
            panel = col_uint(&panel)
        ),
        point = list!(
            cx = col_f32(&dl.pt_cx),
            cy = col_f32(&dl.pt_cy),
            r = col_f32(&dl.pt_r),
            shape = col_u8(&dl.pt_shape)
        ),
        rect = list!(
            x = col_f32(&dl.rc_x),
            y = col_f32(&dl.rc_y),
            w = col_f32(&dl.rc_w),
            h = col_f32(&dl.rc_h)
        ),
        path = list!(
            xy = col_f32(&dl.xy),
            run_offset = col_uint(&dl.run_off),
            path_offset = col_uint(&dl.path_off),
            closed = col_u8(&dl.closed),
            evenodd = col_u8(&dl.evenodd)
        ),
        paints = paint_df,
        clips = clip_df,
        keys = keys,
        panels = dl.panels.iter().map(|s| s.as_str()).collect::<Strings>()
    )
}

impl Scene {
    /// Walk the scene through the display-list backend and encode the result.
    pub(super) fn display_list(&self, panels: Option<Vec<String>>) -> List {
        let mut b = DisplayListBackend::with_panels(panels);
        let _ = self.render_to(&mut b);
        encode(b.finish(), self.w_px as f64, self.h_px as f64)
    }
}
