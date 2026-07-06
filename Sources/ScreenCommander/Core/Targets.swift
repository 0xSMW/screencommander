import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - Data types

struct ResolvedApp: Codable, Sendable {
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

// MARK: - Protocol

protocol TargetResolving {
    func resolveApp(identifier: String) async throws -> ResolvedApp
    func listWindows(app: ResolvedApp?) async throws -> [WindowInfo]
    func resolveWindow(identifier: String, app: ResolvedApp?) async throws -> (SCWindow, WindowInfo)
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
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
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

    func resolveWindow(identifier: String, app: ResolvedApp?) async throws -> (SCWindow, WindowInfo) {
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
            let info = windowInfo(from: win)
            return (win, info)
        }

        // App-name prefix: frontmost window of that app (lowest layer = frontmost)
        let lower = identifier.lowercased()
        let appWindows = candidates.filter {
            $0.owningApplication?.applicationName.lowercased().hasPrefix(lower) == true
        }
        guard let win = appWindows.min(by: { $0.windowLayer < $1.windowLayer }) else {
            throw ScreenCommanderError.windowNotFound("No window matching '\(identifier)'.")
        }
        let info = windowInfo(from: win)
        return (win, info)
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
