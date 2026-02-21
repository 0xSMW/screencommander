import ArgumentParser
import Foundation

struct ScreenshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot",
        abstract: "Capture a display using ScreenCaptureKit and save image + metadata."
    )

    @Option(name: .long, help: "Display ID or 'main'.")
    var display: String = "main"

    @Option(name: .long, help: "Output image path. Defaults to ./Screenshot-<timestamp>.<ext>.")
    var out: String?

    @Option(name: .long, help: "Image format.")
    var format: ImageFormat = .png

    @Option(name: .long, help: "Metadata JSON path. Defaults to <image>.json.")
    var meta: String?

    @Flag(name: .long, help: "Include cursor in screenshot.")
    var cursor: Bool = false

    @Flag(name: .long, help: "Emit machine-readable JSON output.")
    var json: Bool = false

    mutating func run() throws {
        do {
            let request = ScreenshotRequest(
                displayIdentifier: display,
                outputPath: out,
                format: format,
                metadataPath: meta,
                includeCursor: cursor,
                updateLastMetadata: true
            )

            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.screenshot(request)
            }

            if json {
                try CommandRuntime.emitJSON(command: "screenshot", result: result)
                return
            }

            print("Captured screenshot: \(result.imagePath)")
            print("Metadata: \(result.metadataPath)")
            print("Last metadata: \(result.lastMetadataPath)")
            print("Display ID: \(result.metadata.displayID)")
            print("Scale: \(result.metadata.pointPixelScale)")
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }
}
