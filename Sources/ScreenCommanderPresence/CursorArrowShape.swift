import CoreGraphics
import Foundation

/// The arrowhead outline, built mirror-symmetric in a local frame and only
/// then rotated as a rigid body to its pointing angle.
///
/// Local frame: tip at the origin, the axis running straight down (+y) from
/// the tip to the tail notch, x to the right. Every right-hand point has a
/// left-hand twin at (-x, y), and mirrored corners share their radius, so the
/// two flanks are exact reflections, curve handles included.
public struct CursorArrowShape: Equatable, Sendable {
    /// Full angle at the tip, in degrees.
    public var tipAngle: Double = 47
    /// Tip to each tail corner, in local units. Only proportions matter,
    /// since `path(height:)` scales the result.
    public var flankLength: Double = 20
    /// Interior angle of the shallow notch in the back edge, in degrees.
    /// 180 would be a straight back edge.
    public var notchAngle: Double = 155
    /// Blunt, soft corners: about 9.5% of the flank at the tip, a little more
    /// on the two tail lobes, and a wide fillet in the notch.
    public var tipRadius: Double = 1.9
    public var tailRadius: Double = 2.2
    public var notchRadius: Double = 5
    /// Angle between the axis and straight down, in degrees. Positive swings
    /// the tail to the right so the arrow points up and to the left. At 45 the
    /// axis lies on the screen diagonal and neither flank is vertical or
    /// horizontal.
    public var axisTilt: Double = 45

    public init() {}

    /// Half-width and axial distance of the tail corners in the local frame.
    private var tail: CGPoint {
        let half = tipAngle / 2 * .pi / 180
        return CGPoint(x: flankLength * sin(half), y: flankLength * cos(half))
    }

    /// How far the notch vertex sits in front of the line through the tail
    /// corners, toward the tip.
    public var notchDepth: Double {
        let lean = (180 - notchAngle) / 2 * .pi / 180
        return Double(tail.x) * tan(lean)
    }

    /// Corners in order: tip, right tail corner, notch, left tail corner.
    public func localVertices() -> [CGPoint] {
        let tail = tail
        return [
            CGPoint(x: 0, y: 0),
            CGPoint(x: tail.x, y: tail.y),
            CGPoint(x: 0, y: tail.y - notchDepth),
            CGPoint(x: -tail.x, y: tail.y)
        ]
    }

    private var radii: [Double] {
        [tipRadius, tailRadius, notchRadius, tailRadius]
    }

    /// Distance from the tip vertex to the rounded tip's apex, along the axis.
    public var apexInset: Double {
        let half = tipAngle / 2 * .pi / 180
        return tipRadius / sin(half) - tipRadius
    }

    /// The rounded tip's apex in the local frame: where the tip's arc crosses
    /// the axis. This is the hotspot, not the sharper point where the flank
    /// lines would meet if extended.
    public var localApex: CGPoint {
        CGPoint(x: 0, y: apexInset)
    }

    /// The rounded outline in the local frame.
    public func localPath() -> CGPath {
        Self.roundedPolygon(localVertices(), radii: radii)
    }

    /// Rotation for `axisTilt`, a uniform scale to `height`, and a shift that
    /// puts the apex at the origin. A similarity transform: no shear and no
    /// stretch, so the mirror symmetry survives intact.
    public func placementTransform(height: Double) -> CGAffineTransform {
        let rotation = CGAffineTransform(rotationAngle: -axisTilt * .pi / 180)
        var rotated = rotation
        let box = localPath().copy(using: &rotated)?.boundingBoxOfPath ?? localPath().boundingBoxOfPath
        let scale = height / Double(box.height)
        let apex = localApex.applying(rotation)
        return rotation
            .concatenating(CGAffineTransform(translationX: -apex.x, y: -apex.y))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }

    /// The finished outline: `height` tall, apex at the origin, x right, y down.
    public func path(height: Double) -> CGPath {
        var transform = placementTransform(height: height)
        return localPath().copy(using: &transform) ?? localPath()
    }

    /// Closed path with each corner replaced by a circular arc of its radius,
    /// drawn as one cubic per corner. Concave corners round the same way.
    static func roundedPolygon(_ vertices: [CGPoint], radii: [Double]) -> CGPath {
        let count = vertices.count
        var corners: [(start: CGPoint, control1: CGPoint, control2: CGPoint, end: CGPoint)] = []

        for index in 0..<count {
            let vertex = vertices[index]
            let previous = vertices[(index + count - 1) % count]
            let next = vertices[(index + 1) % count]
            let incoming = unit(from: previous, to: vertex)
            let outgoing = unit(from: vertex, to: next)
            // Angle between the two edges at the vertex.
            let toPrevious = CGPoint(x: -incoming.x, y: -incoming.y)
            let cosine = max(-1, min(1, Double(toPrevious.x * outgoing.x + toPrevious.y * outgoing.y)))
            let angle = acos(cosine)
            let radius = radii[index]
            let tangent = radius / tan(angle / 2)
            let sweep = Double.pi - angle
            let handle = 4.0 / 3.0 * tan(sweep / 4) * radius

            let start = CGPoint(x: vertex.x - incoming.x * tangent, y: vertex.y - incoming.y * tangent)
            let end = CGPoint(x: vertex.x + outgoing.x * tangent, y: vertex.y + outgoing.y * tangent)
            corners.append((
                start,
                CGPoint(x: start.x + incoming.x * handle, y: start.y + incoming.y * handle),
                CGPoint(x: end.x - outgoing.x * handle, y: end.y - outgoing.y * handle),
                end
            ))
        }

        let path = CGMutablePath()
        path.move(to: corners[0].start)
        for corner in corners {
            path.addLine(to: corner.start)
            path.addCurve(to: corner.end, control1: corner.control1, control2: corner.control2)
        }
        path.closeSubpath()
        return path
    }

    private static func unit(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        return CGPoint(x: dx / length, y: dy / length)
    }
}
