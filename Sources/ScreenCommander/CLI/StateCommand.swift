import ArgumentParser
import Foundation

struct StateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "state",
        abstract: "Capture an app's window and read its accessibility tree in one call.",
        discussion: """
            Works on windows behind other windows without activating the app. The capture becomes \
            last-screenshot.json, so coordinate input maps against it, and element IDs match those \
            from elements.

            Example:
              screencommander state --app TextEdit
            """
    )

    @Option(name: .long, help: ArgumentHelp(HelpText.appName))
    var app: String

    @Option(name: .customLong("window-id"), help: "Capture and read this window, by ID from 'windows'. Defaults to the app's frontmost window.")
    var windowId: UInt32?

    @Flag(name: .long, help: ArgumentHelp(HelpText.treeText))
    var text: Bool = false

    @Option(name: .long, help: ArgumentHelp(HelpText.imageFormat))
    var format: ImageFormat = .png

    @Option(name: .customLong("max-depth"), help: ArgumentHelp(HelpText.maxDepth))
    var maxDepth: Int = 40

    @Option(name: .customLong("max-elements"), help: ArgumentHelp(HelpText.maxElements))
    var maxElements: Int = 2000

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (outputFormat, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (outputFormat, compact, "state")
            WindowServerConnection.ensureInitialized()

            let request = AppStateRequest(
                appIdentifier: app,
                windowID: windowId,
                maxDepth: maxDepth,
                maxElements: maxElements,
                includeText: text,
                format: format
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.appState(request)
            }

            if outputFormat == .json {
                try CommandRuntime.emitJSON(command: "state", result: result, compact: compact)
                return
            }

            print("\(result.app.name) (pid \(result.app.pid)) window \(result.windowID)")
            print("Image: \(result.imagePath)")
            print("Metadata: \(result.metadataPath)")
            var header = "\(result.tree.elements.count) elements"
            if result.tree.truncated {
                header += " (truncated)"
            }
            print(header)
            if let rendered = result.tree.text {
                print(rendered.isEmpty ? "(no text content)" : rendered)
                return
            }
            for element in result.tree.elements {
                print(ElementLine.render(element))
            }
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}

/// One `elements`-style line: `[id] role "title" = value @(x,y wxh)`.
enum ElementLine {
    static func render(_ element: AXElementRecord) -> String {
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
        return line
    }
}
