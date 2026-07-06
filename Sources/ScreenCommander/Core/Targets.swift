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
        runningApp.activate(options: [.activateIgnoringOtherApps])
    }
}

// MARK: - Production implementation

final class Targets: TargetResolving {
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

        // Name match: gather all running apps, try exact then prefix
        let allApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular || $0.activationPolicy == .accessory
        }

        let lower = identifier.lowercased()
        let exactMatches = allApps.filter { $0.localizedName?.lowercased() == lower }
        if exactMatches.count == 1 {
            let a = exactMatches[0]
            return ResolvedApp(pid: a.processIdentifier, name: a.localizedName ?? "(unknown)", bundleID: a.bundleIdentifier)
        }
        if exactMatches.count > 1 {
            let names = exactMatches.compactMap { $0.localizedName }.joined(separator: ", ")
            throw ScreenCommanderError.invalidArguments("Ambiguous app name '\(identifier)'; candidates: \(names).")
        }

        let prefixMatches = allApps.filter { $0.localizedName?.lowercased().hasPrefix(lower) == true }
        if prefixMatches.count == 1 {
            let a = prefixMatches[0]
            return ResolvedApp(pid: a.processIdentifier, name: a.localizedName ?? "(unknown)", bundleID: a.bundleIdentifier)
        }
        if prefixMatches.count > 1 {
            let names = prefixMatches.compactMap { $0.localizedName }.joined(separator: ", ")
            throw ScreenCommanderError.invalidArguments("Ambiguous app name prefix '\(identifier)'; candidates: \(names).")
        }

        throw ScreenCommanderError.appNotFound("No running app matching '\(identifier)'.")
    }

    func listWindows(app: ResolvedApp?) async throws -> [WindowInfo] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
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
