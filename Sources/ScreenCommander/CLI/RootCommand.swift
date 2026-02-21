import ArgumentParser
import Foundation

struct RootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screencommander",
        abstract: "Capture screenshots and synthesize global mouse and keyboard input.",
        subcommands: [
            DoctorCommand.self,
            ScreenshotCommand.self,
            ClickCommand.self,
            TypeCommand.self,
            KeyCommand.self,
            KeysCommand.self,
            CleanupCommand.self,
            SequenceCommand.self
        ],
        defaultSubcommand: ScreenshotCommand.self
    )
}

enum CommandRuntime {
    static let engine = ScreenCommanderEngine.live()
    private static let fileManager = FileManager.default
    private static let statePaths = StatePaths(fileManager: fileManager)
    private static let fallbackActionShotsDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("screencommander-actionshots", isDirectory: true)
    private static let shotDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    static func emitJSON<Result: Encodable>(command: String, result: Result) throws {
        let envelope = CommandEnvelope(status: "ok", command: command, result: result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ScreenCommanderError.metadataFailure("Could not encode JSON output.")
        }
        print(json)
    }

    static func mapError(_ error: Error) -> Error {
        if error is CleanExit {
            return error
        }

        if let exitCode = error as? ExitCode {
            return exitCode
        }

        if let screenCommanderError = error as? ScreenCommanderError {
            writeError(screenCommanderError.description)
            return ExitCode(screenCommanderError.exitCode)
        }

        if let validationError = error as? ValidationError {
            let wrapped = ScreenCommanderError.invalidArguments(validationError.message)
            writeError(wrapped.description)
            return ExitCode(wrapped.exitCode)
        }

        writeError(error.localizedDescription)
        return ExitCode.failure
    }

    static func captureActionScreenshot(prefix: String) -> ActionScreenshotResult? {
        let timestamp = shotDateFormatter.string(from: Date())
        let filename = "\(prefix)-\(timestamp).png"

        let outputDirectories = [statePaths.capturesDirectoryURL, fallbackActionShotsDirectory]
        var lastFailure: Error?

        for (attemptIndex, directoryURL) in outputDirectories.enumerated() {
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

                let request = ScreenshotRequest(
                    displayIdentifier: "main",
                    outputPath: directoryURL.appendingPathComponent(filename).path,
                    format: .png,
                    metadataPath: nil,
                    includeCursor: false,
                    updateLastMetadata: false
                )

                let result = try AsyncBridge.run {
                    try await engine.screenshot(request)
                }

                return ActionScreenshotResult(
                    imagePath: result.imagePath,
                    metadataPath: result.metadataPath
                )
            } catch {
                lastFailure = error
                if shouldFallbackToTemp(
                    after: error,
                    attemptIndex: attemptIndex,
                    totalAttempts: outputDirectories.count
                ) {
                    continue
                }

                break
            }
        }

        if let error = lastFailure as? ScreenCommanderError {
            writeError("warning: \(prefix.lowercased()) failed: \(error.description)")
        } else if let error = lastFailure {
            writeError("warning: \(prefix.lowercased()) failed: \(error.localizedDescription)")
        }

        return nil
    }

    private static func shouldFallbackToTemp(after error: Error, attemptIndex: Int, totalAttempts: Int) -> Bool {
        guard attemptIndex < (totalAttempts - 1) else {
            return false
        }

        guard let error = error as? ScreenCommanderError else {
            return true
        }

        switch error {
        case .permissionDeniedScreenRecording, .permissionDeniedAccessibility, .captureFailed:
            return false
        case .imageWriteFailed, .metadataFailure, .invalidCoordinate, .mappingFailed, .inputSynthesisFailed, .invalidArguments:
            return true
        }
    }
}

struct CommandEnvelope<Result: Encodable>: Encodable {
    var status: String
    var command: String
    var result: Result
}

struct ActionScreenshotResult: Codable, Sendable {
    var imagePath: String
    var metadataPath: String
}

struct ActionResultEnvelope<ActionResult: Encodable>: Encodable {
    var action: ActionResult
    var preshot: ActionScreenshotResult?
    var postshot: ActionScreenshotResult?
}

enum AsyncBridge {
    static func run<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<T, Error>?

        Task {
            do {
                result = .success(try await operation())
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }

        semaphore.wait()
        guard let result else {
            throw ScreenCommanderError.captureFailed("Unexpected async bridge state.")
        }
        return try result.get()
    }
}
