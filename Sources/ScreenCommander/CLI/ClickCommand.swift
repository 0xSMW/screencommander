import ArgumentParser
import Foundation

struct ClickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Map screenshot coordinates to global space and post mouse events."
    )

    @Argument(help: "X coordinate in selected coordinate space.")
    var x: String

    @Argument(help: "Y coordinate in selected coordinate space.")
    var y: String

    @Option(name: .long, help: "Coordinate input space.")
    var space: CoordinateSpace = .pixels

    @Option(name: .long, help: "Metadata JSON path. Defaults to managed state last-screenshot.json path.")
    var meta: String?

    @Option(name: .long, help: "Mouse button.")
    var button: MouseButtonChoice = .left

    @Flag(name: .long, help: "Send a double-click sequence.")
    var double: Bool = false

    @Flag(name: .long, help: "Send an extra priming mouse-move first (useful when first action only positions cursor).")
    var prime: Bool = false

    @Flag(name: .long, help: "Use raw click events without human-like focus compensation.")
    var raw: Bool = false

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
            guard let parsedX = Double(x), parsedX.isFinite,
                  let parsedY = Double(y), parsedY.isFinite else {
                throw ScreenCommanderError.invalidArguments("x and y must be numeric values.")
            }

            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try CommandRuntime.engine.click(
                ClickRequest(
                    x: parsedX,
                    y: parsedY,
                    coordinateSpace: space,
                    metadataPath: meta,
                    button: button,
                    doubleClick: double,
                    primeClick: prime,
                    humanLike: !raw
                )
            )
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil

            if json {
                try CommandRuntime.emitJSON(
                    command: "click",
                    result: ActionResultEnvelope(action: result, preshot: preshotResult, postshot: postshotResult)
                )
                return
            }

            print("Clicked \(button.rawValue) at global point (\(result.resolved.globalX), \(result.resolved.globalY)).")
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
