import ArgumentParser
import Foundation

struct FocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Bring an app to the foreground."
    )

    @Option(name: .long, help: "App to focus (name or PID). Required.")
    var app: String

    @Flag(name: .long, help: "Emit machine-readable JSON output.")
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (outputFormat, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (outputFormat, compact, "focus")
            let request = FocusRequest(appIdentifier: app)
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.focus(request)
            }

            if outputFormat == .json {
                try CommandRuntime.emitJSON(command: "focus", result: result, compact: compact)
                return
            }

            let priorName = result.priorApp?.name ?? "(none)"
            print("Focused \(result.app.name) (was: \(priorName))")
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
