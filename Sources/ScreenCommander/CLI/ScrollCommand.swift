import ArgumentParser
import Foundation

struct ScrollCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "Scroll at screenshot coordinates or over an element, in the background by default.",
        discussion: """
            Wheel events go to the target window (tier window), or to the window made key without \
            raising it (tier focusAssisted), in the order the app's profile gives ('doctor --app'). \
            --direction scrolls an element by pages, first through its page actions or scroll bar \
            in accessibility (tier ax). None of these activate the app or move your cursor. With --foreground, coordinate scrolls go straight to tier global, and element \
            scrolls try the background tiers first.

            Examples:
              screencommander scroll 600 400 --dy -5
              screencommander scroll --app Safari --element-id 0.3.2 --direction down
            """
    )

    @Argument(help: "X coordinate in --space units. Omit with --element or --element-id.")
    var x: String?

    @Argument(help: "Y coordinate in --space units. Omit with --element or --element-id.")
    var y: String?

    // `.unconditional` so a negative delta such as `--dy -5` is read as the value.
    @Option(name: .long, parsing: .unconditional, help: "Vertical amount in --unit. Positive scrolls up, negative scrolls down.")
    var dy: Int32 = 0

    // `.unconditional` so a negative delta such as `--dx -5` is read as the value.
    @Option(name: .long, parsing: .unconditional, help: "Horizontal amount in --unit. Positive scrolls left, negative scrolls right.")
    var dx: Int32 = 0

    @Option(name: .long, help: "Unit of --dx and --dy: lines or pixels.")
    var unit: ScrollUnit = .lines

    @Option(name: .long, help: "Scroll an element by pages in this direction, instead of --dx and --dy. Needs --element or --element-id.")
    var direction: ScrollDirection?

    @Option(name: .long, help: "Pages to scroll with --direction, 1 to 50.")
    var pages: Int = 1

    @Option(name: .long, help: ArgumentHelp(HelpText.space))
    var space: CoordinateSpace = .pixels

    @Option(name: .long, help: ArgumentHelp(HelpText.meta))
    var meta: String?

    @Flag(name: .customLong("strict-metadata"), help: ArgumentHelp(HelpText.strictMetadata))
    var strictMetadata: Bool = false

    @Option(name: .long, help: ArgumentHelp(HelpText.element))
    var element: String?

    @Option(name: .customLong("element-id"), help: ArgumentHelp(HelpText.elementID))
    var elementId: String?

    @Option(name: .long, help: ArgumentHelp(HelpText.role))
    var role: String?

    @Option(name: .long, help: ArgumentHelp(HelpText.appMixed))
    var app: String?

    @Option(name: .customLong("window-id"), help: ArgumentHelp(HelpText.windowID))
    var windowId: UInt32?

    @Flag(name: .long, help: ArgumentHelp(HelpText.foreground))
    var foreground: Bool = false

    @Option(name: .long, help: "Use only this delivery tier, with no fallback. ax needs --direction. global needs --foreground.")
    var via: InputDeliveryMethod?

    @Flag(name: .long, help: ArgumentHelp(HelpText.strict))
    var strict: Bool = false

    @Flag(name: .customLong("no-cursor"), help: .hidden)
    var noCursor: Bool = false

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
            OutputOptions.current = (format, compact, "scroll")
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
            let diffConfig = try FrameDiffConfig.validated(grid: diffGrid, threshold: diffThreshold)

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
                strict: strict,
                strictMetadata: strictMetadata,
                windowID: windowId,
                foreground: foreground,
                session: presence.session,
                agentCursor: presence.agentCursor,
                direction: direction,
                pages: pages
            )

            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.scroll(request)
            }
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff, config: diffConfig)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "scroll",
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

            if let resolved = result.resolved {
                print("Scrolled at global point (\(resolved.globalX), \(resolved.globalY)) via \(result.deliveryMethod.rawValue).")
            } else {
                print("Scrolled via \(result.deliveryMethod.rawValue).")
            }
            if let record = result.element {
                let label = record.title ?? record.description ?? record.value ?? ""
                print("Element: \(record.role)\(label.isEmpty ? "" : " \"\(label)\"") (id \(record.id))")
            }
            if let freshness = result.metadataFreshness {
                print("Metadata freshness: \(freshness.status.rawValue) (\(freshness.reason))")
            }
            if let direction = result.direction {
                print("Scrolled \(result.pages ?? 1) page(s) \(direction.rawValue)\(result.axMethod.map { " with \($0)" } ?? "").")
            } else {
                print("Delta: dx=\(result.dx), dy=\(result.dy) \(result.unit.rawValue)")
            }
            if let metadataPath = result.metadataPath {
                print("Metadata: \(metadataPath)")
            }
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
