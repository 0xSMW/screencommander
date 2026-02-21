import XCTest
@testable import ScreenCommander

final class CaptureRetentionManagerTests: XCTestCase {
    private func withTempDirectory(_ name: String, execute: (URL, FileManager) throws -> Void) throws {
        let fileManager = FileManager.default
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        try execute(tempDir, fileManager)
    }

    func testPrunesOldFilesAndPreservesExtensions() throws {
        try withTempDirectory("screencommander-capture-retention-tests") { tempDir, fileManager in
            let now = Date()
            let oldDate = now.addingTimeInterval(-90_000)
            let freshDate = now.addingTimeInterval(-10)

            let oldPng = tempDir.appendingPathComponent("old.png")
            let oldJson = tempDir.appendingPathComponent("old.json")
            let oldText = tempDir.appendingPathComponent("old.txt")
            let freshPng = tempDir.appendingPathComponent("fresh.png")

            fileManager.createFile(atPath: oldPng.path, contents: Data(repeating: 1, count: 8), attributes: nil)
            fileManager.createFile(atPath: oldJson.path, contents: Data(repeating: 2, count: 8), attributes: nil)
            fileManager.createFile(atPath: oldText.path, contents: Data(repeating: 3, count: 8), attributes: nil)
            fileManager.createFile(atPath: freshPng.path, contents: Data(repeating: 4, count: 8), attributes: nil)

            try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldPng.path)
            try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldJson.path)
            try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldText.path)
            try fileManager.setAttributes([.modificationDate: freshDate], ofItemAtPath: freshPng.path)

            let retention = CaptureRetentionManager(fileManager: fileManager)
            let result = try retention.pruneCaptures(in: tempDir, olderThan: 60 * 60, now: now)

            XCTAssertEqual(result.deletedCount, 2)
            XCTAssertFalse(fileManager.fileExists(atPath: oldPng.path))
            XCTAssertFalse(fileManager.fileExists(atPath: oldJson.path))
            XCTAssertTrue(fileManager.fileExists(atPath: oldText.path))
            XCTAssertTrue(fileManager.fileExists(atPath: freshPng.path))
        }
    }

    func testIgnoresSubdirectoriesAndUnknownExtensions() throws {
        try withTempDirectory("screencommander-capture-retention-tests-ignores-subdirs") { tempDir, fileManager in
            let now = Date()
            let oldDate = now.addingTimeInterval(-90_000)

            let nested = tempDir.appendingPathComponent("nested", isDirectory: true)
            let oldPng = tempDir.appendingPathComponent("managed.png")
            let unknownFile = tempDir.appendingPathComponent("keep.bin")
            let nestedPng = nested.appendingPathComponent("nested-old.png")

            try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
            fileManager.createFile(atPath: oldPng.path, contents: Data(repeating: 1, count: 4), attributes: nil)
            fileManager.createFile(atPath: unknownFile.path, contents: Data(repeating: 2, count: 4), attributes: nil)
            fileManager.createFile(atPath: nestedPng.path, contents: Data(repeating: 3, count: 4), attributes: nil)

            try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: oldPng.path)
            try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: unknownFile.path)
            try fileManager.setAttributes([.modificationDate: oldDate], ofItemAtPath: nestedPng.path)

            let retention = CaptureRetentionManager(fileManager: fileManager)
            let result = try retention.pruneCaptures(in: tempDir, olderThan: 60 * 60, now: now)

            XCTAssertEqual(result.deletedCount, 1)
            XCTAssertFalse(fileManager.fileExists(atPath: oldPng.path))
            XCTAssertTrue(fileManager.fileExists(atPath: unknownFile.path))
            XCTAssertTrue(fileManager.fileExists(atPath: nestedPng.path))
        }
    }

    func testReturnsZeroForMissingDirectory() throws {
        try withTempDirectory("screencommander-capture-retention-tests-missing") { _, fileManager in
            let missingDir = fileManager.temporaryDirectory
                .appendingPathComponent("screencommander-missing-captures", isDirectory: true)

            try? fileManager.removeItem(at: missingDir)

            let retention = CaptureRetentionManager(fileManager: fileManager)
            let result = try retention.pruneCaptures(
                in: missingDir,
                olderThan: 3600,
                now: Date()
            )

            XCTAssertEqual(result.deletedCount, 0)
            XCTAssertEqual(result.deletedBytesApprox, 0)
        }
    }
}
