import ArgumentParser
import Foundation

struct ScrollCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "Map screenshot coordinates and post a scroll wheel event."
    )

    @Argument(help: "X coordinate in selected coordinate space.")
    var x: String

    @Argument(help: "Y coordinate in selected coordinate space.")
    var y: String

    @Option(name: .long, help: "Vertical scroll delta.")
    var dy: Int32

    @Option(name: .long, help: "Horizontal scroll delta.")
    var dx: Int32 = 0

    @Option(name: .long, help: "Scroll unit: lines (default) or pixels.")
    var unit: ScrollUnit = .lines

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

    @Flag(name: .long, help: "Emit a single machine-readable JSON object to stdout (success or error envelope). For scripting; see README.")
    var json: Bool = false

    mutating func run() throws {
        let (format, compact) = OutputOptions.effective(jsonFlag: json)
        OutputOptions.current = (format, compact, "scroll")
        defer { OutputOptions.current = nil }
        do {
            guard let parsedX = Double(x), parsedX.isFinite,
                  let parsedY = Double(y), parsedY.isFinite else {
                throw ScreenCommanderError.invalidArguments("x and y must be numeric values.")
            }

            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try CommandRuntime.engine.scroll(
                ScrollRequest(
                    x: parsedX,
                    y: parsedY,
                    coordinateSpace: space,
                    metadataPath: meta,
                    dx: dx,
                    dy: dy,
                    unit: unit
                )
            )
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "scroll",
                    result: ActionResultEnvelope(action: result, preshot: preshotResult, postshot: postshotResult),
                    compact: compact
                )
                return
            }

            print("Scrolled at global point (\(result.resolved.globalX), \(result.resolved.globalY)).")
            print("Delta: dx=\(result.dx), dy=\(result.dy) \(result.unit.rawValue)")
            print("Metadata: \(result.metadataPath)")
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
