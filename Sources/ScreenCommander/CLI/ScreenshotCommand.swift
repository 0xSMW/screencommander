import ArgumentParser
import Foundation

struct ScreenshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a display using ScreenCaptureKit and save image + metadata."
    )

    @Option(name: .long, help: "Display ID or 'main'.")
    var display: String = "main"

    @Option(name: .long, help: "Window ID or app-name prefix to capture a single window instead of the full display.")
    var window: String?

    @Option(name: .long, help: "Output image path. Defaults to ~/Library/Caches/screencommander/captures/Screenshot-<timestamp>.<ext>.")
    var out: String?

    @Option(name: .long, help: "Image format.")
    var format: ImageFormat = .png

    @Option(name: .long, help: "Metadata JSON path. Defaults to <image>.json.")
    var meta: String?

    @Flag(name: .long, help: "Include cursor in screenshot.")
    var cursor: Bool = false

    @Flag(name: .long, help: "Emit a single machine-readable JSON object to stdout (success or error envelope). For scripting; see README.")
    var json: Bool = false

    mutating func run() throws {
        let (outputFormat, compact) = OutputOptions.effective(jsonFlag: json)
        OutputOptions.current = (outputFormat, compact, "screenshot")
        defer { OutputOptions.current = nil }
        do {
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
