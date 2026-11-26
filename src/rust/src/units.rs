//! The unit system and its resolution to **viewport-local** pixels.
//!
//! A coordinate is a `(value, Unit)` pair. Resolution happens against a resolved
//! viewport ([`Vp`]) and yields a point/length in *viewport-local* pixels:
//! origin at the viewport's top-left, x right, y down. Placement and rotation
//! into device space are handled by the viewport's affine `transform`, so the
//! resolvers here are purely about the viewport's own coordinate systems. The
//! y-resolvers flip R's bottom-left convention into the local top-left frame.

use tiny_skia::Transform;

/// Coordinate systems supported for primitive coordinates (M1/M2). The flexible
/// `null` unit lives only in layout track sizes, not here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnitKind {
    /// Normalised parent coordinates: 0 = bottom/left, 1 = top/right.
    Npc,
    /// User coordinates relative to the viewport's `xscale`/`yscale`.
    Native,
    Mm,
    Inch,
    Pt,
}

/// A coordinate unit: a base coordinate system plus an optional absolute offset
/// in millimetres — the compound `native + mm` / `npc + mm` unit (B1). The base
/// resolves against the viewport; the offset is added as a device length, so a
/// data or panel anchor can be nudged by an exact physical distance regardless
/// of the scale or aspect. `off_mm == 0.0` is the ordinary single-code unit.
#[derive(Clone, Copy, Debug)]
pub struct Unit {
    pub kind: UnitKind,
    pub off_mm: f64,
}

/// Decode an integer base-unit code from R (npc=0, native=1, mm=2, in=3, pt=4).
/// These codes are part of the R<->Rust ABI and MUST match `.unit_codes` in
/// `R/unit.R`. Unknown codes fall back to npc.
fn kind_from_code(code: i32) -> UnitKind {
    match code {
        1 => UnitKind::Native,
        2 => UnitKind::Mm,
        3 => UnitKind::Inch,
        4 => UnitKind::Pt,
        _ => UnitKind::Npc,
    }
}

/// Length of one absolute base unit in device pixels, if the base is absolute.
fn abs_px(kind: UnitKind, value: f64, dpi: f64) -> Option<f64> {
    match kind {
        UnitKind::Mm => Some(value / 25.4 * dpi),
        UnitKind::Inch => Some(value * dpi),
        UnitKind::Pt => Some(value / 72.0 * dpi),
        _ => None,
    }
}

impl Unit {
    /// A unit with no absolute offset (the ordinary single-code case).
    pub const fn plain(kind: UnitKind) -> Unit {
        Unit { kind, off_mm: 0.0 }
    }

    /// Parse a unit string (base only; an offset is not encodable in a string).
    /// Unknown strings fall back to `Npc`; callers validate on the R side, so
    /// this is only a safety net.
    pub fn parse(s: &str) -> Unit {
        let kind = match s {
            "native" => UnitKind::Native,
            "mm" => UnitKind::Mm,
            "in" | "inch" | "inches" => UnitKind::Inch,
            "pt" | "points" => UnitKind::Pt,
            _ => UnitKind::Npc,
        };
        Unit::plain(kind)
    }

    /// Decode an integer base code from R, with no offset.
    pub fn from_code(code: i32) -> Unit {
        Unit::plain(kind_from_code(code))
    }

    /// Decode a base code plus an absolute mm offset — the compound-unit ABI.
    pub fn from_code_off(code: i32, off_mm: f64) -> Unit {
        Unit { kind: kind_from_code(code), off_mm }
    }

    /// This unit's absolute offset in device pixels.
    fn off_px(self, dpi: f64) -> f64 {
        self.off_mm / 25.4 * dpi
    }
}

/// Device or local coordinates (px) below which `f32` still resolves 1/128 px,
/// so geometry there is built and placed in `f32` as it always was. Beyond it,
/// geometry is placed in `f64` before it is narrowed (VR-45): at 1e7 px an
/// `f32` coordinate snaps to whole pixels, at 1e9 px to 64 px.
pub const PRECISE_PX: f64 = 65536.0;

/// An affine map in `f64`, laid out like tiny-skia's [`Transform`]
/// (`x' = sx x + kx y + tx`, `y' = ky x + sy y + ty`). Viewport placement is
/// composed in it so a large offset cancelled further down the tree is not
/// rounded first (VR-45).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Affine {
    pub sx: f64,
    pub ky: f64,
    pub kx: f64,
    pub sy: f64,
    pub tx: f64,
    pub ty: f64,
}

impl Affine {
    pub const IDENTITY: Affine = Affine {
        sx: 1.0,
        ky: 0.0,
        kx: 0.0,
        sy: 1.0,
        tx: 0.0,
        ty: 0.0,
    };

    pub fn from_transform(t: Transform) -> Affine {
        Affine {
            sx: t.sx as f64,
            ky: t.ky as f64,
            kx: t.kx as f64,
            sy: t.sy as f64,
            tx: t.tx as f64,
            ty: t.ty as f64,
        }
    }

    /// Narrowed to tiny-skia's `f32` transform.
    pub fn to_transform(self) -> Transform {
        Transform::from_row(
            self.sx as f32,
            self.ky as f32,
            self.kx as f32,
            self.sy as f32,
            self.tx as f32,
            self.ty as f32,
        )
    }

    pub fn translate(x: f64, y: f64) -> Affine {
        Affine {
            tx: x,
            ty: y,
            ..Affine::IDENTITY
        }
    }

    /// `self` after `o` (`o` applied first), as [`Transform::pre_concat`].
    pub fn pre_concat(self, o: Affine) -> Affine {
        Affine {
            sx: self.sx * o.sx + self.kx * o.ky,
            ky: self.ky * o.sx + self.sy * o.ky,
            kx: self.sx * o.kx + self.kx * o.sy,
            sy: self.ky * o.kx + self.sy * o.sy,
            tx: self.sx * o.tx + self.kx * o.ty + self.tx,
            ty: self.ky * o.tx + self.sy * o.ty + self.ty,
        }
    }

    /// [`rotation_about`] in `f64`.
    pub fn rotation_about(angle_deg: f64, cx: f64, cy: f64) -> Affine {
        let v = (-angle_deg).to_radians();
        let (s, c) = v.sin_cos();
        let rot = Affine {
            sx: c,
            ky: s,
            kx: -s,
            sy: c,
            tx: 0.0,
            ty: 0.0,
        };
        Affine::translate(cx, cy)
            .pre_concat(rot)
            .pre_concat(Affine::translate(-cx, -cy))
    }

    pub fn is_finite(&self) -> bool {
        [self.sx, self.ky, self.kx, self.sy, self.tx, self.ty]
            .iter()
            .all(|v| v.is_finite())
    }

    /// The point that maps to the device origin, `None` if not invertible.
    pub fn preimage_of_origin(&self) -> Option<(f64, f64)> {
        let det = self.sx * self.sy - self.kx * self.ky;
        if det == 0.0 || !det.is_finite() {
            return None;
        }
        let x = (-self.sy * self.tx + self.kx * self.ty) / det;
        let y = (self.ky * self.tx - self.sx * self.ty) / det;
        (x.is_finite() && y.is_finite()).then_some((x, y))
    }
}

/// A resolved viewport: its local pixel size and native scales, plus the affine
/// transform mapping local pixels to device pixels. Geometry is built in local
/// pixels and drawn through `transform`.
///
/// A viewport placed far from the device origin (beyond [`PRECISE_PX`]) is
/// *rebased* (VR-45): its local frame is shifted by `origin`, chosen so that
/// `transform` carries no large offset, and every position the resolvers
/// return is shifted with it. Geometry the viewport puts back on the page then
/// has small local coordinates, which `f32` holds exactly enough. Every other
/// viewport has `origin` `(0, 0)` and is unchanged.
#[derive(Clone, Copy, Debug)]
pub struct Vp {
    pub transform: Transform,
    pub w: f64,
    pub h: f64,
    pub xscale: (f64, f64),
    pub yscale: (f64, f64),
    pub dpi: f64,
    /// The local frame's shift (local px): positions are `unshifted - origin`.
    pub origin: (f64, f64),
    /// The unshifted local -> device map, in `f64`.
    pub exact: Affine,
}

impl Vp {
    // The `*_base` helpers resolve the base code with no offset; the public
    // resolvers add the unit's absolute mm offset (`off_px`) exactly once, so a
    // compound `native + mm` lands `off_mm` past its data/panel anchor. Every
    // caller passes a `Unit`, so the offset rides through unchanged.

    fn x_len_base(&self, value: f64, kind: UnitKind) -> f64 {
        if let Some(px) = abs_px(kind, value, self.dpi) {
            return px;
        }
        match kind {
            UnitKind::Npc => value * self.w,
            UnitKind::Native => value / span(self.xscale) * self.w,
            _ => unreachable!("absolute handled above"),
        }
    }

    fn y_len_base(&self, value: f64, kind: UnitKind) -> f64 {
        if let Some(px) = abs_px(kind, value, self.dpi) {
            return px;
        }
        match kind {
            UnitKind::Npc => value * self.h,
            UnitKind::Native => value / span(self.yscale) * self.h,
            _ => unreachable!("absolute handled above"),
        }
    }

    /// X position in local pixels (from the left edge). For `native` this
    /// accounts for the scale's origin; for npc/absolute, position == length.
    pub fn x_pos(&self, value: f64, u: Unit) -> f64 {
        let base = match u.kind {
            UnitKind::Native => (value - self.xscale.0) / span(self.xscale) * self.w,
            _ => self.x_len_base(value, u.kind),
        };
        base + u.off_px(self.dpi) - self.origin.0
    }

    /// Y position in local pixels (flips R's bottom-left convention into the
    /// local top-left frame). For `native` this accounts for the scale origin.
    /// A positive mm offset moves *up* (R's y-up), so it is added before the flip.
    pub fn y_pos(&self, value: f64, u: Unit) -> f64 {
        let from_bottom = match u.kind {
            UnitKind::Native => (value - self.yscale.0) / span(self.yscale) * self.h,
            _ => self.y_len_base(value, u.kind),
        };
        self.h - (from_bottom + u.off_px(self.dpi)) - self.origin.1
    }

    /// Horizontal length in local pixels.
    pub fn x_len(&self, value: f64, u: Unit) -> f64 {
        self.x_len_base(value, u.kind) + u.off_px(self.dpi)
    }

    /// Vertical length in local pixels.
    pub fn y_len(&self, value: f64, u: Unit) -> f64 {
        self.y_len_base(value, u.kind) + u.off_px(self.dpi)
    }

    /// Horizontal size of a centred box (rect, round rect, hexagon, image) in
    /// local pixels. Like [`Vp::x_len`], but a `native` size is measured against
    /// the scale's magnitude, so a box on a reversed axis (a decreasing
    /// `xscale`) keeps a positive width instead of resolving negative and being
    /// dropped. Grid draws such a box the same way.
    pub fn x_extent(&self, value: f64, u: Unit) -> f64 {
        match u.kind {
            UnitKind::Native => value / span(self.xscale).abs() * self.w + u.off_px(self.dpi),
            _ => self.x_len(value, u),
        }
    }

    /// Vertical size of a centred box; see [`Vp::x_extent`].
    pub fn y_extent(&self, value: f64, u: Unit) -> f64 {
        match u.kind {
            UnitKind::Native => value / span(self.yscale).abs() * self.h + u.off_px(self.dpi),
            _ => self.y_len(value, u),
        }
    }

    /// Radius-like length: npc is taken against the smaller viewport dimension
    /// (snpc-style) so circles stay round; native uses the x scale. Kept as a
    /// single-unit resolver — radii must not be split per axis.
    pub fn r_len(&self, value: f64, u: Unit) -> f64 {
        let base = if let Some(px) = abs_px(u.kind, value, self.dpi) {
            px
        } else {
            match u.kind {
                UnitKind::Npc => value * self.w.min(self.h),
                UnitKind::Native => value / span(self.xscale) * self.w,
                _ => unreachable!("absolute handled above"),
            }
        };
        base + u.off_px(self.dpi)
    }
}

/// Rotation by `angle_deg` (grid's counter-clockwise convention) about a point
/// given in local pixels. The device frame is y-down, so we negate the angle —
/// this is the single place that sign lives.
pub fn rotation_about(angle_deg: f64, cx: f64, cy: f64) -> Transform {
    Transform::from_rotate_at((-angle_deg) as f32, cx as f32, cy as f32)
}

fn span((lo, hi): (f64, f64)) -> f64 {
    let s = hi - lo;
    if s == 0.0 {
        1.0
    } else {
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vp(xscale: (f64, f64), yscale: (f64, f64)) -> Vp {
        Vp {
            transform: Transform::identity(),
            w: 200.0,
            h: 100.0,
            xscale,
            yscale,
            dpi: 96.0,
            origin: (0.0, 0.0),
            exact: Affine::IDENTITY,
        }
    }

    #[test]
    fn box_extent_is_positive_on_a_reversed_axis() {
        let n = Unit::plain(UnitKind::Native);
        let fwd = vp((0.0, 10.0), (0.0, 5.0));
        let rev = vp((10.0, 0.0), (5.0, 0.0));
        // a signed length flips sign on a reversed axis ...
        assert!(rev.x_len(1.0, n) < 0.0);
        assert!(rev.y_len(1.0, n) < 0.0);
        // ... but a box size keeps its magnitude
        assert_eq!(rev.x_extent(1.0, n), fwd.x_extent(1.0, n));
        assert_eq!(rev.y_extent(1.0, n), fwd.y_extent(1.0, n));
        assert_eq!(fwd.x_extent(1.0, n), 20.0);
        assert_eq!(fwd.y_extent(1.0, n), 20.0);
        // non-native units are unchanged
        let mm = Unit::plain(UnitKind::Mm);
        assert_eq!(rev.x_extent(10.0, mm), rev.x_len(10.0, mm));
    }

    #[test]
    fn affine_matches_tiny_skia() {
        let a = Transform::from_translate(12.5, -3.25)
            .pre_concat(rotation_about(30.0, 40.0, 20.0))
            .pre_concat(Transform::from_translate(7.0, 9.0));
        let b = Affine::translate(12.5, -3.25)
            .pre_concat(Affine::rotation_about(30.0, 40.0, 20.0))
            .pre_concat(Affine::translate(7.0, 9.0))
            .to_transform();
        for (x, y) in [
            (a.sx, b.sx),
            (a.ky, b.ky),
            (a.kx, b.kx),
            (a.sy, b.sy),
            (a.tx, b.tx),
            (a.ty, b.ty),
        ] {
            assert!((x - y).abs() < 1e-4, "{x} vs {y}");
        }
    }

    #[test]
    fn the_preimage_of_the_origin_maps_to_it() {
        let a = Affine::translate(-2e9, 3e8).pre_concat(Affine::rotation_about(20.0, 5.0, 5.0));
        let (x, y) = a.preimage_of_origin().unwrap();
        let back = a.pre_concat(Affine::translate(x, y));
        assert!(back.tx.abs() < 1e-5 && back.ty.abs() < 1e-5);
        assert!(Affine {
            sx: 0.0,
            sy: 0.0,
            ..Affine::IDENTITY
        }
        .preimage_of_origin()
        .is_none());
    }

    #[test]
    fn a_rebased_frame_shifts_positions_only() {
        let mut v = vp((0.0, 10.0), (0.0, 5.0));
        let pt = Unit::plain(UnitKind::Pt);
        let (x, y) = (v.x_pos(3.0, pt), v.y_pos(3.0, pt));
        v.origin = (1e7, -2e7);
        assert_eq!(v.x_pos(3.0, pt), x - 1e7);
        assert_eq!(v.y_pos(3.0, pt), y + 2e7);
        assert_eq!(v.x_len(3.0, pt), 4.0);
    }
}
