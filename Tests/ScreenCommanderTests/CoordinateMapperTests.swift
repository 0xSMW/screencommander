import XCTest
@testable import ScreenCommander

final class CoordinateMapperTests: XCTestCase {
    func testMapsPixelCoordinatesToGlobalPoint() throws {
        let metadata = ScreenshotMetadata(
            capturedAtISO8601: "2026-02-20T00:00:00Z",
            displayID: 1,
            displayBoundsPoints: RectD(x: 100, y: 200, w: 500, h: 300),
            imageSizePixels: SizeD(w: 1000, h: 600),
            pointPixelScale: 2.0,
            imagePath: "/tmp/test.png"
        )

        let result = try CoordinateMapper().map(x: 200, y: 100, space: .pixels, metadata: metadata)

        XCTAssertEqual(result.globalX, 200)
        XCTAssertEqual(result.globalY, 250)
    }

    func testRejectsOutOfBoundsPixels() {
        let metadata = ScreenshotMetadata(
            capturedAtISO8601: "2026-02-20T00:00:00Z",
            displayID: 1,
            displayBoundsPoints: RectD(x: 0, y: 0, w: 100, h: 100),
            imageSizePixels: SizeD(w: 200, h: 200),
            pointPixelScale: 2,
            imagePath: "/tmp/test.png"
        )

        XCTAssertThrowsError(
            try CoordinateMapper().map(x: 200, y: 40, space: .pixels, metadata: metadata)
        )
    }
}
