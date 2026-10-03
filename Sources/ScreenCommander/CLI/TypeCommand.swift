import ArgumentParser
import Foundation

extension TextInputMode: ExpressibleByArgument {}

struct TypeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into an app, in the background by default.",
        discussion: """
            Text goes in through accessibility first (tier ax), at the caret of the element target \
            or of the app's focused text field, and is read back to set verified. Otherwise it goes to \
            the app as Unicode key events through tier window or focusAssisted, in the order the app's \
            profile gives. Chromium and Electron apps get key events first. None of these activate \
            the app or move your cursor. With --foreground, key events go through tier global. The \
            clipboard is used only with --mode paste and --foreground.

            Examples:
              screencommander type --app TextEdit "Hello"
              screencommander type --app Safari --element-id 0.3.2 --replace "example.com"
            """
    )

    @Argument(help: "Text to type.")
    var text: String

    @Option(name: .long, help: "How key events enter the text: unicode (one key event per character) or paste (the clipboard and cmd+v, used only with --foreground).")
    var mode: TextInputMode = .unicode

    @Option(name: .long, parsing: .unconditional, help: "Delay between key events in milliseconds, 0 to 10000.")
    var delayMS: String?

    @Flag(name: .long, help: "Replace the field's whole value instead of inserting at the caret. Needs an element target or a focused text field.")
    var replace: Bool = false

    @Option(name: .long, help: ArgumentHelp(HelpText.element))
    var element: String?

    @Option(name: .customLong("element-id"), help: ArgumentHelp(HelpText.elementID))
    var elementId: String?

    @Option(name: .long, help: ArgumentHelp(HelpText.role))
    var role: String?

    @Option(name: .long, help: ArgumentHelp(HelpText.appKeyboardOrElement))
    var app: String?

    @Option(name: .customLong("window-id"), help: ArgumentHelp(HelpText.windowID))
    var windowId: UInt32?

    @Flag(name: .long, help: ArgumentHelp(HelpText.foreground))
    var foreground: Bool = false

    @Option(name: .long, help: "Use only this delivery tier, with no fallback. ax needs an element target or a focused text field. global needs --foreground.")
    var via: InputDeliveryMethod?

    @Flag(name: .long, help: ArgumentHelp(HelpText.strict))
    var strict: Bool = false

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
            OutputOptions.current = (format, compact, "type")
            let parsedDelay: Int?
            if let delayMS {
                guard let delay = Int(delayMS) else {
                    throw ScreenCommanderError.invalidArguments("--delay-ms must be an integer.")
                }
                parsedDelay = delay
            } else {
                parsedDelay = nil
            }
            let diffConfig = try FrameDiffConfig.validated(grid: diffGrid, threshold: diffThreshold)

            let request = TypeRequest(
                text: text,
                delayMilliseconds: parsedDelay,
                inputMode: mode,
                element: element,
                elementID: elementId,
                role: role,
                appIdentifier: app,
                via: via,
                strict: strict,
                windowID: windowId,
                foreground: foreground,
                session: presence.session,
                agentCursor: presence.agentCursor,
                replace: replace
            )

            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.type(request)
            }
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff, config: diffConfig)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "type",
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

            print("Typed \(result.textLength) characters via \(result.deliveryMethod.rawValue)\(result.replace == true ? ", replacing the value" : "").")
            if let record = result.element {
                let label = record.title ?? record.description ?? ""
                print("Element: \(record.role)\(label.isEmpty ? "" : " \"\(label)\"") (id \(record.id))")
            }
            if let delay = result.delayMilliseconds {
                print("Delay: \(delay) ms")
            }
            print("Mode: \(result.inputMode.rawValue)")
            print("Verified: \(SelectTextCommand.describe(result.verified))")
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
