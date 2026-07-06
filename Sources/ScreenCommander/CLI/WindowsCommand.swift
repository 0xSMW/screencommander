import ArgumentParser
import Foundation

struct WindowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List visible windows, optionally filtered by app."
    )

    @Option(name: .long, help: "Filter to windows belonging to this app (name or PID).")
    var app: String?

    @Flag(name: .long, help: "Emit machine-readable JSON output.")
    var json: Bool = false

    mutating func run() throws {
        let (outputFormat, compact) = OutputOptions.effective(jsonFlag: json)
        OutputOptions.current = (outputFormat, compact, "windows")
        defer { OutputOptions.current = nil }

        do {
            let request = WindowsRequest(appIdentifier: app)
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.windows(request)
            }

            if outputFormat == .json {
                try CommandRuntime.emitJSON(command: "windows", result: result, compact: compact)
                return
            }

            if result.windows.isEmpty {
                print("No windows found.")
                return
            }
            for w in result.windows {
                print("[\(w.windowID)] \(w.appName): \"\(w.title)\" (\(Int(w.boundsPoints.w))x\(Int(w.boundsPoints.h)) at \(Int(w.boundsPoints.x)),\(Int(w.boundsPoints.y)), layer=\(w.layer))")
            }
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
