import ArgumentParser
import Foundation

struct KeyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key",
        abstract: "Press one key chord in an app, in the background by default.",
        discussion: """
            A Command chord that matches one of the app's menu items is pressed through \
            accessibility, and the result's menuItem names the item. Other chords go to the app as \
            key events, and Command chords need an on-screen window, which is made key without \
            raising it (tier focusAssisted). None of these activate the app or move your cursor. \
            With --foreground, the chord goes through tier global.

            Keys that act on the whole Mac need --foreground: the system keys volumeup, volumedown, \
            mute, brightnessup, brightnessdown, playpause, nexttrack, previoustrack, and launchpad, \
            the shortcuts spotlight and missioncontrol, and the chords macOS handles before any app \
            sees them: cmd+tab, cmd+shift+tab, cmd+space, cmd+option+space, cmd+option+esc, \
            cmd+ctrl+q, cmd+shift+q, cmd+shift+3, cmd+shift+4, cmd+shift+5, cmd+shift+ctrl+3, and \
            cmd+shift+ctrl+4. Without --foreground they fail with background_delivery_unavailable.

            Examples:
              screencommander key --app TextEdit cmd+a
              screencommander key --app Safari return
            """
    )

    @Argument(help: "Modifiers and one key joined by +, such as cmd+shift+z, shift+tab, ctrl+up, return, or escape. Modifiers: cmd, shift, option, ctrl, fn.")
    var chord: String

    @Option(name: .long, help: ArgumentHelp(HelpText.appKeyboard))
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
            OutputOptions.current = (format, compact, "key")
            let diffConfig = try FrameDiffConfig.validated(grid: diffGrid, threshold: diffThreshold)
            let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot") : nil
            let request = KeyRequest(
                chord: chord,
                appIdentifier: app,
                windowID: windowId,
                foreground: foreground,
                session: presence.session,
                agentCursor: presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.key(request)
            }
            let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot") : nil
            let diff = CommandRuntime.frameDiff(pre: preshotResult, post: postshotResult, skip: noDiff, config: diffConfig)

            if format == .json {
                try CommandRuntime.emitJSON(
                    command: "key",
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

            print("Pressed chord: \(result.normalizedChord) via \(result.deliveryMethod.rawValue)")
            if let menuItem = result.menuItem {
                print("Menu item: \(menuItem)")
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
