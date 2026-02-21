import ArgumentParser
import Foundation

struct KeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Inject a key chord such as cmd+shift+4 or enter."
    )

    @Argument(help: "Chord in <modifier+key> format.")
    var chord: String

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Capture before/after screenshots around the action (enabled by default)."
    )
    var postshot: Bool = true

    @Flag(name: .long, help: "Emit machine-readable JSON output.")
    var json: Bool = false

    mutating func run() throws {
        do {
            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try CommandRuntime.engine.key(KeyRequest(chord: chord))
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil

            if json {
                try CommandRuntime.emitJSON(
                    command: "key",
                    result: ActionResultEnvelope(action: result, preshot: preshotResult, postshot: postshotResult)
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
