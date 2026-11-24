//! Tests against the bundled STIX Two Math. Reference values were read with
//! fontTools from the same file (v2.13b171).

use super::font::{math_font, MathFont};
use super::layout::assembly_offsets;
use super::table::Part;
use super::*;

fn stix() -> std::rc::Rc<MathFont> {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../inst/fonts/STIXTwoMath-Regular.otf"
    );
    math_font(path, 0).expect("bundled STIX Two Math loads")
}

fn approx(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

#[test]
fn constants_match_fonttools() {
    let f = stix();
    let c = &f.math.constants;
    assert_eq!(f.upem, 1000.0);
    assert_eq!(c.script_percent_scale_down, 70);
    assert_eq!(c.script_script_percent_scale_down, 55);
    assert_eq!(c.delimited_sub_formula_min_height, 1325);
    assert_eq!(c.display_operator_min_height, 1800);
    assert_eq!(c.math_leading, 150);
    assert_eq!(c.axis_height, 258);
    assert_eq!(c.accent_base_height, 480);
    assert_eq!(c.subscript_shift_down, 210);
    assert_eq!(c.subscript_top_max, 368);
    assert_eq!(c.superscript_shift_up, 360);
    assert_eq!(c.superscript_shift_up_cramped, 252);
    assert_eq!(c.superscript_bottom_min, 120);
    assert_eq!(c.sub_superscript_gap_min, 150);
    assert_eq!(c.space_after_script, 40);
    assert_eq!(c.upper_limit_baseline_rise_min, 300);
    assert_eq!(c.lower_limit_baseline_drop_min, 670);
    assert_eq!(c.fraction_numerator_shift_up, 585);
    assert_eq!(c.fraction_numerator_display_style_shift_up, 640);
    assert_eq!(c.fraction_rule_thickness, 68);
    assert_eq!(c.fraction_num_display_style_gap_min, 150);
    assert_eq!(c.radical_vertical_gap, 85);
    assert_eq!(c.radical_display_style_vertical_gap, 170);
    assert_eq!(c.radical_rule_thickness, 68);
    assert_eq!(c.radical_extra_ascender, 78);
    assert_eq!(c.radical_kern_before_degree, 65);
    assert_eq!(c.radical_kern_after_degree, -335);
    assert_eq!(c.radical_degree_bottom_raise_percent, 55);
    assert_eq!(f.math.min_connector_overlap, 100);
}

#[test]
fn glyph_info_and_variants_match_fonttools() {
    let f = stix();
    let a = f.glyph('\u{1D44E}').unwrap(); // math italic a
    assert_eq!(a, 3326);
    assert_eq!(f.math.top_accent_attachment(a), Some(340));
    assert_eq!(f.math.italics_correction(f.glyph('\u{1D453}').unwrap()), 20); // italic f
    let int = f.glyph('∫').unwrap();
    assert_eq!(f.math.italics_correction(1699), 540); // display integral
    assert!(f.math.is_extended_shape(int));
    let paren = f.math.vertical(f.glyph('(').unwrap()).unwrap();
    assert_eq!(paren.variants.len(), 13);
    assert_eq!(paren.variants[0].advance, 933);
    assert_eq!(paren.variants[12].glyph, 1312);
    assert_eq!(paren.assembly.len(), 3);
    assert_eq!(
        paren.assembly[1],
        Part {
            glyph: 4861,
            start_connector: 1000,
            end_connector: 1000,
            full_advance: 1252,
            extender: true
        }
    );
    let sum = f.math.vertical(f.glyph('∑').unwrap()).unwrap();
    assert_eq!(
        sum.variants.iter().map(|v| v.glyph).collect::<Vec<_>>(),
        vec![1646, 1647]
    );
    assert!(sum.assembly.is_empty());
    let hat = f.math.horizontal(f.glyph('\u{0302}').unwrap()).unwrap();
    assert_eq!(hat.variants.len(), 6);
    assert_eq!(hat.variants[5].advance, 2385);
    // Exact ink bounds (fontTools BoundsPen): parenleft (45, -196, 327, 736).
    let b = f.bounds(1064);
    assert_eq!(
        (b.0.round(), b.1.round(), b.2.round(), b.3.round()),
        (45.0, -196.0, 327.0, 736.0)
    );
    // ssty: script and scriptscript alternates exist and differ from the base.
    let g_a = f.glyph('A').unwrap();
    assert_ne!(f.script_variant(g_a, 1), g_a);
    assert_ne!(f.script_variant(g_a, 2), f.script_variant(g_a, 1));
    assert_eq!(f.script_variant(g_a, 0), g_a);
}

#[test]
fn non_math_font_is_rejected() {
    // A file that is not a font at all.
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/Cargo.toml");
    assert!(math_font(path, 0).is_err());
}

fn glyph_of(m: &Formula, ch: char) -> &Glyph {
    m.glyphs.iter().find(|g| g.ch == ch).expect("glyph present")
}

#[test]
fn superscript_shift_follows_constants() {
    let f = stix();
    let m = typeset("x^2", &f, 10.0, false).unwrap();
    let two = glyph_of(&m, '2');
    // Character base: shift = max(SuperscriptShiftUp, d(2) + BottomMin)
    // = max(360, 0 + 120) font units at 10pt.
    assert!(approx(two.y, 3.6), "sup shift {}", two.y);
    assert!(approx(two.size, 7.0), "script size {}", two.size);
    // Cramped (inside a denominator the style is cramped).
    let m = typeset("\\frac{1}{x^2}", &f, 10.0, false).unwrap();
    let ys: Vec<f64> = m.glyphs.iter().map(|g| g.y).collect();
    let x = m.glyphs.iter().position(|g| g.ch == '\u{1D465}').unwrap();
    let two = m.glyphs.iter().rposition(|g| g.ch == '2').unwrap();
    // scriptscript level inside a text-style denominator's script: the
    // shift is the cramped one at script size (252 * 0.7 / 100 pt).
    assert!(
        approx(ys[two] - ys[x], 252.0 * 0.007),
        "cramped sup {}",
        ys[two] - ys[x]
    );
}

#[test]
fn subscript_and_both_scripts() {
    let f = stix();
    let m = typeset("x_i", &f, 10.0, false).unwrap();
    let i = glyph_of(&m, '\u{1D456}');
    assert!(approx(i.y, -2.1), "sub shift {}", i.y); // SubscriptShiftDown 210
    let m = typeset("x_i^2", &f, 10.0, false).unwrap();
    let two = glyph_of(&m, '2');
    let i = glyph_of(&m, '\u{1D456}');
    // The gap between the superscript's bottom and the subscript's top is
    // at least SubSuperscriptGapMin.
    let k7 = 7.0 / 1000.0;
    let (_, y0, _, _) = f.bounds(two.gid);
    let (_, _, _, y1) = f.bounds(i.gid);
    let gap = (two.y + y0 * k7) - (i.y + y1 * k7);
    assert!(gap >= 1.5 - 1e-9, "sub/sup gap {gap}");
}

#[test]
fn fraction_rule_and_gaps_follow_constants() {
    let f = stix();
    for (display, gap_min) in [(false, 68.0), (true, 150.0)] {
        let m = typeset("\\frac{a}{b}", &f, 10.0, display).unwrap();
        assert_eq!(m.rules.len(), 1);
        let r = &m.rules[0];
        assert!(approx(r.h, 0.68), "bar thickness {}", r.h);
        // The bar is centred on the math axis.
        assert!(
            approx(r.y + r.h / 2.0, 2.58),
            "bar centre {}",
            r.y + r.h / 2.0
        );
        let a = glyph_of(&m, '\u{1D44E}');
        let b = glyph_of(&m, '\u{1D44F}');
        let k = a.size / 1000.0;
        let (_, ay0, _, _) = f.bounds(a.gid);
        let (_, _, _, by1) = f.bounds(b.gid);
        let above = (a.y + ay0 * k) - (r.y + r.h);
        let below = r.y - (b.y + by1 * k);
        assert!(above >= gap_min / 100.0 - 1e-9, "num gap {above}");
        assert!(below >= gap_min / 100.0 - 1e-9, "den gap {below}");
        // Display numerators are text size; text-style ones script size.
        assert!(approx(a.size, if display { 10.0 } else { 7.0 }));
        // The bar spans the wider part, with null-delimiter padding.
        assert!(approx(r.x, 1.2));
        assert!(approx(m.width, r.w + 2.4));
    }
}

#[test]
fn radical_covers_body_with_gap() {
    let f = stix();
    let m = typeset("\\sqrt{x}", &f, 10.0, false).unwrap();
    assert_eq!(m.rules.len(), 1);
    let r = &m.rules[0];
    assert!(approx(r.h, 0.68));
    let x = glyph_of(&m, '\u{1D465}');
    let (_, _, _, xy1) = f.bounds(x.gid);
    assert!(
        r.y - xy1 / 100.0 >= 0.85 - 1e-9,
        "radical gap {}",
        r.y - xy1 / 100.0
    );
    // The rule starts where the radical sign's advance ends and covers x.
    let rad = glyph_of(&m, '√');
    assert!(approx(r.x, rad.x + f.advance(rad.gid) / 100.0));
    assert!(r.x <= x.x + 1e-9);
    // Its top meets the radical glyph's top.
    let (_, _, _, ry1) = f.bounds(rad.gid);
    assert!(approx(rad.y + ry1 / 100.0, r.y + r.h));
    // An index is set in scriptscript size, to the left.
    let m = typeset("\\sqrt[3]{x}", &f, 10.0, false).unwrap();
    let three = glyph_of(&m, '3');
    assert!(approx(three.size, 5.5));
    // It sits over the radical's left arm, before the overbar starts.
    assert!(three.x + f.advance(three.gid) * 0.0055 < m.rules[0].x);
    assert!(three.y > 0.0);
}

#[test]
fn delimiters_grow_with_content() {
    let f = stix();
    let height_of = |src: &str| {
        let m = typeset(src, &f, 10.0, false).unwrap();
        let open: Vec<&Glyph> = m
            .glyphs
            .iter()
            .filter(|g| g.ch == '(' || g.ch == '\u{200B}')
            .collect();
        let mut top = f64::NEG_INFINITY;
        let mut bot = f64::INFINITY;
        for g in &open {
            let (_, y0, _, y1) = f.bounds(g.gid);
            top = top.max(g.y + y1 / 100.0);
            bot = bot.min(g.y + y0 / 100.0);
        }
        (top - bot, open[0].gid)
    };
    let (h1, g1) = height_of("\\left( x \\right)");
    let (h2, g2) = height_of("\\left( \\frac{a}{b} \\right)");
    let (h3, _) = height_of("\\left( \\frac{\\frac{a}{b}}{\\frac{c}{d}} \\right)");
    assert_eq!(
        g1,
        f.glyph('(').unwrap(),
        "small content keeps the base glyph"
    );
    assert_ne!(g2, g1, "a fraction needs a bigger variant");
    assert!(h1 < h2 && h2 < h3, "{h1} < {h2} < {h3}");
    // Way past the largest variant, an assembly is used.
    let m = typeset(
        "\\left( \\frac{\\frac{\\frac{a}{b}}{\\frac{c}{d}}}{\\frac{\\frac{a}{b}}{\\frac{c}{d}}} \\right.",
        &f,
        40.0,
        true,
    )
    .unwrap();
    assert!(
        m.glyphs.iter().any(|g| g.ch == '\u{200B}'),
        "assembly pieces"
    );
    // Delimiters are centred on the axis.
    let m = typeset("\\left( \\frac{a}{b} \\right)", &f, 10.0, false).unwrap();
    let p = glyph_of(&m, '(');
    let (_, y0, _, y1) = f.bounds(p.gid);
    let mid = p.y + (y0 + y1) / 200.0;
    assert!((mid - 2.58).abs() < 0.3, "delimiter centre {mid}");
}

#[test]
fn display_operators_and_limits() {
    let f = stix();
    let t = typeset("\\sum_{i=1}^n", &f, 10.0, false).unwrap();
    let d = typeset("\\sum_{i=1}^n", &f, 10.0, true).unwrap();
    assert_eq!(glyph_of(&t, '∑').gid, 1646);
    assert_eq!(glyph_of(&d, '∑').gid, 1647, "display variant");
    // Text style: scripts to the right; display: limits centred over it.
    let n_t = glyph_of(&t, '\u{1D45B}');
    let s_t = glyph_of(&t, '∑');
    assert!(n_t.x > s_t.x + f.advance(s_t.gid) / 100.0 - 1e-9);
    let n_d = glyph_of(&d, '\u{1D45B}');
    let s_d = glyph_of(&d, '∑');
    assert!(n_d.x > s_d.x && n_d.x < s_d.x + f.advance(s_d.gid) / 100.0);
    assert!(n_d.y > 0.0);
    // Integrals keep their scripts at the side, even in display style.
    let i = typeset("\\int_0^1", &f, 10.0, true).unwrap();
    let int = glyph_of(&i, '∫');
    assert_eq!(int.gid, 1699);
    assert!(glyph_of(&i, '1').x > int.x + 1.0);
    // \lim: limits below in display style.
    let l = typeset("\\lim_{x \\to 0}", &f, 10.0, true).unwrap();
    assert!(glyph_of(&l, '0').y < -2.0);
}

#[test]
fn spacing_classes() {
    use super::layout::spacing;
    use super::symbols::Class::*;
    assert_eq!(spacing(Ord, Rel, false), 5.0);
    assert_eq!(spacing(Ord, Rel, true), 0.0);
    assert_eq!(spacing(Ord, Bin, false), 4.0);
    assert_eq!(spacing(Op, Ord, true), 3.0);
    assert_eq!(spacing(Open, Ord, false), 0.0);
    let f = stix();
    // Unary minus is an Ord: "-x" is tighter than "a-x".
    let unary = typeset("-x", &f, 10.0, false).unwrap();
    let binary = typeset("a-x", &f, 10.0, false).unwrap();
    let gap = |m: &Formula| {
        let minus = glyph_of(m, '−');
        glyph_of(m, '\u{1D465}').x - (minus.x + f.advance(minus.gid) / 100.0)
    };
    assert!(approx(gap(&unary), 0.0));
    assert!(approx(gap(&binary), 4.0 * 10.0 / 18.0));
}

#[test]
fn ink_extents_cover_everything() {
    let f = stix();
    for src in [
        "E = mc^2",
        "\\frac{a}{b}",
        "\\sqrt{x^2+1}",
        "\\int_0^\\infty e^{-x}\\,dx",
        "",
    ] {
        let m = typeset(src, &f, 12.0, true).unwrap();
        for g in &m.glyphs {
            let (_, y0, _, y1) = f.bounds(g.gid);
            let k = g.size / 1000.0;
            if y0 == 0.0 && y1 == 0.0 {
                continue;
            }
            assert!(g.y + y1 * k <= m.ascent + 1e-9, "{src}");
            assert!(g.y + y0 * k >= -m.depth - 1e-9, "{src}");
        }
        for r in &m.rules {
            assert!(r.y + r.h <= m.ascent + 1e-9 && r.y >= -m.depth - 1e-9);
        }
    }
}

#[test]
fn assembly_reaches_target_with_legal_overlaps() {
    let parts = [
        Part {
            glyph: 1,
            start_connector: 0,
            end_connector: 250,
            full_advance: 1273,
            extender: false,
        },
        Part {
            glyph: 2,
            start_connector: 1000,
            end_connector: 1000,
            full_advance: 1252,
            extender: true,
        },
        Part {
            glyph: 3,
            start_connector: 250,
            end_connector: 0,
            full_advance: 1273,
            extender: false,
        },
    ];
    for target in [2000.0, 3000.0, 5000.0, 9000.0] {
        let placed = assembly_offsets(&parts, target, 100.0);
        let last = placed.last().unwrap();
        let len = last.1 + 1273.0;
        assert!(len >= target - 1e-6, "{len} < {target}");
        for w in placed.windows(2) {
            let adv = if w[0].0 == 1 { 1273.0 } else { 1252.0 };
            let overlap = w[0].1 + adv - w[1].1;
            assert!(overlap >= 100.0 - 1e-6, "overlap {overlap}");
        }
    }
}

#[test]
fn every_subset_command_lays_out() {
    let f = stix();
    let srcs = [
        "\\alpha\\beta\\gamma\\Gamma\\Delta\\varepsilon\\varphi\\omega\\Omega",
        "a \\pm b \\mp c \\times d \\div e \\cdot f \\ast g",
        "a \\leq b \\geq c \\neq d \\approx e \\sim f \\simeq g \\equiv h \\propto i",
        "x \\in A \\notin B \\subset C \\subseteq D \\cup E \\cap F",
        "a \\to b \\rightarrow c \\leftarrow d \\Rightarrow e \\Leftrightarrow f \\mapsto g",
        "\\infty \\partial \\nabla \\forall \\exists \\ldots \\cdots \\prime 90\\degree",
        "\\sum \\prod \\int \\oint \\lim \\max \\min \\sup \\inf \\log \\exp \\sin \\cos \\tan \\ln",
        "\\left. \\frac{a}{b} \\right| \\left[ x \\right] \\left\\{ y \\right\\} \\left\\| z \\right\\| \\left\\langle w \\right\\rangle",
        "\\mathrm{d}x \\mathbf{v} \\mathit{it} \\mathsf{S} \\mathcal{L} \\mathbb{R} \\text{if } x > 0",
        "\\hat{a} \\bar{x} \\tilde{n} \\vec{v} \\dot{x} \\ddot{y} \\overline{AB} \\underline{z} \\widehat{xyz}",
        "a\\,b\\:c\\;d\\!e\\quad f\\qquad g~h",
        "f'(x) + f''(x) = x'^2",
        "\\displaystyle\\sum_{n=1}^\\infty \\frac{1}{n^2} = \\frac{\\pi^2}{6}",
        "\\binom{n}{k} \\sqrt[n]{x} \\dfrac{1}{2} \\tfrac{3}{4}",
    ];
    for s in srcs {
        let m = typeset(s, &f, 10.0, false).unwrap_or_else(|e| panic!("{s}: {e:?}"));
        assert!(m.width > 0.0, "{s}");
        assert!(!m.glyphs.iter().any(|g| g.gid == 0), "notdef in {s}");
    }
}
