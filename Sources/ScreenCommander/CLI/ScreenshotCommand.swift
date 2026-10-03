import ArgumentParser
import Foundation

struct ScreenshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a display or one window, with metadata for mapping coordinates.",
        discussion: """
            Each capture also becomes last-screenshot.json, which click, scroll, drag, and move map \
            coordinates against. Coordinates are pixels of the image unless an input command passes \
            --space. A window capture works on windows behind other windows.

            Examples:
              screencommander screenshot
              screencommander screenshot --window Safari
            """
    )

    @Option(name: .long, help: "Display to capture: 'main' or a display ID from 'doctor'.")
    var display: String = "main"

    @Option(name: .long, help: "Capture one window instead: a window ID from 'windows', or an app name prefix for that app's frontmost window.")
    var window: String?

    @Option(name: .long, help: "Image path. Defaults to a timestamped file in ~/Library/Caches/screencommander/captures.")
    var out: String?

    @Option(name: .long, help: ArgumentHelp(HelpText.imageFormat))
    var format: ImageFormat = .png

    @Option(name: .long, help: "Metadata path. Defaults to the image path with a .json extension.")
    var meta: String?

    @Flag(name: .long, help: "Include the cursor in the image.")
    var cursor: Bool = false

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (outputFormat, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (outputFormat, compact, "screenshot")
            if window != nil {
                WindowServerConnection.ensureInitialized()
            }

            let request = ScreenshotRequest(
                displayIdentifier: display,
                outputPath: out,
                format: format,
                metadataPath: meta,
                includeCursor: cursor,
                updateLastMetadata: true,
                windowIdentifier: window
            )

            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.screenshot(request)
            }

            if outputFormat == .json {
                try CommandRuntime.emitJSON(command: "screenshot", result: result, compact: compact)
                return
            }

            print("Captured screenshot: \(result.imagePath)")
            print("Metadata: \(result.metadataPath)")
            print("Last metadata: \(result.lastMetadataPath)")
            if let wid = result.metadata.windowID {
                print("Window ID: \(wid)")
            } else {
                print("Display ID: \(result.metadata.displayID)")
            }
            print("Scale: \(result.metadata.pointPixelScale)")
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
