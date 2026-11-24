//! A small reader over the raw bytes of the OpenType `MATH` table.
//!
//! read-fonts (vendored at 0.39) has no `MATH` support, so this walks the
//! table directly. Only what the layout needs is read: the constants, the
//! italics-correction and top-accent-attachment lists, the extended-shape
//! coverage, and the vertical/horizontal size variants with their glyph
//! assemblies. Math kerning is not read (phase 1 positions scripts by the
//! constants and italic correction only).
//!
//! Every read is bounds-checked: a truncated or malformed table yields `None`
//! (or a zero) rather than a panic, so a broken user font can't take the R
//! session down.

/// Big-endian reader over a byte slice. Out-of-range reads return `None`.
#[derive(Clone, Copy)]
struct Bytes<'a>(&'a [u8]);

impl<'a> Bytes<'a> {
    fn u16(&self, at: usize) -> Option<u16> {
        let b = self.0.get(at..at + 2)?;
        Some(u16::from_be_bytes([b[0], b[1]]))
    }
    fn i16(&self, at: usize) -> Option<i16> {
        self.u16(at).map(|v| v as i16)
    }
    /// A sub-table at a 16-bit offset stored at `at` (relative to `base`).
    /// A zero offset means "absent".
    fn sub(&self, base: usize, at: usize) -> Option<usize> {
        let off = self.u16(at)? as usize;
        if off == 0 {
            None
        } else {
            Some(base + off)
        }
    }
}

/// The `MathConstants` record, in font units (percentages as given).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MathConstants {
    pub script_percent_scale_down: i16,
    pub script_script_percent_scale_down: i16,
    pub delimited_sub_formula_min_height: i16,
    pub display_operator_min_height: i16,
    pub math_leading: i16,
    pub axis_height: i16,
    pub accent_base_height: i16,
    pub flattened_accent_base_height: i16,
    pub subscript_shift_down: i16,
    pub subscript_top_max: i16,
    pub subscript_baseline_drop_min: i16,
    pub superscript_shift_up: i16,
    pub superscript_shift_up_cramped: i16,
    pub superscript_bottom_min: i16,
    pub superscript_baseline_drop_max: i16,
    pub sub_superscript_gap_min: i16,
    pub superscript_bottom_max_with_subscript: i16,
    pub space_after_script: i16,
    pub upper_limit_gap_min: i16,
    pub upper_limit_baseline_rise_min: i16,
    pub lower_limit_gap_min: i16,
    pub lower_limit_baseline_drop_min: i16,
    pub stack_top_shift_up: i16,
    pub stack_top_display_style_shift_up: i16,
    pub stack_bottom_shift_down: i16,
    pub stack_bottom_display_style_shift_down: i16,
    pub stack_gap_min: i16,
    pub stack_display_style_gap_min: i16,
    pub stretch_stack_top_shift_up: i16,
    pub stretch_stack_bottom_shift_down: i16,
    pub stretch_stack_gap_above_min: i16,
    pub stretch_stack_gap_below_min: i16,
    pub fraction_numerator_shift_up: i16,
    pub fraction_numerator_display_style_shift_up: i16,
    pub fraction_denominator_shift_down: i16,
    pub fraction_denominator_display_style_shift_down: i16,
    pub fraction_numerator_gap_min: i16,
    pub fraction_num_display_style_gap_min: i16,
    pub fraction_rule_thickness: i16,
    pub fraction_denominator_gap_min: i16,
    pub fraction_denom_display_style_gap_min: i16,
    pub skewed_fraction_horizontal_gap: i16,
    pub skewed_fraction_vertical_gap: i16,
    pub overbar_vertical_gap: i16,
    pub overbar_rule_thickness: i16,
    pub overbar_extra_ascender: i16,
    pub underbar_vertical_gap: i16,
    pub underbar_rule_thickness: i16,
    pub underbar_extra_descender: i16,
    pub radical_vertical_gap: i16,
    pub radical_display_style_vertical_gap: i16,
    pub radical_rule_thickness: i16,
    pub radical_extra_ascender: i16,
    pub radical_kern_before_degree: i16,
    pub radical_kern_after_degree: i16,
    pub radical_degree_bottom_raise_percent: i16,
}

impl MathConstants {
    /// Parse the constants record starting at `at`.
    fn read(b: Bytes, at: usize) -> Option<MathConstants> {
        // Four plain int16s, then 51 MathValueRecords (value + device offset,
        // 4 bytes each), then one int16.
        let i = |k: usize| b.i16(at + 2 * k);
        let v = |k: usize| b.i16(at + 8 + 4 * k);
        let mut vals = [0i16; 51];
        for (k, slot) in vals.iter_mut().enumerate() {
            *slot = v(k)?;
        }
        let [math_leading, axis_height, accent_base_height, flattened_accent_base_height, subscript_shift_down, subscript_top_max, subscript_baseline_drop_min, superscript_shift_up, superscript_shift_up_cramped, superscript_bottom_min, superscript_baseline_drop_max, sub_superscript_gap_min, superscript_bottom_max_with_subscript, space_after_script, upper_limit_gap_min, upper_limit_baseline_rise_min, lower_limit_gap_min, lower_limit_baseline_drop_min, stack_top_shift_up, stack_top_display_style_shift_up, stack_bottom_shift_down, stack_bottom_display_style_shift_down, stack_gap_min, stack_display_style_gap_min, stretch_stack_top_shift_up, stretch_stack_bottom_shift_down, stretch_stack_gap_above_min, stretch_stack_gap_below_min, fraction_numerator_shift_up, fraction_numerator_display_style_shift_up, fraction_denominator_shift_down, fraction_denominator_display_style_shift_down, fraction_numerator_gap_min, fraction_num_display_style_gap_min, fraction_rule_thickness, fraction_denominator_gap_min, fraction_denom_display_style_gap_min, skewed_fraction_horizontal_gap, skewed_fraction_vertical_gap, overbar_vertical_gap, overbar_rule_thickness, overbar_extra_ascender, underbar_vertical_gap, underbar_rule_thickness, underbar_extra_descender, radical_vertical_gap, radical_display_style_vertical_gap, radical_rule_thickness, radical_extra_ascender, radical_kern_before_degree, radical_kern_after_degree] =
            vals;
        Some(MathConstants {
            script_percent_scale_down: i(0)?,
            script_script_percent_scale_down: i(1)?,
            delimited_sub_formula_min_height: i(2)?,
            display_operator_min_height: i(3)?,
            math_leading,
            axis_height,
            accent_base_height,
            flattened_accent_base_height,
            subscript_shift_down,
            subscript_top_max,
            subscript_baseline_drop_min,
            superscript_shift_up,
            superscript_shift_up_cramped,
            superscript_bottom_min,
            superscript_baseline_drop_max,
            sub_superscript_gap_min,
            superscript_bottom_max_with_subscript,
            space_after_script,
            upper_limit_gap_min,
            upper_limit_baseline_rise_min,
            lower_limit_gap_min,
            lower_limit_baseline_drop_min,
            stack_top_shift_up,
            stack_top_display_style_shift_up,
            stack_bottom_shift_down,
            stack_bottom_display_style_shift_down,
            stack_gap_min,
            stack_display_style_gap_min,
            stretch_stack_top_shift_up,
            stretch_stack_bottom_shift_down,
            stretch_stack_gap_above_min,
            stretch_stack_gap_below_min,
            fraction_numerator_shift_up,
            fraction_numerator_display_style_shift_up,
            fraction_denominator_shift_down,
            fraction_denominator_display_style_shift_down,
            fraction_numerator_gap_min,
            fraction_num_display_style_gap_min,
            fraction_rule_thickness,
            fraction_denominator_gap_min,
            fraction_denom_display_style_gap_min,
            skewed_fraction_horizontal_gap,
            skewed_fraction_vertical_gap,
            overbar_vertical_gap,
            overbar_rule_thickness,
            overbar_extra_ascender,
            underbar_vertical_gap,
            underbar_rule_thickness,
            underbar_extra_descender,
            radical_vertical_gap,
            radical_display_style_vertical_gap,
            radical_rule_thickness,
            radical_extra_ascender,
            radical_kern_before_degree,
            radical_kern_after_degree,
            radical_degree_bottom_raise_percent: i(4 + 2 * 51)?,
        })
    }
}

/// One size variant of a stretchy glyph: the glyph and its full advance along
/// the stretch direction (height for vertical, width for horizontal).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Variant {
    pub glyph: u16,
    pub advance: u16,
}

/// One piece of a glyph assembly (bottom-to-top or left-to-right).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Part {
    pub glyph: u16,
    pub start_connector: u16,
    pub end_connector: u16,
    pub full_advance: u16,
    pub extender: bool,
}

/// The size variants of one glyph, plus its assembly when the font has one.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Construction {
    pub variants: Vec<Variant>,
    pub assembly: Vec<Part>,
}

/// The parsed parts of a `MATH` table the layout uses. The table bytes are
/// kept so the per-glyph lookups (coverage searches) stay lazy.
pub struct MathTable {
    data: Vec<u8>,
    pub constants: MathConstants,
    italics: Option<usize>,
    top_accent: Option<usize>,
    extended: Option<usize>,
    pub min_connector_overlap: u16,
    variants: Option<usize>,
}

impl MathTable {
    /// Parse a `MATH` table from its raw bytes. `None` if the header or the
    /// constants are unreadable (glyph info and variants are optional).
    pub fn parse(data: &[u8]) -> Option<MathTable> {
        let b = Bytes(data);
        let major = b.u16(0)?;
        if major != 1 {
            return None;
        }
        let constants = MathConstants::read(b, b.sub(0, 4)?)?;
        let glyph_info = b.sub(0, 6);
        let variants = b.sub(0, 8);
        let (italics, top_accent, extended) = match glyph_info {
            Some(gi) => (b.sub(gi, gi), b.sub(gi, gi + 2), b.sub(gi, gi + 4)),
            None => (None, None, None),
        };
        let min_connector_overlap = variants.and_then(|v| b.u16(v)).unwrap_or(0);
        Some(MathTable {
            data: data.to_vec(),
            constants,
            italics,
            top_accent,
            extended,
            min_connector_overlap,
            variants,
        })
    }

    fn b(&self) -> Bytes<'_> {
        Bytes(&self.data)
    }

    /// Italics correction of `glyph` (font units), 0 when the font lists none.
    pub fn italics_correction(&self, glyph: u16) -> i16 {
        self.italics
            .and_then(|t| self.value_list(t, glyph))
            .unwrap_or(0)
    }

    /// Top-accent attachment x of `glyph` (font units), if the font lists one.
    pub fn top_accent_attachment(&self, glyph: u16) -> Option<i16> {
        self.top_accent.and_then(|t| self.value_list(t, glyph))
    }

    /// Is `glyph` an "extended shape" (a big operator or a tall variant whose
    /// scripts attach by its box rather than as a single character)?
    pub fn is_extended_shape(&self, glyph: u16) -> bool {
        self.extended
            .and_then(|c| coverage_index(self.b(), c, glyph))
            .is_some()
    }

    /// A `{coverage, count, MathValueRecord[count]}` list lookup.
    fn value_list(&self, at: usize, glyph: u16) -> Option<i16> {
        let b = self.b();
        let cov = b.sub(at, at)?;
        let count = b.u16(at + 2)? as usize;
        let idx = coverage_index(b, cov, glyph)?;
        if idx >= count {
            return None;
        }
        b.i16(at + 4 + 4 * idx)
    }

    /// Size variants and assembly for `glyph` growing vertically.
    pub fn vertical(&self, glyph: u16) -> Option<Construction> {
        self.construction(glyph, true)
    }

    /// Size variants and assembly for `glyph` growing horizontally.
    pub fn horizontal(&self, glyph: u16) -> Option<Construction> {
        self.construction(glyph, false)
    }

    fn construction(&self, glyph: u16, vertical: bool) -> Option<Construction> {
        let b = self.b();
        let v = self.variants?;
        let vcount = b.u16(v + 6)? as usize;
        let (cov_at, list_at) = if vertical {
            (v + 2, v + 10)
        } else {
            (v + 4, v + 10 + 2 * vcount)
        };
        let count = b.u16(if vertical { v + 6 } else { v + 8 })? as usize;
        let cov = b.sub(v, cov_at)?;
        let idx = coverage_index(b, cov, glyph)?;
        if idx >= count {
            return None;
        }
        let con = b.sub(v, list_at + 2 * idx)?;
        let nvar = b.u16(con + 2)? as usize;
        let mut variants = Vec::with_capacity(nvar);
        for k in 0..nvar {
            let r = con + 4 + 4 * k;
            variants.push(Variant {
                glyph: b.u16(r)?,
                advance: b.u16(r + 2)?,
            });
        }
        let mut assembly = Vec::new();
        if let Some(asm) = b.sub(con, con) {
            // italicsCorrection (MathValueRecord, 4 bytes), partCount, parts.
            let nparts = b.u16(asm + 4)? as usize;
            for k in 0..nparts {
                let r = asm + 6 + 10 * k;
                assembly.push(Part {
                    glyph: b.u16(r)?,
                    start_connector: b.u16(r + 2)?,
                    end_connector: b.u16(r + 4)?,
                    full_advance: b.u16(r + 6)?,
                    extender: b.u16(r + 8)? & 1 == 1,
                });
            }
        }
        Some(Construction { variants, assembly })
    }
}

/// Index of `glyph` in the coverage table at `at` (format 1 or 2), if covered.
fn coverage_index(b: Bytes, at: usize, glyph: u16) -> Option<usize> {
    match b.u16(at)? {
        1 => {
            let n = b.u16(at + 2)? as usize;
            // Glyph array is sorted: binary search.
            let (mut lo, mut hi) = (0usize, n);
            while lo < hi {
                let mid = (lo + hi) / 2;
                let g = b.u16(at + 4 + 2 * mid)?;
                match g.cmp(&glyph) {
                    std::cmp::Ordering::Less => lo = mid + 1,
                    std::cmp::Ordering::Greater => hi = mid,
                    std::cmp::Ordering::Equal => return Some(mid),
                }
            }
            None
        }
        2 => {
            let n = b.u16(at + 2)? as usize;
            let (mut lo, mut hi) = (0usize, n);
            while lo < hi {
                let mid = (lo + hi) / 2;
                let r = at + 4 + 6 * mid;
                let (start, end) = (b.u16(r)?, b.u16(r + 2)?);
                if glyph < start {
                    hi = mid;
                } else if glyph > end {
                    lo = mid + 1;
                } else {
                    let first = b.u16(r + 4)? as usize;
                    return Some(first + (glyph - start) as usize);
                }
            }
            None
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn coverage_formats() {
        // Format 1: glyphs 3, 7, 9.
        let f1 = [0, 1, 0, 3, 0, 3, 0, 7, 0, 9];
        assert_eq!(coverage_index(Bytes(&f1), 0, 7), Some(1));
        assert_eq!(coverage_index(Bytes(&f1), 0, 8), None);
        // Format 2: range 10..=12 starting at coverage index 5.
        let f2 = [0, 2, 0, 1, 0, 10, 0, 12, 0, 5];
        assert_eq!(coverage_index(Bytes(&f2), 0, 11), Some(6));
        assert_eq!(coverage_index(Bytes(&f2), 0, 13), None);
    }

    #[test]
    fn truncated_table_is_none_not_panic() {
        assert!(MathTable::parse(&[]).is_none());
        assert!(MathTable::parse(&[0, 1, 0, 0, 0, 10]).is_none());
    }
}
