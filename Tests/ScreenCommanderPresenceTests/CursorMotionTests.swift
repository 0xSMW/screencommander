import CoreGraphics
import XCTest
@testable import ScreenCommanderPresence

final class CursorMotionTests: XCTestCase {
    private let tuning = CursorMotionTuning()

    func testPathHitsEndpoints() {
        let path = CursorPath(from: CGPoint(x: 10, y: 20), to: CGPoint(x: 410, y: 320), tuning: tuning)
        XCTAssertEqual(path.point(at: 0), CGPoint(x: 10, y: 20))
        assertClose(path.point(at: 1), CGPoint(x: 410, y: 320))
        // Out-of-range progress clamps instead of extrapolating.
        assertClose(path.point(at: 1.2), CGPoint(x: 410, y: 320))
        XCTAssertEqual(path.point(at: -0.5), CGPoint(x: 10, y: 20))
    }

    func testShortMovesAreStraight() {
        let start = CGPoint(x: 100, y: 100)
        let end = CGPoint(x: 106, y: 104)
        let path = CursorPath(from: start, to: end, tuning: tuning)
        for step in 0...10 {
            let t = Double(step) / 10
            let point = path.point(at: t)
            // On the chord: cross product with the direction is zero.
            let cross = (point.x - start.x) * (end.y - start.y) - (point.y - start.y) * (end.x - start.x)
            XCTAssertEqual(cross, 0, accuracy: 1e-9)
        }
    }

    func testLongMovesBowUpward() {
        let path = CursorPath(from: CGPoint(x: 0, y: 500), to: CGPoint(x: 800, y: 500), tuning: tuning)
        XCTAssertLessThan(path.point(at: 0.5).y, 500, "Horizontal moves arc toward the top of the screen")
        XCTAssertLessThanOrEqual(500 - path.control1.y, tuning.maximumArc + 0.001)
    }

    func testResponseScalesWithDistanceAndClamps() {
        XCTAssertEqual(tuning.response(forDistance: 0), 0.12, accuracy: 1e-9)
        XCTAssertLessThan(tuning.response(forDistance: 100), tuning.response(forDistance: 1000))
        XCTAssertEqual(tuning.response(forDistance: 1_000_000), 2.2, accuracy: 1e-9)
        XCTAssertEqual(CursorSpring(response: 0.01).response, 0.12, accuracy: 1e-9)
        XCTAssertEqual(CursorSpring(response: 50).response, 2.2, accuracy: 1e-9)
    }

    func testSpringUsesSkyDamping() {
        XCTAssertEqual(CursorSpring(response: 0.5).dampingRatio, 0.9)
    }

    func testProgressIsMonotonicAndSettles() {
        var motion = CursorMotion(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 900, y: 600), tuning: tuning)
        var previous = motion.progress
        var elapsed = 0.0
        while !motion.isFinished && elapsed < 10 {
            motion.step(1.0 / 120)
            elapsed += 1.0 / 120
            XCTAssertGreaterThanOrEqual(motion.progress, previous - 1e-12)
            XCTAssertLessThanOrEqual(motion.progress, 1)
            previous = motion.progress
        }
        XCTAssertTrue(motion.isFinished)
        XCTAssertEqual(motion.progress, 1)
        assertClose(motion.point, CGPoint(x: 900, y: 600))
        XCTAssertLessThan(elapsed, 2.2 * 2, "Settles within a couple of response periods")
    }

    func testStepIsFrameRateIndependent() {
        var coarse = CursorSpring(response: 0.6)
        var fine = CursorSpring(response: 0.6)
        coarse.step(0.3)
        for _ in 0..<30 {
            fine.step(0.01)
        }
        XCTAssertEqual(coarse.value, fine.value, accuracy: 1e-9)
        XCTAssertEqual(coarse.velocity, fine.velocity, accuracy: 1e-9)
    }

    func testCloseEnoughFiresBeforeFinished() {
        var motion = CursorMotion(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1200, y: 0), tuning: tuning)
        XCTAssertFalse(motion.isCloseEnough)
        var closeEnoughAt: Double?
        var finishedAt: Double?
        var elapsed = 0.0
        while finishedAt == nil && elapsed < 10 {
            motion.step(1.0 / 60)
            elapsed += 1.0 / 60
            if closeEnoughAt == nil && motion.isCloseEnough {
                closeEnoughAt = elapsed
                XCTAssertTrue(motion.progress >= 0.995 || motion.remainingDistance <= 3)
            }
            if motion.isFinished {
                finishedAt = elapsed
            }
        }
        let close = try! XCTUnwrap(closeEnoughAt)
        let finished = try! XCTUnwrap(finishedAt)
        XCTAssertLessThan(close, finished)
    }

    func testCloseEnoughRule() {
        XCTAssertTrue(CursorMotion.isCloseEnough(progress: 0.995, remainingDistance: 50))
        XCTAssertTrue(CursorMotion.isCloseEnough(progress: 0.5, remainingDistance: 3))
        XCTAssertFalse(CursorMotion.isCloseEnough(progress: 0.99, remainingDistance: 3.5))
    }

    func testZeroLengthMoveIsImmediatelyCloseEnough() {
        let motion = CursorMotion(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5, y: 5), tuning: tuning)
        XCTAssertTrue(motion.isCloseEnough)
    }

    private func assertClose(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }
}

final class CursorGeometryTests: XCTestCase {
    func testHotspotLandsOnRequestedPoint() {
        let height: CGFloat = 1117
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 640.5, y: 400), CGPoint(x: -1200, y: 30), CGPoint(x: 3000, y: 1100)] {
            let origin = CursorGeometry.windowOrigin(forHotspotAt: point, primaryScreenHeight: height)
            XCTAssertEqual(CursorGeometry.hotspot(forWindowOrigin: origin, primaryScreenHeight: height), point)
        }
        // Explicit check against Cocoa's bottom-left frame: tip is 10 pt below the window's top edge.
        let origin = CursorGeometry.windowOrigin(forHotspotAt: CGPoint(x: 100, y: 100), primaryScreenHeight: 1000)
        XCTAssertEqual(origin.x + CursorGeometry.hotspot.x, 100)
        XCTAssertEqual(1000 - (origin.y + CursorGeometry.windowSize.height - CursorGeometry.hotspot.y), 100)
    }

    func testFractionalPointsSplitIntoWholeOriginAndArtOffset() {
        let height: CGFloat = 1117
        let point = CGPoint(x: 664.25, y: 558.5)
        let placement = CursorGeometry.placement(forHotspotAt: point, primaryScreenHeight: height)
        XCTAssertEqual(placement.windowOrigin.x, placement.windowOrigin.x.rounded())
        XCTAssertEqual(placement.windowOrigin.y, placement.windowOrigin.y.rounded())
        XCTAssertTrue((0..<1).contains(placement.artOffset.x))
        XCTAssertTrue((0..<1).contains(placement.artOffset.y))
        let exact = CGPoint(x: placement.windowOrigin.x + placement.artOffset.x, y: placement.windowOrigin.y + placement.artOffset.y)
        XCTAssertEqual(CursorGeometry.hotspot(forWindowOrigin: exact, primaryScreenHeight: height), point)
    }

    func testArrowStartsAtTipAndFitsWindow() {
        let box = CursorGeometry.arrowPath().boundingBoxOfPath
        // The rounded tip bulges a fraction of a point past the apex, never more.
        XCTAssertLessThanOrEqual(box.minX, 0)
        XCTAssertLessThanOrEqual(box.minY, 0)
        XCTAssertGreaterThan(box.minX, -0.75)
        XCTAssertGreaterThan(box.minY, -0.75)
        XCTAssertEqual(box.height, CursorGeometry.arrowHeight, accuracy: 1e-6)
        // Symmetric about the screen diagonal, so exactly as wide as tall.
        XCTAssertEqual(box.width, box.height, accuracy: 1e-6)
        XCTAssertEqual(box.minX, box.minY, accuracy: 1e-6)
        // Room for the soft shadow and rim glow on every side, plus the sub-point offset.
        XCTAssertGreaterThanOrEqual(CursorGeometry.hotspot.x + box.minX, 6)
        XCTAssertGreaterThanOrEqual(CursorGeometry.hotspot.y + box.minY, 6)
        XCTAssertLessThanOrEqual(CursorGeometry.hotspot.x + box.maxX + 6, CursorGeometry.windowSize.width)
        XCTAssertLessThanOrEqual(CursorGeometry.hotspot.y + box.maxY + 6, CursorGeometry.windowSize.height)
    }

    func testFirstSessionIsNeutralAndOthersAreTintedDistinctly() {
        XCTAssertNil(CursorPalette.tint(at: 0), "A lone session reads as plain glass")
        let tints = (1..<CursorPalette.count).compactMap { CursorPalette.tint(at: $0) }
        XCTAssertEqual(tints.count, CursorPalette.count - 1)
        XCTAssertEqual(Set(tints.map { $0.components ?? [] }).count, tints.count)
        XCTAssertEqual(CursorPalette.tint(at: CursorPalette.count + 1), CursorPalette.tint(at: 1), "Slots wrap")
    }

    func testAbortChord() {
        let chord: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        XCTAssertTrue(AbortChord.matches(keyCode: 47, flags: chord))
        XCTAssertTrue(AbortChord.matches(keyCode: 47, flags: chord.union(.maskAlphaShift)))
        XCTAssertFalse(AbortChord.matches(keyCode: 47, flags: chord.union(.maskShift)))
        XCTAssertFalse(AbortChord.matches(keyCode: 47, flags: [.maskControl, .maskCommand]))
        XCTAssertFalse(AbortChord.matches(keyCode: 43, flags: chord))
    }
}
