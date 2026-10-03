import ArgumentParser
import Foundation

struct DragCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drag",
        abstract: "Drag between two screenshot coordinates, in the background by default.",
        discussion: """
            The drag goes to the window under the start point (tier window or focusAssisted, in the \
            order the app's profile gives), without activating the app or moving your cursor. With \
            --foreground it goes through tier global.

            Example:
              screencommander drag 200 300 600 300
            """
    )

    @Argument(help: "Start X coordinate in --space units.")
    var x1: String

    @Argument(help: "Start Y coordinate in --space units.")
    var y1: String

    @Argument(help: "End X coordinate in --space units.")
    var x2: String

    @Argument(help: "End Y coordinate in --space units.")
    var y2: String

    @Option(name: .long, help: "Mouse button: left, right, or middle.")
    var button: MouseButtonChoice = .left

    @Option(name: .long, help: "Number of intermediate drag events, 1 to 10000.")
    var steps: Int = 12

    @Option(name: .long, help: "Total drag time in milliseconds, 0 to 60000.")
    var durationMS: Int = 300

    @Option(name: .long, help: ArgumentHelp(HelpText.space))
    var space: CoordinateSpace = .pixels

    @Option(name: .long, help: ArgumentHelp(HelpText.meta))
    var meta: String?

    @Flag(name: .customLong("strict-metadata"), help: ArgumentHelp(HelpText.strictMetadata))
    var strictMetadata: Bool = false

    @Option(name: .long, help: ArgumentHelp(HelpText.appPointer))
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
            OutputOptions.current = (format, compact, "drag")
            guard let parsedX1 = Double(x1), parsedX1.isFinite,
                  let parsedY1 = Double(y1), parsedY1.isFinite,
                  let parsedX2 = Double(x2), parsedX2.isFinite,
                  let parsedY2 = Double(y2), parsedY2.isFinite else {
                throw ScreenCommanderError.invalidArguments("x1, y1, x2, and y2 must be numeric values.")
            }
            let diffConfig = try FrameDiffConfig.validated(grid: diffGrid, threshold: diffThreshold)

            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let request = DragRequest(
                x1: parsedX1,
                y1: parsedY1,
                x2: parsedX2,
                y2: parsedY2,
                coordinateSpace: space,
                metadataPath: meta,
                button: button,
                steps: steps,
                durationMS: durationMS,
                strictMetadata: strictMetadata,
                appIdentifier: app,
                windowID: windowId,
                foreground: foreground,
                session: presence.session,
                agentCursor: presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.drag(request)
            }
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff, config: diffConfig)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "drag",
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

            print("Dragged \(result.button.rawValue) from (\(result.from.globalX), \(result.from.globalY)) to (\(result.to.globalX), \(result.to.globalY)).")
            print("Delivery: \(result.deliveryMethod.rawValue)")
            print("Steps: \(result.steps)")
            print("Duration: \(result.durationMilliseconds) ms")
            if let freshness = result.metadataFreshness {
                print("Metadata freshness: \(freshness.status.rawValue) (\(freshness.reason))")
            }
            print("Metadata: \(result.metadataPath)")
            CommandRuntime.printFocus(result.focus)
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
