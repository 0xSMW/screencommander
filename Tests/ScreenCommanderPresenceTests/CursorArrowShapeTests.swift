import CoreGraphics
import XCTest
@testable import ScreenCommanderPresence

final class CursorArrowShapeTests: XCTestCase {
    private let shape = CursorArrowShape()

    func testVerticesMirrorAcrossTheAxis() {
        let vertices = shape.localVertices()
        XCTAssertEqual(vertices[0], .zero, "Tip on the axis")
        XCTAssertEqual(vertices[2].x, 0, "Notch on the axis")
        XCTAssertEqual(vertices[1].x, -vertices[3].x, accuracy: 1e-12)
        XCTAssertEqual(vertices[1].y, vertices[3].y, accuracy: 1e-12)
        XCTAssertGreaterThan(vertices[1].x, 0)
    }

    func testRoundedOutlineMirrorsAcrossTheAxis() {
        let points = Self.points(of: shape.localPath())
        XCTAssertFalse(points.isEmpty)
        for point in points {
            let mirrored = CGPoint(x: -point.x, y: point.y)
            XCTAssertTrue(
                points.contains { abs($0.x - mirrored.x) < 1e-9 && abs($0.y - mirrored.y) < 1e-9 },
                "No mirror for \(point)"
            )
        }
    }

    func testPlacementIsRotationPlusUniformScale() {
        let t = shape.placementTransform(height: 15)
        // No shear, no stretch: [a b; c d] is a scaled rotation.
        XCTAssertEqual(t.a, t.d, accuracy: 1e-12)
        XCTAssertEqual(t.b, -t.c, accuracy: 1e-12)
        XCTAssertEqual(atan2(t.b, t.a) * 180 / .pi, -shape.axisTilt, accuracy: 1e-9)
    }

    func testFinishedOutlineMirrorsAcrossTheRotatedAxis() {
        let points = Self.points(of: shape.path(height: 15))
        let tilt = shape.axisTilt * .pi / 180
        // The axis runs from the apex (origin) toward the tail at `tilt` from straight down.
        let axis = CGPoint(x: sin(tilt), y: cos(tilt))
        for point in points {
            let along = point.x * axis.x + point.y * axis.y
            let mirrored = CGPoint(x: 2 * along * axis.x - point.x, y: 2 * along * axis.y - point.y)
            XCTAssertTrue(
                points.contains { abs($0.x - mirrored.x) < 1e-9 && abs($0.y - mirrored.y) < 1e-9 },
                "No mirror for \(point)"
            )
        }
    }

    func testApexIsOnTheRoundedTipAndLandsOnTheHotspot() {
        // The tip corner is the first curve; its midpoint is where the arc crosses the axis.
        let elements = Self.elements(of: shape.localPath())
        guard let tipCurve = elements.first(where: { $0.count == 3 }), let start = elements.first?.first else {
            return XCTFail("Expected a curve")
        }
        let midpoint = Self.cubic(start, tipCurve[0], tipCurve[1], tipCurve[2], t: 0.5)
        XCTAssertEqual(midpoint.x, shape.localApex.x, accuracy: 1e-9)
        XCTAssertEqual(midpoint.y, shape.localApex.y, accuracy: 1e-3)

        let placed = shape.localApex.applying(shape.placementTransform(height: 15))
        XCTAssertEqual(placed.x, 0, accuracy: 1e-9)
        XCTAssertEqual(placed.y, 0, accuracy: 1e-9)
    }

    func testIsoscelesWithEqualFlanksAndWideShallowNotch() {
        let v = shape.localVertices()
        let right = hypot(v[1].x - v[0].x, v[1].y - v[0].y)
        let left = hypot(v[3].x - v[0].x, v[3].y - v[0].y)
        XCTAssertEqual(right, left, accuracy: 1e-12)
        XCTAssertEqual(right, shape.flankLength, accuracy: 1e-12)

        // Interior angle at the notch.
        let toRight = atan2(v[1].y - v[2].y, v[1].x - v[2].x)
        let toLeft = atan2(v[3].y - v[2].y, v[3].x - v[2].x)
        XCTAssertEqual((toLeft - toRight) * 180 / .pi, 155, accuracy: 1e-9)

        // Length from tip to the tail-corner line is about 1.15 times the span between the corners.
        let length = v[1].y
        let width = v[1].x - v[3].x
        XCTAssertEqual(length / width, 1.15, accuracy: 0.01)
        // The notch is shallow: under a tenth of the length.
        XCTAssertEqual(shape.notchDepth / length, 0.097, accuracy: 0.01)
    }

    func testAxisIsTheDiagonalAndNeitherFlankIsAxisAligned() {
        let t = shape.placementTransform(height: 15)
        let v = shape.localVertices().map { $0.applying(t) }
        let degrees = { (from: CGPoint, to: CGPoint) in atan2(to.y - from.y, to.x - from.x) * 180 / .pi }

        // Screen y grows down, so 45 degrees here is down and to the right.
        XCTAssertEqual(degrees(v[0], v[2]), 45, accuracy: 1e-9, "Axis on the diagonal")
        // Upper flank drops 21.5 degrees below horizontal, left flank leans 21.5 degrees off vertical.
        XCTAssertEqual(degrees(v[0], v[1]), 21.5, accuracy: 1e-9)
        XCTAssertEqual(degrees(v[0], v[3]), 68.5, accuracy: 1e-9)
        // The tail corners mirror each other across the diagonal: swap x and y.
        XCTAssertEqual(v[1].x - v[0].x, v[3].y - v[0].y, accuracy: 1e-9)
        XCTAssertEqual(v[1].y - v[0].y, v[3].x - v[0].x, accuracy: 1e-9)
    }

    func testCornersAreSoft() {
        XCTAssertEqual(shape.tipRadius / shape.flankLength, 0.095, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(shape.tailRadius, shape.tipRadius)
        XCTAssertGreaterThan(shape.notchRadius, shape.tailRadius)
    }

    // MARK: Helpers

    private static func elements(of path: CGPath) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint:
                result.append([element.points[0]])
            case .addQuadCurveToPoint:
                result.append([element.points[0], element.points[1]])
            case .addCurveToPoint:
                result.append([element.points[0], element.points[1], element.points[2]])
            case .closeSubpath:
                break
            @unknown default:
                break
            }
        }
        return result
    }

    private static func points(of path: CGPath) -> [CGPoint] {
        elements(of: path).flatMap { $0 }
    }

    private static func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
            y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        )
    }
}
