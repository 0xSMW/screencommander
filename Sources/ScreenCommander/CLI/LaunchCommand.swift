import ArgumentParser
import Foundation

struct LaunchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Launch an app without activating it, and wait until it is running.",
        discussion: """
            If the app takes focus while it starts, the focus guard puts the previous app back, and \
            the focus receipt reports what happened. An app that is already running is reported, \
            not launched again. Nothing is launched while the abort key is in force.

            Example:
              screencommander launch --app TextEdit
            """
    )

    @Option(name: .long, help: "App to launch: name, bundle ID, or path to an .app bundle.")
    var app: String

    @Option(name: .customLong("timeout-ms"), help: "How long to wait for the app to finish launching, 1 to 120000 milliseconds.")
    var timeoutMs: Int = 10_000

    @Option(name: .long, help: "Agent session whose focus guard covers the launch. (default: $SCREENCOMMANDER_SESSION, else 'default')")
    var session: String?

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (outputFormat, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (outputFormat, compact, "launch")
            let request = LaunchRequest(appIdentifier: app, timeoutMS: timeoutMs, session: session)
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.launch(request)
            }

            if outputFormat == .json {
                try CommandRuntime.emitJSON(command: "launch", result: result, compact: compact)
                return
            }

            if result.alreadyRunning {
                print("\(result.app.name) is already running (pid \(result.app.pid)).")
            } else {
                print("Launched \(result.app.name) (pid \(result.app.pid))\(result.ready ? "" : "; still starting after the timeout").")
            }
            print("Path: \(result.path)")
            CommandRuntime.printFocus(result.focus)
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
