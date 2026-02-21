import ArgumentParser
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report permission and display health with traffic-light status."
    )

    @Flag(name: .long, help: "Emit machine-readable JSON output.")
    var json: Bool = false

    mutating func run() throws {
        do {
            let report = try DoctorService().collect()

            if json {
                try CommandRuntime.emitJSON(command: "doctor", result: report)
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
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }

    private func trafficLight(_ granted: Bool) -> String {
        granted ? "🟢" : "🔴"
    }
}
