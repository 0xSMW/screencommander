import ArgumentParser
import Foundation

struct ActionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "action",
        abstract: "Perform an accessibility action that an element lists, such as AXPress.",
        discussion: """
            Runs through accessibility only (tier ax), so it never activates the app or moves your \
            cursor. Each element's actions are listed by elements. A name the element does not list \
            fails with element_not_actionable, and the message lists the ones it does.

            Example:
              screencommander action --app TextEdit --element-id 0.3.2 --name AXShowMenu
            """
    )

    @Option(name: .long, help: "Action to perform, from the element's actions, such as AXPress, AXShowMenu, or AXIncrement. The AX prefix is optional.")
    var name: String

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
            OutputOptions.current = (outputFormat, compact, "action")
            let request = PerformActionRequest(
                element: element,
                elementID: elementId,
                role: role,
                appIdentifier: app,
                windowID: windowId,
                name: name,
                session: presence.session,
                agentCursor: presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.performAction(request)
            }

            if outputFormat == .json {
                try CommandRuntime.emitJSON(command: "action", result: ActionResultEnvelope(action: result), compact: compact)
                return
            }

            let label = result.element.title ?? result.element.description ?? result.element.value ?? ""
            print("Performed \(result.name) on \(result.element.role)\(label.isEmpty ? "" : " \"\(label)\"") (id \(result.element.id)).")
            CommandRuntime.printFocus(result.focus)
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
