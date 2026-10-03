import ArgumentParser
import Foundation

struct SequenceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sequence",
        abstract: "Run input steps from a JSON file in order.",
        discussion: """
            The file holds {"steps": [...]}. Each step is an object with one key: click, scroll, \
            drag, move, type, key, keys, selectText, action, launch, or sleep. Its value takes the \
            command's options as camelCase fields with the MCP tools' names, such as elementId, \
            windowId, durationMs, dwellMs, delayMs, and timeoutMs. keys takes {"steps": [...]} like \
            the keys command, and sleep takes {"ms": 500}. A step's "noDiff": true skips its frame diff. \
            A key a step does not take fails the whole file before any step runs, and the error names \
            the step and the key. The older spellings durationMS, dwellMS, delayMS, and timeoutMS still \
            work. Steps run in the background by default, and the first failing step stops the run. \
            --session and --no-agent-cursor apply to steps that do not set session or agentCursor.

            Example file:
              {"steps": [
                {"click": {"app": "TextEdit", "elementId": "0.3.2"}},
                {"type": {"app": "TextEdit", "text": "Hello"}},
                {"key": {"app": "TextEdit", "chord": "cmd+a"}}
              ]}
            """
    )

    @Option(name: .long, help: "Path to the sequence JSON file.")
    var file: String

    @OptionGroup var presence: AgentPresenceOptions

    @Flag(name: .long, inversion: .prefixedNo, help: ArgumentHelp(HelpText.postshotEachStep))
    var postshot: Bool = true

    @Flag(name: .long, help: ArgumentHelp(HelpText.noDiff))
    var noDiff: Bool = false

    @Option(name: .customLong("diff-grid"), help: ArgumentHelp(HelpText.diffGrid))
    var diffGrid: Int?

    @Option(name: .customLong("diff-threshold"), help: ArgumentHelp(HelpText.diffThreshold))
    var diffThreshold: Double?

    @Flag(name: .long, help: ArgumentHelp(HelpText.json))
    var json: Bool = false

    mutating func run() throws {
        defer { OutputOptions.current = nil }
        do {
            let (format, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (format, compact, "sequence")
            let fileURL = resolvedURL(for: file)
            let data = try Data(contentsOf: fileURL)
            let sequence: SequenceFile
            do {
                sequence = try JSONDecoder().decode(SequenceFile.self, from: data)
            } catch let error as DecodingError {
                throw ScreenCommanderError.invalidArguments(
                    "The sequence file is not a JSON object with a \"steps\" array: \(SequenceStepError.describe(error))"
                )
            }
            let diffConfig = try FrameDiffConfig.validated(grid: diffGrid, threshold: diffThreshold)

            if sequence.steps.isEmpty {
                throw ScreenCommanderError.invalidArguments("Sequence file must include at least one step.")
            }

            var outputs: [SequenceStepResult] = []
            outputs.reserveCapacity(sequence.steps.count)

            for (index, step) in sequence.steps.enumerated() {
                let preshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Preshot-step\(index + 1)") : nil
                let actionResult = try runStep(step)
                let postshotResult = postshot ? CommandRuntime.captureActionScreenshot(prefix: "Postshot-step\(index + 1)") : nil
                let diff = CommandRuntime.frameDiff(
                    pre: preshotResult,
                    post: postshotResult,
                    skip: noDiff || step.noDiff,
                    config: diffConfig
                )

                let stepResult = SequenceStepResult(
                    index: index + 1,
                    action: actionResult.action,
                    click: actionResult.click,
                    scroll: actionResult.scroll,
                    drag: actionResult.drag,
                    move: actionResult.move,
                    type: actionResult.type,
                    key: actionResult.key,
                    keys: actionResult.keys,
                    selectText: actionResult.selectText,
                    performAction: actionResult.performAction,
                    launch: actionResult.launch,
                    sleep: actionResult.sleep,
                    preshot: preshotResult?.result,
                    postshot: postshotResult?.result,
                    diff: diff,
                    preshotError: CommandRuntime.shotFailure("Preshot-step\(index + 1)"),
                    postshotError: CommandRuntime.shotFailure("Postshot-step\(index + 1)")
                )
                outputs.append(stepResult)

                if format != .json {
                    print("Step \(stepResult.index): \(stepResult.action) ok")
                    CommandRuntime.printFrameDiff(diff)
                }
            }

            let result = SequenceRunResult(file: fileURL.path, steps: outputs)
            if format == .json {
                try CommandRuntime.emitJSON(command: "sequence", result: result, compact: compact)
                return
            }

            print("Completed \(outputs.count) steps.")
        } catch {
            throw CommandRuntime.mapError(error)
        }
    }

    private func runStep(_ step: SequenceStep) throws -> StepActionResult {
        switch step {
        case .click(let click):
            let request = ClickRequest(
                x: click.x,
                y: click.y,
                coordinateSpace: click.space ?? .pixels,
                metadataPath: click.meta,
                button: click.button ?? .left,
                doubleClick: click.double ?? false,
                triple: click.triple ?? false,
                // `prime` is accepted and has no effect since 0.6.0.
                primeClick: false,
                humanLike: !(click.raw ?? false),
                modifiers: try MouseModifiers.parse(click.modifiers),
                element: click.element,
                elementID: click.elementId,
                role: click.role,
                appIdentifier: click.app,
                via: click.via,
                noCursor: click.noCursor ?? false,
                strict: click.strict ?? false,
                strictMetadata: click.strictMetadata ?? false,
                windowID: click.windowId,
                foreground: click.foreground ?? false,
                session: click.session ?? presence.session,
                agentCursor: click.agentCursor ?? presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.click(request)
            }
            return StepActionResult(action: "click", click: result)
        case .scroll(let scroll):
            let request = ScrollRequest(
                x: scroll.x,
                y: scroll.y,
                coordinateSpace: scroll.space ?? .pixels,
                metadataPath: scroll.meta,
                dx: scroll.dx ?? 0,
                dy: scroll.dy ?? 0,
                unit: scroll.unit ?? .lines,
                element: scroll.element,
                elementID: scroll.elementId,
                role: scroll.role,
                appIdentifier: scroll.app,
                via: scroll.via,
                noCursor: scroll.noCursor ?? false,
                strict: scroll.strict ?? false,
                strictMetadata: scroll.strictMetadata ?? false,
                windowID: scroll.windowId,
                foreground: scroll.foreground ?? false,
                session: scroll.session ?? presence.session,
                agentCursor: scroll.agentCursor ?? presence.agentCursor,
                direction: scroll.direction,
                pages: scroll.pages ?? 1
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.scroll(request)
            }
            return StepActionResult(action: "scroll", scroll: result)
        case .drag(let drag):
            let request = DragRequest(
                x1: drag.x1,
                y1: drag.y1,
                x2: drag.x2,
                y2: drag.y2,
                coordinateSpace: drag.space ?? .pixels,
                metadataPath: drag.meta,
                button: drag.button ?? .left,
                steps: drag.steps ?? 12,
                durationMS: drag.durationMs ?? 300,
                strictMetadata: drag.strictMetadata ?? false,
                appIdentifier: drag.app,
                windowID: drag.windowId,
                foreground: drag.foreground ?? false,
                session: drag.session ?? presence.session,
                agentCursor: drag.agentCursor ?? presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.drag(request)
            }
            return StepActionResult(action: "drag", drag: result)
        case .move(let move):
            let request = MoveRequest(
                x: move.x,
                y: move.y,
                coordinateSpace: move.space ?? .pixels,
                metadataPath: move.meta,
                dwellMS: move.dwellMs ?? 0,
                strictMetadata: move.strictMetadata ?? false,
                appIdentifier: move.app,
                windowID: move.windowId,
                foreground: move.foreground ?? false,
                session: move.session ?? presence.session,
                agentCursor: move.agentCursor ?? presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.move(request)
            }
            return StepActionResult(action: "move", move: result)
        case .type(let type):
            let request = TypeRequest(
                text: type.text,
                delayMilliseconds: type.delayMs,
                inputMode: type.mode ?? .unicode,
                element: type.element,
                elementID: type.elementId,
                role: type.role,
                appIdentifier: type.app,
                via: type.via,
                strict: type.strict ?? false,
                windowID: type.windowId,
                foreground: type.foreground ?? false,
                session: type.session ?? presence.session,
                agentCursor: type.agentCursor ?? presence.agentCursor,
                replace: type.replace ?? false
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.type(request)
            }
            return StepActionResult(action: "type", type: result)
        case .key(let key):
            let request = KeyRequest(
                chord: key.chord,
                appIdentifier: key.app,
                windowID: key.windowId,
                foreground: key.foreground ?? false,
                session: key.session ?? presence.session,
                agentCursor: key.agentCursor ?? presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.key(request)
            }
            return StepActionResult(action: "key", key: result)
        case .keys(let step):
            let request = KeysRequest(
                steps: step.steps,
                appIdentifier: step.app,
                windowID: step.windowId,
                foreground: step.foreground ?? false,
                session: step.session ?? presence.session,
                agentCursor: step.agentCursor ?? presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.keys(request)
            }
            return StepActionResult(action: "keys", keys: result)
        case .selectText(let step):
            let request = SelectTextRequest(
                element: step.element,
                elementID: step.elementId,
                role: step.role,
                appIdentifier: step.app,
                windowID: step.windowId,
                range: step.range,
                text: step.text,
                session: step.session ?? presence.session,
                agentCursor: step.agentCursor ?? presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.selectText(request)
            }
            return StepActionResult(action: "selectText", selectText: result)
        case .action(let step):
            let request = PerformActionRequest(
                element: step.element,
                elementID: step.elementId,
                role: step.role,
                appIdentifier: step.app,
                windowID: step.windowId,
                name: step.name,
                session: step.session ?? presence.session,
                agentCursor: step.agentCursor ?? presence.agentCursor
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.performAction(request)
            }
            return StepActionResult(action: "action", performAction: result)
        case .launch(let step):
            let request = LaunchRequest(
                appIdentifier: step.app,
                timeoutMS: step.timeoutMs ?? 10_000,
                session: step.session ?? presence.session
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.launch(request)
            }
            return StepActionResult(action: "launch", launch: result)
        case .sleep(let sleep):
            SleepTimer.sleep(milliseconds: sleep.ms)
            return StepActionResult(action: "sleep", sleep: SequenceSleepResult(ms: sleep.ms))
        }
    }

    private func resolvedURL(for path: String) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(expanded)
    }
}

private struct StepActionResult {
    var action: String
    var click: ClickResult? = nil
    var scroll: ScrollResult? = nil
    var drag: DragResult? = nil
    var move: MoveResult? = nil
    var type: TypeResult? = nil
    var key: KeyResult? = nil
    var keys: KeysResult? = nil
    var selectText: SelectTextResult? = nil
    var performAction: PerformActionResult? = nil
    var launch: LaunchResult? = nil
    var sleep: SequenceSleepResult? = nil
}

struct SequenceRunResult: Codable, Sendable {
    var file: String
    var steps: [SequenceStepResult]
}

struct SequenceStepResult: Codable, Sendable {
    var index: Int
    var action: String
    var click: ClickResult?
    var scroll: ScrollResult?
    var drag: DragResult?
    var move: MoveResult?
    var type: TypeResult?
    var key: KeyResult?
    var keys: KeysResult?
    var selectText: SelectTextResult?
    /// The `action` step's result (`action` itself names the step type).
    var performAction: PerformActionResult?
    var launch: LaunchResult?
    var sleep: SequenceSleepResult?
    var preshot: ActionScreenshotResult?
    var postshot: ActionScreenshotResult?
    var diff: FrameDiffResult?
    /// Why a requested capture before or after the step is missing.
    var preshotError: ErrorDetail?
    var postshotError: ErrorDetail?
}

struct SequenceFile: Decodable {
    var steps: [SequenceStep]

    private enum CodingKeys: String, CodingKey {
        case steps
    }

    /// Checks every step before any runs, so a mistyped key fails the whole file
    /// instead of running the steps before it. Errors name the step by number.
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: SequenceAnyKey.self).allKeys.map(\.stringValue)
        if let unknown = keys.first(where: { $0 != CodingKeys.steps.rawValue }) {
            throw ScreenCommanderError.invalidArguments(
                "Unknown key '\(unknown)' at the top of the sequence file. It takes only \"steps\"."
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var list: UnkeyedDecodingContainer
        do {
            list = try container.nestedUnkeyedContainer(forKey: .steps)
        } catch {
            throw ScreenCommanderError.invalidArguments("The sequence file needs a \"steps\" array.")
        }
        var steps: [SequenceStep] = []
        while !list.isAtEnd {
            let number = list.currentIndex + 1
            do {
                steps.append(try list.decode(SequenceStep.self))
            } catch let error as SequenceStepError {
                throw ScreenCommanderError.invalidArguments("Step \(number) (\(error.step)): \(error.message)")
            } catch let error as ScreenCommanderError {
                throw ScreenCommanderError.invalidArguments("Step \(number): \(error.message)")
            } catch let error as DecodingError {
                throw ScreenCommanderError.invalidArguments("Step \(number): \(SequenceStepError.describe(error))")
            }
        }
        self.steps = steps
    }
}

/// A step that failed to decode, before its number is known.
struct SequenceStepError: Error {
    var step: String
    var message: String

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }
            return keys.isEmpty ? "the step" : "'\(keys.joined(separator: "."))'"
        }
        switch error {
        case .keyNotFound(let key, _):
            return "the required key '\(key.stringValue)' is missing."
        case .typeMismatch(let type, let context), .valueNotFound(let type, let context):
            return "\(path(context)) must be \(SequenceStepError.typeName(type))."
        case .dataCorrupted(let context):
            return "\(path(context)) is not valid: \(context.debugDescription)"
        @unknown default:
            return "\(error)"
        }
    }

    private static func typeName(_ type: Any.Type) -> String {
        switch type {
        case is String.Type: return "a string"
        case is Bool.Type: return "true or false"
        case is Double.Type, is Int.Type, is Int32.Type, is UInt32.Type: return "a number"
        case is [String].Type: return "an array of strings"
        default: return "a \(type)"
        }
    }
}

struct SequenceAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

/// A step type's fields. Every key in a step must be one of them, so a typo fails
/// instead of being ignored.
protocol SequenceStepFields: Decodable {
    static var fields: [String] { get }
}

extension SequenceStepFields {
    /// Old spellings that still decode, mapped to the documented field names, which
    /// match the MCP tools.
    static var aliases: [String: String] {
        ["durationMS": "durationMs", "dwellMS": "dwellMs", "delayMS": "delayMs", "timeoutMS": "timeoutMs"]
    }

    /// Decodes one step's object after checking its keys and renaming aliases.
    static func decodeStep(_ value: JSONValue, step: String) throws -> Self {
        guard var object = value.objectValue else {
            throw SequenceStepError(step: step, message: "the value of \"\(step)\" must be an object.")
        }
        for (alias, name) in aliases where fields.contains(name) {
            guard let aliased = object.removeValue(forKey: alias) else {
                continue
            }
            if object[name] != nil {
                throw SequenceStepError(step: step, message: "'\(alias)' and '\(name)' are the same field. Pass only '\(name)'.")
            }
            object[name] = aliased
        }
        if let unknown = object.keys.sorted().first(where: { !fields.contains($0) }) {
            throw SequenceStepError(
                step: step,
                message: "unknown key '\(unknown)'. A \(step) step takes \(fields.joined(separator: ", "))."
            )
        }
        do {
            return try JSONDecoder().decode(Self.self, from: JSONEncoder().encode(JSONValue.object(object)))
        } catch let error as DecodingError {
            throw SequenceStepError(step: step, message: SequenceStepError.describe(error))
        } catch let error as ScreenCommanderError {
            throw SequenceStepError(step: step, message: error.message)
        }
    }
}

enum SequenceStep: Decodable {
    case click(SequenceClickStep)
    case scroll(SequenceScrollStep)
    case drag(SequenceDragStep)
    case move(SequenceMoveStep)
    case type(SequenceTypeStep)
    case key(SequenceKeyStep)
    case keys(SequenceKeysStep)
    case selectText(SequenceSelectTextStep)
    case action(SequenceActionStep)
    case launch(SequenceLaunchStep)
    case sleep(SequenceSleepStep)

    static let stepNames = ["click", "scroll", "drag", "move", "type", "key", "keys", "selectText", "action", "launch", "sleep"]

    var noDiff: Bool {
        switch self {
        case .click(let step):
            return step.noDiff ?? false
        case .scroll(let step):
            return step.noDiff ?? false
        case .drag(let step):
            return step.noDiff ?? false
        case .move(let step):
            return step.noDiff ?? false
        case .type(let step):
            return step.noDiff ?? false
        case .key(let step):
            return step.noDiff ?? false
        case .keys(let step):
            return step.noDiff ?? false
        case .selectText(let step):
            return step.noDiff ?? false
        case .action(let step):
            return step.noDiff ?? false
        case .launch(let step):
            return step.noDiff ?? false
        case .sleep:
            return true
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: SequenceAnyKey.self)
        let names = container.allKeys.map(\.stringValue)
        let expected = "Each step is an object with exactly one key: "
            + Self.stepNames.dropLast().joined(separator: ", ") + ", or " + Self.stepNames.last! + "."
        guard names.count == 1, let name = names.first else {
            throw ScreenCommanderError.invalidArguments(
                names.isEmpty ? expected : "\(expected) This one has \(names.sorted().joined(separator: ", "))."
            )
        }
        guard Self.stepNames.contains(name) else {
            throw ScreenCommanderError.invalidArguments("Unknown step '\(name)'. \(expected)")
        }
        let value = try container.decode(JSONValue.self, forKey: SequenceAnyKey(stringValue: name))
        switch name {
        case "click": self = .click(try .decodeStep(value, step: name))
        case "scroll": self = .scroll(try .decodeStep(value, step: name))
        case "drag": self = .drag(try .decodeStep(value, step: name))
        case "move": self = .move(try .decodeStep(value, step: name))
        case "type": self = .type(try .decodeStep(value, step: name))
        case "key": self = .key(try .decodeStep(value, step: name))
        case "keys": self = .keys(try .decodeStep(value, step: name))
        case "selectText": self = .selectText(try .decodeStep(value, step: name))
        case "action": self = .action(try .decodeStep(value, step: name))
        case "launch": self = .launch(try .decodeStep(value, step: name))
        default: self = .sleep(try .decodeStep(value, step: name))
        }
    }
}

struct SequenceClickStep: SequenceStepFields {
    var x: Double?
    var y: Double?
    var space: CoordinateSpace?
    var meta: String?
    var button: MouseButtonChoice?
    var double: Bool?
    var triple: Bool?
    var modifiers: String?
    var prime: Bool?
    var raw: Bool?
    var element: String?
    var elementId: String?
    var role: String?
    var app: String?
    var via: InputDeliveryMethod?
    var noCursor: Bool?
    var strict: Bool?
    var strictMetadata: Bool?
    var windowId: UInt32?
    var foreground: Bool?
    var session: String?
    var agentCursor: Bool?
    var noDiff: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case x, y, space, meta, button, double, triple, modifiers, prime, raw, element, elementId, role, app, via, noCursor, strict, strictMetadata, windowId, foreground, session, agentCursor, noDiff
    }

    static var fields: [String] { CodingKeys.allCases.map(\.rawValue) }
}

struct SequenceScrollStep: SequenceStepFields {
    var x: Double?
    var y: Double?
    var dx: Int32?
    var dy: Int32?
    var unit: ScrollUnit?
    var space: CoordinateSpace?
    var meta: String?
    var element: String?
    var elementId: String?
    var role: String?
    var app: String?
    var via: InputDeliveryMethod?
    var noCursor: Bool?
    var strict: Bool?
    var strictMetadata: Bool?
    var windowId: UInt32?
    var foreground: Bool?
    var session: String?
    var agentCursor: Bool?
    var direction: ScrollDirection?
    var pages: Int?
    var noDiff: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case x, y, dx, dy, unit, space, meta, element, elementId, role, app, via, noCursor, strict, strictMetadata, windowId, foreground, session, agentCursor, direction, pages, noDiff
    }

    static var fields: [String] { CodingKeys.allCases.map(\.rawValue) }
}

struct SequenceDragStep: SequenceStepFields {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
    var button: MouseButtonChoice?
    var steps: Int?
    var durationMs: Int?
    var space: CoordinateSpace?
    var meta: String?
    var strictMetadata: Bool?
    var app: String?
    var windowId: UInt32?
    var foreground: Bool?
    var session: String?
    var agentCursor: Bool?
    var noDiff: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case x1, y1, x2, y2, button, steps, durationMs, space, meta, strictMetadata, app, windowId, foreground, session, agentCursor, noDiff
    }

    static var fields: [String] { CodingKeys.allCases.map(\.rawValue) }
}

struct SequenceMoveStep: SequenceStepFields {
    var x: Double
    var y: Double
    var dwellMs: Int?
    var space: CoordinateSpace?
    var meta: String?
    var strictMetadata: Bool?
    var app: String?
    var windowId: UInt32?
    var foreground: Bool?
    var session: String?
    var agentCursor: Bool?
    var noDiff: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case x, y, dwellMs, space, meta, strictMetadata, app, windowId, foreground, session, agentCursor, noDiff
    }

    static var fields: [String] { CodingKeys.allCases.map(\.rawValue) }
}

struct SequenceTypeStep: SequenceStepFields {
    var text: String
    var delayMs: Int?
    var mode: TextInputMode?
    var replace: Bool?
    var element: String?
    var elementId: String?
    var role: String?
    var app: String?
    var via: InputDeliveryMethod?
    var strict: Bool?
    var windowId: UInt32?
    var foreground: Bool?
    var session: String?
    var agentCursor: Bool?
    var noDiff: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case text, delayMs, mode, replace, element, elementId, role, app, via, strict, windowId, foreground, session, agentCursor, noDiff
    }

    static var fields: [String] { CodingKeys.allCases.map(\.rawValue) }
}

struct SequenceKeyStep: SequenceStepFields {
    var chord: String
    var app: String?
    var windowId: UInt32?
    var foreground: Bool?
    var session: String?
    var agentCursor: Bool?
    var noDiff: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case chord, app, windowId, foreground, session, agentCursor, noDiff
    }

    static var fields: [String] { CodingKeys.allCases.map(\.rawValue) }
}

struct SequenceKeysStep: SequenceStepFields {
    var steps: [String]
    var app: String?
    var windowId: UInt32?
    var foreground: Bool?
    var session: String?
    var agentCursor: Bool?
    var noDiff: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case steps, app, windowId, foreground, session, agentCursor, noDiff
    }

    static var fields: [String] { CodingKeys.allCases.map(\.rawValue) }
}

struct SequenceSelectTextStep: SequenceStepFields {
    var element: String?
    var elementId: String?
    var role: String?
    var app: String?
    var windowId: UInt32?
    var range: AXTextRange?
    var text: String?
    var session: String?
    var agentCursor: Bool?
    var noDiff: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case element, elementId, role, app, windowId, range, text, session, agentCursor, noDiff
    }

    static var fields: [String] { CodingKeys.allCases.map(\.rawValue) }
}

struct SequenceActionStep: SequenceStepFields {
    var name: String
    var element: String?
    var elementId: String?
    var role: String?
    var app: String?
    var windowId: UInt32?
    var session: String?
    var agentCursor: Bool?
    var noDiff: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case name, element, elementId, role, app, windowId, session, agentCursor, noDiff
    }

    static var fields: [String] { CodingKeys.allCases.map(\.rawValue) }
}

struct SequenceLaunchStep: SequenceStepFields {
    var app: String
    var timeoutMs: Int?
    var session: String?
    var noDiff: Bool?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case app, timeoutMs, session, noDiff
    }

    static var fields: [String] { CodingKeys.allCases.map(\.rawValue) }
}

struct SequenceSleepStep: SequenceStepFields {
    var ms: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case ms
    }

    static var fields: [String] { CodingKeys.allCases.map(\.rawValue) }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ms = try container.decode(Int.self, forKey: .ms)
        try InputLimits.check(ms, in: InputLimits.sequenceSleepMs, "ms")
    }
}

struct SequenceSleepResult: Codable, Sendable {
    var ms: Int
}
