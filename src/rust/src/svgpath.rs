//! SVG path data (`d`) parsing (Phase 12).
//!
//! Turns the `d` mini-language into the flat rings a `path_grob()` is made of,
//! so an icon or a logo becomes real scene geometry rather than a raster pasted
//! into the figure.
//!
//! `d` is the unit of exchange that matters: icon sets (Font Awesome, Bootstrap
//! Icons, Lucide, Material) ship one `<path d="...">` per glyph, which is
//! exactly what `shape = <svg>` scatter markers need.
//!
//! The whole grammar is supported — all of `MmLlHhVvCcSsQqTtAaZz`, implicit
//! repeated commands, the smooth-curve reflection rules, and elliptical arcs —
//! because a partial implementation of a spec this small fails on real files
//! for reasons a user cannot diagnose.

/// Curves are flattened to polylines at this many segments per curve. Constant
/// rather than adaptive: an icon is drawn a few millimetres across, where the
/// difference is invisible, and the caller can simplify afterwards.
const CURVE_STEPS: usize = 16;

struct Lexer<'a> {
    s: &'a [u8],
    i: usize,
}

impl<'a> Lexer<'a> {
    fn new(s: &'a str) -> Self {
        Lexer { s: s.as_bytes(), i: 0 }
    }
    fn skip_sep(&mut self) {
        while self.i < self.s.len() {
            match self.s[self.i] {
                b' ' | b'\t' | b'\r' | b'\n' | b',' => self.i += 1,
                _ => break,
            }
        }
    }
    fn command(&mut self) -> Option<u8> {
        self.skip_sep();
        let c = *self.s.get(self.i)?;
        if c.is_ascii_alphabetic() {
            self.i += 1;
            Some(c)
        } else {
            None
        }
    }
    /// Peek whether another number follows (an implicit repeat of the command).
    fn has_number(&mut self) -> bool {
        self.skip_sep();
        match self.s.get(self.i) {
            Some(&c) => c == b'-' || c == b'+' || c == b'.' || c.is_ascii_digit(),
            None => false,
        }
    }
    fn number(&mut self) -> Option<f64> {
        self.skip_sep();
        let start = self.i;
        if matches!(self.s.get(self.i), Some(b'-') | Some(b'+')) {
            self.i += 1;
        }
        while matches!(self.s.get(self.i), Some(c) if c.is_ascii_digit()) {
            self.i += 1;
        }
        if self.s.get(self.i) == Some(&b'.') {
            self.i += 1;
            while matches!(self.s.get(self.i), Some(c) if c.is_ascii_digit()) {
                self.i += 1;
            }
        }
        if matches!(self.s.get(self.i), Some(b'e') | Some(b'E')) {
            let save = self.i;
            self.i += 1;
            if matches!(self.s.get(self.i), Some(b'-') | Some(b'+')) {
                self.i += 1;
            }
            if matches!(self.s.get(self.i), Some(c) if c.is_ascii_digit()) {
                while matches!(self.s.get(self.i), Some(c) if c.is_ascii_digit()) {
                    self.i += 1;
                }
            } else {
                self.i = save; // a trailing 'e' was not an exponent after all
            }
        }
        if self.i == start {
            return None;
        }
        std::str::from_utf8(&self.s[start..self.i]).ok()?.parse().ok()
    }
    /// An arc flag is a single character, `0` or `1`, and may be written without
    /// a separator ("a1 1 0 011 5 5"), so it cannot go through `number()`.
    fn flag(&mut self) -> Option<f64> {
        self.skip_sep();
        match self.s.get(self.i) {
            Some(b'0') => {
                self.i += 1;
                Some(0.0)
            }
            Some(b'1') => {
                self.i += 1;
                Some(1.0)
            }
            _ => None,
        }
    }
}

/// Parsed path: flattened rings as flat `x`/`y` plus a length per subpath, and
/// a flag per subpath recording whether it was explicitly closed.
pub struct SvgPath {
    pub x: Vec<f64>,
    pub y: Vec<f64>,
    pub nper: Vec<i32>,
    pub closed: Vec<bool>,
}

/// Flatten an elliptical arc (the `A` command) to line segments.
///
/// Implements the endpoint-to-centre conversion from the SVG spec's
/// implementation notes, including the radius correction for radii too small to
/// span the endpoints -- which real icon files do contain.
#[allow(clippy::too_many_arguments)]
fn arc_to(
    out: &mut Vec<(f64, f64)>,
    x0: f64, y0: f64, mut rx: f64, mut ry: f64,
    phi_deg: f64, large: bool, sweep: bool, x1: f64, y1: f64,
) {
    if rx == 0.0 || ry == 0.0 {
        out.push((x1, y1)); // degenerate radii: the spec says draw a line
        return;
    }
    rx = rx.abs();
    ry = ry.abs();
    let phi = phi_deg.to_radians();
    let (cp, sp) = (phi.cos(), phi.sin());
    let dx2 = (x0 - x1) / 2.0;
    let dy2 = (y0 - y1) / 2.0;
    let x1p = cp * dx2 + sp * dy2;
    let y1p = -sp * dx2 + cp * dy2;
    // Scale up radii that cannot reach between the endpoints.
    let lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
    if lam > 1.0 {
        let s = lam.sqrt();
        rx *= s;
        ry *= s;
    }
    let num = (rx * rx * ry * ry) - (rx * rx * y1p * y1p) - (ry * ry * x1p * x1p);
    let den = (rx * rx * y1p * y1p) + (ry * ry * x1p * x1p);
    let mut co = if den > 0.0 { (num / den).max(0.0).sqrt() } else { 0.0 };
    if large == sweep {
        co = -co;
    }
    let cxp = co * rx * y1p / ry;
    let cyp = -co * ry * x1p / rx;
    let cx = cp * cxp - sp * cyp + (x0 + x1) / 2.0;
    let cy = sp * cxp + cp * cyp + (y0 + y1) / 2.0;

    let ang = |ux: f64, uy: f64, vx: f64, vy: f64| -> f64 {
        let dot = ux * vx + uy * vy;
        let len = (ux * ux + uy * uy).sqrt() * (vx * vx + vy * vy).sqrt();
        let mut a = if len > 0.0 { (dot / len).clamp(-1.0, 1.0).acos() } else { 0.0 };
        if ux * vy - uy * vx < 0.0 {
            a = -a;
        }
        a
    };
    let (ux, uy) = ((x1p - cxp) / rx, (y1p - cyp) / ry);
    let (vx, vy) = ((-x1p - cxp) / rx, (-y1p - cyp) / ry);
    let theta = ang(1.0, 0.0, ux, uy);
    let mut delta = ang(ux, uy, vx, vy);
    if !sweep && delta > 0.0 {
        delta -= std::f64::consts::TAU;
    } else if sweep && delta < 0.0 {
        delta += std::f64::consts::TAU;
    }
    // More steps for a longer sweep, so a near-full ellipse is not coarse.
    let steps = ((delta.abs() / std::f64::consts::FRAC_PI_2 * CURVE_STEPS as f64).ceil() as usize)
        .clamp(2, 4 * CURVE_STEPS);
    for i in 1..=steps {
        let t = theta + delta * (i as f64 / steps as f64);
        let (ct, st) = (t.cos(), t.sin());
        out.push((cx + rx * ct * cp - ry * st * sp, cy + rx * ct * sp + ry * st * cp));
    }
}

fn cubic(out: &mut Vec<(f64, f64)>, p0: (f64, f64), p1: (f64, f64), p2: (f64, f64), p3: (f64, f64)) {
    for i in 1..=CURVE_STEPS {
        let t = i as f64 / CURVE_STEPS as f64;
        let u = 1.0 - t;
        let (a, b, c, d) = (u * u * u, 3.0 * u * u * t, 3.0 * u * t * t, t * t * t);
        out.push((
            a * p0.0 + b * p1.0 + c * p2.0 + d * p3.0,
            a * p0.1 + b * p1.1 + c * p2.1 + d * p3.1,
        ));
    }
}

/// Parse SVG path data into flattened rings.
///
/// Unknown commands stop the parse and whatever has been read so far is
/// returned, rather than erroring: a truncated icon is a better failure than no
/// icon and a stack trace, and the caller can see it in the output.
pub fn parse(d: &str) -> SvgPath {
    let mut lx = Lexer::new(d);
    let mut subpaths: Vec<(Vec<(f64, f64)>, bool)> = Vec::new();
    let mut cur: Vec<(f64, f64)> = Vec::new();
    let mut cur_closed = false;
    let (mut px, mut py) = (0.0f64, 0.0f64); // current point
    let (mut sx, mut sy) = (0.0f64, 0.0f64); // start of the current subpath
    // Last cubic/quadratic control point, for the S/T reflection rules.
    let mut last_c: Option<(f64, f64)> = None;
    let mut last_q: Option<(f64, f64)> = None;
    let mut cmd = 0u8;

    let flush = |cur: &mut Vec<(f64, f64)>, closed: bool, subpaths: &mut Vec<(Vec<(f64, f64)>, bool)>| {
        if cur.len() >= 2 {
            subpaths.push((std::mem::take(cur), closed));
        } else {
            cur.clear();
        }
    };

    loop {
        if let Some(c) = lx.command() {
            cmd = c;
        } else if !lx.has_number() {
            break;
        } else if cmd == b'M' {
            cmd = b'L'; // an implicit repeat of moveto is lineto, per the spec
        } else if cmd == b'm' {
            cmd = b'l';
        }
        let rel = cmd.is_ascii_lowercase();
        let (ox, oy) = if rel { (px, py) } else { (0.0, 0.0) };
        match cmd.to_ascii_uppercase() {
            b'M' => {
                let (Some(a), Some(b)) = (lx.number(), lx.number()) else { break };
                flush(&mut cur, cur_closed, &mut subpaths);
                cur_closed = false;
                px = ox + a;
                py = oy + b;
                sx = px;
                sy = py;
                cur.push((px, py));
                last_c = None;
                last_q = None;
            }
            b'L' => {
                let (Some(a), Some(b)) = (lx.number(), lx.number()) else { break };
                px = ox + a;
                py = oy + b;
                cur.push((px, py));
                last_c = None;
                last_q = None;
            }
            b'H' => {
                let Some(a) = lx.number() else { break };
                px = ox + a;
                cur.push((px, py));
                last_c = None;
                last_q = None;
            }
            b'V' => {
                let Some(a) = lx.number() else { break };
                py = oy + a;
                cur.push((px, py));
                last_c = None;
                last_q = None;
            }
            b'C' | b'S' => {
                let (c1, c2, end) = if cmd.to_ascii_uppercase() == b'C' {
                    let (Some(a), Some(b), Some(c), Some(d), Some(e), Some(f)) =
                        (lx.number(), lx.number(), lx.number(), lx.number(), lx.number(), lx.number())
                    else { break };
                    ((ox + a, oy + b), (ox + c, oy + d), (ox + e, oy + f))
                } else {
                    let (Some(c), Some(d), Some(e), Some(f)) =
                        (lx.number(), lx.number(), lx.number(), lx.number())
                    else { break };
                    // S reflects the previous cubic's second control point about
                    // the current point; with no previous cubic it is the point.
                    let r = match last_c {
                        Some((lcx, lcy)) => (2.0 * px - lcx, 2.0 * py - lcy),
                        None => (px, py),
                    };
                    (r, (ox + c, oy + d), (ox + e, oy + f))
                };
                if cur.is_empty() {
                    cur.push((px, py));
                }
                cubic(&mut cur, (px, py), c1, c2, end);
                last_c = Some(c2);
                last_q = None;
                px = end.0;
                py = end.1;
            }
            b'Q' | b'T' => {
                let (q, end) = if cmd.to_ascii_uppercase() == b'Q' {
                    let (Some(a), Some(b), Some(c), Some(d)) =
                        (lx.number(), lx.number(), lx.number(), lx.number())
                    else { break };
                    ((ox + a, oy + b), (ox + c, oy + d))
                } else {
                    let (Some(c), Some(d)) = (lx.number(), lx.number()) else { break };
                    let r = match last_q {
                        Some((lqx, lqy)) => (2.0 * px - lqx, 2.0 * py - lqy),
                        None => (px, py),
                    };
                    (r, (ox + c, oy + d))
                };
                if cur.is_empty() {
                    cur.push((px, py));
                }
                // Degree-elevate to a cubic rather than writing a second
                // flattener: exactly equivalent, and one code path to be wrong in.
                let c1 = (px + 2.0 / 3.0 * (q.0 - px), py + 2.0 / 3.0 * (q.1 - py));
                let c2 = (end.0 + 2.0 / 3.0 * (q.0 - end.0), end.1 + 2.0 / 3.0 * (q.1 - end.1));
                cubic(&mut cur, (px, py), c1, c2, end);
                last_q = Some(q);
                last_c = None;
                px = end.0;
                py = end.1;
            }
            b'A' => {
                let (Some(rx), Some(ry), Some(rot)) = (lx.number(), lx.number(), lx.number())
                else { break };
                let (Some(large), Some(sweep)) = (lx.flag(), lx.flag()) else { break };
                let (Some(a), Some(b)) = (lx.number(), lx.number()) else { break };
                let (ex, ey) = (ox + a, oy + b);
                if cur.is_empty() {
                    cur.push((px, py));
                }
                arc_to(&mut cur, px, py, rx, ry, rot, large != 0.0, sweep != 0.0, ex, ey);
                px = ex;
                py = ey;
                last_c = None;
                last_q = None;
            }
            b'Z' => {
                cur_closed = true;
                flush(&mut cur, true, &mut subpaths);
                cur_closed = false;
                px = sx;
                py = sy;
                last_c = None;
                last_q = None;
            }
            _ => break, // unknown command: keep what we have
        }
    }
    flush(&mut cur, cur_closed, &mut subpaths);

    let mut out = SvgPath { x: Vec::new(), y: Vec::new(), nper: Vec::new(), closed: Vec::new() };
    for (pts, closed) in subpaths {
        // A closed ring repeats its start point; the scene's rings are implicit,
        // so drop the duplicate rather than leaving a zero-length edge.
        let mut pts = pts;
        if closed && pts.len() > 2 {
            let (f, l) = (pts[0], pts[pts.len() - 1]);
            if (f.0 - l.0).abs() < 1e-12 && (f.1 - l.1).abs() < 1e-12 {
                pts.pop();
            }
        }
        if pts.len() < 2 {
            continue;
        }
        out.nper.push(pts.len() as i32);
        out.closed.push(closed);
        for (x, y) in pts {
            out.x.push(x);
            out.y.push(y);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_closed_triangle() {
        let p = parse("M 0 0 L 10 0 L 5 8 Z");
        assert_eq!(p.nper, vec![3]);
        assert_eq!(p.closed, vec![true]);
        assert_eq!(p.x, vec![0.0, 10.0, 5.0]);
        assert_eq!(p.y, vec![0.0, 0.0, 8.0]);
    }

    #[test]
    fn relative_commands_accumulate() {
        let abs = parse("M 0 0 L 10 0 L 10 10 Z");
        let rel = parse("m 0 0 l 10 0 l 0 10 z");
        assert_eq!(abs.x, rel.x);
        assert_eq!(abs.y, rel.y);
    }

    #[test]
    fn implicit_repeats_work_and_moveto_repeats_as_lineto() {
        let a = parse("M0 0 10 0 10 10");
        assert_eq!(a.nper, vec![3], "the repeated pairs are linetos, not moves");
        let b = parse("M0 0L10 0L10 10");
        assert_eq!(a.x, b.x);
    }

    #[test]
    fn horizontal_and_vertical_shorthands() {
        let a = parse("M0 0 H10 V10 H0 Z");
        assert_eq!(a.x, vec![0.0, 10.0, 10.0, 0.0]);
        assert_eq!(a.y, vec![0.0, 0.0, 10.0, 10.0]);
    }

    #[test]
    fn several_subpaths() {
        let p = parse("M0 0 L1 0 L1 1 Z M5 5 L6 5 L6 6 Z");
        assert_eq!(p.nper.len(), 2);
        assert_eq!(p.closed, vec![true, true]);
    }

    #[test]
    fn an_open_subpath_is_marked_open() {
        let p = parse("M0 0 L1 0 L1 1");
        assert_eq!(p.closed, vec![false]);
    }

    #[test]
    fn a_cubic_ends_where_it_should() {
        let p = parse("M0 0 C 0 10, 10 10, 10 0");
        let n = p.x.len();
        assert!((p.x[n - 1] - 10.0).abs() < 1e-9);
        assert!((p.y[n - 1] - 0.0).abs() < 1e-9);
        assert!(p.y.iter().any(|&v| v > 5.0), "it bulges upward");
    }

    #[test]
    fn a_smooth_cubic_reflects_the_previous_control_point() {
        // S after C must equal the explicit C with the reflected control point.
        let smooth = parse("M0 0 C0 5 5 5 5 0 S10 -5 10 0");
        let explicit = parse("M0 0 C0 5 5 5 5 0 C5 -5 10 -5 10 0");
        assert_eq!(smooth.x.len(), explicit.x.len());
        for (a, b) in smooth.y.iter().zip(explicit.y.iter()) {
            assert!((a - b).abs() < 1e-9);
        }
    }

    #[test]
    fn a_quadratic_matches_its_cubic_equivalent() {
        let q = parse("M0 0 Q 5 10 10 0");
        let c = parse("M0 0 C 3.3333333333333335 6.666666666666667 6.666666666666667 6.666666666666667 10 0");
        for (a, b) in q.y.iter().zip(c.y.iter()) {
            assert!((a - b).abs() < 1e-9, "{a} vs {b}");
        }
    }

    #[test]
    fn an_arc_traces_a_semicircle() {
        // Half of a unit circle, from (0,0) to (2,0).
        let p = parse("M0 0 A 1 1 0 0 1 2 0");
        let n = p.x.len();
        assert!((p.x[n - 1] - 2.0).abs() < 1e-9);
        // Every point sits on the circle centred at (1, 0).
        for i in 0..n {
            let d = ((p.x[i] - 1.0).powi(2) + p.y[i].powi(2)).sqrt();
            assert!((d - 1.0).abs() < 1e-6, "radius {d}");
        }
    }

    #[test]
    fn arc_flags_parse_without_separators() {
        // "a1 1 0 011 5 5" packs large=0, sweep=1, then x=1 -- the form real
        // minified icon files use, and the reason flags cannot go through the
        // number lexer.
        let packed = parse("M0 0a5 5 0 015 5");
        let spaced = parse("M0 0 a 5 5 0 0 1 5 5");
        assert_eq!(packed.x.len(), spaced.x.len());
        for (a, b) in packed.x.iter().zip(spaced.x.iter()) {
            assert!((a - b).abs() < 1e-9);
        }
    }

    #[test]
    fn arc_radii_too_small_are_scaled_up_not_rejected() {
        // Radius 1 cannot span 10 units; the spec says enlarge it. The result
        // must still land on the endpoint.
        let p = parse("M0 0 A 1 1 0 0 1 10 0");
        let n = p.x.len();
        assert!((p.x[n - 1] - 10.0).abs() < 1e-9);
        assert!(p.x.iter().all(|v| v.is_finite()));
    }

    #[test]
    fn scientific_notation_and_tight_packing() {
        let p = parse("M1e1,0L-1.5e1 0");
        assert_eq!(p.x, vec![10.0, -15.0]);
    }

    #[test]
    fn garbage_yields_nothing_rather_than_panicking() {
        assert!(parse("").nper.is_empty());
        assert!(parse("not a path").nper.is_empty());
        assert!(parse("M").nper.is_empty());
        assert!(parse("M 0").nper.is_empty());
    }

    #[test]
    fn a_truncated_path_keeps_what_parsed() {
        let p = parse("M0 0 L10 0 L10 10 L");
        assert_eq!(p.nper, vec![3]);
    }
}
