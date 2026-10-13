import ArgumentParser
import Foundation

struct AppsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "List running apps and installed apps.",
        discussion: """
            Running apps show their pid, bundle ID, on-screen window count, and which one is \
            frontmost. Installed apps come from /Applications, /System/Applications, and \
            ~/Applications.

            Example:
              screencommander apps --running-only --filter safari
            """
    )

    @Option(name: .long, help: "Only list apps whose name or bundle ID contains this text, ignoring case.")
    var filter: String?

    @Flag(name: .customLong("running-only"), help: "Skip the installed-app scan.")
    var runningOnly: Bool = false

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (outputFormat, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (outputFormat, compact, "apps")
            let result = CommandRuntime.engine.apps(AppsRequest(includeInstalled: !runningOnly, filter: filter))

            if outputFormat == .json {
                try CommandRuntime.emitJSON(command: "apps", result: result, compact: compact)
                return
            }

            print("Running:")
            for app in result.running {
                var line = "- \(app.name) (pid \(app.pid)"
                if let bundleID = app.bundleID {
                    line += ", \(bundleID)"
                }
                line += ", \(app.windowCount) window\(app.windowCount == 1 ? "" : "s")"
                if app.activationPolicy != "regular" {
                    line += ", \(app.activationPolicy)"
                }
                line += ")"
                if app.frontmost {
                    line += " [frontmost]"
                }
                print(line)
            }
            if let installed = result.installed {
                print("")
                print("Installed\(result.installedTruncated == true ? " (truncated)" : ""):")
                for app in installed {
                    print("- \(app.name)\(app.bundleID.map { " (\($0))" } ?? "")\(app.running ? " [running]" : "") \(app.path)")
                }
            }
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
