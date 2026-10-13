import ArgumentParser
import Foundation

struct MoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Hover at screenshot coordinates, in the background by default.",
        discussion: """
            Sends a pointer move to the window under the point (tier window or focusAssisted, in the \
            order the app's profile gives), without activating the app or moving your cursor. With \
            --foreground it goes through tier global and moves the real cursor.

            Example:
              screencommander move 412 230 --dwell-ms 800
            """
    )

    @Argument(help: "X coordinate in --space units.")
    var x: String

    @Argument(help: "Y coordinate in --space units.")
    var y: String

    @Option(name: .long, help: "Wait this many milliseconds after the move, 0 to 60000, so hover effects can appear.")
    var dwellMS: Int = 0

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
            OutputOptions.current = (format, compact, "move")
            guard let parsedX = Double(x), parsedX.isFinite,
                  let parsedY = Double(y), parsedY.isFinite else {
                throw ScreenCommanderError.invalidArguments("x and y must be numeric values.")
            }
            let diffConfig = try FrameDiffConfig.validated(grid: diffGrid, threshold: diffThreshold)

            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let request = MoveRequest(
                x: parsedX,
                y: parsedY,
                coordinateSpace: space,
                metadataPath: meta,
                dwellMS: dwellMS,
                strictMetadata: strictMetadata,
                appIdentifier: app,
                windowID: windowId,
                foreground: foreground,
                session: presence.session,
                agentCursor: presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.move(request)
            }
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff, config: diffConfig)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "move",
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

            print("Moved to global point (\(result.resolved.globalX), \(result.resolved.globalY)) via \(result.deliveryMethod.rawValue).")
            print("Dwell: \(result.dwellMilliseconds) ms")
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
