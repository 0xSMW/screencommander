import ArgumentParser
import Foundation

struct ElementsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "elements",
        abstract: "Read an app's accessibility tree: roles, text, state, element IDs, and bounds.",
        discussion: """
            Reads the app's focused window, or the windows chosen with --window-id or --all-windows, \
            without activating the app or capturing pixels. Each element has an element ID such as \
            0.3.2, which is its position in the tree. Pass it to --element-id in click, type, scroll, \
            select-text, or action, and read the tree again after the UI changes. boundsPixels maps \
            each element into the last screenshot.

            Examples:
              screencommander elements --app TextEdit --text
              screencommander elements --app Safari --roles button,textfield --visible-only
            """
    )

    @Option(name: .long, help: ArgumentHelp(HelpText.appFrontmost))
    var app: String?

    @Option(name: .customLong("window-id"), help: "Read only this window, by ID from 'windows'.")
    var windowID: UInt32?

    @Flag(name: .customLong("all-windows"), help: "Read every window of the app instead of only the focused one.")
    var allWindows: Bool = false

    @Flag(name: .long, help: ArgumentHelp(HelpText.treeText))
    var text: Bool = false

    @Option(name: .long, help: "Only return these roles, comma-separated and case-insensitive, such as AXButton,AXTextField or button,textfield.")
    var roles: String?

    @Flag(name: .customLong("visible-only"), help: "Only return elements whose frame intersects their window.")
    var visibleOnly: Bool = false

    @Option(name: .long, help: "Fields to read: full, or text (skips bounds and actions, which is faster).")
    var profile: String = "full"

    @Option(name: .customLong("max-depth"), help: ArgumentHelp(HelpText.maxDepth))
    var maxDepth: Int = 40

    @Option(name: .customLong("max-elements"), help: ArgumentHelp(HelpText.maxElements))
    var maxElements: Int = 2000

    @Option(name: .customLong("max-value-length"), help: "Cut element values longer than this many characters.")
    var maxValueLength: Int = 200

    @Option(name: .customLong("max-visited"), help: "Stop after visiting this many nodes, 1 to 100000. The result then reports partialReason.")
    var maxVisited: Int?

    @Option(name: .customLong("timeout-ms"), help: "Stop reading after this many milliseconds, 1 to 60000. The result then reports partialReason.")
    var timeoutMS: Int?

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (format, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (format, compact, "elements")
            let parsedRoles = roles.map {
                $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }

            guard let readProfile = AXTreeOptions.Profile(rawValue: profile) else {
                throw ScreenCommanderError.invalidArguments("profile must be full or text.")
            }
            let request = ElementsRequest(
                appIdentifier: app,
                windowID: windowID,
                allWindows: allWindows,
                includeText: text,
                maxDepth: maxDepth,
                maxElements: maxElements,
                roles: parsedRoles,
                visibleOnly: visibleOnly,
                maxValueLength: maxValueLength,
                profile: readProfile,
                maxVisited: maxVisited,
                timeoutMS: timeoutMS
            )

            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.elements(request)
            }

            if format == .json {
                try CommandRuntime.emitJSON(command: "elements", result: result, compact: compact)
                return
            }

            printHuman(result)
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }

    private func printHuman(_ result: ElementsResult) {
        if text {
            let rendered = result.text ?? ""
            print(rendered.isEmpty ? "(no text content)" : rendered)
            return
        }

        var header = "\(result.app.name) (pid \(result.app.pid)) — \(result.elements.count) elements"
        if result.truncated {
            header += " (truncated at \(maxElements))"
        }
        if result.axPrimed {
            header += " [ax primed]"
        }
        print(header)
        if let metadataPath = result.metadataPath {
            print("Pixel bounds from: \(metadataPath)")
        }

        for element in result.elements {
            let indent = String(repeating: "  ", count: element.depth)
            var line = "\(indent)[\(element.id)] \(element.role)"
            if let title = element.title, !title.isEmpty {
                line += " \"\(title)\""
            }
            if let value = element.value, !value.isEmpty {
                line += " = \(value)"
                if element.valueTruncated == true {
                    line += "…"
                }
            }
            if !element.enabled {
                line += " (disabled)"
            }
            if element.focused == true {
                line += " (focused)"
            }
            if let bounds = element.boundsPoints {
                line += " @(\(Int(bounds.x)),\(Int(bounds.y)) \(Int(bounds.w))x\(Int(bounds.h)))"
            }
            print(line)
        }
    }
}
