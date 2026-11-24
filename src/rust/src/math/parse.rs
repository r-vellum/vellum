//! Parser for the TeX math subset: source string -> a list of [`Node`]s.
//!
//! Letters are mapped to their final Unicode math-alphabet characters here
//! (italic by default, upright under `\mathrm`, and so on), so the layout
//! never needs to know which alphabet command was in force.
//!
//! Errors carry a message and the 1-based character position of the
//! offending token, which the R side turns into a cli error.

use super::symbols::{self, Class, Limits};

/// A math style forced by `\displaystyle` and friends.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ForceStyle {
    Display,
    Text,
    Script,
    ScriptScript,
}

/// Explicit spacing, in mu (1/18 em) or as the font's interword space.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Space {
    Mu(f64),
    Word,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Node {
    /// One character (already mapped to its math alphabet) and its class.
    Char {
        ch: char,
        class: Class,
    },
    /// A braced group: laid out as a sub-list, an Ord atom.
    Group(Vec<Node>),
    Scripts {
        base: Box<Node>,
        sub: Option<Vec<Node>>,
        sup: Option<Vec<Node>>,
    },
    /// A fraction. `rule` false is a bar-less fraction (`\\binom`'s
    /// zero-thickness `\\genfrac`); `delims` are its fraction-sized
    /// delimiters (`\\binom`'s parentheses).
    Frac {
        num: Vec<Node>,
        den: Vec<Node>,
        rule: bool,
        style: Option<ForceStyle>,
        delims: Option<(char, char)>,
    },
    /// A fixed-size delimiter (`\\big(`, `\\Bigl[`, ...): `scale` is 1,
    /// 1.5, 2 or 2.5 (amsmath's `\\big@size` multiples). `None` is `.`.
    BigDelim {
        ch: Option<char>,
        scale: f64,
        class: Class,
    },
    Sqrt {
        index: Option<Vec<Node>>,
        body: Vec<Node>,
    },
    BigOp {
        ch: char,
        limits: Limits,
    },
    OpName {
        name: String,
        limits: Limits,
    },
    LeftRight {
        left: Option<char>,
        right: Option<char>,
        body: Vec<Node>,
    },
    Accent {
        ch: char,
        stretchy: bool,
        body: Vec<Node>,
    },
    Overline(Vec<Node>),
    Underline(Vec<Node>),
    Space(Space),
    /// Text from the math font (`\text{}` upright, `\textit{}` and
    /// friends in their alphabet), spaces kept.
    Text(String, Alphabet),
    /// `\phantom{}` and friends: the body's space (width if `h`, height and
    /// depth if `v`) with nothing drawn.
    Phantom {
        body: Vec<Node>,
        h: bool,
        v: bool,
    },
    /// `\displaystyle` etc.: the rest of the enclosing group in that style.
    Style(ForceStyle, Vec<Node>),
}

#[derive(Clone, Debug, PartialEq)]
pub struct ParseError {
    pub msg: String,
    /// 1-based character position in the source.
    pub pos: usize,
}

/// The math alphabet in force.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Alphabet {
    /// TeX defaults: Latin and lowercase Greek italic, digits and uppercase
    /// Greek upright.
    Normal,
    Rm,
    It,
    Bf,
    /// Bold italic (`\mathbfit`).
    BfIt,
    /// `\boldsymbol`: each symbol bold in the shape it already has (amsmath's
    /// meaning): Latin and lowercase Greek bold italic, capital Greek and
    /// digits bold upright.
    BoldSym,
    Sf,
    Tt,
    Cal,
    Bb,
}

/// Parse a whole formula.
pub fn parse(src: &str) -> Result<Vec<Node>, ParseError> {
    let mut p = Parser {
        s: src.chars().collect(),
        i: 0,
        depth: 0,
        in_infix: false,
        split_by_infix: false,
    };
    let nodes = p.expr(Stop::Eof, Alphabet::Normal)?;
    Ok(nodes)
}

/// What ends the list being parsed.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Stop {
    Eof,
    Brace,
    Bracket,
    Right,
}

#[derive(Clone, Debug, PartialEq)]
enum Tok {
    Cmd(String),
    Char(char),
    Open,
    Close,
    Sup,
    Sub,
}

struct Parser {
    s: Vec<char>,
    i: usize,
    /// Current nesting depth (groups, arguments, atoms), bounded by
    /// `MAX_DEPTH` so a pathological formula is an error, not a stack
    /// overflow in the parser or the (equally recursive) layout.
    depth: usize,
    /// Inside the denominator of an infix fraction of the current list,
    /// where a second `\over` is ambiguous (TeX's error too).
    in_infix: bool,
    /// Set when the list just parsed was split by an infix fraction (read
    /// by a style switch, which then keeps its style to the numerator).
    split_by_infix: bool,
}

/// Nesting limit. Each brace level costs about two (the group's list and
/// its atom), so this allows roughly 100 levels -- far past any real
/// formula, and well inside the stack.
const MAX_DEPTH: usize = 200;

fn err<T>(msg: impl Into<String>, pos: usize) -> Result<T, ParseError> {
    Err(ParseError {
        msg: msg.into(),
        pos: pos + 1,
    })
}

impl Parser {
    fn skip_ws(&mut self) {
        while self.i < self.s.len() && self.s[self.i].is_whitespace() {
            self.i += 1;
        }
    }

    /// The next token and its start position, without consuming it.
    fn peek(&mut self) -> Option<(usize, Tok)> {
        let save = self.i;
        let t = self.next();
        self.i = save;
        t
    }

    fn next(&mut self) -> Option<(usize, Tok)> {
        self.skip_ws();
        let start = self.i;
        let c = *self.s.get(self.i)?;
        self.i += 1;
        let tok = match c {
            '\\' => {
                let mut name = String::new();
                while let Some(&d) = self.s.get(self.i) {
                    if d.is_ascii_alphabetic() {
                        name.push(d);
                        self.i += 1;
                    } else {
                        break;
                    }
                }
                if name.is_empty() {
                    match self.s.get(self.i) {
                        Some(&d) => {
                            self.i += 1;
                            name.push(d);
                        }
                        None => name.push('\\'),
                    }
                }
                Tok::Cmd(name)
            }
            '{' => Tok::Open,
            '}' => Tok::Close,
            '^' => Tok::Sup,
            '_' => Tok::Sub,
            c => Tok::Char(c),
        };
        Some((start, tok))
    }

    /// Parse atoms until `stop`. The closing token is left for the caller
    /// (except that EOF needs none).
    fn expr(&mut self, stop: Stop, alpha: Alphabet) -> Result<Vec<Node>, ParseError> {
        self.enter()?;
        let infix = std::mem::replace(&mut self.in_infix, false);
        let r = self.expr_inner(stop, alpha);
        self.in_infix = infix;
        self.split_by_infix = false;
        self.depth -= 1;
        r
    }

    fn enter(&mut self) -> Result<(), ParseError> {
        self.depth += 1;
        if self.depth > MAX_DEPTH {
            self.depth -= 1;
            return err(
                format!(
                    "Formula nested too deeply (more than {} levels)",
                    MAX_DEPTH / 2
                ),
                self.i.min(self.s.len()),
            );
        }
        Ok(())
    }

    fn expr_inner(&mut self, stop: Stop, alpha: Alphabet) -> Result<Vec<Node>, ParseError> {
        let mut out: Vec<Node> = Vec::new();
        loop {
            let Some((pos, tok)) = self.peek() else {
                return match stop {
                    Stop::Eof => Ok(out),
                    Stop::Brace => err("Missing closing brace `}`", self.s.len()),
                    Stop::Bracket => err("Missing closing bracket `]`", self.s.len()),
                    Stop::Right => err("`\\left` without a matching `\\right`", self.s.len()),
                };
            };
            match (&tok, stop) {
                (Tok::Close, Stop::Brace) => return Ok(out),
                (Tok::Close, _) => return err("Unexpected closing brace `}`", pos),
                (Tok::Char(']'), Stop::Bracket) => return Ok(out),
                (Tok::Cmd(c), Stop::Right) if c == "right" => return Ok(out),
                (Tok::Cmd(c), _) if c == "right" => {
                    return err("`\\right` without a matching `\\left`", pos)
                }
                _ => {}
            }
            // TeX's infix fractions: `{a \over b}`, `{n \choose k}`,
            // `{a \atop b}` split the enclosing list.
            if let Tok::Cmd(c) = &tok {
                if matches!(c.as_str(), "over" | "atop" | "choose") {
                    let kind = c.clone();
                    if self.in_infix {
                        return err(
                            format!("Ambiguous `\\{kind}`: group one of the fractions in braces"),
                            pos,
                        );
                    }
                    self.next();
                    self.in_infix = true;
                    let den = self.expr_inner(stop, alpha);
                    self.in_infix = false;
                    let den = den?;
                    let num = std::mem::take(&mut out);
                    let frac = Node::Frac {
                        num,
                        den,
                        rule: kind == "over",
                        style: None,
                        delims: if kind == "choose" {
                            Some(('(', ')'))
                        } else {
                            None
                        },
                    };
                    out.push(frac);
                    self.split_by_infix = true;
                    return Ok(out);
                }
            }
            // Style switches swallow the rest of the list.
            if let Tok::Cmd(c) = &tok {
                let force = match c.as_str() {
                    "displaystyle" => Some(ForceStyle::Display),
                    "textstyle" => Some(ForceStyle::Text),
                    "scriptstyle" => Some(ForceStyle::Script),
                    "scriptscriptstyle" => Some(ForceStyle::ScriptScript),
                    _ => None,
                };
                if let Some(f) = force {
                    self.next();
                    // The rest of this same list: an infix fraction in it
                    // splits this list (a second one is ambiguous), and the
                    // style then applies to the numerator only, as in TeX.
                    self.enter()?;
                    self.split_by_infix = false;
                    let rest = self.expr_inner(stop, alpha);
                    self.depth -= 1;
                    let mut rest = rest?;
                    if std::mem::take(&mut self.split_by_infix) {
                        if let Some(Node::Frac { num, .. }) = rest.first_mut() {
                            let inner = std::mem::take(num);
                            let mut new_num = std::mem::take(&mut out);
                            new_num.push(Node::Style(f, inner));
                            *num = new_num;
                        }
                        self.split_by_infix = true;
                        return Ok(rest);
                    }
                    out.push(Node::Style(f, rest));
                    return Ok(out);
                }
            }
            match tok {
                Tok::Sup | Tok::Sub => {
                    // A script with no base: attach to an empty group.
                    let base = Node::Group(Vec::new());
                    let n = self.scripts(base, alpha)?;
                    out.push(n);
                }
                _ => {
                    let atom = self.atom(alpha)?;
                    let n = self.scripts(atom, alpha)?;
                    out.push(n);
                }
            }
        }
    }

    /// Attach any `^`, `_` and `'` that follow `base`.
    fn scripts(&mut self, base: Node, alpha: Alphabet) -> Result<Node, ParseError> {
        let mut sub: Option<Vec<Node>> = None;
        let mut sup: Option<Vec<Node>> = None;
        let mut primes = 0usize;
        let mut base = base;
        loop {
            let Some((pos, tok)) = self.peek() else { break };
            match tok {
                Tok::Sup => {
                    self.next();
                    if sup.is_some() {
                        return err("Double superscript", pos);
                    }
                    let arg = self.arg(alpha, "^", pos)?;
                    sup = Some(arg);
                }
                Tok::Sub => {
                    self.next();
                    if sub.is_some() {
                        return err("Double subscript", pos);
                    }
                    let arg = self.arg(alpha, "_", pos)?;
                    sub = Some(arg);
                }
                Tok::Char('\'') => {
                    self.next();
                    if sup.is_some() {
                        return err("Double superscript (a prime after `^`)", pos);
                    }
                    primes += 1;
                }
                Tok::Cmd(ref c) if c == "limits" || c == "nolimits" => {
                    self.next();
                    let lim = if c == "limits" {
                        Limits::Always
                    } else {
                        Limits::Never
                    };
                    match &mut base {
                        Node::BigOp { limits, .. } | Node::OpName { limits, .. } => *limits = lim,
                        _ => return err(format!("`\\{c}` is allowed only after an operator"), pos),
                    }
                }
                _ => break,
            }
        }
        if primes > 0 {
            // Unicode has single glyphs for up to four primes; more are a
            // quadruple prime followed by the rest.
            let mut p = String::new();
            let mut left = primes;
            while left > 0 {
                let k = left.min(4);
                p.push(['′', '″', '‴', '⁗'][k - 1]);
                left -= k;
            }
            let mut list: Vec<Node> = p
                .chars()
                .map(|ch| Node::Char {
                    ch,
                    class: Class::Ord,
                })
                .collect();
            if let Some(s) = sup.take() {
                list.extend(s);
            }
            sup = Some(list);
        }
        if sub.is_none() && sup.is_none() {
            return Ok(base);
        }
        Ok(Node::Scripts {
            base: Box::new(base),
            sub,
            sup,
        })
    }

    /// One argument: a braced group or a single token.
    fn arg(&mut self, alpha: Alphabet, what: &str, at: usize) -> Result<Vec<Node>, ParseError> {
        match self.peek() {
            None => {
                let _ = at;
                err(format!("Missing argument for `{what}`"), self.s.len())
            }
            Some((pos, Tok::Close)) => err(format!("Missing argument for `{what}`"), pos),
            Some((pos, Tok::Sup)) | Some((pos, Tok::Sub)) => {
                err(format!("Missing argument for `{what}`"), pos)
            }
            Some((_, Tok::Open)) => {
                self.next();
                let body = self.expr(Stop::Brace, alpha)?;
                self.next(); // the `}`
                Ok(body)
            }
            Some(_) => Ok(vec![self.atom(alpha)?]),
        }
    }

    /// A braced group that must be present (`\frac`'s arguments, etc.).
    fn group_arg(
        &mut self,
        alpha: Alphabet,
        cmd: &str,
        at: usize,
    ) -> Result<Vec<Node>, ParseError> {
        self.arg(alpha, &format!("\\{cmd}"), at)
    }

    /// Raw text up to the matching `}` (for `\text`): braces nest, a
    /// backslash escapes the next character.
    fn raw_group(&mut self, cmd: &str, at: usize) -> Result<String, ParseError> {
        self.skip_ws();
        if self.s.get(self.i) != Some(&'{') {
            return err(format!("`\\{cmd}` needs a braced argument"), at);
        }
        self.i += 1;
        let mut depth = 1usize;
        let mut out = String::new();
        while let Some(&c) = self.s.get(self.i) {
            self.i += 1;
            match c {
                '{' => {
                    depth += 1;
                }
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        return Ok(out);
                    }
                }
                '\\' => {
                    if let Some(&d) = self.s.get(self.i) {
                        self.i += 1;
                        out.push(d);
                    }
                }
                c => out.push(c),
            }
        }
        err(
            format!("Missing closing brace `}}` for `\\{cmd}`"),
            self.s.len(),
        )
    }

    /// One atom (no scripts).
    fn atom(&mut self, alpha: Alphabet) -> Result<Node, ParseError> {
        self.enter()?;
        let r = self.atom_inner(alpha);
        self.depth -= 1;
        r
    }

    fn atom_inner(&mut self, alpha: Alphabet) -> Result<Node, ParseError> {
        let Some((pos, tok)) = self.next() else {
            return err("Unexpected end of input", self.s.len());
        };
        match tok {
            Tok::Open => {
                let body = self.expr(Stop::Brace, alpha)?;
                self.next();
                Ok(Node::Group(body))
            }
            Tok::Close => err("Unexpected closing brace `}`", pos),
            Tok::Sup | Tok::Sub => err("Unexpected script", pos),
            Tok::Char(c) => self.char_atom(c, pos, alpha),
            Tok::Cmd(name) => self.command(&name, pos, alpha),
        }
    }

    fn char_atom(&mut self, c: char, pos: usize, alpha: Alphabet) -> Result<Node, ParseError> {
        match c {
            '~' => Ok(Node::Space(Space::Word)),
            '&' => err("Alignment `&` is not supported", pos),
            '#' => err("`#` is not allowed in math (write `\\#`)", pos),
            '%' => err("`%` is not allowed in math (write `\\%`)", pos),
            '$' => err("`$` is not allowed inside a formula", pos),
            '\'' => Ok(Node::Char {
                ch: '′',
                class: Class::Ord,
            }),
            c if c.is_ascii_alphanumeric() || is_greek(c) => Ok(Node::Char {
                ch: map_alpha(c, alpha),
                class: Class::Ord,
            }),
            c => {
                let (ch, class) = symbols::literal(c);
                Ok(Node::Char { ch, class })
            }
        }
    }

    fn command(&mut self, name: &str, pos: usize, alpha: Alphabet) -> Result<Node, ParseError> {
        if let Some(g) = symbols::greek(name) {
            return Ok(Node::Char {
                ch: map_alpha(g, alpha),
                class: Class::Ord,
            });
        }
        if let Some((ch, class)) = symbols::symbol(name) {
            return Ok(Node::Char { ch, class });
        }
        if let Some((ch, limits)) = symbols::big_op(name) {
            return Ok(Node::BigOp { ch, limits });
        }
        if let Some((n, limits)) = symbols::op_name(name) {
            return Ok(Node::OpName {
                name: n.to_string(),
                limits,
            });
        }
        if let Some((ch, stretchy)) = symbols::accent(name) {
            let body = self.group_arg(alpha, name, pos)?;
            return Ok(Node::Accent { ch, stretchy, body });
        }
        let space = |mu: f64| Ok(Node::Space(Space::Mu(mu)));
        match name {
            "," | "thinspace" => space(3.0),
            ":" | ">" | "medspace" => space(4.0),
            ";" | "thickspace" => space(5.0),
            "!" | "negthinspace" => space(-3.0),
            "quad" => space(18.0),
            "qquad" => space(36.0),
            " " => Ok(Node::Space(Space::Word)),
            "frac" | "dfrac" | "tfrac" | "binom" => {
                let num = self.group_arg(alpha, name, pos)?;
                let den = self.group_arg(alpha, name, pos)?;
                let style = match name {
                    "dfrac" => Some(ForceStyle::Display),
                    "tfrac" => Some(ForceStyle::Text),
                    _ => None,
                };
                // amsmath's \binom is \genfrac(){0pt}: a zero-thickness
                // fraction between fraction-sized parentheses.
                let binom = name == "binom";
                Ok(Node::Frac {
                    num,
                    den,
                    rule: !binom,
                    style,
                    delims: if binom { Some(('(', ')')) } else { None },
                })
            }
            "big" | "Big" | "bigg" | "Bigg" | "bigl" | "Bigl" | "biggl" | "Biggl" | "bigr"
            | "Bigr" | "biggr" | "Biggr" | "bigm" | "Bigm" | "biggm" | "Biggm" => {
                let stem = name.trim_end_matches(['l', 'r', 'm']);
                let scale = match stem {
                    "big" => 1.0,
                    "Big" => 1.5,
                    "bigg" => 2.0,
                    _ => 2.5,
                };
                let class = match name.chars().last() {
                    Some('l') => Class::Open,
                    Some('r') => Class::Close,
                    Some('m') => Class::Rel,
                    _ => Class::Ord,
                };
                let ch = self.delimiter(name, pos)?;
                Ok(Node::BigDelim { ch, scale, class })
            }
            "sqrt" => {
                let index = match self.peek() {
                    Some((_, Tok::Char('['))) => {
                        self.next();
                        let ix = self.expr(Stop::Bracket, alpha)?;
                        self.next(); // `]`
                        Some(ix)
                    }
                    _ => None,
                };
                let body = self.group_arg(alpha, name, pos)?;
                Ok(Node::Sqrt { index, body })
            }
            "left" => {
                let left = self.delimiter("left", pos)?;
                let body = self.expr(Stop::Right, alpha)?;
                let (rpos, _) = self.next().expect("expr stops at \\right");
                let right = self.delimiter("right", rpos)?;
                Ok(Node::LeftRight { left, right, body })
            }
            "mathrm" | "mathit" | "mathbf" | "mathsf" | "mathtt" | "mathcal" | "mathbb"
            | "mathnormal" | "mathbfit" | "boldsymbol" => {
                let a = match name {
                    "mathbfit" => Alphabet::BfIt,
                    "boldsymbol" => Alphabet::BoldSym,
                    "mathrm" => Alphabet::Rm,
                    "mathit" => Alphabet::It,
                    "mathbf" => Alphabet::Bf,
                    "mathsf" => Alphabet::Sf,
                    "mathtt" => Alphabet::Tt,
                    "mathcal" => Alphabet::Cal,
                    "mathbb" => Alphabet::Bb,
                    _ => Alphabet::Normal,
                };
                let body = self.group_arg(a, name, pos)?;
                Ok(Node::Group(body))
            }
            "text" | "textrm" | "mbox" | "textup" | "textnormal" => {
                Ok(Node::Text(self.raw_group(name, pos)?, Alphabet::Rm))
            }
            "textit" => Ok(Node::Text(self.raw_group(name, pos)?, Alphabet::It)),
            "textbf" => Ok(Node::Text(self.raw_group(name, pos)?, Alphabet::Bf)),
            "textbfit" => Ok(Node::Text(self.raw_group(name, pos)?, Alphabet::BfIt)),
            "phantom" | "hphantom" | "vphantom" => {
                let body = self.group_arg(alpha, name, pos)?;
                Ok(Node::Phantom {
                    body,
                    h: name != "vphantom",
                    v: name != "hphantom",
                })
            }
            "operatorname" => {
                let star = self.s.get(self.i) == Some(&'*');
                if star {
                    self.i += 1;
                }
                let name_txt = self.raw_group("operatorname", pos)?;
                Ok(Node::OpName {
                    name: name_txt,
                    limits: if star { Limits::Display } else { Limits::Never },
                })
            }
            "overline" => Ok(Node::Overline(self.group_arg(alpha, name, pos)?)),
            "underline" => Ok(Node::Underline(self.group_arg(alpha, name, pos)?)),
            "limits" | "nolimits" => {
                err(format!("`\\{name}` is allowed only after an operator"), pos)
            }
            "right" => err("`\\right` without a matching `\\left`", pos),
            "\\" => err("Line breaks (`\\\\`) are not supported in `tex()`", pos),
            _ => err(format!("Unknown command `\\{name}`"), pos),
        }
    }

    fn delimiter(&mut self, which: &str, at: usize) -> Result<Option<char>, ParseError> {
        let Some((pos, tok)) = self.next() else {
            return err(format!("Missing delimiter after `\\{which}`"), at);
        };
        let d = match &tok {
            Tok::Char(c) => symbols::delimiter_char(*c),
            Tok::Cmd(c) => symbols::delimiter_cmd(c),
            _ => None,
        };
        match d {
            Some(d) => Ok(d),
            None => err(format!("Invalid delimiter after `\\{which}`"), pos),
        }
    }
}

fn is_greek(c: char) -> bool {
    ('\u{0391}'..='\u{03A9}').contains(&c)
        || ('\u{03B1}'..='\u{03C9}').contains(&c)
        || matches!(c, 'ϑ' | 'ϕ' | 'ϖ' | 'ϰ' | 'ϱ' | 'ϵ')
}

/// Offset of a lowercase Greek letter (or its variant forms) in the math
/// alphabets' 25 + 7 layout (α..ω, then ∂ ϵ ϑ ϰ ϕ ϱ ϖ).
fn greek_lower_index(c: char) -> Option<u32> {
    match c {
        '\u{03B1}'..='\u{03C9}' => Some(c as u32 - 0x03B1),
        '∂' => Some(25),
        'ϵ' => Some(26),
        'ϑ' => Some(27),
        'ϰ' => Some(28),
        'ϕ' => Some(29),
        'ϱ' => Some(30),
        'ϖ' => Some(31),
        _ => None,
    }
}

fn from_u32(v: u32, fallback: char) -> char {
    char::from_u32(v).unwrap_or(fallback)
}

/// Map a Latin letter, digit or Greek letter into a math alphabet.
pub fn map_alpha(c: char, alpha: Alphabet) -> char {
    let upper = c.is_ascii_uppercase();
    let lower = c.is_ascii_lowercase();
    let digit = c.is_ascii_digit();
    let gup = ('\u{0391}'..='\u{03A9}').contains(&c);
    let glo = greek_lower_index(c);
    let latin = |base_upper: u32, base_lower: u32| -> char {
        if upper {
            from_u32(base_upper + (c as u32 - 'A' as u32), c)
        } else {
            from_u32(base_lower + (c as u32 - 'a' as u32), c)
        }
    };
    match alpha {
        Alphabet::Normal | Alphabet::It => {
            if lower && c == 'h' {
                return 'ℎ';
            }
            if upper || lower {
                return latin(0x1D434, 0x1D44E);
            }
            if let Some(k) = glo {
                return from_u32(0x1D6FC + k, c);
            }
            if gup && alpha == Alphabet::It {
                return from_u32(0x1D6E2 + (c as u32 - 0x0391), c);
            }
            c
        }
        Alphabet::Rm => c,
        Alphabet::Bf => {
            if upper || lower {
                return latin(0x1D400, 0x1D41A);
            }
            if digit {
                return from_u32(0x1D7CE + (c as u32 - '0' as u32), c);
            }
            if gup {
                return from_u32(0x1D6A8 + (c as u32 - 0x0391), c);
            }
            if let Some(k) = glo {
                return from_u32(0x1D6C2 + k, c);
            }
            c
        }
        Alphabet::BoldSym => {
            if gup {
                return from_u32(0x1D6A8 + (c as u32 - 0x0391), c);
            }
            map_alpha(c, Alphabet::BfIt)
        }
        Alphabet::BfIt => {
            if upper || lower {
                return latin(0x1D468, 0x1D482);
            }
            if digit {
                return from_u32(0x1D7CE + (c as u32 - '0' as u32), c);
            }
            if gup {
                return from_u32(0x1D71C + (c as u32 - 0x0391), c);
            }
            if let Some(k) = glo {
                return from_u32(0x1D736 + k, c);
            }
            c
        }
        Alphabet::Sf => {
            if upper || lower {
                return latin(0x1D5A0, 0x1D5BA);
            }
            if digit {
                return from_u32(0x1D7E2 + (c as u32 - '0' as u32), c);
            }
            c
        }
        Alphabet::Tt => {
            if upper || lower {
                return latin(0x1D670, 0x1D68A);
            }
            if digit {
                return from_u32(0x1D7F6 + (c as u32 - '0' as u32), c);
            }
            c
        }
        Alphabet::Cal => {
            // Script capitals live partly in Letterlike Symbols.
            let hole = match c {
                'B' => Some('ℬ'),
                'E' => Some('ℰ'),
                'F' => Some('ℱ'),
                'H' => Some('ℋ'),
                'I' => Some('ℐ'),
                'L' => Some('ℒ'),
                'M' => Some('ℳ'),
                'R' => Some('ℛ'),
                'e' => Some('ℯ'),
                'g' => Some('ℊ'),
                'o' => Some('ℴ'),
                _ => None,
            };
            if let Some(h) = hole {
                return h;
            }
            if upper || lower {
                return latin(0x1D49C, 0x1D4B6);
            }
            c
        }
        Alphabet::Bb => {
            let hole = match c {
                'C' => Some('ℂ'),
                'H' => Some('ℍ'),
                'N' => Some('ℕ'),
                'P' => Some('ℙ'),
                'Q' => Some('ℚ'),
                'R' => Some('ℝ'),
                'Z' => Some('ℤ'),
                _ => None,
            };
            if let Some(h) = hole {
                return h;
            }
            if upper || lower {
                return latin(0x1D538, 0x1D552);
            }
            if digit {
                return from_u32(0x1D7D8 + (c as u32 - '0' as u32), c);
            }
            c
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(src: &str) -> ParseError {
        parse(src).expect_err("expected a parse error")
    }

    #[test]
    fn letters_are_math_italic_digits_upright() {
        let n = parse("a1h").unwrap();
        let chars: Vec<char> = n
            .iter()
            .map(|x| match x {
                Node::Char { ch, .. } => *ch,
                _ => '?',
            })
            .collect();
        assert_eq!(chars, vec!['\u{1D44E}', '1', 'ℎ']);
    }

    #[test]
    fn alphabets() {
        assert_eq!(map_alpha('R', Alphabet::Bb), 'ℝ');
        assert_eq!(map_alpha('x', Alphabet::Bf), '\u{1D431}');
        assert_eq!(map_alpha('α', Alphabet::Normal), '\u{1D6FC}');
        assert_eq!(map_alpha('Γ', Alphabet::Normal), 'Γ');
        assert_eq!(map_alpha('L', Alphabet::Cal), 'ℒ');
    }

    #[test]
    fn scripts_and_primes() {
        let n = parse("x_i^2").unwrap();
        assert!(matches!(
            &n[0],
            Node::Scripts {
                sub: Some(_),
                sup: Some(_),
                ..
            }
        ));
        let n = parse("f''(x)").unwrap();
        match &n[0] {
            Node::Scripts { sup: Some(s), .. } => assert_eq!(s.len(), 1),
            _ => panic!("prime should become a superscript"),
        }
    }

    #[test]
    fn errors_name_command_and_position() {
        let x = e("a + \\foo");
        assert_eq!(x.pos, 5);
        assert!(x.msg.contains("\\foo"));
        assert_eq!(e("x^").msg, "Missing argument for `^`");
        assert!(e("\\frac{a}").msg.contains("\\frac"));
        assert!(e("{a").msg.contains("closing brace"));
        assert_eq!(e("a}").pos, 2);
        assert!(e("\\left( x").msg.contains("\\right"));
        assert!(e("x \\right)").msg.contains("\\left"));
        assert!(e("x^1^2").msg.contains("Double superscript"));
        assert!(e("\\left< x \\right\\foo")
            .msg
            .contains("Invalid delimiter"));
    }
}
