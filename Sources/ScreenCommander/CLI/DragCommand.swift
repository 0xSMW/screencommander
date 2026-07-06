import ArgumentParser
import Foundation

struct DragCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "drag",
        abstract: "Map two screenshot coordinates and post a mouse drag."
    )

    @Argument(help: "Start X coordinate in selected coordinate space.")
    var x1: String

    @Argument(help: "Start Y coordinate in selected coordinate space.")
    var y1: String

    @Argument(help: "End X coordinate in selected coordinate space.")
    var x2: String

    @Argument(help: "End Y coordinate in selected coordinate space.")
    var y2: String

    @Option(name: .long, help: "Mouse button.")
    var button: MouseButtonChoice = .left

    @Option(name: .long, help: "Interpolated drag event count.")
    var steps: Int = 12

    @Option(name: .long, help: "Drag duration in milliseconds.")
    var durationMS: Int = 300

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

            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try CommandRuntime.engine.drag(
                DragRequest(
                    x1: parsedX1,
                    y1: parsedY1,
                    x2: parsedX2,
                    y2: parsedY2,
                    coordinateSpace: space,
                    metadataPath: meta,
                    button: button,
                    steps: steps,
                    durationMS: durationMS
                )
            )
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "drag",
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

            print("Dragged \(result.button.rawValue) from (\(result.from.globalX), \(result.from.globalY)) to (\(result.to.globalX), \(result.to.globalY)).")
            print("Steps: \(result.steps)")
            print("Duration: \(result.durationMilliseconds) ms")
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
