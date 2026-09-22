import CoreGraphics
import XCTest
@testable import ScreenCommander

final class CaptureGeometryTests: XCTestCase {
    private let frame = CGRect(x: 20, y: 30, width: 640, height: 480)

    private func info(_ frame: CGRect, visible: Bool = true) -> [String: Any] {
        [kCGWindowBounds as String: frame.dictionaryRepresentation,
         kCGWindowIsOnscreen as String: visible]
    }

    func testUnchangedWindowCanReuseEnumeration() {
        XCTAssertTrue(CaptureGeometry.matches(frame: frame, isOnScreen: true, currentInfo: info(frame)))
    }

    func testMovedResizedMinimizedAndClosedWindowsRequireRefresh() {
        XCTAssertFalse(CaptureGeometry.matches(frame: frame, isOnScreen: true, currentInfo: info(frame.offsetBy(dx: 1, dy: 0))))
        XCTAssertFalse(CaptureGeometry.matches(frame: frame, isOnScreen: true, currentInfo: info(CGRect(x: 20, y: 30, width: 800, height: 480))))
        XCTAssertFalse(CaptureGeometry.matches(frame: frame, isOnScreen: true, currentInfo: info(frame, visible: false)))
        XCTAssertFalse(CaptureGeometry.matches(frame: frame, isOnScreen: true, currentInfo: nil))
        XCTAssertFalse(CaptureGeometry.matches(frame: frame, isOnScreen: true, currentInfo: [:]))
    }
}
