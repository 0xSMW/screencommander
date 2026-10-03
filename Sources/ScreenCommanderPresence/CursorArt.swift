import CoreGraphics
import Foundation

/// Per-session rim tints. The cursor body is neutral glass, so sessions are
/// told apart only by a faint tint in the rim and its glow. Slot 0 has no
/// tint, so a lone session reads as plain glass. A session keeps its slot for
/// its lifetime, and new sessions take the lowest free slot.
public enum CursorPalette {
    /// sRGB components, or nil for the neutral slot.
    public static let tints: [(red: CGFloat, green: CGFloat, blue: CGFloat)?] = [
        nil,                // neutral
        (1.00, 0.62, 0.30), // amber
        (0.72, 0.52, 1.00), // lavender
        (0.38, 0.86, 0.58), // mint
        (1.00, 0.48, 0.66), // rose
        (0.36, 0.80, 0.92)  // sky
    ]

    public static var count: Int {
        tints.count
    }

    public static func tint(at index: Int) -> CGColor? {
        guard let entry = tints[((index % count) + count) % count] else {
            return nil
        }
        return CGColor(srgbRed: entry.red, green: entry.green, blue: entry.blue, alpha: 1)
    }
}

/// Size and hotspot of the cursor window, plus conversions between the
/// hotspot's global CG point and the window's Cocoa frame. Pure, so the
/// "hotspot lands exactly on the requested point" rule is testable.
public enum CursorGeometry {
    /// Window size in points. Large enough for the arrow, its shadow and rim
    /// glow, and the sub-point art offset.
    public static let windowSize = CGSize(width: 32, height: 32)
    /// Arrow tip inside the window, measured from the window's top-left.
    public static let hotspot = CGPoint(x: 9, y: 8)
    /// Arrow height in points, rounded corners included.
    public static let arrowHeight: CGFloat = 15

    /// Cocoa window origin (bottom-left, y up) that puts the hotspot on
    /// `point`, given in global CG coordinates (top-left, y down).
    public static func windowOrigin(forHotspotAt point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(
            x: point.x - hotspot.x,
            y: primaryScreenHeight - point.y - (windowSize.height - hotspot.y)
        )
    }

    /// WindowServer keeps window origins on whole points, so a fractional
    /// point is split into a whole-point window origin plus a sub-point shift
    /// of the art inside the window (Cocoa axes, y up).
    public static func placement(forHotspotAt point: CGPoint, primaryScreenHeight: CGFloat) -> (windowOrigin: CGPoint, artOffset: CGPoint) {
        let exact = windowOrigin(forHotspotAt: point, primaryScreenHeight: primaryScreenHeight)
        let whole = CGPoint(x: exact.x.rounded(.down), y: exact.y.rounded(.down))
        return (whole, CGPoint(x: exact.x - whole.x, y: exact.y - whole.y))
    }

    /// Inverse of `windowOrigin(forHotspotAt:primaryScreenHeight:)`.
    public static func hotspot(forWindowOrigin origin: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(
            x: origin.x + hotspot.x,
            y: primaryScreenHeight - origin.y - (windowSize.height - hotspot.y)
        )
    }

    /// The arrowhead outline with its hotspot at the origin, x right and y
    /// down. See `CursorArrowShape` for how it is built.
    public static func arrowPath(height: CGFloat = arrowHeight) -> CGPath {
        CursorArrowShape().path(height: Double(height))
    }
}
