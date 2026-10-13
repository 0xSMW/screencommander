import ArgumentParser
import Foundation

struct SelectTextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "select-text",
        abstract: "Select text in an element through accessibility.",
        discussion: """
            Pass exactly one of --range or --text. The selection is set through accessibility \
            (tier ax) without activating the app or moving your cursor, then read back to set \
            verified.

            Example:
              screencommander select-text --app TextEdit --element-id 0.3.2 --text "hello"
            """
    )

    @Option(name: .long, help: "Range to select as <location>,<length> in UTF-16 code units, such as 0,5.")
    var range: String?

    @Option(name: .long, help: "Select the first occurrence of this text, matching case first and then ignoring case.")
    var text: String?

    @Option(name: .long, help: ArgumentHelp(HelpText.element))
    var element: String?

    @Option(name: .customLong("element-id"), help: ArgumentHelp(HelpText.elementID))
    var elementId: String?

    @Option(name: .long, help: ArgumentHelp(HelpText.role))
    var role: String?

    @Option(name: .long, help: ArgumentHelp(HelpText.appFrontmost))
    var app: String?

    @Option(name: .customLong("window-id"), help: ArgumentHelp(HelpText.windowIDCursorOnly))
    var windowId: UInt32?

    @OptionGroup var presence: AgentPresenceOptions

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (outputFormat, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (outputFormat, compact, "select-text")
            let request = SelectTextRequest(
                element: element,
                elementID: elementId,
                role: role,
                appIdentifier: app,
                windowID: windowId,
                range: try range.map(Self.parseRange),
                text: text,
                session: presence.session,
                agentCursor: presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.selectText(request)
            }

            if outputFormat == .json {
                try CommandRuntime.emitJSON(command: "select-text", result: ActionResultEnvelope(action: result), compact: compact)
                return
            }

            print("Selected \(result.range.location),\(result.range.length) in \(result.element.role) (id \(result.element.id)).")
            if let selected = result.selectedText {
                print("Selection: \"\(selected)\"")
            }
            print("Verified: \(Self.describe(result.verified))")
            CommandRuntime.printFocus(result.focus)
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }

    static func parseRange(_ raw: String) throws -> AXTextRange {
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let location = Int(parts[0]), let length = Int(parts[1]) else {
            throw ScreenCommanderError.invalidArguments("--range must be <location>,<length>, e.g. 0,5.")
        }
        return AXTextRange(location: location, length: length)
    }

    static func describe(_ verified: ActionVerification) -> String {
        switch verified {
        case .checked(let value): return value ? "yes" : "no"
        case .unknown: return "unknown"
        }
    }
}
