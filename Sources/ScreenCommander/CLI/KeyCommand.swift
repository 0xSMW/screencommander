import ArgumentParser
import Foundation

struct KeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Inject a key chord or special key such as fn+f5, cmd+tab, or volumeup."
    )

    @Argument(help: "Chord in <modifier+key> format. Examples: cmd+shift+4, ctrl+up, fn+f5, volumeup, spotlight, raycast, missioncontrol, launchpad.")
    var chord: String

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Capture before/after screenshots around the action (enabled by default)."
    )
    var postshot: Bool = true

    @Flag(name: .long, help: "Emit a single machine-readable JSON object to stdout (success or error envelope). For scripting; see README.")
    var json: Bool = false

    mutating func run() throws {
        let (format, compact) = OutputOptions.effective(jsonFlag: json)
        OutputOptions.current = (format, compact, "key")
        defer { OutputOptions.current = nil }
        do {
            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try CommandRuntime.engine.key(KeyRequest(chord: chord))
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "key",
                    result: ActionResultEnvelope(action: result, preshot: preshotResult, postshot: postshotResult),
                    compact: compact
                )
                return
            }

            print("Pressed chord: \(result.normalizedChord)")
            if let preshotResult {
                print("Preshot image: \(preshotResult.imagePath)")
                print("Preshot metadata: \(preshotResult.metadataPath)")
            }
            if let postshotResult {
                print("Postshot image: \(postshotResult.imagePath)")
                print("Postshot metadata: \(postshotResult.metadataPath)")
            }
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
