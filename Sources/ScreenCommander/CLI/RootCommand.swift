import ArgumentParser
import Foundation

/// Output format for scriptability; when .json, stdout is exactly one JSON object (success or error).
enum OutputFormat: String, ExpressibleByArgument {
    case human
    case json
}

/// Global output options: pre-scanned from argv and env so subcommands can resolve effective format.
enum OutputOptions {
    static var preScanned: (output: String?, compact: Bool) = (nil, false)
    static var current: (format: OutputFormat, compact: Bool, commandName: String)?

    static func preScan(_ args: [String]) {
        var output: String?
        var compact = false
        for i in args.indices {
            if args[i] == "--output", i + 1 < args.count {
                output = args[i + 1]
            } else if args[i] == "--compact" {
                compact = true
            }
        }
        if output == nil, let env = ProcessInfo.processInfo.environment["SCREENCOMMANDER_OUTPUT"] {
            output = env
        }
        if !compact, ProcessInfo.processInfo.environment["SCREENCOMMANDER_JSON_COMPACT"] == "1" {
            compact = true
        }
        preScanned = (output, compact)
    }

    /// Resolve effective format: per-command --json > pre-scanned/root --output > env > human.
    static func effective(jsonFlag: Bool) -> (format: OutputFormat, compact: Bool) {
        let format: OutputFormat = jsonFlag
            ? .json
            : (preScanned.output?.lowercased() == "json" ? .json : (ProcessInfo.processInfo.environment["SCREENCOMMANDER_OUTPUT"]?.lowercased() == "json" ? .json : .human))
        let compact = preScanned.compact || ProcessInfo.processInfo.environment["SCREENCOMMANDER_JSON_COMPACT"] == "1"
        return (format, compact)
    }
}

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

    @Option(name: .long, help: "Output format for all subcommands: human (default) or json. With json, stdout is exactly one JSON object (success or error). Use for scripting.")
    var output: String?

    @Flag(name: .long, help: "When output is json, emit one-line compact JSON. Use with --output json for scripting.")
    var compact: Bool = false
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

    static func emitJSON<Result: Encodable>(command: String, result: Result, compact: Bool = false) throws {
        let exitCodeValue = 0
        let envelope = CommandEnvelope(status: "ok", command: command, result: result, exitCode: exitCodeValue)
        let encoder = JSONEncoder()
        encoder.outputFormatting = compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(envelope)
        guard let json = String(data: data, encoding: .utf8) else {
            throw ScreenCommanderError.metadataFailure("Could not encode JSON output.")
        }
        print(json)
    }

    /// Emit a single JSON error object to stdout so scripts get one parseable object on failure.
    static func emitErrorJSON(command: String, error: ScreenCommanderError, exitCode: Int32, compact: Bool = false) {
        let envelope = ErrorEnvelope(
            status: "error",
            command: command,
            error: ErrorDetail(code: error.stableCode, message: error.description),
            exitCode: exitCode
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(envelope), let json = String(data: data, encoding: .utf8) {
            print(json)
        }
    }

    static func mapError(_ error: Error) -> Error {
        if error is CleanExit {
            return error
        }

        if let exitCode = error as? ExitCode {
            return exitCode
        }

        if let screenCommanderError = error as? ScreenCommanderError {
            if let current = OutputOptions.current, current.format == .json {
                emitErrorJSON(command: current.commandName, error: screenCommanderError, exitCode: screenCommanderError.exitCode, compact: current.compact)
            } else {
                writeError(screenCommanderError.description)
            }
            return ExitCode(screenCommanderError.exitCode)
        }

        if let validationError = error as? ValidationError {
            let wrapped = ScreenCommanderError.invalidArguments(validationError.message)
            if let current = OutputOptions.current, current.format == .json {
                emitErrorJSON(command: current.commandName, error: wrapped, exitCode: wrapped.exitCode, compact: current.compact)
            } else {
                writeError(wrapped.description)
            }
            return ExitCode(wrapped.exitCode)
        }

        if let current = OutputOptions.current, current.format == .json {
            let generic = ScreenCommanderError.invalidArguments(error.localizedDescription)
            emitErrorJSON(command: current.commandName, error: generic, exitCode: 60, compact: current.compact)
            return ExitCode(60)
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
    var exitCode: Int?
}

struct ErrorDetail: Encodable {
    var code: String
    var message: String
}

struct ErrorEnvelope: Encodable {
    var status: String
    var command: String
    var error: ErrorDetail
    var exitCode: Int32
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
