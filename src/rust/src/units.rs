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
pub enum Unit {
    /// Normalised parent coordinates: 0 = bottom/left, 1 = top/right.
    Npc,
    /// User coordinates relative to the viewport's `xscale`/`yscale`.
    Native,
    Mm,
    Inch,
    Pt,
}

impl Unit {
    /// Parse a unit string. Unknown strings fall back to `Npc`; callers validate
    /// on the R side, so this is only a safety net.
    pub fn parse(s: &str) -> Unit {
        match s {
            "native" => Unit::Native,
            "mm" => Unit::Mm,
            "in" | "inch" | "inches" => Unit::Inch,
            "pt" | "points" => Unit::Pt,
            _ => Unit::Npc,
        }
    }

    /// Length of one absolute unit in device pixels, if this unit is absolute.
    fn abs_px(self, value: f64, dpi: f64) -> Option<f64> {
        match self {
            Unit::Mm => Some(value / 25.4 * dpi),
            Unit::Inch => Some(value * dpi),
            Unit::Pt => Some(value / 72.0 * dpi),
            _ => None,
        }
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
    /// X position in local pixels (from the left edge). For `native` this
    /// accounts for the scale's origin; for npc/absolute, position == length.
    pub fn x_pos(&self, value: f64, u: Unit) -> f64 {
        match u {
            Unit::Native => (value - self.xscale.0) / span(self.xscale) * self.w,
            _ => self.x_len(value, u),
        }
    }

    /// Y position in local pixels (flips R's bottom-left convention into the
    /// local top-left frame). For `native` this accounts for the scale origin.
    pub fn y_pos(&self, value: f64, u: Unit) -> f64 {
        let from_bottom = match u {
            Unit::Native => (value - self.yscale.0) / span(self.yscale) * self.h,
            _ => self.y_len(value, u),
        };
        self.h - from_bottom
    }

    /// Horizontal length in local pixels.
    pub fn x_len(&self, value: f64, u: Unit) -> f64 {
        if let Some(px) = u.abs_px(value, self.dpi) {
            return px;
        }
        match u {
            Unit::Npc => value * self.w,
            Unit::Native => value / span(self.xscale) * self.w,
            _ => unreachable!("absolute handled above"),
        }
    }

    /// Vertical length in local pixels.
    pub fn y_len(&self, value: f64, u: Unit) -> f64 {
        if let Some(px) = u.abs_px(value, self.dpi) {
            return px;
        }
        match u {
            Unit::Npc => value * self.h,
            Unit::Native => value / span(self.yscale) * self.h,
            _ => unreachable!("absolute handled above"),
        }
    }

    /// Radius-like length: npc is taken against the smaller viewport dimension
    /// (snpc-style) so circles stay round; native uses the x scale. Kept as a
    /// single-unit resolver — radii must not be split per axis.
    pub fn r_len(&self, value: f64, u: Unit) -> f64 {
        if let Some(px) = u.abs_px(value, self.dpi) {
            return px;
        }
        match u {
            Unit::Npc => value * self.w.min(self.h),
            Unit::Native => value / span(self.xscale) * self.w,
            _ => unreachable!("absolute handled above"),
        }
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
