import ArgumentParser
import Foundation

struct ClickCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Map screenshot coordinates to global space and post mouse events."
    )

    @Argument(help: "X coordinate in selected coordinate space (omit when using --element/--element-id).")
    var x: String?

    @Argument(help: "Y coordinate in selected coordinate space (omit when using --element/--element-id).")
    var y: String?

    @Option(name: .long, help: "Coordinate input space.")
    var space: CoordinateSpace = .pixels

    @Option(name: .long, help: "Metadata JSON path. Defaults to managed state last-screenshot.json path.")
    var meta: String?

    @Option(name: .long, help: "Click an element by title/label substring instead of coordinates (resolved fresh at click time).")
    var element: String?

    @Option(name: .customLong("element-id"), help: "Click an element by its id from 'elements' (dot-joined child-index path, e.g. 0.3.2).")
    var elementId: String?

    @Option(name: .long, help: "Role filter to disambiguate --element matches (e.g. button or AXButton).")
    var role: String?

    @Option(name: .long, help: "App owning the target element (name or pid). Defaults to the frontmost app.")
    var app: String?

    @Option(name: .long, help: "Force one delivery tier: ax, pid, or global (no fallback; --strict implied).")
    var via: InputDeliveryMethod?

    @Flag(name: .customLong("no-cursor"), help: "Never fall back to global delivery — the real cursor stays put (element clicks use ax then pid).")
    var noCursor: Bool = false

    @Flag(name: .long, help: "Treat delivery-tier downgrades as errors (element_not_actionable) instead of recording them.")
    var strict: Bool = false

    @Flag(name: .customLong("verify-target"), help: "Hit-test the mapped point via accessibility before clicking and include the element in the result (coordinate clicks only).")
    var verifyTarget: Bool = false

    @Option(name: .long, help: "Mouse button.")
    var button: MouseButtonChoice = .left

    @Flag(name: .long, help: "Send a double-click sequence.")
    var double: Bool = false

    @Flag(name: .long, help: "Send a triple-click sequence.")
    var triple: Bool = false

    @Option(name: .long, help: "Comma-separated modifiers: cmd,shift,option,ctrl.")
    var modifiers: String?

    @Flag(name: .long, help: "Send an extra priming mouse-move first (useful when first action only positions cursor).")
    var prime: Bool = false

    @Flag(name: .long, help: "Use raw click events without human-like cursor priming or target-app activation.")
    var raw: Bool = false

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

            let request = ClickRequest(
                x: parsedX,
                y: parsedY,
                coordinateSpace: space,
                metadataPath: meta,
                button: button,
                doubleClick: double,
                triple: triple,
                primeClick: prime,
                humanLike: !raw,
                modifiers: parsedModifiers,
                element: element,
                elementID: elementId,
                role: role,
                appIdentifier: app,
                via: via,
                noCursor: noCursor,
                strict: strict,
                verifyTarget: verifyTarget
            )

            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.click(request)
            }
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "click",
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
            if !result.modifiers.isEmpty {
                print("Modifiers: \(result.modifiers.joined(separator: ","))")
            }
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
