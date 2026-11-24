//! Command and character tables for the TeX subset: which Unicode character a
//! command stands for, and its TeX atom class (which sets the spacing).

/// TeX's atom classes. The spacing between two adjacent atoms is a function
/// of their classes (TeXbook ch. 18, the table in `layout::spacing`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    Ord,
    Op,
    Bin,
    Rel,
    Open,
    Close,
    Punct,
    Inner,
}

/// Where a big operator's scripts go.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Limits {
    /// Above/below in display style, as scripts otherwise (`\sum`, `\lim`).
    Display,
    /// Always above/below (`\limits`).
    Always,
    /// Always as scripts (`\int`, `\nolimits`).
    Never,
}

/// Greek letter commands -> the upright Unicode letter. Italic forms are
/// chosen by the math-alphabet mapping in `parse`.
pub fn greek(cmd: &str) -> Option<char> {
    Some(match cmd {
        "alpha" => 'α',
        "beta" => 'β',
        "gamma" => 'γ',
        "delta" => 'δ',
        "epsilon" => 'ϵ',
        "varepsilon" => 'ε',
        "zeta" => 'ζ',
        "eta" => 'η',
        "theta" => 'θ',
        "vartheta" => 'ϑ',
        "iota" => 'ι',
        "kappa" => 'κ',
        "varkappa" => 'ϰ',
        "lambda" => 'λ',
        "mu" => 'μ',
        "nu" => 'ν',
        "xi" => 'ξ',
        "omicron" => 'ο',
        "pi" => 'π',
        "varpi" => 'ϖ',
        "rho" => 'ρ',
        "varrho" => 'ϱ',
        "sigma" => 'σ',
        "varsigma" => 'ς',
        "tau" => 'τ',
        "upsilon" => 'υ',
        "phi" => 'ϕ',
        "varphi" => 'φ',
        "chi" => 'χ',
        "psi" => 'ψ',
        "omega" => 'ω',
        "Gamma" => 'Γ',
        "Delta" => 'Δ',
        "Theta" => 'Θ',
        "Lambda" => 'Λ',
        "Xi" => 'Ξ',
        "Pi" => 'Π',
        "Sigma" => 'Σ',
        "Upsilon" => 'Υ',
        "Phi" => 'Φ',
        "Psi" => 'Ψ',
        "Omega" => 'Ω',
        _ => return None,
    })
}

/// Symbol commands -> (character, class).
pub fn symbol(cmd: &str) -> Option<(char, Class)> {
    use Class::*;
    Some(match cmd {
        // binary operators
        "pm" => ('±', Bin),
        "mp" => ('∓', Bin),
        "times" => ('×', Bin),
        "div" => ('÷', Bin),
        "cdot" => ('⋅', Bin),
        "ast" => ('∗', Bin),
        "star" => ('⋆', Bin),
        "circ" => ('∘', Bin),
        "bullet" => ('∙', Bin),
        "cup" => ('∪', Bin),
        "cap" => ('∩', Bin),
        "setminus" => ('∖', Bin),
        "wedge" | "land" => ('∧', Bin),
        "vee" | "lor" => ('∨', Bin),
        "oplus" => ('⊕', Bin),
        "ominus" => ('⊖', Bin),
        "otimes" => ('⊗', Bin),
        "odot" => ('⊙', Bin),
        "dagger" => ('†', Bin),
        // relations
        "leq" | "le" => ('≤', Rel),
        "geq" | "ge" => ('≥', Rel),
        "neq" | "ne" => ('≠', Rel),
        "approx" => ('≈', Rel),
        "sim" => ('∼', Rel),
        "simeq" => ('≃', Rel),
        "cong" => ('≅', Rel),
        "equiv" => ('≡', Rel),
        "propto" => ('∝', Rel),
        "ll" => ('≪', Rel),
        "gg" => ('≫', Rel),
        "in" => ('∈', Rel),
        "notin" => ('∉', Rel),
        "ni" => ('∋', Rel),
        "subset" => ('⊂', Rel),
        "subseteq" => ('⊆', Rel),
        "supset" => ('⊃', Rel),
        "supseteq" => ('⊇', Rel),
        "perp" => ('⟂', Rel),
        "parallel" => ('∥', Rel),
        "mid" => ('∣', Rel),
        "to" | "rightarrow" => ('→', Rel),
        "leftarrow" | "gets" => ('←', Rel),
        "leftrightarrow" => ('↔', Rel),
        "Rightarrow" => ('⇒', Rel),
        "Leftarrow" => ('⇐', Rel),
        "Leftrightarrow" => ('⇔', Rel),
        "mapsto" => ('↦', Rel),
        "longrightarrow" => ('⟶', Rel),
        "longleftarrow" => ('⟵', Rel),
        "implies" | "Longrightarrow" => ('⟹', Rel),
        "impliedby" | "Longleftarrow" => ('⟸', Rel),
        "iff" | "Longleftrightarrow" => ('⟺', Rel),
        "uparrow" => ('↑', Rel),
        "downarrow" => ('↓', Rel),
        // ordinary symbols
        "infty" => ('∞', Ord),
        "partial" => ('𝜕', Ord),
        "nabla" => ('∇', Ord),
        "forall" => ('∀', Ord),
        "exists" => ('∃', Ord),
        "nexists" => ('∄', Ord),
        "emptyset" | "varnothing" => ('∅', Ord),
        "prime" => ('′', Ord),
        "degree" => ('°', Ord),
        "hbar" => ('ℏ', Ord),
        "ell" => ('ℓ', Ord),
        "Re" => ('ℜ', Ord),
        "Im" => ('ℑ', Ord),
        "aleph" => ('ℵ', Ord),
        "wp" => ('℘', Ord),
        "neg" | "lnot" => ('¬', Ord),
        "angle" => ('∠', Ord),
        "triangle" => ('△', Ord),
        "top" => ('⊤', Ord),
        "bot" => ('⊥', Ord),
        "vert" => ('|', Ord),
        "Vert" => ('‖', Ord),
        "|" => ('‖', Ord),
        "ldots" | "dots" => ('…', Inner),
        "cdots" => ('⋯', Inner),
        "vdots" => ('⋮', Ord),
        "ddots" => ('⋱', Inner),
        "colon" => (':', Punct),
        // escaped literals
        "{" | "lbrace" => ('{', Open),
        "}" | "rbrace" => ('}', Close),
        "langle" => ('⟨', Open),
        "rangle" => ('⟩', Close),
        "lfloor" => ('⌊', Open),
        "rfloor" => ('⌋', Close),
        "lceil" => ('⌈', Open),
        "rceil" => ('⌉', Close),
        "lvert" => ('|', Open),
        "rvert" => ('|', Close),
        "lVert" => ('‖', Open),
        "rVert" => ('‖', Close),
        "%" => ('%', Ord),
        "$" => ('$', Ord),
        "&" => ('&', Ord),
        "#" => ('#', Ord),
        "_" => ('_', Ord),
        _ => return None,
    })
}

/// Big operators -> (character, default limits placement).
pub fn big_op(cmd: &str) -> Option<(char, Limits)> {
    use Limits::*;
    Some(match cmd {
        "sum" => ('∑', Display),
        "prod" => ('∏', Display),
        "coprod" => ('∐', Display),
        "bigcup" => ('⋃', Display),
        "bigcap" => ('⋂', Display),
        "bigoplus" => ('⨁', Display),
        "bigotimes" => ('⨂', Display),
        "bigvee" => ('⋁', Display),
        "bigwedge" => ('⋀', Display),
        "int" => ('∫', Never),
        "iint" => ('∬', Never),
        "iiint" => ('∭', Never),
        "oint" => ('∮', Never),
        _ => return None,
    })
}

/// Operator names set upright (`\sin`), and whether their scripts become
/// limits in display style (`\lim`).
pub fn op_name(cmd: &str) -> Option<(&'static str, Limits)> {
    use Limits::*;
    Some(match cmd {
        "lim" => ("lim", Display),
        "liminf" => ("lim inf", Display),
        "limsup" => ("lim sup", Display),
        "max" => ("max", Display),
        "min" => ("min", Display),
        "sup" => ("sup", Display),
        "inf" => ("inf", Display),
        "det" => ("det", Display),
        "Pr" => ("Pr", Display),
        "gcd" => ("gcd", Display),
        "argmax" => ("arg max", Display),
        "argmin" => ("arg min", Display),
        "log" => ("log", Never),
        "ln" => ("ln", Never),
        "lg" => ("lg", Never),
        "exp" => ("exp", Never),
        "sin" => ("sin", Never),
        "cos" => ("cos", Never),
        "tan" => ("tan", Never),
        "cot" => ("cot", Never),
        "sec" => ("sec", Never),
        "csc" => ("csc", Never),
        "arcsin" => ("arcsin", Never),
        "arccos" => ("arccos", Never),
        "arctan" => ("arctan", Never),
        "sinh" => ("sinh", Never),
        "cosh" => ("cosh", Never),
        "tanh" => ("tanh", Never),
        "arg" => ("arg", Never),
        "deg" => ("deg", Never),
        "dim" => ("dim", Never),
        "ker" => ("ker", Never),
        "hom" => ("hom", Never),
        _ => return None,
    })
}

/// Accent commands -> (combining character, stretchy).
pub fn accent(cmd: &str) -> Option<(char, bool)> {
    Some(match cmd {
        "hat" => ('\u{0302}', false),
        "widehat" => ('\u{0302}', true),
        "tilde" => ('\u{0303}', false),
        "widetilde" => ('\u{0303}', true),
        "bar" => ('\u{0304}', false),
        "vec" => ('\u{20D7}', false),
        "dot" => ('\u{0307}', false),
        "ddot" => ('\u{0308}', false),
        "check" => ('\u{030C}', false),
        "breve" => ('\u{0306}', false),
        "acute" => ('\u{0301}', false),
        "grave" => ('\u{0300}', false),
        _ => return None,
    })
}

/// A delimiter after `\left` / `\right` given as a command. `Some(None)` is
/// the null delimiter `.`.
pub fn delimiter_cmd(cmd: &str) -> Option<Option<char>> {
    Some(Some(match cmd {
        "{" | "lbrace" => '{',
        "}" | "rbrace" => '}',
        "|" | "Vert" | "lVert" | "rVert" => '‖',
        "vert" | "lvert" | "rvert" => '|',
        "langle" => '⟨',
        "rangle" => '⟩',
        "lfloor" => '⌊',
        "rfloor" => '⌋',
        "lceil" => '⌈',
        "rceil" => '⌉',
        "uparrow" => '↑',
        "downarrow" => '↓',
        "backslash" => '\\',
        _ => return None,
    }))
}

/// A literal delimiter character after `\left` / `\right`.
pub fn delimiter_char(c: char) -> Option<Option<char>> {
    Some(match c {
        '.' => None,
        '(' | ')' | '[' | ']' | '|' | '/' | '⟨' | '⟩' | '‖' | '⌊' | '⌋' | '⌈' | '⌉' => {
            Some(c)
        }
        '<' => Some('⟨'),
        '>' => Some('⟩'),
        _ => return None,
    })
}

/// The atom class of a literal character typed in math mode, and the
/// character it stands for (`-` is a minus sign, `*` an asterisk operator).
pub fn literal(c: char) -> (char, Class) {
    use Class::*;
    match c {
        '+' => ('+', Bin),
        '-' | '−' => ('−', Bin),
        '*' => ('∗', Bin),
        '/' => ('/', Ord),
        '=' | '<' | '>' | ':' => (c, Rel),
        ',' | ';' => (c, Punct),
        '(' | '[' => (c, Open),
        ')' | ']' | '!' | '?' => (c, Close),
        '\'' => ('′', Ord),
        _ => (c, unicode_class(c)),
    }
}

/// Class of a non-ASCII character typed directly (e.g. `≤`), from the
/// command tables; Ord when unknown.
fn unicode_class(c: char) -> Class {
    match c {
        '±' | '∓' | '×' | '÷' | '⋅' | '∗' | '⋆' | '∘' | '∙' | '∪' | '∩' | '∖' | '∧' | '∨' | '⊕'
        | '⊖' | '⊗' | '⊙' => Class::Bin,
        '≤' | '≥' | '≠' | '≈' | '∼' | '≃' | '≅' | '≡' | '∝' | '≪' | '≫' | '∈' | '∉' | '∋' | '⊂'
        | '⊆' | '⊃' | '⊇' | '→' | '←' | '↔' | '⇒' | '⇐' | '⇔' | '↦' | '⟶' | '⟹' | '⟺' => {
            Class::Rel
        }
        '⟨' | '⌊' | '⌈' => Class::Open,
        '⟩' | '⌋' | '⌉' => Class::Close,
        _ => Class::Ord,
    }
}
