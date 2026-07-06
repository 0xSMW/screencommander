import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - Data types

struct ResolvedApp: Codable, Sendable, Equatable {
    var pid: pid_t
    var name: String
    var bundleID: String?
}

struct RunningAppSnapshot: Equatable {
    var pid: pid_t
    var localizedName: String?
    var bundleID: String?
}

struct WindowInfo: Codable, Sendable {
    var windowID: UInt32
    var title: String
    var appName: String
    var pid: pid_t
    var boundsPoints: RectD
    var isOnScreen: Bool
    var layer: Int
}

/// A window resolved for capture. `scWindow` carries the live ScreenCaptureKit handle
/// needed to build a content filter; it is optional so test fakes (which cannot
/// construct `SCWindow`) can drive the window-capture path through the engine.
struct ResolvedWindow {
    var info: WindowInfo
    var scWindow: SCWindow?
}

// MARK: - Protocol

protocol TargetResolving {
    func resolveApp(identifier: String) async throws -> ResolvedApp
    func listWindows(app: ResolvedApp?) async throws -> [WindowInfo]
    func resolveWindow(identifier: String, app: ResolvedApp?) async throws -> ResolvedWindow
}

/// Brings an app to the foreground. Lives behind an engine-injected closure so
/// `focus` can be tested without touching live NSRunningApplication state.
enum AppActivator {
    static func activate(_ app: ResolvedApp) throws {
        guard let runningApp = NSRunningApplication(processIdentifier: app.pid) else {
            throw ScreenCommanderError.appNotFound("App with PID \(app.pid) is no longer running.")
        }
        guard runningApp.activate() else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not activate app '\(app.name)' with PID \(app.pid).")
        }
        for _ in 0..<10 {
            if runningApp.isActive {
                return
            }
            usleep(25_000)
        }
        guard runningApp.isActive else {
            throw ScreenCommanderError.inputSynthesisFailed("App '\(app.name)' with PID \(app.pid) did not become active.")
        }
    }
}

// MARK: - Production implementation

final class Targets: TargetResolving {
    private let contentProvider: ShareableContentProvider
    private let runningApplications: () -> [RunningAppSnapshot]

    init(
        contentProvider: ShareableContentProvider = ShareableContentProvider(),
        runningApplications: @escaping () -> [RunningAppSnapshot] = {
            NSWorkspace.shared.runningApplications.map {
                RunningAppSnapshot(
                    pid: $0.processIdentifier,
                    localizedName: $0.localizedName,
                    bundleID: $0.bundleIdentifier
                )
            }
        }
    ) {
        self.contentProvider = contentProvider
        self.runningApplications = runningApplications
    }

    func resolveApp(identifier: String) async throws -> ResolvedApp {
        // Numeric: treat as PID
        if let pidValue = Int32(identifier) {
            guard let app = NSRunningApplication(processIdentifier: pidValue) else {
                throw ScreenCommanderError.appNotFound("No running app with PID \(pidValue).")
            }
            return ResolvedApp(
                pid: app.processIdentifier,
                name: app.localizedName ?? "(unknown)",
                bundleID: app.bundleIdentifier
            )
        }

        // Name match: gather all running apps, try exact then prefix. Do not
        // filter by activation policy here; menu-bar and background utilities can
        // still be legitimate automation targets, and PID remains the fallback
        // disambiguator when multiple processes share a name.
        let allApps = runningApplications()

        let lower = identifier.lowercased()
        let exactMatches = allApps.filter { $0.localizedName?.lowercased() == lower }
        if exactMatches.count == 1 {
            let a = exactMatches[0]
            return resolvedApp(from: a)
        }
        if exactMatches.count > 1 {
            throw ScreenCommanderError.invalidArguments(
                "Ambiguous app name '\(identifier)'; candidates: \(describeAppCandidates(exactMatches))."
            )
        }

        let prefixMatches = allApps.filter { $0.localizedName?.lowercased().hasPrefix(lower) == true }
        if prefixMatches.count == 1 {
            let a = prefixMatches[0]
            return resolvedApp(from: a)
        }
        if prefixMatches.count > 1 {
            throw ScreenCommanderError.invalidArguments(
                "Ambiguous app name prefix '\(identifier)'; candidates: \(describeAppCandidates(prefixMatches))."
            )
        }

        throw ScreenCommanderError.appNotFound("No running app matching '\(identifier)'.")
    }

    private func resolvedApp(from app: RunningAppSnapshot) -> ResolvedApp {
        ResolvedApp(pid: app.pid, name: app.localizedName ?? "(unknown)", bundleID: app.bundleID)
    }

    private func describeAppCandidates(_ apps: [RunningAppSnapshot]) -> String {
        apps
            .map { app in
                var description = "\(app.localizedName ?? "(unknown)") (pid \(app.pid)"
                if let bundleID = app.bundleID, !bundleID.isEmpty {
                    description += ", bundle \(bundleID)"
                }
                description += ")"
                return description
            }
            .joined(separator: ", ")
    }

    func listWindows(app: ResolvedApp?) async throws -> [WindowInfo] {
        let content: SCShareableContent
        do {
            content = try await contentProvider.content(onScreenWindowsOnly: true)
        } catch {
            throw ScreenCommanderError.captureFailed("Could not enumerate windows: \(error.localizedDescription)")
        }

        var windows = content.windows
        if let app {
            windows = windows.filter { $0.owningApplication?.processID == app.pid }
        }

        return windows.map { w in
            WindowInfo(
                windowID: w.windowID,
                title: w.title ?? "",
                appName: w.owningApplication?.applicationName ?? "",
                pid: w.owningApplication?.processID ?? 0,
                boundsPoints: RectD(w.frame),
                isOnScreen: w.isOnScreen,
                layer: w.windowLayer
            )
        }
    }

    func resolveWindow(identifier: String, app: ResolvedApp?) async throws -> ResolvedWindow {
        let content: SCShareableContent
        do {
            content = try await contentProvider.content(onScreenWindowsOnly: false)
        } catch {
            throw ScreenCommanderError.captureFailed("Could not enumerate windows: \(error.localizedDescription)")
        }

        var candidates = content.windows
        if let app {
            candidates = candidates.filter { $0.owningApplication?.processID == app.pid }
        }

        // Numeric: match by windowID
        if let idValue = UInt32(identifier) {
            guard let win = candidates.first(where: { $0.windowID == idValue }) else {
                throw ScreenCommanderError.windowNotFound("No window with ID \(idValue).")
            }
            return ResolvedWindow(info: windowInfo(from: win), scWindow: win)
        }

        // App-name prefix: frontmost window of that app. All normal windows share
        // layer 0, so prefer on-screen windows (off-screen/minimized ones have no
        // defined ordering in the enumeration) before tie-breaking on layer.
        let lower = identifier.lowercased()
        let appWindows = candidates.filter {
            $0.owningApplication?.applicationName.lowercased().hasPrefix(lower) == true
        }
        let onScreenWindows = appWindows.filter { $0.isOnScreen }
        let pool = onScreenWindows.isEmpty ? appWindows : onScreenWindows
        guard let win = pool.min(by: { $0.windowLayer < $1.windowLayer }) else {
            throw ScreenCommanderError.windowNotFound("No window matching '\(identifier)'.")
        }
        return ResolvedWindow(info: windowInfo(from: win), scWindow: win)
    }

    private func windowInfo(from w: SCWindow) -> WindowInfo {
        WindowInfo(
            windowID: w.windowID,
            title: w.title ?? "",
            appName: w.owningApplication?.applicationName ?? "",
            pid: w.owningApplication?.processID ?? 0,
            boundsPoints: RectD(w.frame),
            isOnScreen: w.isOnScreen,
            layer: w.windowLayer
        )
    }
}

extension ResolvedApp {
    init(_ app: NSRunningApplication) {
        self.init(
            pid: app.processIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
            bundleID: app.bundleIdentifier
        )
    }
}
