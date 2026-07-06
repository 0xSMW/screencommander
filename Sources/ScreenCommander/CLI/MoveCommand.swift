import ArgumentParser
import Foundation

struct MoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Map screenshot coordinates and move the mouse cursor."
    )

    @Argument(help: "X coordinate in selected coordinate space.")
    var x: String

    @Argument(help: "Y coordinate in selected coordinate space.")
    var y: String

    @Option(name: .long, help: "Dwell after moving, in milliseconds.")
    var dwellMS: Int = 0

    @Option(name: .long, help: "Coordinate input space.")
    var space: CoordinateSpace = .pixels

    @Option(name: .long, help: "Metadata JSON path. Defaults to managed state last-screenshot.json path.")
    var meta: String?

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
        do {
            let (format, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (format, compact, "move")
            defer { OutputOptions.current = nil }
            guard let parsedX = Double(x), parsedX.isFinite,
                  let parsedY = Double(y), parsedY.isFinite else {
                throw ScreenCommanderError.invalidArguments("x and y must be numeric values.")
            }

            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try CommandRuntime.engine.move(
                MoveRequest(
                    x: parsedX,
                    y: parsedY,
                    coordinateSpace: space,
                    metadataPath: meta,
                    dwellMS: dwellMS
                )
            )
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "move",
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

            print("Moved to global point (\(result.resolved.globalX), \(result.resolved.globalY)).")
            print("Dwell: \(result.dwellMilliseconds) ms")
            print("Metadata: \(result.metadataPath)")
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
