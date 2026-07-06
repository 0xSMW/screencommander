import ArgumentParser
import Foundation

struct KeysCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Execute held keyboard sequence steps such as down/up/press and sleep."
    )

    @Argument(help: "Sequence steps in <action>:<token> format (down/up/press/sleep).")
    var steps: [String]

    @Flag(name: .long, help: "Capture before/after screenshots around the action (enabled by default).")
    var postshot: Bool = true

    @Flag(name: .long, help: "Skip frame diff comparison between pre- and post-action screenshots.")
    var noDiff: Bool = false

    @Flag(name: .long, help: "Emit a single machine-readable JSON object to stdout (success or error envelope). For scripting; see README.")
    var json: Bool = false

    mutating func run() throws {
        let (format, compact) = OutputOptions.effective(jsonFlag: json)
        OutputOptions.current = (format, compact, "keys")
        defer { OutputOptions.current = nil }
        do {
            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try CommandRuntime.engine.keys(KeysRequest(steps: steps))
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "keys",
                    result: ActionResultEnvelope(
                        action: result,
                        preshot: preshotResult?.result,
                        postshot: postshotResult?.result,
                        diff: diff
                    ),
                    compact: compact
                )
                return
            }

            print("Executed sequence steps:")
            for step in result.normalizedSteps {
                print("- \(step)")
            }

            if let preshotResult {
                print("Preshot image: \(preshotResult.result.imagePath)")
                print("Preshot metadata: \(preshotResult.result.metadataPath)")
            }
            if let postshotResult {
                print("Postshot image: \(postshotResult.result.imagePath)")
                print("Postshot metadata: \(postshotResult.result.metadataPath)")
            }
            CommandRuntime.printFrameDiff(diff)
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
