import AppKit
import Foundation

// WP4 note: WP2 owns the canonical version of this file (ResolvedApp, TargetResolving,
// and the SCShareableContent-backed production resolver with window listing and the
// app_not_found/window_not_found error codes). The shapes below match the capability
// spec exactly so the integrator can keep WP2's file wholesale; only `Targets` here is
// a minimal placeholder so `elements --app <name|pid>` works standalone.

/// A resolved running application target.
struct ResolvedApp: Codable, Sendable, Equatable {
    var pid: Int32
    var name: String
    var bundleID: String?
}

/// Resolves `--app` identifiers (pid or app-name match) to running applications.
protocol TargetResolving {
    func resolveApp(identifier: String) async throws -> ResolvedApp
}

/// Minimal NSWorkspace-backed resolver: numeric pid, then case-insensitive exact name,
/// then unambiguous case-insensitive name prefix.
struct Targets: TargetResolving {
    func resolveApp(identifier: String) async throws -> ResolvedApp {
        let trimmed = identifier.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw ScreenCommanderError.invalidArguments("--app requires an app name or pid.")
        }

        let running = NSWorkspace.shared.runningApplications

        if let pid = Int32(trimmed) {
            guard let app = running.first(where: { $0.processIdentifier == pid }) else {
                throw ScreenCommanderError.invalidArguments("No running app with pid \(pid).")
            }
            return ResolvedApp(app)
        }

        let lowered = trimmed.lowercased()
        let named = running.filter { $0.localizedName != nil }

        let exact = named.filter { $0.localizedName!.lowercased() == lowered }
        if let app = exact.first {
            return ResolvedApp(app)
        }

        let prefixed = named.filter { $0.localizedName!.lowercased().hasPrefix(lowered) }
        switch prefixed.count {
        case 0:
            throw ScreenCommanderError.invalidArguments("No running app matches '\(trimmed)'.")
        case 1:
            return ResolvedApp(prefixed[0])
        default:
            let candidates = prefixed.compactMap(\.localizedName).sorted().joined(separator: ", ")
            throw ScreenCommanderError.invalidArguments(
                "App name '\(trimmed)' is ambiguous. Candidates: \(candidates)."
            )
        }
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
