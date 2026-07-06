import ArgumentParser
import Foundation

struct ElementsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "elements",
        abstract: "Read an app's accessibility (AX) element tree: ground-truth UI structure and text without pixels."
    )

    @Option(name: .long, help: "Target app by name or pid. Defaults to the frontmost application.")
    var app: String?

    @Option(name: .customLong("window-id"), help: "Restrict traversal to the window with this id.")
    var windowID: UInt32?

    @Flag(name: .customLong("all-windows"), help: "Traverse every window instead of just the focused one.")
    var allWindows: Bool = false

    @Flag(name: .long, help: "Emit an indented text-only view of the UI (role \"title\": value lines).")
    var text: Bool = false

    @Option(name: .customLong("max-depth"), help: "Maximum tree depth to traverse (1...200).")
    var maxDepth: Int = 40

    @Option(name: .customLong("max-elements"), help: "Maximum number of elements to emit (1...10000); result is marked truncated when hit.")
    var maxElements: Int = 2000

    @Option(name: .long, help: "Comma-separated role filter, e.g. 'AXButton,AXTextField' (case-insensitive; 'button' also matches).")
    var roles: String?

    @Flag(name: .customLong("visible-only"), help: "Emit only elements whose frame intersects their window bounds.")
    var visibleOnly: Bool = false

    @Option(name: .customLong("max-value-length"), help: "Truncate element values longer than this many characters.")
    var maxValueLength: Int = 200

    @Flag(name: .long, help: "Emit a single machine-readable JSON object to stdout (success or error envelope). For scripting; see README.")
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (format, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (format, compact, "elements")
            let parsedRoles = roles.map {
                $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
                maxValueLength: maxValueLength
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
