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

    // MARK: - Presence socket path

    private let longStateDirectory = "/Users/someone/Library/Application Support/a-very-long-directory-name/that-keeps-going/screencommander-state"

    func testShortStateDirectoryKeepsPresenceSocketInside() {
        let path = StatePaths.presenceSocketPath(stateDirectory: "/tmp/sc-state", uid: 501)
        XCTAssertEqual(path, "/tmp/sc-state/presence.sock")

        let paths = StatePaths(environment: ["SCREENCOMMANDER_STATE_DIR": "/tmp/sc-state"])
        XCTAssertEqual(paths.presenceSocketURL.path, "/tmp/sc-state/presence.sock")
    }

    func testLongStateDirectoryFallsBackToShortPerUserPath() {
        XCTAssertGreaterThan((longStateDirectory + "/presence.sock").utf8.count, StatePaths.maximumSocketPathBytes)

        let path = StatePaths.presenceSocketPath(stateDirectory: longStateDirectory, uid: 501)

        XCTAssertTrue(path.hasPrefix("/tmp/screencommander-501/presence-"), path)
        XCTAssertTrue(path.hasSuffix(".sock"), path)
        XCTAssertLessThanOrEqual(path.utf8.count, StatePaths.maximumSocketPathBytes)
        XCTAssertEqual((path as NSString).deletingLastPathComponent, StatePaths.presenceFallbackDirectory(uid: 501))
    }

    func testFallbackPathIsDeterministic() {
        let first = StatePaths.presenceSocketPath(stateDirectory: longStateDirectory, uid: 501)
        let second = StatePaths.presenceSocketPath(stateDirectory: longStateDirectory, uid: 501)
        XCTAssertEqual(first, second)

        let environment = ["SCREENCOMMANDER_STATE_DIR": longStateDirectory]
        XCTAssertEqual(StatePaths(environment: environment).presenceSocketURL.path,
                       StatePaths(environment: environment).presenceSocketURL.path)
        // Pinned so a change to the hash that would split clients from a running server is caught.
        XCTAssertEqual(StatePaths.stableHash("abc"), "e71fa2190541574b")
    }

    func testFallbackPathDiffersByStateDirectoryAndUser() {
        let base = StatePaths.presenceSocketPath(stateDirectory: longStateDirectory, uid: 501)
        let otherDirectory = StatePaths.presenceSocketPath(stateDirectory: longStateDirectory + "-2", uid: 501)
        let otherUser = StatePaths.presenceSocketPath(stateDirectory: longStateDirectory, uid: 502)

        XCTAssertNotEqual(base, otherDirectory)
        XCTAssertNotEqual(base, otherUser)
    }

    func testSocketDirectoryCheckIgnoresPathsOutsideFallback() {
        XCTAssertNil(PresenceLaunch.socketDirectoryProblem(
            socketPath: "/nonexistent/state/presence.sock",
            create: false,
            fallbackDirectory: "/tmp/screencommander-test-fallback"
        ))
    }

    func testSocketDirectoryCheckCreatesOwnerOnlyDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sc-sock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fallback = root.appendingPathComponent("screencommander-\(getuid())").path

        XCTAssertNil(PresenceLaunch.socketDirectoryProblem(socketPath: fallback + "/presence-x.sock", create: true, fallbackDirectory: fallback))
        let attributes = try FileManager.default.attributesOfItem(atPath: fallback)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        chmod(fallback, 0o755)
        XCTAssertNotNil(PresenceLaunch.socketDirectoryProblem(socketPath: fallback + "/presence-x.sock", create: false, fallbackDirectory: fallback))
        XCTAssertNil(PresenceLaunch.socketDirectoryProblem(socketPath: fallback + "/presence-x.sock", create: true, fallbackDirectory: fallback))
    }

    func testProbeClientRefusesUnsafeFallbackDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sc-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fallback = root.appendingPathComponent("screencommander-\(getuid())").path
        let socket = fallback + "/presence-x.sock"

        // Missing directory: nothing to trust or distrust yet, so a probe is allowed.
        XCTAssertNotNil(PresenceLaunch.probeClient(socketPath: socket, clientName: "test", fallbackDirectory: fallback))

        // Group- or world-accessible directory: refused, and probes never chmod it.
        XCTAssertEqual(mkdir(fallback, 0o755), 0)
        chmod(fallback, 0o755)
        XCTAssertNil(PresenceLaunch.probeClient(socketPath: socket, clientName: "test", fallbackDirectory: fallback))
        let attributes = try FileManager.default.attributesOfItem(atPath: fallback)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)

        // A symlink in place of the directory: refused.
        try FileManager.default.removeItem(atPath: fallback)
        try FileManager.default.createSymbolicLink(atPath: fallback, withDestinationPath: root.path)
        XCTAssertNil(PresenceLaunch.probeClient(socketPath: socket, clientName: "test", fallbackDirectory: fallback))

        // Owner-only directory: allowed.
        try FileManager.default.removeItem(atPath: fallback)
        XCTAssertEqual(mkdir(fallback, 0o700), 0)
        XCTAssertNotNil(PresenceLaunch.probeClient(socketPath: socket, clientName: "test", fallbackDirectory: fallback))
    }
}
