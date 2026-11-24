//! TeX-style math layout over an OpenType MATH font.
//!
//! The algorithms follow the TeXbook's Appendix G as adapted to OpenType
//! math by LuaTeX/XeTeX: every shift and gap comes from the font's
//! `MathConstants`, glyph growth from its size variants and assemblies. All
//! lengths here are points, y up, baseline at 0.

use super::font::MathFont;
use super::parse::{ForceStyle, Node, Space};
use super::symbols::{Class, Limits};
use super::table::{Corner, MathConstants, Part};

/// TeX's \nulldelimiterspace (1.2pt at 10pt), as a fraction of the base size.
const NULL_DELIMITER_EM: f64 = 0.12;
/// TeX's \delimiterfactor / 1000 and \delimitershortfall (5pt at 10pt, in em).
const DELIMITER_FACTOR: f64 = 0.901;
const DELIMITER_SHORTFALL_EM: f64 = 0.5;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Display,
    Text,
    Script,
    ScriptScript,
}

/// A math style: a level plus TeX's "cramped" flag (cramped styles raise
/// superscripts less).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Style {
    pub level: Level,
    pub cramped: bool,
}

impl Style {
    pub fn new(display: bool) -> Style {
        Style {
            level: if display { Level::Display } else { Level::Text },
            cramped: false,
        }
    }
    fn with(self, level: Level) -> Style {
        Style { level, ..self }
    }
    fn cramp(self) -> Style {
        Style {
            cramped: true,
            ..self
        }
    }
    fn script_level(self) -> Level {
        match self.level {
            Level::Display | Level::Text => Level::Script,
            _ => Level::ScriptScript,
        }
    }
    fn sup(self) -> Style {
        self.with(self.script_level())
    }
    fn sub(self) -> Style {
        self.with(self.script_level()).cramp()
    }
    fn num(self) -> Style {
        let l = match self.level {
            Level::Display => Level::Text,
            Level::Text => Level::Script,
            _ => Level::ScriptScript,
        };
        self.with(l)
    }
    fn den(self) -> Style {
        self.num().cramp()
    }
    fn is_display(self) -> bool {
        self.level == Level::Display
    }
    fn is_script(self) -> bool {
        matches!(self.level, Level::Script | Level::ScriptScript)
    }
    /// 0 for display/text, 1 script, 2 scriptscript (the `ssty` level).
    fn ssty(self) -> u8 {
        match self.level {
            Level::Display | Level::Text => 0,
            Level::Script => 1,
            Level::ScriptScript => 2,
        }
    }
}

/// A positioned glyph in points. `ch` is the character the glyph came from
/// (for PDF text extraction); assembly pieces after the first carry U+200B.
#[derive(Clone, Debug, PartialEq)]
pub struct Glyph {
    pub gid: u16,
    pub x: f64,
    pub y: f64,
    pub size: f64,
    pub ch: char,
}

/// A filled rectangle in points; `y` is its bottom edge.
#[derive(Clone, Debug, PartialEq)]
pub struct Rule {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

/// A laid-out box: width, height above and depth below the baseline, its
/// content, plus what scripts and accents need to know about it.
#[derive(Clone, Debug, Default)]
pub struct MBox {
    pub w: f64,
    pub h: f64,
    pub d: f64,
    pub glyphs: Vec<Glyph>,
    pub rules: Vec<Rule>,
    /// Italic correction (points) when the box is a single glyph.
    pub ic: f64,
    /// Top-accent attachment x (points) when the box is a single glyph.
    pub accent_x: Option<f64>,
    /// A single character from the font (TeX's "character box"), which
    /// attaches scripts at the font's fixed shifts.
    pub is_char: bool,
}

impl MBox {
    /// Append `other`'s content shifted by (dx, dy). Extents are not updated.
    fn put(&mut self, other: &MBox, dx: f64, dy: f64) {
        for g in &other.glyphs {
            self.glyphs.push(Glyph {
                x: g.x + dx,
                y: g.y + dy,
                ..g.clone()
            });
        }
        for r in &other.rules {
            self.rules.push(Rule {
                x: r.x + dx,
                y: r.y + dy,
                ..r.clone()
            });
        }
    }
    /// Grow height/depth to include `other` placed at vertical shift `dy`.
    fn cover(&mut self, other: &MBox, dy: f64) {
        self.h = self.h.max(other.h + dy);
        self.d = self.d.max(other.d - dy);
    }
    /// Move all content (and the extents) by `dy`.
    fn shift(&mut self, dy: f64) {
        for g in &mut self.glyphs {
            g.y += dy;
        }
        for r in &mut self.rules {
            r.y += dy;
        }
        self.h += dy;
        self.d -= dy;
    }
}

/// One element of a horizontal list: an atom with its class, or a kern.
enum Item {
    Atom(Class, MBox),
    Kern(f64),
}

pub struct Ctx<'a> {
    pub font: &'a MathFont,
    /// Base size in points (text/display style).
    pub size: f64,
    /// Characters the font has no glyph for (drawn as `.notdef`).
    pub missing: std::cell::RefCell<Vec<char>>,
}

impl<'a> Ctx<'a> {
    pub fn new(font: &'a MathFont, size: f64) -> Ctx<'a> {
        Ctx {
            font,
            size,
            missing: std::cell::RefCell::new(Vec::new()),
        }
    }

    /// The nominal glyph for `ch`, or `.notdef` (0), remembering the miss.
    fn gid_of(&self, ch: char) -> u16 {
        match self.font.glyph(ch) {
            Some(g) => g,
            None => {
                let mut m = self.missing.borrow_mut();
                if !m.contains(&ch) {
                    m.push(ch);
                }
                0
            }
        }
    }

    fn c(&self) -> &MathConstants {
        &self.font.math.constants
    }
    /// Font size (points) of a style.
    fn size_of(&self, st: Style) -> f64 {
        let c = self.c();
        let pct = |v: i16, fallback: f64| if v > 0 { v as f64 / 100.0 } else { fallback };
        match st.level {
            Level::Display | Level::Text => self.size,
            Level::Script => self.size * pct(c.script_percent_scale_down, 0.7),
            Level::ScriptScript => self.size * pct(c.script_script_percent_scale_down, 0.5),
        }
    }
    /// Points per font unit in a style.
    fn k(&self, st: Style) -> f64 {
        self.size_of(st) / self.font.upem
    }
    /// A constant (font units) scaled to a style.
    fn v(&self, st: Style, f: impl Fn(&MathConstants) -> i16) -> f64 {
        f(self.c()) as f64 * self.k(st)
    }
    fn mu(&self, st: Style) -> f64 {
        self.size_of(st) / 18.0
    }

    /// A box holding glyph `gid` at style `st`'s size, extents from its ink.
    fn glyph_box(&self, gid: u16, ch: char, st: Style) -> MBox {
        let k = self.k(st);
        let (_, y0, _, y1) = self.font.bounds(gid);
        MBox {
            w: self.font.advance(gid) * k,
            h: (y1 * k).max(0.0),
            d: (-y0 * k).max(0.0),
            glyphs: vec![Glyph {
                gid,
                x: 0.0,
                y: 0.0,
                size: self.size_of(st),
                ch,
            }],
            rules: Vec::new(),
            ic: self.font.math.italics_correction(gid) as f64 * k,
            accent_x: self
                .font
                .math
                .top_accent_attachment(gid)
                .map(|a| a as f64 * k),
            is_char: true,
        }
    }

    /// The glyph for `ch` (`.notdef` when the font lacks it), with the
    /// script-style alternate in script styles.
    fn char_box(&self, ch: char, st: Style) -> MBox {
        let gid = self.gid_of(ch);
        let gid = self.font.script_variant(gid, st.ssty());
        self.glyph_box(gid, ch, st)
    }

    /// The smallest vertical variant of `ch` at least `target` points tall,
    /// else a glyph assembly, else the largest variant.
    fn vertical(&self, ch: char, target: f64, st: Style) -> MBox {
        let gid = self.gid_of(ch);
        let k = self.k(st);
        let Some(con) = self.font.math.vertical(gid) else {
            return self.glyph_box(gid, ch, st);
        };
        for v in &con.variants {
            if v.advance as f64 * k >= target {
                let mut b = self.glyph_box(v.glyph, ch, st);
                // A grown variant (an extended shape) attaches scripts by
                // its box, not at a character's fixed shifts.
                b.is_char = !self.font.math.is_extended_shape(v.glyph) || v.glyph == gid;
                return b;
            }
        }
        if !con.assembly.is_empty() {
            return self.assemble(&con.assembly, target / k, ch, st, true);
        }
        match con.variants.last() {
            Some(v) => self.glyph_box(v.glyph, ch, st),
            None => self.glyph_box(gid, ch, st),
        }
    }

    /// The widest horizontal variant of `ch` no wider than `width` points
    /// (TeX's rule for `\\widehat`/`\\widetilde`), else the base glyph.
    fn widest_within(&self, ch: char, width: f64, st: Style) -> MBox {
        let gid = self.gid_of(ch);
        let k = self.k(st);
        let pick = self.font.math.horizontal(gid).and_then(|con| {
            con.variants
                .iter()
                .filter(|v| v.advance as f64 * k <= width)
                .max_by_key(|v| v.advance)
                .map(|v| v.glyph)
        });
        self.glyph_box(pick.unwrap_or(gid), ch, st)
    }

    /// Build a glyph assembly at least `target` font units long. Vertical
    /// assemblies start at y = 0 (parts bottom to top); horizontal ones at
    /// x = 0 (left to right).
    fn assemble(&self, parts: &[Part], target: f64, ch: char, st: Style, vertical: bool) -> MBox {
        let k = self.k(st);
        let placed = assembly_offsets(parts, target, self.font.math.min_connector_overlap as f64);
        let mut b = MBox::default();
        let size = self.size_of(st);
        for (i, (gid, off)) in placed.iter().enumerate() {
            let (x0, y0, x1, y1) = self.font.bounds(*gid);
            let (dx, dy) = if vertical {
                (0.0, off * k)
            } else {
                (off * k, 0.0)
            };
            b.glyphs.push(Glyph {
                gid: *gid,
                x: dx,
                y: dy,
                size,
                ch: if i == 0 { ch } else { '\u{200B}' },
            });
            b.h = b.h.max(y1 * k + dy);
            b.d = b.d.max(-(y0 * k + dy));
            if vertical {
                b.w = b.w.max(self.font.advance(*gid) * k).max(x1 * k);
            } else {
                b.w = b.w.max(dx + self.font.advance(*gid) * k);
                let _ = x0;
            }
        }
        b
    }

    // --- lists --------------------------------------------------------------

    /// Lay out a list of nodes as one horizontal box.
    pub fn hlist(&self, nodes: &[Node], st: Style) -> MBox {
        let items = self.items(nodes, st);
        join(items, st, self)
    }

    fn items(&self, nodes: &[Node], st: Style) -> Vec<Item> {
        let mut out = Vec::with_capacity(nodes.len());
        for n in nodes {
            match n {
                Node::Space(s) => out.push(Item::Kern(self.space(*s, st))),
                Node::Style(f, rest) => {
                    let st2 = forced(*f, st);
                    out.extend(self.items(rest, st2));
                }
                _ => {
                    let (class, b) = self.atom(n, st);
                    out.push(Item::Atom(class, b));
                }
            }
        }
        out
    }

    fn space(&self, s: Space, st: Style) -> f64 {
        match s {
            Space::Mu(m) => m * self.mu(st),
            Space::Word => self.word_space(st),
        }
    }

    fn word_space(&self, st: Style) -> f64 {
        match self.font.glyph(' ') {
            Some(g) => self.font.advance(g) * self.k(st),
            None => self.size_of(st) * 0.25,
        }
    }

    /// One node as an atom: its class and its box.
    fn atom(&self, n: &Node, st: Style) -> (Class, MBox) {
        match n {
            Node::Char { ch, class } => (*class, self.char_box(*ch, st)),
            Node::Group(list) => {
                let mut b = self.hlist(list, st);
                b.is_char = false;
                (Class::Ord, b)
            }
            Node::Scripts { base, sub, sup } => {
                self.scripts(base, sub.as_deref(), sup.as_deref(), st)
            }
            // LaTeX's \\frac is braced, so it is an Ord atom (plain TeX's \\over would be Inner).
            Node::Frac {
                num,
                den,
                rule,
                style,
                delims,
            } => (Class::Ord, self.frac(num, den, *rule, *style, *delims, st)),
            Node::BigDelim { ch, scale, class } => (*class, self.big_delim(*ch, *scale, st)),
            Node::Sqrt { index, body } => (Class::Ord, self.sqrt(index.as_deref(), body, st)),
            Node::BigOp { ch, .. } => (Class::Op, self.big_op(*ch, st)),
            Node::OpName { name, .. } => (Class::Op, self.op_name(name, st)),
            Node::LeftRight { left, right, body } => {
                (Class::Inner, self.left_right(*left, *right, body, st))
            }
            Node::Accent { ch, stretchy, body } => {
                (Class::Ord, self.accent(*ch, *stretchy, body, st))
            }
            Node::Overline(body) => (Class::Ord, self.overline(body, st)),
            Node::Underline(body) => (Class::Ord, self.underline(body, st)),
            Node::Text(s) => (Class::Ord, self.text(s, st)),
            // Handled in `items`; as a lone atom (a script argument) they
            // still lay out sensibly.
            Node::Space(s) => (
                Class::Ord,
                MBox {
                    w: self.space(*s, st),
                    ..MBox::default()
                },
            ),
            Node::Style(f, rest) => (Class::Ord, self.hlist(rest, forced(*f, st))),
        }
    }

    // --- scripts and limits ---------------------------------------------------

    fn scripts(
        &self,
        base: &Node,
        sub: Option<&[Node]>,
        sup: Option<&[Node]>,
        st: Style,
    ) -> (Class, MBox) {
        // Big operators with limits above/below.
        let limits = match base {
            Node::BigOp { limits, .. } | Node::OpName { limits, .. } => match limits {
                Limits::Always => true,
                Limits::Never => false,
                Limits::Display => st.is_display(),
            },
            _ => false,
        };
        let (class, b) = self.atom(base, st);
        let is_op = matches!(base, Node::BigOp { .. });
        let sub_b = sub.map(|s| self.hlist(s, st.sub()));
        let sup_b = sup.map(|s| self.hlist(s, st.sup()));
        if limits {
            return (class, self.limits(b, sub_b, sup_b, st));
        }
        (class, self.attach(b, is_op, sub_b, sup_b, st))
    }

    /// TeX rule 18: attach scripts beside `b`.
    fn attach(
        &self,
        b: MBox,
        is_op: bool,
        sub: Option<MBox>,
        sup: Option<MBox>,
        st: Style,
    ) -> MBox {
        let c = |f: fn(&MathConstants) -> i16| self.v(st, f);
        // A character base uses the font's fixed shifts; any other box
        // attaches relative to its own top and bottom.
        let (u0, v0) = if b.is_char && !is_op {
            (0.0, 0.0)
        } else {
            (
                b.h - c(|m| m.superscript_baseline_drop_max),
                b.d + c(|m| m.subscript_baseline_drop_min),
            )
        };
        let mut out = MBox {
            w: b.w,
            h: b.h,
            d: b.d,
            ..MBox::default()
        };
        out.put(&b, 0.0, 0.0);
        // Superscripts sit after the italic correction; an operator's
        // subscript tucks back under it instead.
        let (sup_x, sub_x) = if is_op {
            (b.w, b.w - b.ic)
        } else {
            (b.w + b.ic, b.w)
        };
        let mut sup_shift = 0.0;
        let mut sub_shift = 0.0;
        if let Some(sp) = &sup {
            let up = if st.cramped {
                c(|m| m.superscript_shift_up_cramped)
            } else {
                c(|m| m.superscript_shift_up)
            };
            sup_shift = u0.max(up).max(sp.d + c(|m| m.superscript_bottom_min));
        }
        match (&sup, &sub) {
            (None, Some(sb)) => {
                sub_shift = v0
                    .max(c(|m| m.subscript_shift_down))
                    .max(sb.h - c(|m| m.subscript_top_max));
            }
            (Some(sp), Some(sb)) => {
                sub_shift = v0.max(c(|m| m.subscript_shift_down));
                let gap = (sup_shift - sp.d) - (sb.h - sub_shift);
                let min_gap = c(|m| m.sub_superscript_gap_min);
                if gap < min_gap {
                    sub_shift += min_gap - gap;
                    let psi = c(|m| m.superscript_bottom_max_with_subscript) - (sup_shift - sp.d);
                    if psi > 0.0 {
                        sup_shift += psi;
                        sub_shift -= psi;
                    }
                }
            }
            _ => {}
        }
        // OpenType math kerning (cut-ins): a single-glyph base and the
        // script's first glyph each carry a kern by height at the facing
        // corners. It is read at two heights -- the base's top or bottom and
        // the script's bottom or top -- and the larger (looser) sum is used.
        let base_g = if b.is_char && b.glyphs.len() == 1 && !is_op {
            Some(&b.glyphs[0])
        } else {
            None
        };
        let kern_pair = |script: &MBox,
                         shift: f64,
                         base_corner: Corner,
                         script_corner: Corner,
                         heights: [f64; 2]| {
            let first = script.glyphs.iter().find(|g| g.x.abs() < 1e-9);
            if base_g.is_none() && first.is_none() {
                return 0.0;
            }
            let mut best = f64::NEG_INFINITY;
            for hgt in heights {
                let mut k = 0.0;
                if let Some(g) = base_g {
                    let s = g.size / self.font.upem;
                    k += self.font.math.kern_at(g.gid, base_corner, (hgt - g.y) / s) * s;
                }
                if let Some(g) = first {
                    let s = g.size / self.font.upem;
                    k += self
                        .font
                        .math
                        .kern_at(g.gid, script_corner, (hgt - shift - g.y) / s)
                        * s;
                }
                best = best.max(k);
            }
            best
        };
        let sup_kern = sup.as_ref().map_or(0.0, |sp| {
            kern_pair(
                sp,
                sup_shift,
                Corner::TopRight,
                Corner::BottomLeft,
                [b.h, sup_shift - sp.d],
            )
        });
        let sub_kern = sub.as_ref().map_or(0.0, |sb| {
            kern_pair(
                sb,
                -sub_shift,
                Corner::BottomRight,
                Corner::TopLeft,
                [-b.d, sb.h - sub_shift],
            )
        });
        // The cut-in adds to the italic correction (measured against
        // LuaLaTeX: W^2, V^2 and T^2 sit at advance + correction + kern).
        let sup_x = sup_x + sup_kern;
        let sub_x = sub_x + sub_kern;
        let mut right = b.w;
        if let Some(sp) = &sup {
            out.put(sp, sup_x, sup_shift);
            out.cover(sp, sup_shift);
            right = right.max(sup_x + sp.w);
        }
        if let Some(sb) = &sub {
            out.put(sb, sub_x, -sub_shift);
            out.cover(sb, -sub_shift);
            right = right.max(sub_x + sb.w);
        }
        out.w = right + c(|m| m.space_after_script);
        out
    }

    /// Limits centred above and below an operator.
    fn limits(&self, op: MBox, sub: Option<MBox>, sup: Option<MBox>, st: Style) -> MBox {
        let c = |f: fn(&MathConstants) -> i16| self.v(st, f);
        let w =
            op.w.max(sup.as_ref().map_or(0.0, |b| b.w))
                .max(sub.as_ref().map_or(0.0, |b| b.w));
        let mut out = MBox {
            w,
            h: op.h,
            d: op.d,
            ..MBox::default()
        };
        out.put(&op, (w - op.w) / 2.0, 0.0);
        if let Some(sp) = &sup {
            let rise =
                c(|m| m.upper_limit_baseline_rise_min).max(c(|m| m.upper_limit_gap_min) + sp.d);
            let y = op.h + rise;
            out.put(sp, (w - sp.w) / 2.0 + op.ic / 2.0, y);
            out.cover(sp, y);
        }
        if let Some(sb) = &sub {
            let drop =
                c(|m| m.lower_limit_baseline_drop_min).max(c(|m| m.lower_limit_gap_min) + sb.h);
            let y = -(op.d + drop);
            out.put(sb, (w - sb.w) / 2.0 - op.ic / 2.0, y);
            out.cover(sb, y);
        }
        out
    }

    // --- operators --------------------------------------------------------------

    /// A big operator glyph, its display-size variant in display style,
    /// centred on the math axis.
    fn big_op(&self, ch: char, st: Style) -> MBox {
        let gid = self.gid_of(ch);
        let mut b = if st.is_display() {
            let min_h = self.c().display_operator_min_height as f64;
            let g = self
                .font
                .math
                .vertical(gid)
                .and_then(|con| {
                    con.variants
                        .iter()
                        .find(|v| v.advance as f64 >= min_h)
                        .or(con.variants.last())
                        .map(|v| v.glyph)
                })
                .unwrap_or(gid);
            self.glyph_box(g, ch, st)
        } else {
            self.char_box(ch, st)
        };
        let axis = self.v(st, |m| m.axis_height);
        let shift = (b.h - b.d) / 2.0 - axis;
        b.shift(-shift);
        b.accent_x = None;
        b
    }

    /// An operator name (`\sin`, `\lim`), upright, as one box.
    fn op_name(&self, name: &str, st: Style) -> MBox {
        let mut nodes = Vec::new();
        for ch in name.chars() {
            if ch == ' ' {
                nodes.push(Node::Space(Space::Mu(3.0)));
            } else {
                nodes.push(Node::Char {
                    ch,
                    class: Class::Ord,
                });
            }
        }
        let mut b = self.hlist(&nodes, st);
        b.is_char = false;
        b.ic = 0.0;
        b
    }

    // --- fractions and radicals -----------------------------------------------

    fn frac(
        &self,
        num: &[Node],
        den: &[Node],
        rule: bool,
        force: Option<ForceStyle>,
        delims: Option<(char, char)>,
        st: Style,
    ) -> MBox {
        let fs = match force {
            Some(f) => forced(f, st),
            None => st,
        };
        let c = |f: fn(&MathConstants) -> i16| self.v(fs, f);
        let n = self.hlist(num, fs.num());
        let d = self.hlist(den, fs.den());
        let axis = c(|m| m.axis_height);
        // A bar-less fraction (\\binom's zero-thickness \\genfrac) uses the
        // stack shifts and gap, as LuaTeX does for a zero rule thickness.
        let (mut u, mut v) = match (rule, fs.is_display()) {
            (true, true) => (
                c(|m| m.fraction_numerator_display_style_shift_up),
                c(|m| m.fraction_denominator_display_style_shift_down),
            ),
            (true, false) => (
                c(|m| m.fraction_numerator_shift_up),
                c(|m| m.fraction_denominator_shift_down),
            ),
            (false, true) => (
                c(|m| m.stack_top_display_style_shift_up),
                c(|m| m.stack_bottom_display_style_shift_down),
            ),
            (false, false) => (
                c(|m| m.stack_top_shift_up),
                c(|m| m.stack_bottom_shift_down),
            ),
        };
        let theta = if rule {
            c(|m| m.fraction_rule_thickness)
        } else {
            0.0
        };
        if rule {
            let (gn, gd) = if fs.is_display() {
                (
                    c(|m| m.fraction_num_display_style_gap_min),
                    c(|m| m.fraction_denom_display_style_gap_min),
                )
            } else {
                (
                    c(|m| m.fraction_numerator_gap_min),
                    c(|m| m.fraction_denominator_gap_min),
                )
            };
            let above = (u - n.d) - (axis + theta / 2.0);
            if above < gn {
                u += gn - above;
            }
            let below = (axis - theta / 2.0) - (d.h - v);
            if below < gd {
                v += gd - below;
            }
        } else {
            let gmin = if fs.is_display() {
                c(|m| m.stack_display_style_gap_min)
            } else {
                c(|m| m.stack_gap_min)
            };
            let gap = (u - n.d) - (d.h - v);
            if gap < gmin {
                let half = (gmin - gap) / 2.0;
                u += half;
                v += half;
            }
        }
        // \nulldelimiterspace pads a fraction on both sides, unless it sits
        // between real delimiters (\binom).
        let pad = if delims.is_none() {
            NULL_DELIMITER_EM * self.size
        } else {
            0.0
        };
        let w = n.w.max(d.w);
        let mut out = MBox {
            w: w + 2.0 * pad,
            h: u + n.h,
            d: v + d.d,
            ..MBox::default()
        };
        out.put(&n, pad + (w - n.w) / 2.0, u);
        out.put(&d, pad + (w - d.w) / 2.0, -v);
        if rule {
            out.rules.push(Rule {
                x: pad,
                y: axis - theta / 2.0,
                w,
                h: theta,
            });
        }
        match delims {
            None => out,
            Some((l, r)) => {
                // \genfrac's delimiters take TeX's fraction-delimiter size
                // (\delim1 = 2.39 em in display, \delim2 = 1.01 em otherwise,
                // as LuaLaTeX gives them), centred on the axis.
                let size = self.size_of(fs) * if fs.is_display() { 2.39 } else { 1.01 };
                let lb = self.delimiter(Some(l), size, fs);
                let rb = self.delimiter(Some(r), size, fs);
                let mut b = MBox {
                    w: lb.w + out.w + rb.w,
                    h: out.h.max(lb.h).max(rb.h),
                    d: out.d.max(lb.d).max(rb.d),
                    ..MBox::default()
                };
                b.put(&lb, 0.0, 0.0);
                b.put(&out, lb.w, 0.0);
                b.put(&rb, lb.w + out.w, 0.0);
                b
            }
        }
    }

    fn sqrt(&self, index: Option<&[Node]>, body: &[Node], st: Style) -> MBox {
        let c = |f: fn(&MathConstants) -> i16| self.v(st, f);
        let b = self.hlist(body, st.cramp());
        let theta = c(|m| m.radical_rule_thickness);
        let mut gap = if st.is_display() {
            c(|m| m.radical_display_style_vertical_gap)
        } else {
            c(|m| m.radical_vertical_gap)
        };
        let target = b.h + b.d + gap + theta;
        let rad = self.vertical('√', target, st);
        let excess = (rad.h + rad.d) - target;
        if excess > 0.0 {
            gap += excess / 2.0;
        }
        // The radical's top meets the top of the overbar.
        let top = b.h + gap + theta;
        let rad_y = top - rad.h;

        // Optional degree, raised over the radical's left arm.
        let (lead, idx) = match index {
            Some(ix) if !ix.is_empty() => {
                let ib = self.hlist(
                    ix,
                    Style {
                        level: Level::ScriptScript,
                        cramped: true,
                    },
                );
                let before = c(|m| m.radical_kern_before_degree);
                let after = c(|m| m.radical_kern_after_degree);
                let raise = self.c().radical_degree_bottom_raise_percent as f64 / 100.0;
                let bottom = rad_y - rad.d;
                let y = bottom + raise * (rad.h + rad.d);
                let lead = (before + ib.w + after).max(0.0);
                (lead, Some((ib, before, y)))
            }
            _ => (0.0, None),
        };
        let mut out = MBox {
            w: lead + rad.w + b.w,
            h: top + c(|m| m.radical_extra_ascender),
            d: b.d.max(rad.d - rad_y),
            ..MBox::default()
        };
        if let Some((ib, before, y)) = &idx {
            out.put(ib, *before, *y);
            out.cover(ib, *y);
        }
        out.put(&rad, lead, rad_y);
        out.put(&b, lead + rad.w, 0.0);
        out.rules.push(Rule {
            x: lead + rad.w,
            y: b.h + gap,
            w: b.w,
            h: theta,
        });
        out
    }

    // --- delimiters -------------------------------------------------------------

    fn delimiter(&self, ch: Option<char>, target: f64, st: Style) -> MBox {
        let Some(ch) = ch else {
            return MBox {
                w: NULL_DELIMITER_EM * self.size,
                ..MBox::default()
            };
        };
        let mut b = self.vertical(ch, target, st);
        let axis = self.v(st, |m| m.axis_height);
        let shift = (b.h - b.d) / 2.0 - axis;
        b.shift(-shift);
        b.is_char = false;
        b
    }

    /// `\\big(` and friends: a delimiter at least `scale` x amsmath's
    /// `\\big@size` tall (1.2 x the strut height 0.7 x 1.2 em), centred on
    /// the axis.
    fn big_delim(&self, ch: Option<char>, scale: f64, st: Style) -> MBox {
        // LuaTeX picks the first variant at least that tall (no
        // \\delimiterfactor), which is what LuaLaTeX shows.
        let h = scale * 1.2 * 0.84 * self.size_of(st);
        self.delimiter(ch, h, st)
    }

    fn left_right(
        &self,
        left: Option<char>,
        right: Option<char>,
        body: &[Node],
        st: Style,
    ) -> MBox {
        let inner_items = self.items(body, st);
        // Extents of the content (spacing doesn't change heights).
        let (mut h, mut d) = (0.0f64, 0.0f64);
        for it in &inner_items {
            if let Item::Atom(_, b) = it {
                h = h.max(b.h);
                d = d.max(b.d);
            }
        }
        let axis = self.v(st, |m| m.axis_height);
        let delta = (h - axis).max(d + axis);
        let target =
            (2.0 * delta * DELIMITER_FACTOR).max(2.0 * delta - DELIMITER_SHORTFALL_EM * self.size);
        let lb = self.delimiter(left, target, st);
        let rb = self.delimiter(right, target, st);
        let mut items = Vec::with_capacity(inner_items.len() + 2);
        items.push(Item::Atom(Class::Open, lb));
        items.extend(inner_items);
        items.push(Item::Atom(Class::Close, rb));
        let mut out = join(items, st, self);
        out.is_char = false;
        out
    }

    // --- accents and bars -------------------------------------------------------

    fn accent(&self, ch: char, stretchy: bool, body: &[Node], st: Style) -> MBox {
        let b = self.hlist(body, st.cramp());
        // A single-glyph body attaches at its own top-accent point.
        let single = match body {
            [Node::Char { .. }] => true,
            [Node::Group(inner)] => matches!(inner.as_slice(), [Node::Char { .. }]),
            _ => false,
        };
        let base_x = if single && b.glyphs.len() == 1 {
            let g = &b.glyphs[0];
            self.font
                .math
                .top_accent_attachment(g.gid)
                .map(|a| a as f64 * self.k(st.cramp()))
                .unwrap_or(b.w / 2.0)
        } else {
            b.w / 2.0
        };
        let acc = if stretchy {
            self.widest_within(ch, b.w, st)
        } else {
            self.char_box(ch, st)
        };
        let acc_x = match (acc.glyphs.len(), acc.accent_x) {
            (1, Some(a)) => a,
            _ => {
                // Centre of the accent's ink.
                let mut x0 = f64::INFINITY;
                let mut x1 = f64::NEG_INFINITY;
                for g in &acc.glyphs {
                    let (a, _, c, _) = self.font.bounds(g.gid);
                    let k = g.size / self.font.upem;
                    x0 = x0.min(g.x + a * k);
                    x1 = x1.max(g.x + c * k);
                }
                if x0.is_finite() {
                    (x0 + x1) / 2.0
                } else {
                    acc.w / 2.0
                }
            }
        };
        let y = (b.h - self.v(st, |m| m.accent_base_height)).max(0.0);
        let mut out = MBox {
            w: b.w,
            h: b.h,
            d: b.d,
            ..MBox::default()
        };
        out.put(&b, 0.0, 0.0);
        out.put(&acc, base_x - acc_x, y);
        out.cover(&acc, y);
        // An accented single letter takes scripts like the letter (`\hat{y}_i`
        // keeps the subscript where `y_i` has it).
        if single {
            out.is_char = true;
            out.ic = b.ic;
        }
        out
    }

    fn overline(&self, body: &[Node], st: Style) -> MBox {
        let c = |f: fn(&MathConstants) -> i16| self.v(st, f);
        let b = self.hlist(body, st.cramp());
        let gap = c(|m| m.overbar_vertical_gap);
        let theta = c(|m| m.overbar_rule_thickness);
        let mut out = MBox {
            w: b.w,
            h: b.h + gap + theta + c(|m| m.overbar_extra_ascender),
            d: b.d,
            ..MBox::default()
        };
        out.put(&b, 0.0, 0.0);
        out.rules.push(Rule {
            x: 0.0,
            y: b.h + gap,
            w: b.w,
            h: theta,
        });
        out
    }

    fn underline(&self, body: &[Node], st: Style) -> MBox {
        let c = |f: fn(&MathConstants) -> i16| self.v(st, f);
        let b = self.hlist(body, st);
        let gap = c(|m| m.underbar_vertical_gap);
        let theta = c(|m| m.underbar_rule_thickness);
        let mut out = MBox {
            w: b.w,
            h: b.h,
            d: b.d + gap + theta + c(|m| m.underbar_extra_descender),
            ..MBox::default()
        };
        out.put(&b, 0.0, 0.0);
        out.rules.push(Rule {
            x: 0.0,
            y: -(b.d + gap + theta),
            w: b.w,
            h: theta,
        });
        out
    }

    /// `\text{}`: upright glyphs from the math font, spaces kept, no
    /// script alternates.
    fn text(&self, s: &str, st: Style) -> MBox {
        let mut out = MBox::default();
        for ch in s.chars() {
            if ch.is_whitespace() {
                out.w += self.word_space(st);
                continue;
            }
            let gid = self.gid_of(ch);
            let g = self.glyph_box(gid, ch, st);
            out.put(&g, out.w, 0.0);
            out.h = out.h.max(g.h);
            out.d = out.d.max(g.d);
            out.w += g.w;
        }
        out
    }
}

fn forced(f: ForceStyle, _st: Style) -> Style {
    let level = match f {
        ForceStyle::Display => Level::Display,
        ForceStyle::Text => Level::Text,
        ForceStyle::Script => Level::Script,
        ForceStyle::ScriptScript => Level::ScriptScript,
    };
    // An explicit style switch is never cramped (TeX: \\displaystyle is D,
    // not D').
    Style {
        level,
        cramped: false,
    }
}

/// Inter-atom space in mu (TeXbook ch. 18). Parenthesised entries of the
/// table (spaces suppressed in script styles) are the `ns` ones.
pub fn spacing(left: Class, right: Class, script: bool) -> f64 {
    use Class::*;
    // (mu, also in script styles)
    let (mu, always) = match (left, right) {
        (Ord, Op) | (Op, Ord) | (Op, Op) | (Close, Op) | (Inner, Op) => (3.0, true),
        (Ord, Bin)
        | (Bin, Ord)
        | (Bin, Op)
        | (Bin, Open)
        | (Bin, Inner)
        | (Close, Bin)
        | (Inner, Bin) => (4.0, false),
        (Ord, Rel)
        | (Op, Rel)
        | (Rel, Ord)
        | (Rel, Op)
        | (Rel, Open)
        | (Rel, Inner)
        | (Close, Rel)
        | (Inner, Rel) => (5.0, false),
        (Ord, Inner)
        | (Op, Inner)
        | (Close, Inner)
        | (Inner, Ord)
        | (Inner, Open)
        | (Inner, Punct)
        | (Inner, Inner) => (3.0, false),
        (Punct, Ord)
        | (Punct, Op)
        | (Punct, Rel)
        | (Punct, Open)
        | (Punct, Close)
        | (Punct, Punct)
        | (Punct, Inner) => (3.0, false),
        _ => (0.0, true),
    };
    if script && !always {
        0.0
    } else {
        mu
    }
}

/// TeX's Bin -> Ord rule: a binary operator with nothing to operate on
/// (first in the list, or after an operator, relation, opening or
/// punctuation; or before a relation, closing or punctuation, or last)
/// is an ordinary symbol.
fn fix_bins(classes: &mut [Class]) {
    use Class::*;
    let n = classes.len();
    for i in 0..n {
        if classes[i] == Bin {
            let prev = if i == 0 { None } else { Some(classes[i - 1]) };
            if matches!(
                prev,
                None | Some(Bin) | Some(Op) | Some(Rel) | Some(Open) | Some(Punct)
            ) {
                classes[i] = Ord;
            }
        }
    }
    for i in 0..n {
        if classes[i] == Bin {
            let next = classes.get(i + 1).copied();
            if matches!(next, None | Some(Rel) | Some(Close) | Some(Punct)) {
                classes[i] = Ord;
            }
        }
    }
}

/// Concatenate items with TeX's inter-atom spacing.
fn join(items: Vec<Item>, st: Style, ctx: &Ctx) -> MBox {
    let mut classes: Vec<Class> = items
        .iter()
        .filter_map(|it| match it {
            Item::Atom(c, _) => Some(*c),
            Item::Kern(_) => None,
        })
        .collect();
    fix_bins(&mut classes);
    let mu = ctx.mu(st);
    let mut out = MBox::default();
    let mut x = 0.0;
    let mut prev: Option<Class> = None;
    let mut k = 0usize;
    let mut atoms = 0usize;
    let mut last: Option<MBox> = None;
    for it in items {
        match it {
            Item::Kern(w) => x += w,
            Item::Atom(_, b) => {
                let class = classes[k];
                k += 1;
                if let Some(p) = prev {
                    x += spacing(p, class, st.is_script()) * mu;
                }
                out.put(&b, x, 0.0);
                out.h = out.h.max(b.h);
                out.d = out.d.max(b.d);
                x += b.w;
                prev = Some(class);
                atoms += 1;
                last = Some(b);
            }
        }
    }
    out.w = x;
    // A one-atom list keeps the atom's character-ness (so `{x}`-free script
    // bases and accents still see a glyph).
    if atoms == 1 && out.glyphs.len() == 1 {
        if let Some(b) = last {
            out.ic = b.ic;
            out.accent_x = b.accent_x;
        }
    }
    out
}

/// Place the parts of a glyph assembly so the whole is at least `target`
/// font units long: repeat the extenders as few times as needed, then
/// spread the connector overlaps evenly. Returns `(glyph, offset)` pairs.
///
/// The repeat count is solved directly (the maximum length grows linearly
/// with it), so the cost is linear in the number of parts placed. It is
/// capped at `MAX_REPEATS`, far beyond any height a formula within the
/// parser's nesting limit can ask for.
pub fn assembly_offsets(parts: &[Part], target: f64, min_overlap: f64) -> Vec<(u16, f64)> {
    const MAX_REPEATS: usize = 10_000;
    if parts.is_empty() {
        return Vec::new();
    }
    let n_fixed = parts.iter().filter(|p| !p.extender).count();
    let n_ext = parts.len() - n_fixed;
    let fixed_len: f64 = parts
        .iter()
        .filter(|p| !p.extender)
        .map(|p| p.full_advance as f64)
        .sum();
    let ext_len: f64 = parts
        .iter()
        .filter(|p| p.extender)
        .map(|p| p.full_advance as f64)
        .sum();
    // Max length with r repeats: fixed + r*ext - (count - 1) * min_overlap,
    // count = n_fixed + r * n_ext.
    let max_len = |r: usize| {
        let count = n_fixed + r * n_ext;
        fixed_len + r as f64 * ext_len - (count.max(1) - 1) as f64 * min_overlap
    };
    let gain = ext_len - n_ext as f64 * min_overlap;
    let mut reps = if n_fixed == 0 { 1 } else { 0 };
    if n_ext > 0 && gain > 0.0 && max_len(reps) < target {
        let need = ((target - max_len(reps)) / gain).ceil().max(0.0) as usize;
        reps = (reps + need).min(MAX_REPEATS);
    }
    let seq: Vec<&Part> = parts
        .iter()
        .flat_map(|p| std::iter::repeat_n(p, if p.extender { reps } else { 1 }))
        .collect();
    if seq.is_empty() {
        return Vec::new();
    }
    let joints = seq.len() - 1;
    let full: f64 = seq.iter().map(|p| p.full_advance as f64).sum();
    let longest = full - joints as f64 * min_overlap;
    let maxo: Vec<f64> = (0..joints)
        .map(|i| (seq[i].end_connector.min(seq[i + 1].start_connector) as f64).max(min_overlap))
        .collect();
    let shrinkable: f64 = maxo.iter().map(|m| m - min_overlap).sum();
    let t = if shrinkable > 0.0 {
        ((longest - target) / shrinkable).clamp(0.0, 1.0)
    } else {
        0.0
    };
    let mut out = Vec::with_capacity(seq.len());
    let mut pos = 0.0;
    for (i, p) in seq.iter().enumerate() {
        out.push((p.glyph, pos));
        if i < joints {
            pos += p.full_advance as f64 - (min_overlap + t * (maxo[i] - min_overlap));
        }
    }
    out
}
