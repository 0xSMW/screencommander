import ArgumentParser
import Foundation

struct ClickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Click at screenshot coordinates or on an element, in the background by default.",
        discussion: """
            Background delivery tries tiers in order and reports the one that worked as \
            deliveryMethod. An element target with a plain left or right click is pressed through \
            accessibility (tier ax). Otherwise mouse events go to the target window (tier window), or \
            to the window made key without raising it (tier focusAssisted), in the order the app's \
            profile gives ('doctor --app'). None of these activate the app or move your cursor. With \
            --foreground, coordinate clicks go straight to tier global, and element clicks try the \
            background tiers first.

            Examples:
              screencommander click 412 230
              screencommander click --app TextEdit --element-id 0.3.2
              screencommander click --app Calculator --element 7
            """
    )

    @Argument(help: "X coordinate in --space units. Omit with --element or --element-id.")
    var x: String?

    @Argument(help: "Y coordinate in --space units. Omit with --element or --element-id.")
    var y: String?

    @Option(name: .long, help: "Mouse button: left, right, or middle.")
    var button: MouseButtonChoice = .left

    @Flag(name: .long, help: "Double-click.")
    var double: Bool = false

    @Flag(name: .long, help: "Triple-click.")
    var triple: Bool = false

    @Option(name: .long, help: "Modifier keys to hold during the click, comma-separated: cmd, shift, option, ctrl.")
    var modifiers: String?

    @Flag(name: .long, help: "Skip the pointer move and short pause sent before the click. With --foreground, also skip activating the target app.")
    var raw: Bool = false

    /// Removed in 0.6.0. Still accepted, hidden, and has no effect, so scripts that
    /// pass it keep working.
    @Flag(name: .long, help: .hidden)
    var prime: Bool = false

    @Flag(name: .customLong("verify-target"), help: "Before a coordinate click, read the accessibility element at the point and report it as verifiedTarget. The click happens either way.")
    var verifyTarget: Bool = false

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

    @Option(name: .long, help: "Use only this delivery tier, with no fallback. ax needs --element or --element-id. global needs --foreground.")
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
            OutputOptions.current = (format, compact, "click")
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
            if double && triple {
                throw ScreenCommanderError.invalidArguments("--double and --triple are mutually exclusive.")
            }
            let parsedModifiers = try MouseModifiers.parse(modifiers)
            let diffConfig = try FrameDiffConfig.validated(grid: diffGrid, threshold: diffThreshold)

            let request = ClickRequest(
                x: parsedX,
                y: parsedY,
                coordinateSpace: space,
                metadataPath: meta,
                button: button,
                doubleClick: double,
                triple: triple,
                primeClick: false,
                humanLike: !raw,
                modifiers: parsedModifiers,
                element: element,
                elementID: elementId,
                role: role,
                appIdentifier: app,
                via: via,
                noCursor: noCursor,
                strict: strict,
                verifyTarget: verifyTarget,
                strictMetadata: strictMetadata,
                windowID: windowId,
                foreground: foreground,
                session: presence.session,
                agentCursor: presence.agentCursor
            )

            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.click(request)
            }
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff, config: diffConfig)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "click",
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

            let clickKind = triple ? "triple-clicked" : (double ? "double-clicked" : "clicked")
            if let resolved = result.resolved {
                print("\(clickKind.capitalized) \(button.rawValue) at global point (\(resolved.globalX), \(resolved.globalY)) via \(result.deliveryMethod.rawValue).")
            } else {
                print("\(clickKind.capitalized) \(button.rawValue) via \(result.deliveryMethod.rawValue).")
            }
            if let record = result.element {
                let label = record.title ?? record.description ?? record.value ?? ""
                print("Element: \(record.role)\(label.isEmpty ? "" : " \"\(label)\"") (id \(record.id))")
            }
            if let hit = result.verifiedTarget {
                let label = hit.title ?? hit.description ?? hit.value ?? ""
                print("Target at point: \(hit.role)\(label.isEmpty ? "" : " \"\(label)\"")")
            }
            if let freshness = result.metadataFreshness {
                print("Metadata freshness: \(freshness.status.rawValue) (\(freshness.reason))")
            }
            if !result.modifiers.isEmpty {
                print("Modifiers: \(result.modifiers.joined(separator: ","))")
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
