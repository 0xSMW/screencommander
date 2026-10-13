import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// MARK: - Data types

struct RunningAppEntry: Codable, Sendable, Equatable {
    var name: String
    var bundleID: String?
    var pid: pid_t
    var frontmost: Bool
    /// On-screen normal-layer windows.
    var windowCount: Int
    /// `regular` (Dock app) or `accessory` (menu-bar or agent app).
    var activationPolicy: String
    var bundlePath: String?
}

struct InstalledAppEntry: Codable, Sendable, Equatable {
    var name: String
    var bundleID: String?
    var path: String
    var version: String?
    var running: Bool
}

/// An installed app picked for `launch`, `doctor --app`, or a profile lookup.
struct InstalledAppTarget: Equatable, Sendable {
    var name: String
    var bundleID: String?
    var url: URL
}

// MARK: - Fresh process list

/// `NSWorkspace.runningApplications` only updates from main-run-loop notifications,
/// which neither the CLI nor `serve` spins, so in a long-lived process it never
/// shows apps launched after the first read. This builds the list from the kernel's
/// pid list instead, minting a fresh `NSRunningApplication` per pid (about 30 ms).
enum RunningApplications {
    /// Apps for every pid the kernel lists right now. When the kernel list cannot be
    /// read, the result is empty rather than `NSWorkspace`'s list, which would be
    /// stale in exactly the long-lived processes this exists for.
    static func current(listPIDs: () -> [pid_t]? = kernelPIDs) -> [NSRunningApplication] {
        guard let pids = listPIDs() else {
            return []
        }
        return pids.compactMap { pid in
            pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
        }
    }

    /// Every pid from `proc_listallpids`, retried once with a larger buffer in case
    /// processes started between sizing and listing. Nil when it keeps failing.
    static func kernelPIDs() -> [pid_t]? {
        for headroom in [64, 1024] {
            let estimate = proc_listallpids(nil, 0)
            guard estimate > 0 else {
                continue
            }
            var pids = [pid_t](repeating: 0, count: Int(estimate) + headroom)
            let count = pids.withUnsafeMutableBytes { buffer in
                proc_listallpids(buffer.baseAddress, Int32(buffer.count))
            }
            if count > 0, Int(count) < pids.count {
                return Array(pids.prefix(Int(count)))
            }
        }
        return nil
    }
}

// MARK: - Catalog

/// Running and installed apps. Injected into the engine so tests never touch
/// LaunchServices or the file system.
protocol AppCataloging {
    func runningApps() -> [RunningAppEntry]
    /// Installed `.app` bundles, possibly served from a short-lived cache.
    func installedApps() -> (apps: [InstalledAppEntry], truncated: Bool)
    /// The bundle URL of a running process, when it has one.
    func bundleURL(pid: pid_t) -> URL?
    /// Resolves a name, bundle ID, or path to an installed app bundle.
    func resolveInstalled(identifier: String) throws -> InstalledAppTarget
}

final class AppCatalog: AppCataloging, @unchecked Sendable {
    /// Directories scanned for installed apps, one level of subfolders deep.
    static let defaultSearchDirectories: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }()

    /// The scan stops after this many bundles and reports `truncated`.
    static let installedLimit = 2000

    private let searchDirectories: [URL]
    private let cacheTTL: TimeInterval
    private let fileManager: FileManager
    private let now: () -> Date
    private let lock = NSLock()
    private var cachedInstalled: (apps: [InstalledAppEntry], truncated: Bool, at: Date)?

    init(
        searchDirectories: [URL] = AppCatalog.defaultSearchDirectories,
        cacheTTL: TimeInterval = 60,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.searchDirectories = searchDirectories
        self.cacheTTL = cacheTTL
        self.fileManager = fileManager
        self.now = now
    }

    func runningApps() -> [RunningAppEntry] {
        let frontmost = FrontmostApp.current()?.pid
        let windowCounts = Self.onScreenWindowCounts()
        return RunningApplications.current().compactMap { app in
            let policy: String
            switch app.activationPolicy {
            case .regular: policy = "regular"
            case .accessory: policy = "accessory"
            default: return nil
            }
            guard !app.isTerminated else { return nil }
            return RunningAppEntry(
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                bundleID: app.bundleIdentifier,
                pid: app.processIdentifier,
                frontmost: app.processIdentifier == frontmost,
                windowCount: windowCounts[app.processIdentifier] ?? 0,
                activationPolicy: policy,
                bundlePath: app.bundleURL?.path
            )
        }
        .sorted { lhs, rhs in
            if lhs.activationPolicy != rhs.activationPolicy {
                return lhs.activationPolicy == "regular"
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func installedApps() -> (apps: [InstalledAppEntry], truncated: Bool) {
        let running = RunningApplications.current()
        let runningIDs = Set(running.compactMap(\.bundleIdentifier))
        let runningPaths = Set(running.compactMap { $0.bundleURL?.standardizedFileURL.path })

        let scanned = scanInstalled()
        let apps = scanned.apps.map { entry -> InstalledAppEntry in
            var entry = entry
            entry.running = entry.bundleID.map(runningIDs.contains) == true || runningPaths.contains(entry.path)
            return entry
        }
        return (apps, scanned.truncated)
    }

    func bundleURL(pid: pid_t) -> URL? {
        NSRunningApplication(processIdentifier: pid)?.bundleURL
    }

    func resolveInstalled(identifier: String) throws -> InstalledAppTarget {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScreenCommanderError.invalidArguments("--app must not be empty.")
        }

        if trimmed.contains("/") || trimmed.hasSuffix(".app") && fileManager.fileExists(atPath: trimmed) {
            let url = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
            guard url.pathExtension == "app", fileManager.fileExists(atPath: url.path) else {
                throw ScreenCommanderError.appNotFound("No app bundle at '\(trimmed)'.")
            }
            let info = AppBundleClassifier.infoPlist(of: url)
            return InstalledAppTarget(
                name: url.deletingPathExtension().lastPathComponent,
                bundleID: info?["CFBundleIdentifier"] as? String,
                url: url
            )
        }

        if trimmed.contains("."), !trimmed.contains(" "),
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) {
            return InstalledAppTarget(name: url.deletingPathExtension().lastPathComponent, bundleID: trimmed, url: url)
        }

        return try Self.match(identifier: trimmed, in: scanInstalled().apps)
    }

    /// Exact name, then bundle ID, then a unique name prefix (case-insensitive).
    static func match(identifier: String, in apps: [InstalledAppEntry]) throws -> InstalledAppTarget {
        let lower = identifier.lowercased()
        func target(_ entry: InstalledAppEntry) -> InstalledAppTarget {
            InstalledAppTarget(name: entry.name, bundleID: entry.bundleID, url: URL(fileURLWithPath: entry.path))
        }
        func describe(_ entries: [InstalledAppEntry]) -> String {
            entries.prefix(8).map { "\($0.name) (\($0.path))" }.joined(separator: ", ")
        }

        let exact = apps.filter { $0.name.lowercased() == lower || $0.bundleID?.lowercased() == lower }
        if let first = exact.first {
            // Two copies of the same bundle (e.g. /Applications and ~/Applications)
            // are not ambiguous in any way that matters; the first scanned wins.
            if Set(exact.map { $0.bundleID ?? $0.path }).count == 1 {
                return target(first)
            }
            throw ScreenCommanderError.invalidArguments(
                "Ambiguous app name '\(identifier)'; candidates: \(describe(exact)). Pass a bundle ID or path."
            )
        }

        let prefix = apps.filter { $0.name.lowercased().hasPrefix(lower) }
        if prefix.count == 1 || Set(prefix.map { $0.bundleID ?? $0.path }).count == 1, let first = prefix.first {
            return target(first)
        }
        if !prefix.isEmpty {
            throw ScreenCommanderError.invalidArguments(
                "Ambiguous app name prefix '\(identifier)'; candidates: \(describe(prefix)). Pass the full name, a bundle ID, or a path."
            )
        }
        throw ScreenCommanderError.appNotFound(
            "No installed app matching '\(identifier)'. List installed apps with 'screencommander apps'."
        )
    }

    private func scanInstalled() -> (apps: [InstalledAppEntry], truncated: Bool) {
        lock.lock()
        if let cached = cachedInstalled, now().timeIntervalSince(cached.at) < cacheTTL {
            lock.unlock()
            return (cached.apps, cached.truncated)
        }
        lock.unlock()

        var apps: [InstalledAppEntry] = []
        var seenPaths = Set<String>()
        var truncated = false

        func add(_ url: URL) {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return }
            let info = AppBundleClassifier.infoPlist(of: url)
            apps.append(InstalledAppEntry(
                name: url.deletingPathExtension().lastPathComponent,
                bundleID: info?["CFBundleIdentifier"] as? String,
                path: path,
                version: info?["CFBundleShortVersionString"] as? String,
                running: false
            ))
        }

        scan: for directory in searchDirectories {
            guard let children = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if apps.count >= Self.installedLimit {
                    truncated = true
                    break scan
                }
                if child.pathExtension == "app" {
                    add(child)
                    continue
                }
                // One level of folders (Utilities, vendor suites), but not into bundles.
                let isDirectory = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory,
                      let nested = try? fileManager.contentsOfDirectory(
                        at: child,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                      ) else {
                    continue
                }
                for app in nested.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where app.pathExtension == "app" {
                    if apps.count >= Self.installedLimit {
                        truncated = true
                        break scan
                    }
                    add(app)
                }
            }
        }

        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        lock.lock()
        cachedInstalled = (apps, truncated, now())
        lock.unlock()
        return (apps, truncated)
    }

    /// On-screen normal-layer window counts per pid, from one window-list call.
    static func onScreenWindowCounts() -> [pid_t: Int] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var counts: [pid_t: Int] = [:]
        for info in list {
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0 == 0 else {
                continue
            }
            counts[pid, default: 0] += 1
        }
        return counts
    }
}

// MARK: - Launching

/// Starts apps without activating them. Injected so tests never launch anything.
protocol AppLaunching {
    /// Launches the bundle with `activates = false` and returns the new process ID.
    func launch(url: URL) async throws -> pid_t
    /// Waits until the process has finished launching (or answers AX), up to `timeout`.
    func waitUntilReady(pid: pid_t, timeout: TimeInterval) async -> Bool
}

struct LiveAppLauncher: AppLaunching {
    func launch(url: URL) async throws -> pid_t {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
                if let app {
                    continuation.resume(returning: app.processIdentifier)
                } else {
                    let detail = error?.localizedDescription ?? "LaunchServices returned no app."
                    continuation.resume(throwing: ScreenCommanderError.appNotFound(
                        "Could not launch '\(url.lastPathComponent)': \(detail)"
                    ))
                }
            }
        }
    }

    /// Neither the CLI nor `serve` spins the main run loop, so a cached
    /// `NSRunningApplication` never updates. Each poll asks for a fresh instance and
    /// also accepts an AX answer from the app element.
    func waitUntilReady(pid: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
                return false
            }
            if app.isFinishedLaunching || Self.answersAccessibility(pid: pid) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private static func answersAccessibility(pid: pid_t) -> Bool {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
    }
}
