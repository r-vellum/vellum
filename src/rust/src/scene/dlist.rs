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

/// `l` with one more named element appended.
fn with_field(l: List, name: &str, value: Robj) -> List {
    let mut names: Vec<String> = l
        .names()
        .map(|n| n.map(String::from).collect())
        .unwrap_or_default();
    let mut values: Vec<Robj> = l.values().collect();
    names.push(name.to_string());
    values.push(value);
    List::from_names_and_values(names, values).expect("list field")
}

fn hex(c: Option<u32>) -> Option<String> {
    c.map(|c| format!("#{c:08x}"))
}

/// A key that survives a round trip through `u32` as decimal text.
fn int_key(k: &str) -> Option<u32> {
    let v: u32 = k.parse().ok()?;
    (v.to_string() == k).then_some(v)
}

/// The key table and per-record key indices. With `given` (VR-22: the
/// caller's own key vector, e.g. vellumwidget's element table) a record's key
/// is its first position in `given`, and only the keys `given` lacks are
/// listed, in first-use order, at `given.len()` onwards. `None` entries
/// (`NA`) match nothing. Without it, the list's own table in first-use order.
fn key_refs(
    dl_keys: &[String],
    rec_keys: &[u32],
    given: Option<&[Option<String>]>,
) -> (Vec<u32>, Vec<String>) {
    let Some(given) = given else {
        return (rec_keys.to_vec(), dl_keys.to_vec());
    };
    let mut pos: HashMap<&str, u32> = HashMap::with_capacity(given.len());
    for (i, k) in given.iter().enumerate() {
        if let Some(k) = k {
            pos.entry(k.as_str()).or_insert(i as u32);
        }
    }
    let base = given.len() as u32;
    let mut extra: Vec<String> = Vec::new();
    let map: Vec<u32> = dl_keys
        .iter()
        .map(|k| match pos.get(k.as_str()) {
            Some(&i) => i,
            None => {
                extra.push(k.clone());
                base + extra.len() as u32 - 1
            }
        })
        .collect();
    let refs = rec_keys
        .iter()
        .map(|&k| map.get(k as usize).copied().unwrap_or(k))
        .collect();
    (refs, extra)
}

pub(super) fn encode(dl: DisplayList, w: f64, h: f64, given: Option<&[Option<String>]>) -> List {
    // Paints, interned in first-use order.
    let mut paint_ix: HashMap<_, u32> = HashMap::new();
    let mut paints = Vec::new();
    let mut kind = Vec::with_capacity(dl.recs.len());
    let mut paint = Vec::with_capacity(dl.recs.len());
    let mut key = Vec::with_capacity(dl.recs.len());
    let mut flags = Vec::with_capacity(dl.recs.len());
    let mut clip = Vec::with_capacity(dl.recs.len());
    let mut panel = Vec::with_capacity(dl.recs.len());
    let mut group = Vec::with_capacity(dl.recs.len());
    let mut run = Vec::with_capacity(dl.recs.len());
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
        group.push(r.group);
        run.push(r.run);
    }
    let v2 = dl.version >= 2;
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
    // Version 2 (VW-23) adds, and a version-1 reader never sees: the paints'
    // gradient refs, the gradient table, the clip paths, and the opacity groups.
    let mut paint_df = paint_df;
    let mut clip_df = clip_df;
    if v2 {
        paint_df = with_field(
            paint_df,
            "fill_gradient",
            paints
                .iter()
                .map(|p| p.grad as i32)
                .collect::<Vec<i32>>()
                .into(),
        );
        clip_df = with_field(
            clip_df,
            "path_start",
            dl.clip_paths
                .iter()
                .map(|c| c.0 as i32)
                .collect::<Vec<i32>>()
                .into(),
        );
        clip_df = with_field(
            clip_df,
            "path_n",
            dl.clip_paths
                .iter()
                .map(|c| c.1 as i32)
                .collect::<Vec<i32>>()
                .into(),
        );
    }
    // Keys: integer-valued keys (the common `data_id = row`) ship as a number
    // column -- usually a `seq` -- rather than as text.
    let (key, key_table) = key_refs(&dl.keys, &key, given);
    let ints: Option<Vec<u32>> = key_table.iter().map(|k| int_key(k)).collect();
    let keys: Robj = match ints {
        Some(v) if !v.is_empty() => col_uint(&v),
        _ => key_table
            .iter()
            .map(|s| s.as_str())
            .collect::<Strings>()
            .into(),
    };
    let out = list!(
        format = "vellum-display-list",
        version = if v2 { 2 } else { 1 },
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
    );
    // VR-22: `record$key` indexes `c(given, keys)`; say how many come first.
    let out = match given {
        Some(g) => with_field(out, "keys_given", Robj::from(g.len() as i32)),
        None => out,
    };
    if !v2 {
        return out;
    }
    let mut out = out;
    // record$group
    let rec_ix = out.names().unwrap().position(|n| n == "record").unwrap();
    let rec: List = out.elt(rec_ix).unwrap().try_into().unwrap();
    let rec = with_field(rec, "group", col_uint(&group));
    let rec = with_field(rec, "run", col_uint(&run));
    let _ = out.set_elt(rec_ix, rec.into());
    let out = with_field(out, "runs", Robj::from(dl.runs as i32));
    let out = with_field(
        out,
        "run_blend",
        dl.run_blend
            .iter()
            .map(|s| s.as_str())
            .collect::<Strings>()
            .into(),
    );
    let g = &dl.gradients;
    let mut stop_off = vec![0i32];
    let mut stop_pos: Vec<f64> = Vec::new();
    let mut stop_col: Vec<String> = Vec::new();
    for gr in g {
        for &(o, c) in &gr.stops {
            stop_pos.push(o as f64);
            stop_col.push(format!("#{c:08x}"));
        }
        stop_off.push(stop_pos.len() as i32);
    }
    let tcol = |k: usize| {
        g.iter()
            .map(|gr| gr.transform[k] as f64)
            .collect::<Vec<f64>>()
    };
    // (`type` is a reserved word for `list!`.)
    let gradients = List::from_names_and_values(
        [
            "type",
            "x1",
            "y1",
            "x2",
            "y2",
            "r1",
            "r2",
            "a",
            "b",
            "c",
            "d",
            "e",
            "f",
            "stop_offset",
            "stop_pos",
            "stop_color",
        ],
        [
            Robj::from(
                g.iter()
                    .map(|gr| if gr.radial { "radial" } else { "linear" })
                    .collect::<Strings>(),
            ),
            Robj::from(g.iter().map(|gr| gr.p1.0).collect::<Vec<f64>>()),
            Robj::from(g.iter().map(|gr| gr.p1.1).collect::<Vec<f64>>()),
            Robj::from(g.iter().map(|gr| gr.p2.0).collect::<Vec<f64>>()),
            Robj::from(g.iter().map(|gr| gr.p2.1).collect::<Vec<f64>>()),
            Robj::from(g.iter().map(|gr| gr.r1).collect::<Vec<f64>>()),
            Robj::from(g.iter().map(|gr| gr.r2).collect::<Vec<f64>>()),
            Robj::from(tcol(0)),
            Robj::from(tcol(1)),
            Robj::from(tcol(2)),
            Robj::from(tcol(3)),
            Robj::from(tcol(4)),
            Robj::from(tcol(5)),
            Robj::from(stop_off),
            Robj::from(stop_pos),
            Robj::from(stop_col),
        ],
    )
    .expect("gradients");
    let clip_paths = list!(
        xy = col_f32(&dl.cp_xy),
        run_offset = col_uint(&dl.cp_run_off),
        path_offset = col_uint(&dl.cp_path_off),
        evenodd = col_u8(&dl.cp_evenodd)
    );
    let groups = list!(
        alpha = dl
            .groups
            .iter()
            .map(|gr| gr.alpha as f64)
            .collect::<Vec<f64>>(),
        parent = dl
            .groups
            .iter()
            .map(|gr| gr.parent as i32)
            .collect::<Vec<i32>>()
    );
    let out = with_field(out, "gradients", gradients.into());
    let out = with_field(out, "clip_paths", clip_paths.into());
    with_field(out, "groups", groups.into())
}

impl Scene {
    /// Walk the scene through the display-list backend and encode the result.
    /// `keys` (VR-22): the caller's key table for `record$key` to index.
    pub(super) fn display_list(
        &self,
        panels: Option<Vec<String>>,
        version: u32,
        keys: Option<Vec<Option<String>>>,
    ) -> List {
        let mut b = DisplayListBackend::with_options(panels, version);
        let _ = self.render_to(&mut b);
        encode(
            b.finish(),
            self.w_px as f64,
            self.h_px as f64,
            keys.as_deref(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::key_refs;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn key_refs_without_given_is_identity() {
        let (refs, table) = key_refs(&s(&["a", "b"]), &[1, 0, 1], None);
        assert_eq!(refs, vec![1, 0, 1]);
        assert_eq!(table, s(&["a", "b"]));
    }

    #[test]
    fn key_refs_index_the_given_table_then_the_rest() {
        let given = vec![
            Some("x".to_string()),
            None,
            Some("b".to_string()),
            Some("a".to_string()),
            Some("b".to_string()),
        ];
        // "c" and "d" are not given: they follow the given table in first-use order.
        let (refs, table) = key_refs(&s(&["a", "c", "b", "d"]), &[0, 1, 2, 3, 0], Some(&given));
        assert_eq!(refs, vec![3, 5, 2, 6, 3]);
        assert_eq!(table, s(&["c", "d"]));
    }
}
