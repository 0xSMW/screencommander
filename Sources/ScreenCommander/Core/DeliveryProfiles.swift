import AppKit
import Foundation

// MARK: - Profile model

/// The UI toolkit an app bundle was built with, read statically from the bundle.
enum AppToolkit: String, Codable, Sendable, CaseIterable {
    /// AppKit or SwiftUI.
    case native
    /// Mac Catalyst, or an iPhone/iPad app running on a Mac.
    case catalyst
    /// A Chrome-family browser or a CEF host.
    case chromium
    case electron
    case qt
    /// AWT/Swing/JavaFX on a bundled or system JVM.
    case java
    /// Unity, Unreal, or Godot.
    case gameEngine
    /// No bundle to read (a bare executable or a process LaunchServices does not know).
    case unknown
}

/// How well background delivery is expected to work for an app.
///
/// - `supported`: AX actions and window-addressed events work while the app is inactive.
/// - `degraded`: some input works in the background; read `reason` for what does not.
/// - `unsupported`: the app has no background path for synthesized events. Coordinate
///   and keyboard events are refused with `background_delivery_unavailable` unless the
///   caller forces a tier with `--via` or passes `--foreground`. AX actions are still tried.
enum DeliverySupport: String, Codable, Sendable, Comparable {
    case supported
    case degraded
    case unsupported

    private var rank: Int {
        switch self {
        case .supported: return 0
        case .degraded: return 1
        case .unsupported: return 2
        }
    }

    static func < (lhs: DeliverySupport, rhs: DeliverySupport) -> Bool {
        lhs.rank < rhs.rank
    }
}

/// One app's background-delivery profile: what the ladder tries, in which order, and why.
struct BackgroundDeliveryProfile: Codable, Equatable, Sendable {
    var toolkit: AppToolkit
    /// The background tier tried first. The other background tier is the fallback.
    var preferredTier: InputDeliveryMethod
    /// In `focusAssisted`, post keyboard events through `SLEventPostToPid` with an
    /// authentication message.
    var authenticatedKeyboard: Bool
    var support: DeliverySupport
    /// Human-readable explanation of `support`.
    var reason: String
    /// Background tiers for mouse input in ladder order, after symbol availability.
    /// `ax` applies to element-targeted actions only; `global` needs `--foreground`.
    var mouseTiers: [InputDeliveryMethod]
    /// Background tiers for keyboard input in ladder order.
    var keyboardTiers: [InputDeliveryMethod]
    /// The engine inside a `gameEngine` app: `unity`, `unreal`, or `godot`.
    var engine: String?
    /// Bundle facts the classification rests on, e.g. `Contents/Frameworks/Electron Framework.framework`.
    var evidence: [String]
    var bundleID: String?
    var version: String?
    var bundlePath: String?
    /// True when the classification came from the profile cache under the state directory.
    var cached: Bool

    init(
        toolkit: AppToolkit,
        preferredTier: InputDeliveryMethod,
        authenticatedKeyboard: Bool,
        support: DeliverySupport = .supported,
        reason: String = "",
        mouseTiers: [InputDeliveryMethod]? = nil,
        keyboardTiers: [InputDeliveryMethod]? = nil,
        engine: String? = nil,
        evidence: [String] = [],
        bundleID: String? = nil,
        version: String? = nil,
        bundlePath: String? = nil,
        cached: Bool = false
    ) {
        self.toolkit = toolkit
        self.preferredTier = preferredTier
        self.authenticatedKeyboard = authenticatedKeyboard
        self.support = support
        self.reason = reason
        // Without explicit lists, both background tiers in the preferred order.
        let order: [InputDeliveryMethod] = preferredTier == .focusAssisted
            ? [.ax, .focusAssisted, .window]
            : [.ax, .window, .focusAssisted]
        self.mouseTiers = mouseTiers ?? order
        self.keyboardTiers = keyboardTiers ?? order
        self.engine = engine
        self.evidence = evidence
        self.bundleID = bundleID
        self.version = version
        self.bundlePath = bundlePath
        self.cached = cached
    }

    static let native = BackgroundDeliveryProfile(toolkit: .native, preferredTier: .window, authenticatedKeyboard: false)
}

// MARK: - Static classification

/// What the bundle on disk says, independent of this machine's private symbols.
/// This is the part cached under the state directory.
struct AppBundleClassification: Codable, Equatable, Sendable {
    /// Bumped whenever the rules change, so older cache entries are ignored.
    static let rulesVersion = 2

    var rulesVersion: Int = AppBundleClassification.rulesVersion
    var toolkit: AppToolkit
    var engine: String?
    var evidence: [String]
    var bundleID: String?
    var version: String?
    var bundlePath: String?
}

/// Classifies an app bundle by toolkit from its layout and Info.plist. Reads files
/// only; never launches or messages the app.
enum AppBundleClassifier {
    static func classify(bundleURL: URL, fileManager: FileManager = .default) -> AppBundleClassification {
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let info = infoPlist(of: bundleURL)
        let bundleID = info?["CFBundleIdentifier"] as? String
        let version = versionString(info)

        func result(_ toolkit: AppToolkit, engine: String? = nil, evidence: [String]) -> AppBundleClassification {
            AppBundleClassification(
                toolkit: toolkit,
                engine: engine,
                evidence: evidence,
                bundleID: bundleID,
                version: version,
                bundlePath: bundleURL.path
            )
        }

        func exists(_ relative: String) -> Bool {
            fileManager.fileExists(atPath: contents.appendingPathComponent(relative).path)
        }
        func names(_ relative: String) -> [String] {
            (try? fileManager.contentsOfDirectory(atPath: contents.appendingPathComponent(relative).path)) ?? []
        }

        // iPhone/iPad apps on Apple silicon sit inside a thin wrapper bundle with no
        // Contents directory of their own.
        if fileManager.fileExists(atPath: bundleURL.appendingPathComponent("WrappedBundle").path)
            || fileManager.fileExists(atPath: bundleURL.appendingPathComponent("Wrapper").path) {
            return result(.catalyst, evidence: ["WrappedBundle (iPhone/iPad app)"])
        }

        let frameworks = names("Frameworks")
        let resources = names("Resources")

        // Game engines first: some games also ship a CEF or Qt helper.
        if frameworks.contains(where: { $0 == "UnityPlayer.dylib" || $0 == "GameAssembly.dylib" }) {
            let name = frameworks.contains("UnityPlayer.dylib") ? "UnityPlayer.dylib" : "GameAssembly.dylib"
            return result(.gameEngine, engine: "unity", evidence: ["Contents/Frameworks/\(name)"])
        }
        if exists("Resources/Data/Managed/UnityEngine.dll") || exists("Resources/Data/unity default resources") {
            return result(.gameEngine, engine: "unity", evidence: ["Contents/Resources/Data (Unity player data)"])
        }
        for directory in ["UE", "UE4", "UE5"] where exists(directory) {
            return result(.gameEngine, engine: "unreal", evidence: ["Contents/\(directory)"])
        }
        if let pack = resources.first(where: { $0.hasSuffix(".pck") }) {
            return result(.gameEngine, engine: "godot", evidence: ["Contents/Resources/\(pack)"])
        }

        if frameworks.contains("Electron Framework.framework") {
            return result(.electron, evidence: ["Contents/Frameworks/Electron Framework.framework"])
        }
        if let chromium = BackgroundDeliveryPolicy.chromiumFramework(in: frameworks, at: contents.appendingPathComponent("Frameworks"), fileManager: fileManager) {
            return result(.chromium, evidence: [chromium])
        }

        if let java = javaEvidence(info: info, frameworks: frameworks, exists: exists, plugIns: names("PlugIns")) {
            return result(.java, evidence: [java])
        }

        if let qt = frameworks.first(where: { $0 == "QtCore.framework" }) ?? frameworks.first(where: isQtLibraryName) {
            return result(.qt, evidence: ["Contents/Frameworks/\(qt)"])
        }
        if exists("PlugIns/platforms/libqcocoa.dylib") {
            return result(.qt, evidence: ["Contents/PlugIns/platforms/libqcocoa.dylib"])
        }

        if let catalyst = catalystEvidence(info: info) {
            return result(.catalyst, evidence: [catalyst])
        }

        guard info != nil else {
            return result(.unknown, evidence: ["No Contents/Info.plist"])
        }
        return result(.native, evidence: ["No cross-platform toolkit found in the bundle"])
    }

    static func infoPlist(of bundleURL: URL) -> [String: Any]? {
        let url = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        return plist
    }

    /// `CFBundleShortVersionString (CFBundleVersion)`, or whichever one is present.
    static func versionString(_ info: [String: Any]?) -> String? {
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build:
            return "\(short) (\(build))"
        case let (short?, _):
            return short
        case let (nil, build?):
            return build
        default:
            return nil
        }
    }

    static func isQtLibraryName(_ name: String) -> Bool {
        (name.hasPrefix("Qt") && name.hasSuffix(".framework") && name.contains("Core"))
            || (name.hasPrefix("libQt") && name.contains("Core") && name.hasSuffix(".dylib"))
    }

    private static func javaEvidence(
        info: [String: Any]?,
        frameworks: [String],
        exists: (String) -> Bool,
        plugIns: [String]
    ) -> String? {
        if let key = ["JVMOptions", "Java", "JVMMainClassName", "JVMVersion"].first(where: { info?[$0] != nil }) {
            return "Info.plist \(key)"
        }
        for directory in ["Java", "runtime", "jbr"] where exists(directory) {
            return "Contents/\(directory)"
        }
        if let runtime = plugIns.first(where: { $0.hasSuffix(".jdk") || $0.hasSuffix(".jre") }) {
            return "Contents/PlugIns/\(runtime)"
        }
        if frameworks.contains("libjli.dylib") {
            return "Contents/Frameworks/libjli.dylib"
        }
        return nil
    }

    private static func catalystEvidence(info: [String: Any]?) -> String? {
        if let platforms = info?["CFBundleSupportedPlatforms"] as? [String],
           platforms.contains(where: { $0.hasPrefix("iPhone") }) {
            return "Info.plist CFBundleSupportedPlatforms \(platforms.joined(separator: ","))"
        }
        if info?["UIDeviceFamily"] != nil {
            return "Info.plist UIDeviceFamily"
        }
        if (info?["LSRequiresIPhoneOS"] as? Bool) == true {
            return "Info.plist LSRequiresIPhoneOS"
        }
        return nil
    }
}

// MARK: - Policy

/// Turns a static classification plus this machine's private-symbol availability
/// into a delivery profile.
enum BackgroundDeliveryPolicy {
    static func profile(
        for classification: AppBundleClassification,
        capabilities: DeliveryCapabilities,
        authenticatedKeyboardOS: Bool,
        cached: Bool = false
    ) -> BackgroundDeliveryProfile {
        var support: DeliverySupport
        var reasons: [String] = []
        var preferred: InputDeliveryMethod = .window
        var authenticated = false

        switch classification.toolkit {
        case .native:
            support = .supported
            reasons.append("AppKit/SwiftUI app: AX actions and window-addressed events work while it is in the background. "
                + "Verified live on an AppKit test app on macOS 15 and macOS 27.2.")
        case .electron:
            support = .degraded
            preferred = .focusAssisted
            authenticated = authenticatedKeyboardOS
            reasons.append("Electron app: it drops clicks unless its window is key, so input goes through focusAssisted, "
                + "which makes the window key without activating the app, and text goes in as key events first. Verified live "
                + "with an Electron test app on macOS 27.2 (clicks, typing into inputs, text areas, and contenteditables, keys, "
                + "menu shortcuts, scrolling, state, and window capture) and on macOS 15 (clicks, typing, keys, menu shortcuts, "
                + "scrolling, state, and window capture, before the key-events-first text ordering). On macOS 15 a coordinate "
                + "click into web content once moved the window toward the front, which macOS 27.2 never showed. "
                + "Window-addressed input reaches only the window's active tab or web view.")
        case .chromium:
            support = .degraded
            preferred = .focusAssisted
            authenticated = authenticatedKeyboardOS
            reasons.append("Chromium browser or CEF app: input goes through focusAssisted, which makes the window key without "
                + "activating the app, and text goes in as key events first. Google Chrome 154 was verified live on macOS 27.2: "
                + "clicks, typing into inputs, text areas, and contenteditables, keys and menu shortcuts, scrolling, select-text, "
                + "state, and window capture, with window order unchanged. Chrome activates itself for menu commands that open a "
                + "window or tab, and the focus guard puts the previous app back. Not tested on macOS 15, and other Chromium "
                + "browsers and CEF apps have not been tested. Window-addressed input reaches only the window's active tab.")
        case .catalyst:
            support = .degraded
            reasons.append("UIKit app (Mac Catalyst or iPhone/iPad): AX actions work, but some controls react to window events "
                + "only while the app is active. Not tested live.")
        case .qt:
            support = .degraded
            preferred = .focusAssisted
            reasons.append("Qt app: window events arrive, but Qt widgets often ignore keystrokes unless their window is key, "
                + "and the AX tree is sparse. Not tested live.")
        case .java:
            support = .degraded
            preferred = .focusAssisted
            reasons.append("Java app: AWT/Swing reads input only for its key window and exposes a thin AX tree; "
                + "focus-assisted delivery is tried first. Not tested live.")
        case .gameEngine:
            support = .unsupported
            let engine = classification.engine.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? "Game"
            reasons.append("\(engine) game engine: it reads input from its own event loop or the HID system while frontmost and drops synthesized background events. Use --foreground, or force a tier with --via.")
        case .unknown:
            support = .degraded
            reasons.append("No app bundle to classify; using the default AppKit ladder.")
        }

        if !capabilities.windowLocation, support != .unsupported {
            support = max(support, .degraded)
            reasons.append("CGEventSetWindowLocation is missing, so background mouse input is limited to AX actions.")
        }

        let isChromiumFamily = classification.toolkit == .chromium || classification.toolkit == .electron
        if isChromiumFamily {
            // Plain window events reach a Chromium window but are dropped while it is
            // not key, so they are never a fallback: they would report success while
            // nothing happens. `--via window` can still force them.
            if !capabilities.focusRecords || !capabilities.windowLocation {
                support = max(support, .degraded)
                reasons.append("The focus-record or window-location symbols are missing, so the window cannot be made key "
                    + "and background clicks and keys are refused. AX actions still work.")
            }
            if authenticatedKeyboardOS && !capabilities.authenticatedPost {
                reasons.append("Authenticated SkyLight posting is missing, so keys go out as plain per-process events.")
            }
        }

        let order: [InputDeliveryMethod] = isChromiumFamily
            ? [.focusAssisted]
            : (preferred == .focusAssisted ? [.focusAssisted, .window] : [.window, .focusAssisted])
        let mouseTiers: [InputDeliveryMethod]
        let keyboardTiers: [InputDeliveryMethod]
        if support == .unsupported {
            mouseTiers = [.ax]
            keyboardTiers = [.ax]
        } else {
            mouseTiers = [.ax] + order.filter { tier in
                tier == .window ? capabilities.windowLocation : capabilities.focusRecords && capabilities.windowLocation
            }
            keyboardTiers = [.ax] + order.filter { tier in
                // focusAssisted makes the window key with a click, which needs a
                // window location.
                tier == .window ? true : capabilities.focusRecords && capabilities.windowLocation
            }
        }

        return BackgroundDeliveryProfile(
            toolkit: classification.toolkit,
            preferredTier: preferred,
            authenticatedKeyboard: authenticated,
            support: support,
            reason: reasons.joined(separator: " "),
            mouseTiers: mouseTiers,
            keyboardTiers: keyboardTiers,
            engine: classification.engine,
            evidence: classification.evidence,
            bundleID: classification.bundleID,
            version: classification.version,
            bundlePath: classification.bundlePath,
            cached: cached
        )
    }

    /// Electron, CEF, and Chrome-family browsers all ship their engine as a framework
    /// inside the app bundle.
    static func isChromiumFamily(bundleURL: URL, fileManager: FileManager = .default) -> Bool {
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: frameworks.path) else {
            return false
        }
        return chromiumFramework(in: names, at: frameworks, fileManager: fileManager) != nil
    }

    /// Resource packs only the Chromium engine ships. Every Chromium build puts them
    /// in its framework's Resources, whatever the framework is named.
    static let chromiumResourceMarkers = ["chrome_100_percent.pak", "chrome_200_percent.pak"]

    /// The bundle evidence for a Chromium engine among `names` in `frameworksURL`: a
    /// framework holding Chromium's resource packs, else a framework with a known
    /// Chromium name. Nil when there is neither.
    static func chromiumFramework(in names: [String], at frameworksURL: URL, fileManager: FileManager = .default) -> String? {
        for name in names.sorted() where name.hasSuffix(".framework") {
            let resources = frameworksURL.appendingPathComponent(name).appendingPathComponent("Resources")
            if let marker = chromiumResourceMarkers.first(where: {
                fileManager.fileExists(atPath: resources.appendingPathComponent($0).path)
            }) {
                return "Contents/Frameworks/\(name)/Resources/\(marker)"
            }
        }
        return names.first(where: isChromiumFrameworkName).map { "Contents/Frameworks/\($0)" }
    }

    /// Known Chromium framework names, the fallback when the resource packs are not
    /// where they are expected.
    static func isChromiumFrameworkName(_ name: String) -> Bool {
        let known = [
            "Electron Framework.framework",
            "Chromium Embedded Framework.framework",
            "Google Chrome Framework.framework",
            "Google Chrome Beta Framework.framework",
            "Google Chrome Canary Framework.framework",
            "Chromium Framework.framework",
            "Microsoft Edge Framework.framework",
            "Brave Browser Framework.framework",
            "Vivaldi Framework.framework",
            "Opera Framework.framework",
            "Arc Framework.framework",
            "Comet Framework.framework",
        ]
        return known.contains(name)
    }
}

// MARK: - Resolver and cache

/// Resolves and caches delivery profiles. Classifications are cached on disk under
/// `<state>/profiles/`, keyed by bundle ID and version, and in memory per bundle.
/// Symbol availability is applied on every lookup, so a cache entry never goes stale
/// across macOS updates.
final class DeliveryProfileResolver: @unchecked Sendable {
    private let cacheDirectory: URL?
    private let capabilities: DeliveryCapabilities
    private let authenticatedKeyboardOS: Bool
    private let fileManager: FileManager
    private let bundleURLForPid: (pid_t) -> URL?
    private let lock = NSLock()
    private var memory: [String: AppBundleClassification] = [:]

    init(
        cacheDirectory: URL?,
        capabilities: DeliveryCapabilities = .live(),
        authenticatedKeyboardOS: Bool = DeliveryProfileResolver.isAuthenticatedKeyboardOS(),
        fileManager: FileManager = .default,
        bundleURLForPid: @escaping (pid_t) -> URL? = { NSRunningApplication(processIdentifier: $0)?.bundleURL }
    ) {
        self.cacheDirectory = cacheDirectory
        self.capabilities = capabilities
        self.authenticatedKeyboardOS = authenticatedKeyboardOS
        self.fileManager = fileManager
        self.bundleURLForPid = bundleURLForPid
    }

    /// No disk cache: the engine's default when no state directory is wired in.
    static let uncached = DeliveryProfileResolver(cacheDirectory: nil)

    convenience init(statePaths: StatePaths) {
        self.init(cacheDirectory: statePaths.profilesDirectoryURL)
    }

    /// Authenticated keyboard posting is what Chromium needs from macOS 15 on.
    static func isAuthenticatedKeyboardOS() -> Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )
    }

    func profile(pid: pid_t) -> BackgroundDeliveryProfile {
        profile(bundleURL: bundleURLForPid(pid))
    }

    func profile(bundleURL: URL?) -> BackgroundDeliveryProfile {
        guard let bundleURL, bundleURL.pathExtension == "app" else {
            let classification = AppBundleClassification(
                toolkit: .unknown,
                evidence: [bundleURL.map { "\($0.lastPathComponent) is not an .app bundle" } ?? "No bundle URL for the process"],
                bundlePath: bundleURL?.path
            )
            return BackgroundDeliveryPolicy.profile(
                for: classification,
                capabilities: capabilities,
                authenticatedKeyboardOS: authenticatedKeyboardOS
            )
        }
        let (classification, cached) = classification(bundleURL: bundleURL)
        return BackgroundDeliveryPolicy.profile(
            for: classification,
            capabilities: capabilities,
            authenticatedKeyboardOS: authenticatedKeyboardOS,
            cached: cached
        )
    }

    func classification(bundleURL: URL) -> (AppBundleClassification, cached: Bool) {
        let info = AppBundleClassifier.infoPlist(of: bundleURL)
        let bundleID = info?["CFBundleIdentifier"] as? String
        let version = AppBundleClassifier.versionString(info)
        let memoryKey = "\(bundleURL.path)\n\(version ?? "")"

        lock.lock()
        let remembered = memory[memoryKey]
        lock.unlock()
        if let remembered {
            return (remembered, true)
        }

        if let bundleID, let cacheURL = cacheURL(bundleID: bundleID, version: version),
           let data = try? Data(contentsOf: cacheURL),
           let stored = try? JSONDecoder().decode(AppBundleClassification.self, from: data),
           stored.rulesVersion == AppBundleClassification.rulesVersion,
           stored.bundleID == bundleID,
           stored.version == version {
            remember(stored, key: memoryKey)
            return (stored, true)
        }

        let fresh = AppBundleClassifier.classify(bundleURL: bundleURL, fileManager: fileManager)
        remember(fresh, key: memoryKey)
        if let bundleID, let cacheURL = cacheURL(bundleID: bundleID, version: version),
           let data = try? JSONEncoder().encode(fresh) {
            try? fileManager.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        return (fresh, false)
    }

    func cacheURL(bundleID: String, version: String?) -> URL? {
        guard let cacheDirectory else { return nil }
        let name = Self.sanitized(bundleID) + "@" + Self.sanitized(version ?? "unversioned") + ".json"
        return cacheDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private func remember(_ classification: AppBundleClassification, key: String) {
        lock.lock()
        memory[key] = classification
        lock.unlock()
    }

    private static func sanitized(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}
