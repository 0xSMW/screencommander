import ArgumentParser
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check permissions, displays, background delivery, and the presence process.",
        discussion: """
            Run this first when something fails. Capture needs Screen Recording and input needs \
            Accessibility. The presence process, which draws the agent cursor and holds session \
            leases, starts with the first background action, so 'Not running' before that is normal.

            Examples:
              screencommander doctor
              screencommander doctor --app Safari
            """
    )

    @Option(name: .long, help: "Also report this app's background delivery profile: support level, toolkit, and tier order. Takes a running app (name or pid) or an installed one (name, bundle ID, or path). Sends no input.")
    var app: String?

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (format, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (format, compact, "doctor")
            var report = try DoctorService().collect()
            if let app {
                report.appProfile = try AsyncBridge.run {
                    try await CommandRuntime.engine.appProfile(identifier: app)
                }
            }

            if format == .json {
                try CommandRuntime.emitJSON(command: "doctor", result: report, compact: compact)
                return
            }

            print("Doctor report")
            print("")
            print("Permissions:")
            print("\(trafficLight(report.permissions.screenRecordingGranted)) Screen Recording: \(report.permissions.screenRecordingGranted ? "granted" : "denied")")
            print("\(trafficLight(report.permissions.accessibilityGranted)) Accessibility: \(report.permissions.accessibilityGranted ? "granted" : "denied")")

            if !report.permissions.screenRecordingGranted {
                print("  Fix: System Settings > Privacy & Security > Screen Recording")
                print("  Deeplink: x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
            }

            if !report.permissions.accessibilityGranted {
                print("  Fix: System Settings > Privacy & Security > Accessibility")
                print("  Deeplink: x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }

            print("")
            print("Displays:")
            if report.displays.isEmpty {
                print("⚠️ No active displays found.")
            } else {
                for display in report.displays {
                    let marker = display.isMain ? "main" : "secondary"
                    let b = display.boundsPoints
                    print("- \(marker) id=\(display.displayID) bounds=(x:\(b.x), y:\(b.y), w:\(b.w), h:\(b.h))")
                }
            }

            print("")
            print("Background delivery (private APIs):")
            for symbol in report.privateAPIs {
                print("\(trafficLight(symbol.available)) \(symbol.name): \(symbol.available ? "available" : "missing") (\(symbol.usedBy))")
            }

            if let presence = report.presence {
                print("")
                print("Presence (agent cursor):")
                if presence.running, let pid = presence.serverPID {
                    print("🟢 Running: pid \(pid)")
                    let tap = presence.tapAvailable ?? false
                    print("\(trafficLight(tap)) User-input tap: \(tap ? "available" : "unavailable (yield and the abort key are off)")")
                    let aborted = presence.aborted ?? false
                    print("\(trafficLight(!aborted)) Aborted: \(aborted ? "yes (run 'screencommander resume')" : "no")")
                    switch presence.keepAwake {
                    case .some(true):
                        print("🟢 Keep awake: holding a display-awake assertion while sessions are active")
                    case .some(false):
                        print("⚪️ Keep awake: not held (no active session)")
                    case .none:
                        print("⚪️ Keep awake: off in the presence process (SCREENCOMMANDER_KEEP_AWAKE=0)")
                    }
                    let sessions = presence.sessions ?? []
                    if sessions.isEmpty {
                        print("- No sessions")
                    }
                    for session in sessions {
                        let pids = session.pids.map(String.init).joined(separator: ",")
                        print("- session \(session.id): pids [\(pids)], state \(session.state.rawValue)\(session.userActive ? ", user active" : "")")
                    }
                } else if !presence.enabled {
                    print("⚪️ Disabled (SCREENCOMMANDER_PRESENCE=0)")
                } else if let startError = presence.startError {
                    print("🔴 Not running: \(startError)")
                    print("- Socket: \(presence.socketPath)")
                } else {
                    print("⚪️ Not running (starts on the next background action)")
                }
                if !presence.keepAwakeEnabled {
                    print("⚪️ Keep awake: off (SCREENCOMMANDER_KEEP_AWAKE=0)")
                }
            }

            if let appProfile = report.appProfile {
                printAppProfile(appProfile)
            }
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }

    private func printAppProfile(_ report: AppProfileReport) {
        let profile = report.profile
        print("")
        print("App profile: \(report.name)\(report.bundleID.map { " (\($0))" } ?? "")")
        let light: String
        switch profile.support {
        case .supported: light = "🟢"
        case .degraded: light = "🟡"
        case .unsupported: light = "🔴"
        }
        var toolkit = profile.toolkit.rawValue
        if let engine = profile.engine {
            toolkit += " (\(engine))"
        }
        print("\(light) Background delivery: \(profile.support.rawValue)")
        print("- Toolkit: \(toolkit)")
        if let version = profile.version {
            print("- Version: \(version)")
        }
        print("- Running: \(report.running ? "yes\(report.pid.map { " (pid \($0))" } ?? "")" : "no")")
        print("- Mouse tiers: \(profile.mouseTiers.map(\.rawValue).joined(separator: " → "))")
        print("- Keyboard tiers: \(profile.keyboardTiers.map(\.rawValue).joined(separator: " → "))\(profile.authenticatedKeyboard ? " (authenticated keyboard)" : "")")
        print("- Why: \(profile.reason)")
        if !profile.evidence.isEmpty {
            print("- Evidence: \(profile.evidence.joined(separator: "; "))")
        }
        if let path = report.path {
            print("- Path: \(path)")
        }
    }

    private func trafficLight(_ granted: Bool) -> String {
        granted ? "🟢" : "🔴"
    }
}
