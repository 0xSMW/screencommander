import ArgumentParser
import Foundation

struct WindowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List on-screen windows with their IDs, apps, titles, and bounds.",
        discussion: """
            Window IDs work with --window-id on input commands, elements, and state, and with \
            screenshot --window.

            Example:
              screencommander windows --app Safari
            """
    )

    @Option(name: .long, help: "Only list windows of this app: name or pid.")
    var app: String?

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (outputFormat, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (outputFormat, compact, "windows")
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
