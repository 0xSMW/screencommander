import XCTest
@testable import ScreenCommander

final class StatePathsTests: XCTestCase {
    func testDefaultStateDirectoryUsesCaches() {
        let fileManager = FileManager.default
        let paths = StatePaths(fileManager: fileManager)

        let homePath = fileManager.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            paths.stateDirectoryURL.path,
            URL(fileURLWithPath: homePath)
                .appendingPathComponent("Library")
                .appendingPathComponent("Caches")
                .appendingPathComponent("screencommander")
                .path
        )
        XCTAssertTrue(paths.capturesDirectoryURL.path.hasSuffix("Library/Caches/screencommander/captures"))
        XCTAssertTrue(paths.lastMetadataURL.path.hasSuffix("Library/Caches/screencommander/last-screenshot.json"))
    }

    func testRespectsEnvironmentOverride() {
        let override = "/tmp/screencommander-state-test"
        let paths = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": override])

        XCTAssertEqual(paths.stateDirectoryURL.path, override)
        XCTAssertTrue(paths.capturesDirectoryURL.path.hasPrefix(override))
    }

    func testRespectsRelativeEnvironmentOverride() {
        let override = "tmp/relative-screencommander-state"
        let fileManager = FileManager.default
        let expected = URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(override, isDirectory: true)

        let paths = StatePaths(fileManager: fileManager, environment: ["SCREENCOMMANDER_STATE_DIR": override])

        XCTAssertEqual(paths.stateDirectoryURL.standardizedFileURL.path, expected.standardizedFileURL.path)
    }
}
