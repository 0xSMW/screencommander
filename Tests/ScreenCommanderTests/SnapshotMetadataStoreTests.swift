import XCTest
@testable import ScreenCommander

final class SnapshotMetadataStoreTests: XCTestCase {
    func testDefaultLastMetadataURLCanBeInjected() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("screencommander-metadata-tests")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let injectedLast = tempDir.appendingPathComponent("custom-last.json")
        let store = SnapshotMetadataStore(fileManager: .default, lastMetadataURL: injectedLast)

        XCTAssertEqual(store.defaultLastMetadataURL.path, injectedLast.path)

        let metadata = ScreenshotMetadata(
            capturedAtISO8601: "2026-02-21T00:00:00Z",
            displayID: 1234,
            displayBoundsPoints: RectD(x: 1, y: 2, w: 3, h: 4),
            imageSizePixels: SizeD(w: 10, h: 20),
            pointPixelScale: 2,
            imagePath: "/tmp/test.png"
        )

        let metadataURL = tempDir.appendingPathComponent("shot.json")
        try store.save(metadata: metadata, at: metadataURL, updateLastAt: injectedLast)

        let reloaded = try store.load(from: metadataURL)
        XCTAssertEqual(reloaded.displayID, metadata.displayID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: injectedLast.path))
    }

    func testConcurrentSaveLoadUsesIndependentCoders() async throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("screencommander-metadata-concurrent-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = SnapshotMetadataStore(
            fileManager: .default,
            lastMetadataURL: tempDir.appendingPathComponent("last.json")
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<25 {
                group.addTask {
                    let metadata = ScreenshotMetadata(
                        capturedAtISO8601: "2026-02-21T00:00:00Z",
                        displayID: UInt32(index),
                        displayBoundsPoints: RectD(x: Double(index), y: 0, w: 100, h: 100),
                        imageSizePixels: SizeD(w: 200, h: 200),
                        pointPixelScale: 2,
                        imagePath: "/tmp/test-\(index).png"
                    )
                    let url = tempDir.appendingPathComponent("shot-\(index).json")
                    try store.save(metadata: metadata, at: url, updateLastAt: nil)
                    let reloaded = try store.load(from: url)
                    XCTAssertEqual(reloaded.displayID, UInt32(index))
                }
            }

            try await group.waitForAll()
        }
    }
}
