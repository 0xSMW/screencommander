import ArgumentParser
import Foundation

struct ScrollCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "Map screenshot coordinates and post a scroll wheel event."
    )

    @Argument(help: "X coordinate in selected coordinate space (omit when using --element/--element-id).")
    var x: String?

    @Argument(help: "Y coordinate in selected coordinate space (omit when using --element/--element-id).")
    var y: String?

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

    @Option(name: .long, help: "Scroll at an element's center by title/label substring (resolved fresh; pid then global delivery).")
    var element: String?

    @Option(name: .customLong("element-id"), help: "Scroll at the element with this id from 'elements'.")
    var elementId: String?

    @Option(name: .long, help: "Role filter to disambiguate --element matches (e.g. table or AXScrollArea).")
    var role: String?

    @Option(name: .long, help: "App owning the target element / receiving pid-delivered events (name or pid).")
    var app: String?

    @Option(name: .long, help: "Force one delivery tier: pid or global (scroll has no ax tier).")
    var via: InputDeliveryMethod?

    @Flag(name: .customLong("no-cursor"), help: "Never fall back to global delivery — the real cursor stays put (pid tier only).")
    var noCursor: Bool = false

    @Flag(name: .long, help: "Treat delivery-tier downgrades as errors (element_not_actionable) instead of recording them.")
    var strict: Bool = false

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
        OutputOptions.current = (format, compact, "scroll")
        defer { OutputOptions.current = nil }
        do {
            let targetsElement = element != nil || elementId != nil
            var parsedX: Double?
            var parsedY: Double?
            if targetsElement {
                guard x == nil, y == nil else {
                    throw ScreenCommanderError.invalidArguments("Pass either coordinates or --element/--element-id, not both.")
                }
            } else {
                guard let x, let y,
                      let numericX = Double(x), numericX.isFinite,
                      let numericY = Double(y), numericY.isFinite else {
                    throw ScreenCommanderError.invalidArguments("x and y must be numeric values (or use --element/--element-id).")
                }
                parsedX = numericX
                parsedY = numericY
            }

            let request = ScrollRequest(
                x: parsedX,
                y: parsedY,
                coordinateSpace: space,
                metadataPath: meta,
                dx: dx,
                dy: dy,
                unit: unit,
                element: element,
                elementID: elementId,
                role: role,
                appIdentifier: app,
                via: via,
                noCursor: noCursor,
                strict: strict
            )

            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.scroll(request)
            }
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "scroll",
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

            if let resolved = result.resolved {
                print("Scrolled at global point (\(resolved.globalX), \(resolved.globalY)) via \(result.deliveryMethod.rawValue).")
            } else {
                print("Scrolled via \(result.deliveryMethod.rawValue).")
            }
            if let record = result.element {
                let label = record.title ?? record.description ?? record.value ?? ""
                print("Element: \(record.role)\(label.isEmpty ? "" : " \"\(label)\"") (id \(record.id))")
            }
            print("Delta: dx=\(result.dx), dy=\(result.dy) \(result.unit.rawValue)")
            if let metadataPath = result.metadataPath {
                print("Metadata: \(metadataPath)")
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
