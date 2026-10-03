import ArgumentParser
import CoreGraphics
import Foundation

/// Output format for scriptability; when .json, stdout is exactly one JSON object (success or error).
enum OutputFormat: String, ExpressibleByArgument {
    case human
    case json
}

/// Global output options: pre-scanned from argv and env so subcommands can resolve effective format.
enum OutputOptions {
    static var preScanned: (output: String?, compact: Bool) = (nil, false)
    static var preScannedOutputIsExplicit = false
    static var current: (format: OutputFormat, compact: Bool, commandName: String)?

    static func preScan(_ args: [String]) {
        var output: String?
        var outputIsExplicit = false
        var compact = false
        for i in args.indices {
            if args[i] == "--output", i + 1 < args.count {
                output = args[i + 1]
                outputIsExplicit = true
            } else if args[i].hasPrefix("--output=") {
                output = String(args[i].dropFirst("--output=".count))
                outputIsExplicit = true
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
        preScannedOutputIsExplicit = outputIsExplicit
    }

    /// Resolve effective format: per-command --json > pre-scanned/root --output > env > human.
    static func effective(jsonFlag: Bool) throws -> (format: OutputFormat, compact: Bool) {
        let format: OutputFormat
        if jsonFlag {
            if preScannedOutputIsExplicit, let output = preScanned.output {
                _ = try parseOutputFormat(output)
            }
            format = .json
        } else if let output = preScanned.output {
            format = try parseOutputFormat(output)
        } else if let env = ProcessInfo.processInfo.environment["SCREENCOMMANDER_OUTPUT"] {
            format = try parseOutputFormat(env)
        } else {
            format = .human
        }
        let compact = preScanned.compact || ProcessInfo.processInfo.environment["SCREENCOMMANDER_JSON_COMPACT"] == "1"
        return (format, compact)
    }

    /// The JSON error envelope for an argument that could not be parsed, when JSON
    /// output was asked for with `--json`, `--output json`, or
    /// SCREENCOMMANDER_OUTPUT=json. Nil when it was not, and for help and version
    /// requests, which print as text.
    static func parseErrorEnvelope(
        for error: Error,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ErrorEnvelope? {
        if error is CleanExit {
            return nil
        }
        var wantsJSON = arguments.contains("--json")
        if let index = arguments.lastIndex(of: "--output"), index + 1 < arguments.count {
            wantsJSON = wantsJSON || arguments[index + 1].trimmingCharacters(in: .whitespaces).lowercased() == "json"
        } else if let inline = arguments.last(where: { $0.hasPrefix("--output=") }) {
            wantsJSON = wantsJSON || inline.dropFirst("--output=".count).lowercased() == "json"
        } else if environment["SCREENCOMMANDER_OUTPUT"]?.trimmingCharacters(in: .whitespaces).lowercased() == "json" {
            wantsJSON = true
        }
        guard wantsJSON else {
            return nil
        }
        let names = Set(RootCommand.configuration.subcommands.compactMap { $0.configuration.commandName })
        let command = arguments.first(where: names.contains) ?? "screencommander"
        var message = RootCommand.message(for: error)
        if message.isEmpty {
            message = "\(error)"
        }
        let wrapped = ScreenCommanderError.invalidArguments(message)
        return ErrorEnvelope(
            status: "error",
            command: command,
            error: ErrorDetail(code: wrapped.stableCode, message: wrapped.description),
            exitCode: wrapped.exitCode
        )
    }

    private static func parseOutputFormat(_ raw: String) throws -> OutputFormat {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let format = OutputFormat(rawValue: value) else {
            throw ScreenCommanderError.invalidArguments("--output must be 'human' or 'json'.")
        }
        return format
    }
}

/// The one version string: `--version` and the MCP server's `serverInfo.version`.
enum ScreenCommanderVersion {
    static let current = "0.6.0"
}

/// Help text shared by several commands, so each option reads the same everywhere.
enum HelpText {
    static let json = "Print one JSON object to stdout, for success or error. Same as --output json."

    static let appName = "Target app: name or pid."
    static let appFrontmost = "Target app: name or pid. Defaults to the frontmost app."
    static let appKeyboard = "Target app: name or pid. Without it or --window-id, keys go to the window of the last window screenshot, else to the frontmost app."
    static let appKeyboardOrElement = "Target app: name or pid. Without it or --window-id, text goes to the window of the last window screenshot, else to the frontmost app. --element and --element-id search the frontmost app."
    static let appPointer = "Target app: name or pid. Defaults to the window of the last window screenshot, else whatever is topmost at the point, at any layer."
    static let appMixed = "Target app: name or pid. Element targets default to the frontmost app. Coordinates default to the window of the last window screenshot, else whatever is topmost at the point, at any layer."
    static let windowID = "Window to send background input to, by ID from 'windows'. Keys go to this window, made key first, and --element searches it."
    static let windowIDCursorOnly = "Window that --element searches and the agent cursor is drawn over, by ID from 'windows'. Input goes through accessibility either way."

    static let element = "Target the element whose title, description, or value matches this text in the app's focused window, or in --window-id when given (case-insensitive, exact match before substring)."
    static let elementID = "Target an element by its element ID from 'elements' or 'state', such as 0.3.2. IDs are tree positions, so read them again after the UI changes."
    static let role = "Only match --element against this role, such as button or AXButton."

    static let foreground = "Allow foreground delivery (tier global): post through the HID event tap and activate the target app when it is known. This moves the real cursor and can change focus. The target app is still leased, and the action waits until you stop typing or moving the mouse."
    static let strict = "Use only the first delivery tier and fail instead of falling back to the next one."

    static let space = "Coordinate space of the input: pixels of the screenshot image, points, or normalized 0 to 1, all from the screenshot's top-left corner."
    static let meta = "Screenshot metadata to map coordinates against. Defaults to last-screenshot.json, which screenshot and state write."
    static let strictMetadata = "Fail with stale_metadata when the screenshot metadata is known to be out of date."

    static let postshot = "Capture the main display before and after the action and report what changed. Does not replace last-screenshot.json."
    static let postshotEachStep = "Capture the main display before and after each step and report what changed. Does not replace last-screenshot.json."
    static let noDiff = "Skip the frame diff between the before and after captures."
    static let diffGrid = "Grid size of the frame diff, 1 to 512. (default: 64)"
    static let diffThreshold = "Per-cell change threshold of the frame diff, 0 to 1. (default: 0.04)"

    static let maxDepth = "Maximum tree depth to read, 1 to 200."
    static let maxElements = "Maximum elements to return, 1 to 10000. The result is marked truncated when the limit is hit."
    static let treeText = "Also render an indented text view, one 'role \"title\": value' line per element with text. Human output then prints only that view."
    static let imageFormat = "Image format: png or jpeg."
}

struct RootCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screencommander",
        abstract: "Observe and operate the macOS desktop from the terminal, or as an MCP server.",
        discussion: """
            Read the screen with screenshot, state, and elements. Act with click, type, key, and the \
            other input commands. By default, input goes to the target app in the background. It does \
            not activate the app, move your cursor, or take keyboard focus, and an agent cursor shows \
            where the agent is working. Pass --foreground to an input command to allow the real cursor \
            and keyboard. Press Control-Option-Command-Period to stop agent input, foreground included, and run \
            resume to allow it again.

            Coordinates map against the last screenshot or state capture. Element IDs come from \
            elements or state.

            Output is human-readable text unless JSON is requested. --output json, a command's --json, \
            and SCREENCOMMANDER_OUTPUT=json all print one JSON object to stdout, for errors too. \
            --output and --compact work before or after the command name. observe always prints JSON lines.

            Get started:
              screencommander doctor
              screencommander state --app TextEdit
              screencommander click --app TextEdit --element-id 0.3.2
            """,
        subcommands: [
            DoctorCommand.self,
            ScreenshotCommand.self,
            ClickCommand.self,
            ScrollCommand.self,
            DragCommand.self,
            MoveCommand.self,
            TypeCommand.self,
            KeyCommand.self,
            KeysCommand.self,
            ElementsCommand.self,
            StateCommand.self,
            SelectTextCommand.self,
            ActionCommand.self,
            ObserveCommand.self,
            CleanupCommand.self,
            SequenceCommand.self,
            WindowsCommand.self,
            AppsCommand.self,
            LaunchCommand.self,
            FocusCommand.self,
            ResumeCommand.self,
            ServeCommand.self,
            PresenceCommand.self
        ],
        defaultSubcommand: ScreenshotCommand.self
    )

    @Option(name: .long, help: "Output format: human or json. Overrides SCREENCOMMANDER_OUTPUT. A command's --json overrides both. (default: human)")
    var output: String?

    @Flag(name: .long, help: "Print JSON on one line. Same as SCREENCOMMANDER_JSON_COMPACT=1.")
    var compact: Bool = false

    /// Handled in main.swift before parsing. Declared here so root help lists it
    /// without ArgumentParser adding `--version` to every subcommand.
    @Flag(name: .long, help: "Print the version and exit.")
    var version: Bool = false
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

    /// Why each failed action capture failed, by prefix ("Preshot", "Postshot-step2").
    private static var shotFailures: [String: ErrorDetail] = [:]

    /// The failure of the action capture with this prefix, when it failed.
    static func shotFailure(_ prefix: String) -> ErrorDetail? {
        shotFailures[prefix]
    }

    /// Bounds a whole action capture, display listing and capture together, even if
    /// a step under it never answers. Each ScreenCaptureKit call has its own
    /// `CaptureDeadline`, so this only fires when something else hangs.
    static let actionShotDeadlineSeconds = CaptureDeadline.defaultSeconds * 2 + 1

    /// A capture before or after an action. It never fails or holds up the action:
    /// a failure or timeout prints a warning, is recorded for `shotFailure`, and
    /// returns nil.
    static func captureActionScreenshot(
        prefix: String,
        deadline: TimeInterval = actionShotDeadlineSeconds,
        capture: @escaping @Sendable (ScreenshotRequest) async throws -> ScreenshotResult = { try await engine.screenshot($0) }
    ) -> ActionScreenshotCapture? {
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

                let result = try AsyncBridge.run(
                    deadline: deadline,
                    timedOut: ScreenCommanderError.captureTimeout(
                        "The \(prefix.lowercased()) capture did not finish within \(String(format: "%.1f", deadline)) s."
                    )
                ) {
                    try await capture(request)
                }

                shotFailures[prefix] = nil
                let screenshotResult = ActionScreenshotResult(
                    imagePath: result.imagePath,
                    metadataPath: result.metadataPath
                )
                // Diff against the in-memory capture — no PNG re-decode round trip.
                return ActionScreenshotCapture(result: screenshotResult, image: result.image)
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
            shotFailures[prefix] = ErrorDetail(code: error.stableCode, message: error.description)
            writeError("warning: \(prefix.lowercased()) failed, the action is unaffected: \(error.description)")
        } else if let error = lastFailure {
            shotFailures[prefix] = ErrorDetail(code: "capture_failed", message: error.localizedDescription)
            writeError("warning: \(prefix.lowercased()) failed, the action is unaffected: \(error.localizedDescription)")
        }

        return nil
    }

    static func frameDiff(
        pre: ActionScreenshotCapture?,
        post: ActionScreenshotCapture?,
        skip: Bool,
        config: FrameDiffConfig = .default
    ) -> FrameDiffResult? {
        guard !skip,
              let preImage = pre?.image,
              let postImage = post?.image else {
            return nil
        }

        return FrameDiff.compare(preImage, postImage, config: config)
    }

    static func printFocus(_ focus: FocusReceipt?) {
        guard let focus else {
            return
        }
        let frontmost = focus.frontmostAfter ?? "unknown"
        print("Focus: \(focus.preserved ? "preserved" : "changed") (frontmost \(frontmost)), cursor \(focus.cursorMoved ? "moved" : "unmoved")")
        if focus.guardRestored == true {
            print("Focus guard: the target took focus and the previous app was put back")
        }
    }

    static func printFrameDiff(_ diff: FrameDiffResult?) {
        guard let diff, diff.changedFraction > 0 else {
            return
        }

        if let region = diff.changedRegion {
            print(String(
                format: "diff: %.1f%% changed in (%.0f,%.0f %.0fx%.0f)",
                diff.changedFraction * 100,
                region.x,
                region.y,
                region.w,
                region.h
            ))
        } else {
            print(String(format: "diff: %.1f%% changed", diff.changedFraction * 100))
        }
    }

    private static func shouldFallbackToTemp(after error: Error, attemptIndex: Int, totalAttempts: Int) -> Bool {
        guard attemptIndex < (totalAttempts - 1) else {
            return false
        }

        guard let error = error as? ScreenCommanderError else {
            return true
        }

        switch error {
        case .permissionDeniedScreenRecording, .permissionDeniedAccessibility, .captureFailed, .captureTimeout, .windowMinimized, .axTreeUnavailable:
            return false
        case .imageWriteFailed, .metadataFailure, .invalidCoordinate, .mappingFailed, .inputSynthesisFailed, .backgroundDeliveryUnavailable, .targetBusy, .abortedByUser, .userInterrupted, .invalidArguments, .elementNotFound, .elementNotActionable, .observeTimeout, .windowNotFound, .appNotFound, .elementAmbiguous, .staleMetadata:
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

struct ErrorDetail: Codable, Sendable, Equatable {
    var code: String
    var message: String
}

struct ErrorEnvelope: Codable, Equatable {
    var status: String
    var command: String
    var error: ErrorDetail
    var exitCode: Int32
}

struct ActionScreenshotResult: Codable, Sendable {
    var imagePath: String
    var metadataPath: String
}

struct ActionScreenshotCapture {
    var result: ActionScreenshotResult
    var image: CGImage?
}

struct ActionResultEnvelope<ActionResult: Encodable>: Encodable {
    var action: ActionResult
    var preshot: ActionScreenshotResult?
    var postshot: ActionScreenshotResult?
    var diff: FrameDiffResult?
    /// Why a requested capture before or after the action is missing. The action
    /// itself ran, and `action` reports it.
    var preshotError: ErrorDetail?
    var postshotError: ErrorDetail?

    init(
        action: ActionResult,
        preshot: ActionScreenshotResult? = nil,
        postshot: ActionScreenshotResult? = nil,
        diff: FrameDiffResult? = nil,
        preshotError: ErrorDetail? = nil,
        postshotError: ErrorDetail? = nil
    ) {
        self.action = action
        self.preshot = preshot
        self.postshot = postshot
        self.diff = diff
        self.preshotError = preshotError
        self.postshotError = postshotError
    }
}

enum AsyncBridge {
    static func run<T>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        try run(deadline: nil, operation)
    }

    /// With a deadline, gives up waiting after that many seconds and throws
    /// `timedOut`. The operation is left to finish, or not, on its own.
    static func run<T>(
        deadline: TimeInterval?,
        timedOut: @autoclosure () -> Error = ScreenCommanderError.captureTimeout("The operation did not finish in time."),
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()

        let task = Task {
            let outcome: Result<T, Error>
            do {
                outcome = .success(try await operation())
            } catch {
                outcome = .failure(error)
            }
            box.set(outcome)
            semaphore.signal()
        }

        if let deadline {
            guard semaphore.wait(timeout: .now() + max(0, deadline)) == .success else {
                task.cancel()
                throw timedOut()
            }
        } else {
            semaphore.wait()
        }
        guard let result = box.get() else {
            throw ScreenCommanderError.captureFailed("Unexpected async bridge state.")
        }
        return try result.get()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, Error>?

        func set(_ value: Result<T, Error>) {
            lock.lock()
            self.value = value
            lock.unlock()
        }

        func get() -> Result<T, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
