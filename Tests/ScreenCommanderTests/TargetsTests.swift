import XCTest
@testable import ScreenCommander

final class TargetsTests: XCTestCase {
    func testResolveAppNameIncludesAllRunningAppSnapshots() async throws {
        let targets = Targets(
            runningApplications: {
                [
                    RunningAppSnapshot(
                        pid: 44,
                        localizedName: "Menu Utility",
                        bundleID: "com.example.menu"
                    )
                ]
            }
        )

        let app = try await targets.resolveApp(identifier: "Menu Utility")

        XCTAssertEqual(app, ResolvedApp(pid: 44, name: "Menu Utility", bundleID: "com.example.menu"))
    }

    func testResolveAppExactAmbiguityIncludesPidAndBundleID() async {
        let targets = Targets(
            runningApplications: {
                [
                    RunningAppSnapshot(pid: 10, localizedName: "Terminal", bundleID: "com.apple.Terminal"),
                    RunningAppSnapshot(pid: 11, localizedName: "Terminal", bundleID: "com.example.Terminal")
                ]
            }
        )

        do {
            _ = try await targets.resolveApp(identifier: "Terminal")
            XCTFail("Expected ambiguous app error")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("pid 10"))
            XCTAssertTrue(message.contains("com.apple.Terminal"))
            XCTAssertTrue(message.contains("pid 11"))
            XCTAssertTrue(message.contains("com.example.Terminal"))
        }
    }

    func testPrefixNeverPicksABackgroundOnlyService() async throws {
        let snapshots = [
            RunningAppSnapshot(
                pid: 30, localizedName: "CursorUIViewService",
                bundleID: "com.apple.TextInputUI.xpc.CursorUIViewService", isBackgroundOnly: true
            ),
        ]
        let targets = Targets(runningApplications: { snapshots })

        do {
            _ = try await targets.resolveApp(identifier: "Cursor")
            XCTFail("A prefix must not resolve to a background-only service")
        } catch {
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "app_not_found")
        }
        // The exact name still reaches it.
        let exact = try await targets.resolveApp(identifier: "CursorUIViewService")
        XCTAssertEqual(exact.pid, 30)
    }

    func testResolveAppPrefixAmbiguityIncludesPidAndBundleID() async {
        let targets = Targets(
            runningApplications: {
                [
                    RunningAppSnapshot(pid: 20, localizedName: "TextEdit", bundleID: "com.apple.TextEdit"),
                    RunningAppSnapshot(pid: 21, localizedName: "TextMate", bundleID: "com.macromates.TextMate")
                ]
            }
        )

        do {
            _ = try await targets.resolveApp(identifier: "Text")
            XCTFail("Expected ambiguous app error")
        } catch {
            let message = String(describing: error)
            XCTAssertTrue(message.contains("pid 20"))
            XCTAssertTrue(message.contains("com.apple.TextEdit"))
            XCTAssertTrue(message.contains("pid 21"))
            XCTAssertTrue(message.contains("com.macromates.TextMate"))
        }
    }

    func testActivationWaitPollsUntilAppIsFrontmost() throws {
        let app = ResolvedApp(pid: 42, name: "Calculator", bundleID: "com.apple.calculator")
        var reads: [pid_t?] = [7, 7, 42]
        var pauses = 0

        try AppActivator.waitUntilFrontmost(app, isFrontmost: { reads.removeFirst() == $0 }, pause: { pauses += 1 })

        XCTAssertEqual(pauses, 2)
        XCTAssertTrue(reads.isEmpty)
    }

    func testActivationWaitFailsWhenAppNeverComesForward() {
        let app = ResolvedApp(pid: 42, name: "Calculator", bundleID: nil)
        var reads = 0
        var pauses = 0

        XCTAssertThrowsError(try AppActivator.waitUntilFrontmost(
            app,
            attempts: 3,
            isFrontmost: { _ in reads += 1; return false },
            pause: { pauses += 1 }
        )) { error in
            XCTAssertTrue(String(describing: error).contains("did not become active"))
        }
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(pauses, 2)
    }

    // MARK: - FrontmostApp

    private static let apps: [pid_t: ResolvedApp] = [
        10: ResolvedApp(pid: 10, name: "Warp", bundleID: "dev.warp.Warp-Stable"),
        20: ResolvedApp(pid: 20, name: "Safari", bundleID: "com.apple.Safari"),
    ]

    func testFrontmostPrefersWindowServerFrontProcess() {
        var axAsked = false
        let app = FrontmostApp.current(
            frontProcessPID: { 20 },
            axFocusedPID: { axAsked = true; return 10 },
            app: { Self.apps[$0] }
        )
        XCTAssertEqual(app?.pid, 20)
        XCTAssertFalse(axAsked)
    }

    /// The AX system-wide query fails (-25204) while Warp is frontmost.
    func testFrontmostUsesWindowServerWhenAXFails() {
        let app = FrontmostApp.current(frontProcessPID: { 10 }, axFocusedPID: { nil }, app: { Self.apps[$0] })
        XCTAssertEqual(app?.name, "Warp")
    }

    func testFrontmostFallsBackToAXWhenPrivateSymbolsAreUnavailable() {
        let app = FrontmostApp.current(frontProcessPID: { nil }, axFocusedPID: { 20 }, app: { Self.apps[$0] })
        XCTAssertEqual(app?.name, "Safari")
    }

    func testFrontmostFallsBackToAXWhenFrontProcessIsNotARunningApp() {
        let app = FrontmostApp.current(frontProcessPID: { 99 }, axFocusedPID: { 20 }, app: { Self.apps[$0] })
        XCTAssertEqual(app?.pid, 20)
    }

    /// With both sources failing there is no answer. A cached `NSWorkspace` value
    /// would name whichever app was frontmost when the process started.
    func testFrontmostIsNilWhenBothSourcesFail() {
        XCTAssertNil(FrontmostApp.current(frontProcessPID: { nil }, axFocusedPID: { nil }, app: { Self.apps[$0] }))
        XCTAssertNil(FrontmostApp.current(frontProcessPID: { 0 }, axFocusedPID: { -1 }, app: { Self.apps[$0] }))
    }
}
