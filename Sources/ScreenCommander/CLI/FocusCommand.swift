import ArgumentParser
import Foundation

struct FocusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Bring an app to the front.",
        discussion: """
            This activates the app on purpose and takes focus from the user. Input commands do not \
            need it, because they work in the background. It fails with aborted_by_user while the \
            abort key (Control-Option-Command-Period) is in force.

            Example:
              screencommander focus --app TextEdit
            """
    )

    @Option(name: .long, help: "App to activate: name or pid.")
    var app: String

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
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
