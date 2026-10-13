import ApplicationServices
import Foundation
import XCTest
@testable import ScreenCommander

/// Builds fake `.app` bundles in a temp directory.
private struct BundleFactory {
    let root: URL

    init(_ name: String) {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("screencommander-profile-tests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    @discardableResult
    func app(
        _ name: String,
        bundleID: String? = nil,
        version: String = "1.0",
        info extra: [String: Any] = [:],
        files: [String] = [],
        directories: [String] = [],
        in folder: String? = nil,
        plist: Bool = true
    ) throws -> URL {
        var base = root
        if let folder {
            base = base.appendingPathComponent(folder, isDirectory: true)
        }
        let bundle = base.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        if plist {
            var info: [String: Any] = [
                "CFBundleIdentifier": bundleID ?? "com.example.\(name.lowercased().replacingOccurrences(of: " ", with: ""))",
                "CFBundleShortVersionString": version,
                "CFBundleExecutable": name,
            ]
            info.merge(extra) { _, new in new }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        for directory in directories {
            try FileManager.default.createDirectory(at: contents.appendingPathComponent(directory, isDirectory: true), withIntermediateDirectories: true)
        }
        for file in files {
            let url = contents.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        return bundle
    }
}

final class DeliveryProfileTests: XCTestCase {

    // MARK: Classifier

    func testClassifierFindsAnUnlistedChromiumBrowserByItsEngineResources() throws {
        let factory = BundleFactory("classifier-chromium-markers")
        // A browser whose framework name is on no list, laid out like Chrome's:
        // Resources is a symlink into Versions/Current.
        let browser = try factory.app("Nimbus", files: [
            "Frameworks/NimbusCore.framework/Versions/A/Resources/chrome_100_percent.pak",
        ])
        let framework = browser.appendingPathComponent("Contents/Frameworks/NimbusCore.framework")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")
        let plain = try factory.app("Plain", directories: ["Frameworks/Sparkle.framework/Resources"])

        let classification = AppBundleClassifier.classify(bundleURL: browser)
        XCTAssertEqual(classification.toolkit, .chromium)
        XCTAssertEqual(classification.evidence, ["Contents/Frameworks/NimbusCore.framework/Resources/chrome_100_percent.pak"])
        XCTAssertTrue(BackgroundDeliveryPolicy.isChromiumFamily(bundleURL: browser))
        XCTAssertEqual(AppBundleClassifier.classify(bundleURL: plain).toolkit, .native)
        XCTAssertFalse(BackgroundDeliveryPolicy.isChromiumFamily(bundleURL: plain))
    }

    func testClassifierRecognizesEachToolkit() throws {
        let factory = BundleFactory("classifier")
        let cases: [(URL, AppToolkit, String?)] = [
            (try factory.app("Plain"), .native, nil),
            (try factory.app("Slack", directories: ["Frameworks/Electron Framework.framework"]), .electron, nil),
            (try factory.app("Spotify", directories: ["Frameworks/Chromium Embedded Framework.framework"]), .chromium, nil),
            (try factory.app("Chrome", directories: ["Frameworks/Google Chrome Framework.framework"]), .chromium, nil),
            (try factory.app("QtTool", directories: ["Frameworks/QtCore.framework"]), .qt, nil),
            (try factory.app("QtDylib", files: ["Frameworks/libQt6Core.6.dylib"]), .qt, nil),
            (try factory.app("QtPlugin", files: ["PlugIns/platforms/libqcocoa.dylib"]), .qt, nil),
            (try factory.app("JavaApp", directories: ["Java"]), .java, nil),
            (try factory.app("IDE", directories: ["jbr"]), .java, nil),
            (try factory.app("Jpackage", directories: ["runtime"]), .java, nil),
            (try factory.app("Catalyst", info: ["UIDeviceFamily": [2, 6]]), .catalyst, nil),
            (try factory.app("Unity", files: ["Frameworks/UnityPlayer.dylib"]), .gameEngine, "unity"),
            (try factory.app("UnityData", files: ["Resources/Data/Managed/UnityEngine.dll"]), .gameEngine, "unity"),
            (try factory.app("Unreal", directories: ["UE4"]), .gameEngine, "unreal"),
            (try factory.app("Godot", files: ["Resources/Game.pck"]), .gameEngine, "godot"),
            (try factory.app("Bare", plist: false), .unknown, nil),
        ]

        for (url, toolkit, engine) in cases {
            let classification = AppBundleClassifier.classify(bundleURL: url)
            XCTAssertEqual(classification.toolkit, toolkit, url.lastPathComponent)
            XCTAssertEqual(classification.engine, engine, url.lastPathComponent)
            XCTAssertFalse(classification.evidence.isEmpty, url.lastPathComponent)
        }

        let wrapped = factory.root.appendingPathComponent("Phone.app", isDirectory: true)
        try FileManager.default.createDirectory(at: wrapped.appendingPathComponent("Wrapper"), withIntermediateDirectories: true)
        XCTAssertEqual(AppBundleClassifier.classify(bundleURL: wrapped).toolkit, .catalyst)
    }

    func testClassifierPrefersGameEnginesOverEmbeddedBrowsers() throws {
        let factory = BundleFactory("classifier-precedence")
        let game = try factory.app(
            "Launcher",
            files: ["Frameworks/UnityPlayer.dylib"],
            directories: ["Frameworks/Chromium Embedded Framework.framework"]
        )
        XCTAssertEqual(AppBundleClassifier.classify(bundleURL: game).toolkit, .gameEngine)
    }

    func testClassifierReadsBundleIDAndVersion() throws {
        let factory = BundleFactory("classifier-version")
        let url = try factory.app("Versioned", bundleID: "com.example.versioned", version: "2.1", info: ["CFBundleVersion": "210"])
        let classification = AppBundleClassifier.classify(bundleURL: url)
        XCTAssertEqual(classification.bundleID, "com.example.versioned")
        XCTAssertEqual(classification.version, "2.1 (210)")
        XCTAssertEqual(classification.bundlePath, url.path)
    }

    // MARK: Policy

    private func classification(_ toolkit: AppToolkit, engine: String? = nil) -> AppBundleClassification {
        AppBundleClassification(toolkit: toolkit, engine: engine, evidence: ["test"])
    }

    func testPolicySupportLevelsAndTierOrders() {
        let native = BackgroundDeliveryPolicy.profile(for: classification(.native), capabilities: .all, authenticatedKeyboardOS: true)
        XCTAssertEqual(native.support, .supported)
        XCTAssertEqual(native.preferredTier, .window)
        XCTAssertEqual(native.mouseTiers, [.ax, .window, .focusAssisted])
        XCTAssertFalse(native.authenticatedKeyboard)

        // Electron is degraded: verified on macOS 27.2 only.
        let electron = BackgroundDeliveryPolicy.profile(for: classification(.electron), capabilities: .all, authenticatedKeyboardOS: true)
        XCTAssertEqual(electron.support, .degraded)
        XCTAssertTrue(electron.reason.contains("macOS 27.2"), electron.reason)
        XCTAssertTrue(electron.reason.contains("on macOS 15 (clicks"), electron.reason)
        XCTAssertEqual(electron.preferredTier, .focusAssisted)
        // Plain window events are dropped while a Chromium window is not key, so
        // they are never a silent fallback.
        XCTAssertEqual(electron.keyboardTiers, [.ax, .focusAssisted])
        XCTAssertEqual(electron.mouseTiers, [.ax, .focusAssisted])
        XCTAssertTrue(electron.authenticatedKeyboard)
        XCTAssertTrue(electron.reason.contains("active tab"), electron.reason)

        // Chrome was tested on macOS 27.2 only.
        let chromium = BackgroundDeliveryPolicy.profile(for: classification(.chromium), capabilities: .all, authenticatedKeyboardOS: true)
        XCTAssertEqual(chromium.support, .degraded)
        XCTAssertEqual(chromium.keyboardTiers, [.ax, .focusAssisted])
        XCTAssertTrue(chromium.reason.contains("Google Chrome"), chromium.reason)
        XCTAssertTrue(chromium.reason.contains("Not tested on macOS 15"), chromium.reason)
        XCTAssertTrue(chromium.reason.contains("active tab"), chromium.reason)

        for toolkit in [AppToolkit.catalyst, .qt, .java, .unknown] {
            let profile = BackgroundDeliveryPolicy.profile(for: classification(toolkit), capabilities: .all, authenticatedKeyboardOS: true)
            XCTAssertEqual(profile.support, .degraded, toolkit.rawValue)
            XCTAssertFalse(profile.reason.isEmpty, toolkit.rawValue)
        }
        for toolkit in [AppToolkit.catalyst, .qt, .java] {
            let profile = BackgroundDeliveryPolicy.profile(for: classification(toolkit), capabilities: .all, authenticatedKeyboardOS: true)
            XCTAssertTrue(profile.reason.contains("Not tested live"), profile.reason)
        }

        let game = BackgroundDeliveryPolicy.profile(for: classification(.gameEngine, engine: "unreal"), capabilities: .all, authenticatedKeyboardOS: true)
        XCTAssertEqual(game.support, .unsupported)
        XCTAssertEqual(game.mouseTiers, [.ax])
        XCTAssertEqual(game.keyboardTiers, [.ax])
        XCTAssertTrue(game.reason.hasPrefix("Unreal game engine"), game.reason)
    }

    func testPolicyDegradesWhenPrivateSymbolsAreMissing() {
        let noWindowLocation = DeliveryCapabilities(windowLocation: false, focusRecords: true, authenticatedPost: true)
        let native = BackgroundDeliveryPolicy.profile(for: classification(.native), capabilities: noWindowLocation, authenticatedKeyboardOS: true)
        XCTAssertEqual(native.support, .degraded)
        XCTAssertEqual(native.mouseTiers, [.ax])
        // focusAssisted makes the window key with a window-addressed click.
        XCTAssertEqual(native.keyboardTiers, [.ax, .window])
        XCTAssertTrue(native.reason.contains("CGEventSetWindowLocation"))

        // Plain per-process keys arrived live, so a missing authentication envelope
        // is only noted, never reported as missing focus symbols.
        let noAuth = DeliveryCapabilities(windowLocation: true, focusRecords: true, authenticatedPost: false)
        let electronNoAuth = BackgroundDeliveryPolicy.profile(for: classification(.electron), capabilities: noAuth, authenticatedKeyboardOS: true)
        XCTAssertEqual(electronNoAuth.support, .degraded)
        XCTAssertFalse(electronNoAuth.reason.contains("symbols are missing"), electronNoAuth.reason)
        XCTAssertTrue(electronNoAuth.reason.contains("Authenticated SkyLight posting is missing"), electronNoAuth.reason)

        let noFocus = DeliveryCapabilities(windowLocation: true, focusRecords: false, authenticatedPost: true)
        let electron = BackgroundDeliveryPolicy.profile(for: classification(.electron), capabilities: noFocus, authenticatedKeyboardOS: true)
        XCTAssertEqual(electron.support, .degraded)
        XCTAssertEqual(electron.mouseTiers, [.ax])
        XCTAssertEqual(electron.keyboardTiers, [.ax])
    }

    // MARK: Resolver cache

    func testResolverCachesByBundleIDAndVersion() throws {
        let factory = BundleFactory("resolver-cache")
        let cacheDirectory = factory.root.appendingPathComponent("state/profiles", isDirectory: true)
        let bundle = try factory.app("Cached", bundleID: "com.example.cached", version: "1.0", in: "Apps")

        let first = DeliveryProfileResolver(cacheDirectory: cacheDirectory, capabilities: .all, authenticatedKeyboardOS: true)
        let fresh = first.profile(bundleURL: bundle)
        XCTAssertEqual(fresh.toolkit, .native)
        XCTAssertFalse(fresh.cached)
        let cacheFile = try XCTUnwrap(first.cacheURL(bundleID: "com.example.cached", version: "1.0"))
        XCTAssertEqual(cacheFile.lastPathComponent, "com.example.cached@1.0.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))

        // Same bundle ID and version: a new process reads the cache, not the bundle.
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
            withIntermediateDirectories: true
        )
        let second = DeliveryProfileResolver(cacheDirectory: cacheDirectory, capabilities: .all, authenticatedKeyboardOS: true)
        let cached = second.profile(bundleURL: bundle)
        XCTAssertEqual(cached.toolkit, .native)
        XCTAssertTrue(cached.cached)

        // A new version is a new key, so the bundle is classified again.
        try factory.app("Cached", bundleID: "com.example.cached", version: "2.0", in: "Apps")
        let third = DeliveryProfileResolver(cacheDirectory: cacheDirectory, capabilities: .all, authenticatedKeyboardOS: true)
        let updated = third.profile(bundleURL: bundle)
        XCTAssertEqual(updated.toolkit, .electron)
        XCTAssertFalse(updated.cached)
        XCTAssertEqual(updated.version, "2.0")
    }

    func testResolverIgnoresCacheEntriesFromOlderRules() throws {
        let factory = BundleFactory("resolver-rules")
        let cacheDirectory = factory.root.appendingPathComponent("profiles", isDirectory: true)
        let bundle = try factory.app("Ruled", bundleID: "com.example.ruled", directories: ["Frameworks/QtCore.framework"])
        let resolver = DeliveryProfileResolver(cacheDirectory: cacheDirectory, capabilities: .all, authenticatedKeyboardOS: true)
        let cacheFile = try XCTUnwrap(resolver.cacheURL(bundleID: "com.example.ruled", version: "1.0"))

        var stale = AppBundleClassification(toolkit: .native, evidence: ["old"], bundleID: "com.example.ruled", version: "1.0")
        stale.rulesVersion = AppBundleClassification.rulesVersion - 1
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(stale).write(to: cacheFile)

        let profile = resolver.profile(bundleURL: bundle)
        XCTAssertEqual(profile.toolkit, .qt)
        XCTAssertFalse(profile.cached)
    }

    func testResolverTreatsANonBundleProcessAsUnknown() {
        let resolver = DeliveryProfileResolver(
            cacheDirectory: nil,
            capabilities: .all,
            authenticatedKeyboardOS: true,
            bundleURLForPid: { _ in URL(fileURLWithPath: "/tmp/some-tool/", isDirectory: true) }
        )
        let profile = resolver.profile(pid: 123)
        XCTAssertEqual(profile.toolkit, .unknown)
        XCTAssertEqual(profile.support, .degraded)
        XCTAssertEqual(profile.mouseTiers, [.ax, .window, .focusAssisted])
    }

    // MARK: App catalog

    func testCatalogScansOneFolderLevelAndMatchesNames() throws {
        let factory = BundleFactory("catalog")
        try factory.app("Alpha", bundleID: "com.example.alpha")
        try factory.app("Alphabet", bundleID: "com.example.alphabet")
        try factory.app("Beta", bundleID: "com.example.beta", in: "Suite")
        try factory.app("Deep", bundleID: "com.example.deep", in: "Suite/Nested")
        let catalog = AppCatalog(searchDirectories: [factory.root], cacheTTL: 0)

        let scan = catalog.installedApps()
        XCTAssertEqual(scan.apps.map(\.name), ["Alpha", "Alphabet", "Beta"])
        XCTAssertFalse(scan.truncated)
        XCTAssertEqual(scan.apps.first?.version, "1.0")

        XCTAssertEqual(try catalog.resolveInstalled(identifier: "alpha").bundleID, "com.example.alpha")
        XCTAssertEqual(try catalog.resolveInstalled(identifier: "bet").bundleID, "com.example.beta")
        XCTAssertEqual(try catalog.resolveInstalled(identifier: factory.root.appendingPathComponent("Alpha.app").path).name, "Alpha")
        XCTAssertThrowsError(try catalog.resolveInstalled(identifier: "Alp")) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "invalid_arguments")
        }
        XCTAssertThrowsError(try catalog.resolveInstalled(identifier: "Gamma")) { error in
            XCTAssertEqual((error as? ScreenCommanderError)?.stableCode, "app_not_found")
        }
    }

    func testTargetsPointsAtLaunchWhenAnAppIsNotRunning() async {
        let targets = Targets(runningApplications: { [] })
        do {
            _ = try await targets.resolveApp(identifier: "Calculator")
            XCTFail("Expected app_not_found")
        } catch let error as ScreenCommanderError {
            XCTAssertEqual(error.stableCode, "app_not_found")
            XCTAssertTrue(error.description.contains("launch --app Calculator"), error.description)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testActionNameMatching() {
        let available = ["AXPress", "AXShowMenu"]
        XCTAssertEqual(ScreenCommanderEngine.matchActionName("AXPress", available: available), "AXPress")
        XCTAssertEqual(ScreenCommanderEngine.matchActionName("axshowmenu", available: available), "AXShowMenu")
        XCTAssertEqual(ScreenCommanderEngine.matchActionName("Press", available: available), "AXPress")
        XCTAssertNil(ScreenCommanderEngine.matchActionName("AXRaise", available: available))
    }
}

// MARK: - Scoped AXEnhancedUserInterface

private final class FakePrimingTarget: AXPrimingTarget {
    var manualResult: AXError = .attributeUnsupported
    var enhancedResult: AXError = .success
    var prior: CFTypeRef?
    private(set) var writes: [(name: String, value: Bool)] = []
    private(set) var timeouts: [Float] = []

    func setAttribute(_ name: String, value: CFTypeRef) -> AXError {
        let flag = CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((value as! CFBoolean))
        writes.append((name, flag))
        switch name {
        case AXPriming.manualAccessibility:
            return manualResult
        default:
            // The restore write always succeeds; only the first EUI write is scripted.
            return writes.filter { $0.name == AXPriming.enhancedUserInterface }.count == 1 ? enhancedResult : .success
        }
    }

    func copyAttribute(_ name: String) -> CFTypeRef? {
        prior
    }

    func setMessagingTimeout(seconds: Float) {
        timeouts.append(seconds)
    }

    var enhancedWrites: [Bool] {
        writes.filter { $0.name == AXPriming.enhancedUserInterface }.map(\.value)
    }
}

private struct PrimingFailure: Error {}

final class AXPrimingTests: XCTestCase {
    func testManualAccessibilityNeverTouchesEnhancedUserInterface() {
        let target = FakePrimingTarget()
        target.manualResult = .success
        let primed = AXPriming.withPrimed(target) { $0 }
        XCTAssertTrue(primed)
        XCTAssertEqual(target.enhancedWrites, [])
    }

    func testEnhancedUserInterfaceIsClearedAfterTheRead() {
        let target = FakePrimingTarget()
        let primed = AXPriming.withPrimed(target) { $0 }
        XCTAssertTrue(primed)
        XCTAssertEqual(target.enhancedWrites, [true, false])
        XCTAssertEqual(target.timeouts, [AXPriming.restoreTimeout])
    }

    func testEnhancedUserInterfaceIsClearedWhenTheReadThrows() {
        let target = FakePrimingTarget()
        XCTAssertThrowsError(try AXPriming.withPrimed(target) { _ in throw PrimingFailure() })
        XCTAssertEqual(target.enhancedWrites, [true, false])
    }

    func testATimedOutWriteIsStillUndone() {
        let target = FakePrimingTarget()
        target.enhancedResult = .cannotComplete
        let primed = AXPriming.withPrimed(target) { $0 }
        XCTAssertFalse(primed)
        XCTAssertEqual(target.enhancedWrites, [true, false])
    }

    func testARefusedWriteNeedsNoRestore() {
        let target = FakePrimingTarget()
        target.enhancedResult = .attributeUnsupported
        let primed = AXPriming.withPrimed(target) { $0 }
        XCTAssertFalse(primed)
        XCTAssertEqual(target.enhancedWrites, [true])
    }

    func testAnAlreadyEnabledAssertionIsLeftAlone() {
        let target = FakePrimingTarget()
        target.prior = kCFBooleanTrue
        let primed = AXPriming.withPrimed(target) { $0 }
        XCTAssertTrue(primed)
        XCTAssertEqual(target.enhancedWrites, [])
    }
}
