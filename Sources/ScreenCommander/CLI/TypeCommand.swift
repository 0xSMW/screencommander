import ArgumentParser
import Foundation

extension TextInputMode: ExpressibleByArgument {}

struct TypeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Inject text globally (paste mode by default, Unicode key events optional)."
    )

    @Argument(help: "Text to type globally.")
    var text: String

    @Option(name: .long, parsing: .unconditional, help: "Optional delay in milliseconds between characters.")
    var delayMS: String?

    @Option(name: .long, help: "Text input mode: paste (clipboard + cmd+v) or unicode (per-character key events).")
    var mode: TextInputMode = .paste

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Capture before/after screenshots around the action (enabled by default)."
    )
    var postshot: Bool = true

    @Flag(name: .long, help: "Skip frame diff comparison between pre- and post-action screenshots.")
    var noDiff: Bool = false

    @Flag(name: .long, help: "Emit a single machine-readable JSON object to stdout (success or error envelope). For scripting; see README.")
    var json: Bool = false

    mutating func run() throws {
        let (format, compact) = OutputOptions.effective(jsonFlag: json)
        OutputOptions.current = (format, compact, "type")
        defer { OutputOptions.current = nil }
        do {
            let parsedDelay: Int?
            if let delayMS {
                guard let delay = Int(delayMS) else {
                    throw ScreenCommanderError.invalidArguments("--delay-ms must be an integer.")
                }
                parsedDelay = delay
            } else {
                parsedDelay = nil
            }

            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try CommandRuntime.engine.type(
                TypeRequest(text: text, delayMilliseconds: parsedDelay, inputMode: mode)
            )
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "type",
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

            print("Typed \(result.textLength) characters.")
            if let delay = result.delayMilliseconds {
                print("Delay: \(delay) ms")
            }
            print("Mode: \(result.inputMode.rawValue)")
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
