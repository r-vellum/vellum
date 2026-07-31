//! Boolean path operations (Phase 12, H2).
//!
//! Union / intersection / difference / xor over closed rings, via `i_overlay`.
//!
//! These produce **geometry**, not a render-time mask, and that is the point:
//! a mask rasterises, degrades on some PDF paths, and cannot be measured,
//! simplified, hit-tested or exported as `<path>` data. A boolean result is an
//! ordinary path and behaves like one everywhere.

use i_overlay::core::fill_rule::FillRule;
use i_overlay::core::overlay_rule::OverlayRule;
use i_overlay::float::single::SingleFloatOverlay;

/// Which boolean operation to apply.
pub enum Op {
    Union,
    Intersect,
    Difference,
    Xor,
}

impl Op {
    /// Decode the integer op code from R. Codes are part of the R<->Rust ABI and
    /// must match `.PATH_OPS` in `R/booleans.R`.
    pub fn from_code(code: i32) -> Op {
        match code {
            1 => Op::Intersect,
            2 => Op::Difference,
            3 => Op::Xor,
            _ => Op::Union,
        }
    }
    fn rule(&self) -> OverlayRule {
        match self {
            Op::Union => OverlayRule::Union,
            Op::Intersect => OverlayRule::Intersect,
            Op::Difference => OverlayRule::Difference,
            Op::Xor => OverlayRule::Xor,
        }
    }
}

/// Split a flat coordinate pair plus per-ring lengths into rings of points.
fn to_rings(x: &[f64], y: &[f64], nper: &[i32]) -> Vec<Vec<[f64; 2]>> {
    let mut out = Vec::with_capacity(nper.len());
    let mut at = 0usize;
    let n = x.len().min(y.len());
    for &len in nper {
        let len = len.max(0) as usize;
        let hi = (at + len).min(n);
        if hi > at {
            out.push((at..hi).map(|i| [x[i], y[i]]).collect());
        }
        at = hi;
    }
    out
}

/// Apply `op` to two sets of rings.
///
/// `even_odd` selects the fill rule used to interpret each *input* -- which is
/// what decides whether an inner ring is a hole or a separate island, and so
/// must match the `rule` the caller's paths were drawn with, or the answer will
/// be right for a shape they did not mean.
///
/// Returns `(x, y, nper)`: rings flattened the same way they arrived, so the
/// result can go straight back into a path grob.
pub fn path_op(
    ax: &[f64], ay: &[f64], anper: &[i32],
    bx: &[f64], by: &[f64], bnper: &[i32],
    op: Op, even_odd: bool,
) -> (Vec<f64>, Vec<f64>, Vec<i32>) {
    let subj = to_rings(ax, ay, anper);
    let clip = to_rings(bx, by, bnper);
    let fill = if even_odd { FillRule::EvenOdd } else { FillRule::NonZero };
    let shapes = subj.overlay(&clip, op.rule(), fill);

    let (mut x, mut y, mut nper) = (Vec::new(), Vec::new(), Vec::new());
    // `shapes` is a list of shapes, each a list of contours (outer then holes).
    // Both flatten into the ring list a path grob wants -- the winding already
    // distinguishes holes, which is why the result must be drawn with the
    // non-zero rule regardless of what the inputs used.
    for shape in shapes {
        for contour in shape {
            if contour.len() < 3 {
                continue;
            }
            nper.push(contour.len() as i32);
            for p in contour {
                x.push(p[0]);
                y.push(p[1]);
            }
        }
    }
    (x, y, nper)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Two unit squares overlapping in a 0.5 x 1 strip.
    fn a() -> (Vec<f64>, Vec<f64>, Vec<i32>) {
        (vec![0.0, 1.0, 1.0, 0.0], vec![0.0, 0.0, 1.0, 1.0], vec![4])
    }
    fn b() -> (Vec<f64>, Vec<f64>, Vec<i32>) {
        (vec![0.5, 1.5, 1.5, 0.5], vec![0.0, 0.0, 1.0, 1.0], vec![4])
    }
    fn area(x: &[f64], y: &[f64], nper: &[i32]) -> f64 {
        let mut at = 0usize;
        let mut total = 0.0;
        for &len in nper {
            let len = len as usize;
            let mut s = 0.0;
            for i in 0..len {
                let j = (i + 1) % len;
                s += x[at + i] * y[at + j] - x[at + j] * y[at + i];
            }
            total += s / 2.0;
            at += len;
        }
        total.abs()
    }

    #[test]
    fn union_is_the_combined_area() {
        let (ax, ay, an) = a();
        let (bx, by, bn) = b();
        let (x, y, n) = path_op(&ax, &ay, &an, &bx, &by, &bn, Op::Union, false);
        assert!((area(&x, &y, &n) - 1.5).abs() < 1e-6, "got {}", area(&x, &y, &n));
    }

    #[test]
    fn intersection_is_the_overlap() {
        let (ax, ay, an) = a();
        let (bx, by, bn) = b();
        let (x, y, n) = path_op(&ax, &ay, &an, &bx, &by, &bn, Op::Intersect, false);
        assert!((area(&x, &y, &n) - 0.5).abs() < 1e-6, "got {}", area(&x, &y, &n));
    }

    #[test]
    fn difference_removes_the_overlap() {
        let (ax, ay, an) = a();
        let (bx, by, bn) = b();
        let (x, y, n) = path_op(&ax, &ay, &an, &bx, &by, &bn, Op::Difference, false);
        assert!((area(&x, &y, &n) - 0.5).abs() < 1e-6, "got {}", area(&x, &y, &n));
    }

    #[test]
    fn xor_is_union_minus_intersection() {
        let (ax, ay, an) = a();
        let (bx, by, bn) = b();
        let (x, y, n) = path_op(&ax, &ay, &an, &bx, &by, &bn, Op::Xor, false);
        assert!((area(&x, &y, &n) - 1.0).abs() < 1e-6, "got {}", area(&x, &y, &n));
    }

    #[test]
    fn disjoint_shapes_union_to_two_rings() {
        let (ax, ay, an) = a();
        let far = (vec![5.0, 6.0, 6.0, 5.0], vec![0.0, 0.0, 1.0, 1.0], vec![4]);
        let (_, _, n) = path_op(&ax, &ay, &an, &far.0, &far.1, &far.2, Op::Union, false);
        assert_eq!(n.len(), 2);
    }

    #[test]
    fn cutting_a_hole_leaves_two_rings() {
        // A big square minus a small central one: outer boundary plus the hole.
        let outer = (vec![0.0, 4.0, 4.0, 0.0], vec![0.0, 0.0, 4.0, 4.0], vec![4]);
        let inner = (vec![1.0, 3.0, 3.0, 1.0], vec![1.0, 1.0, 3.0, 3.0], vec![4]);
        let (x, y, n) = path_op(
            &outer.0, &outer.1, &outer.2, &inner.0, &inner.1, &inner.2,
            Op::Difference, false,
        );
        assert_eq!(n.len(), 2, "outer ring + hole");
        assert!((area(&x, &y, &n) - (16.0 - 4.0)).abs() < 1e-6);
    }

    #[test]
    fn an_empty_result_is_empty_not_a_panic() {
        let (ax, ay, an) = a();
        let far = (vec![5.0, 6.0, 6.0, 5.0], vec![0.0, 0.0, 1.0, 1.0], vec![4]);
        let (x, _, n) = path_op(&ax, &ay, &an, &far.0, &far.1, &far.2, Op::Intersect, false);
        assert!(x.is_empty() && n.is_empty());
    }
}
