import CoreGraphics
import XCTest
@testable import ScreenCommander

final class MetadataFreshnessCheckerTests: XCTestCase {
    func testFreshDisplayMetadataReportsFresh() {
        let checker = MetadataFreshnessChecker(
            displayBounds: { id in
                XCTAssertEqual(id, 123)
                return CGRect(x: 10, y: 20, width: 300, height: 200)
            },
            windowBounds: { _ in nil }
        )

        let result = checker.freshness(for: metadata())

        XCTAssertEqual(result.status, .fresh)
        XCTAssertEqual(result.scope, "display")
    }

    func testChangedDisplayBoundsReportsStale() {
        let checker = MetadataFreshnessChecker(
            displayBounds: { _ in CGRect(x: 10, y: 20, width: 301, height: 200) },
            windowBounds: { _ in nil },
            tolerance: 0.25
        )

        let result = checker.freshness(for: metadata())

        XCTAssertEqual(result.status, .stale)
        XCTAssertEqual(result.scope, "display")
    }

    func testMissingWindowReportsStale() {
        let checker = MetadataFreshnessChecker(
            displayBounds: { _ in CGRect(x: 10, y: 20, width: 300, height: 200) },
            windowBounds: { _ in nil }
        )

        let result = checker.freshness(
            for: metadata(windowID: 77, windowBounds: RectD(x: 50, y: 60, w: 70, h: 80))
        )

        XCTAssertEqual(result.status, .stale)
        XCTAssertEqual(result.scope, "window")
    }

    func testMovedWindowReportsStale() {
        let checker = MetadataFreshnessChecker(
            displayBounds: { _ in CGRect(x: 10, y: 20, width: 300, height: 200) },
            windowBounds: { id in
                XCTAssertEqual(id, 77)
                return CGRect(x: 55, y: 60, width: 70, height: 80)
            },
            tolerance: 0.25
        )

        let result = checker.freshness(
            for: metadata(windowID: 77, windowBounds: RectD(x: 50, y: 60, w: 70, h: 80))
        )

        XCTAssertEqual(result.status, .stale)
        XCTAssertEqual(result.scope, "window")
    }

    private func metadata(
        windowID: UInt32? = nil,
        windowBounds: RectD? = nil
    ) -> ScreenshotMetadata {
        ScreenshotMetadata(
            capturedAtISO8601: "2026-02-21T00:00:00Z",
            displayID: 123,
            displayBoundsPoints: RectD(x: 10, y: 20, w: 300, h: 200),
            imageSizePixels: SizeD(w: 600, h: 400),
            pointPixelScale: 2,
            imagePath: "/tmp/test.png",
            windowID: windowID,
            windowBoundsPoints: windowBounds
        )
    }
}
