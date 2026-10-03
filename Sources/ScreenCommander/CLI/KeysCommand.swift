import ArgumentParser
import Foundation

struct KeysCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Press, hold, and release keys in order, in the background by default.",
        discussion: """
            Steps run in order as key events to one app (tier window or focusAssisted), without \
            activating it or moving your cursor. Steps that hold Command need an on-screen window, \
            which is made key without raising it (tier focusAssisted). With --foreground, the steps \
            go through tier global. System keys and the spotlight and missioncontrol shortcuts need \
            --foreground, as with key.

            Example:
              screencommander keys --app TextEdit down:shift press:right up:shift
            """
    )

    @Argument(help: "Steps as <action>:<key>. down:<key> holds a key, up:<key> releases it, press:<chord> presses a chord, and sleep:<ms> waits.")
    var steps: [String]

    @Option(name: .long, help: ArgumentHelp(HelpText.appKeyboard))
    var app: String?

    @Option(name: .customLong("window-id"), help: ArgumentHelp(HelpText.windowID))
    var windowId: UInt32?

    @Flag(name: .long, help: ArgumentHelp(HelpText.foreground))
    var foreground: Bool = false

    @OptionGroup var presence: AgentPresenceOptions

    @Flag(name: .long, inversion: .prefixedNo, help: ArgumentHelp(HelpText.postshot))
    var postshot: Bool = true

    @Flag(name: .long, help: ArgumentHelp(HelpText.noDiff))
    var noDiff: Bool = false

    @Option(name: .customLong("diff-grid"), help: ArgumentHelp(HelpText.diffGrid))
    var diffGrid: Int?

    @Option(name: .customLong("diff-threshold"), help: ArgumentHelp(HelpText.diffThreshold))
    var diffThreshold: Double?

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (format, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (format, compact, "keys")
            let diffConfig = try FrameDiffConfig.validated(grid: diffGrid, threshold: diffThreshold)
            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let request = KeysRequest(
                steps: steps,
                appIdentifier: app,
                windowID: windowId,
                foreground: foreground,
                session: presence.session,
                agentCursor: presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.keys(request)
            }
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff, config: diffConfig)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "keys",
                    result: ActionResultEnvelope(
                        action: result,
                        preshot: preshotResult?.result,
                        postshot: postshotResult?.result,
                        diff: diff,
                        preshotError: CommandRuntime.shotFailure("Preshot"),
                        postshotError: CommandRuntime.shotFailure("Postshot")
                    ),
                    compact: compact
                )
                return
            }

            print("Executed sequence steps via \(result.deliveryMethod.rawValue):")
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
            CommandRuntime.printFocus(result.focus)
            CommandRuntime.printFrameDiff(diff)
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
