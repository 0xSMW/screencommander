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
}
