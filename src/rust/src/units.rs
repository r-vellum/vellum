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

/// A resolved viewport: its local pixel size and native scales, plus the affine
/// transform mapping local pixels to device pixels. Geometry is built in local
/// pixels and drawn through `transform`.
#[derive(Clone, Copy, Debug)]
pub struct Vp {
    pub transform: Transform,
    pub w: f64,
    pub h: f64,
    pub xscale: (f64, f64),
    pub yscale: (f64, f64),
    pub dpi: f64,
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
        base + u.off_px(self.dpi)
    }

    /// Y position in local pixels (flips R's bottom-left convention into the
    /// local top-left frame). For `native` this accounts for the scale origin.
    /// A positive mm offset moves *up* (R's y-up), so it is added before the flip.
    pub fn y_pos(&self, value: f64, u: Unit) -> f64 {
        let from_bottom = match u.kind {
            UnitKind::Native => (value - self.yscale.0) / span(self.yscale) * self.h,
            _ => self.y_len_base(value, u.kind),
        };
        self.h - (from_bottom + u.off_px(self.dpi))
    }

    /// Horizontal length in local pixels.
    pub fn x_len(&self, value: f64, u: Unit) -> f64 {
        self.x_len_base(value, u.kind) + u.off_px(self.dpi)
    }

    /// Vertical length in local pixels.
    pub fn y_len(&self, value: f64, u: Unit) -> f64 {
        self.y_len_base(value, u.kind) + u.off_px(self.dpi)
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
