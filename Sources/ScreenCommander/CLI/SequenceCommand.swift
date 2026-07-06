import ArgumentParser
import Foundation

struct SequenceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sequence",
        abstract: "Execute an ordered bundle of click/type/key actions from JSON."
    )

    @Option(name: .long, help: "Path to a sequence JSON file.")
    var file: String

    @Flag(
        name: .long,
        inversion: .prefixedNo,
        help: "Capture before/after screenshots around each step (enabled by default)."
    )
    var postshot: Bool = true

    @Flag(name: .long, help: "Skip frame diff comparison between pre- and post-action screenshots.")
    var noDiff: Bool = false

    @Flag(name: .long, help: "Emit a single machine-readable JSON object to stdout (success or error envelope). For scripting; see README.")
    var json: Bool = false

    mutating func run() throws {
        do {
            let (format, compact) = try OutputOptions.effective(jsonFlag: json)
            OutputOptions.current = (format, compact, "sequence")
            defer { OutputOptions.current = nil }
            let fileURL = resolvedURL(for: file)
            let data = try Data(contentsOf: fileURL)
            let sequence = try JSONDecoder().decode(SequenceFile.self, from: data)

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
                    skip: noDiff || step.noDiff
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
                    sleep: actionResult.sleep,
                    preshot: preshotResult?.result,
                    postshot: postshotResult?.result,
                    diff: diff
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
                primeClick: click.prime ?? false,
                humanLike: !(click.raw ?? false),
                modifiers: try MouseModifiers.parse(click.modifiers),
                element: click.element,
                elementID: click.elementId,
                role: click.role,
                appIdentifier: click.app,
                via: click.via,
                noCursor: click.noCursor ?? false,
                strict: click.strict ?? false
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
                strict: scroll.strict ?? false
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.scroll(request)
            }
            return StepActionResult(action: "scroll", scroll: result)
        case .drag(let drag):
            let result = try CommandRuntime.engine.drag(
                DragRequest(
                    x1: drag.x1,
                    y1: drag.y1,
                    x2: drag.x2,
                    y2: drag.y2,
                    coordinateSpace: drag.space ?? .pixels,
                    metadataPath: drag.meta,
                    button: drag.button ?? .left,
                    steps: drag.steps ?? 12,
                    durationMS: drag.durationMS ?? 300
                )
            )
            return StepActionResult(action: "drag", drag: result)
        case .move(let move):
            let result = try CommandRuntime.engine.move(
                MoveRequest(
                    x: move.x,
                    y: move.y,
                    coordinateSpace: move.space ?? .pixels,
                    metadataPath: move.meta,
                    dwellMS: move.dwellMS ?? 0
                )
            )
            return StepActionResult(action: "move", move: result)
        case .type(let type):
            let request = TypeRequest(
                text: type.text,
                delayMilliseconds: type.delayMS,
                inputMode: type.mode ?? .paste,
                element: type.element,
                elementID: type.elementId,
                role: type.role,
                appIdentifier: type.app,
                via: type.via,
                strict: type.strict ?? false
            )
            let result = try AsyncBridge.run {
                try await CommandRuntime.engine.type(request)
            }
            return StepActionResult(action: "type", type: result)
        case .key(let key):
            let result = try CommandRuntime.engine.key(KeyRequest(chord: key.chord))
            return StepActionResult(action: "key", key: result)
        case .sleep(let sleep):
            guard sleep.ms >= 0 else {
                throw ScreenCommanderError.invalidArguments("sleep.ms must be greater than or equal to zero.")
            }
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
    var sleep: SequenceSleepResult?
    var preshot: ActionScreenshotResult?
    var postshot: ActionScreenshotResult?
    var diff: FrameDiffResult?
}

struct SequenceFile: Decodable {
    var steps: [SequenceStep]
}

enum SequenceStep: Decodable {
    case click(SequenceClickStep)
    case scroll(SequenceScrollStep)
    case drag(SequenceDragStep)
    case move(SequenceMoveStep)
    case type(SequenceTypeStep)
    case key(SequenceKeyStep)
    case sleep(SequenceSleepStep)

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
        case .sleep:
            return true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case click
        case scroll
        case drag
        case move
        case type
        case key
        case sleep
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let presentKeys = container.allKeys
        guard presentKeys.count == 1 else {
            throw ScreenCommanderError.invalidArguments(
                "Each sequence step must contain exactly one key: click, scroll, drag, move, type, key, or sleep."
            )
        }

        if container.contains(.click) {
            self = .click(try container.decode(SequenceClickStep.self, forKey: .click))
            return
        }
        if container.contains(.scroll) {
            self = .scroll(try container.decode(SequenceScrollStep.self, forKey: .scroll))
            return
        }
        if container.contains(.drag) {
            self = .drag(try container.decode(SequenceDragStep.self, forKey: .drag))
            return
        }
        if container.contains(.move) {
            self = .move(try container.decode(SequenceMoveStep.self, forKey: .move))
            return
        }
        if container.contains(.type) {
            self = .type(try container.decode(SequenceTypeStep.self, forKey: .type))
            return
        }
        if container.contains(.key) {
            self = .key(try container.decode(SequenceKeyStep.self, forKey: .key))
            return
        }
        if container.contains(.sleep) {
            self = .sleep(try container.decode(SequenceSleepStep.self, forKey: .sleep))
            return
        }

        throw ScreenCommanderError.invalidArguments(
            "Each sequence step must contain exactly one key: click, scroll, drag, move, type, key, or sleep."
        )
    }
}

struct SequenceClickStep: Decodable {
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
    var noDiff: Bool?
}

struct SequenceScrollStep: Decodable {
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
    var noDiff: Bool?
}

struct SequenceDragStep: Decodable {
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
    var button: MouseButtonChoice?
    var steps: Int?
    var durationMS: Int?
    var space: CoordinateSpace?
    var meta: String?
    var noDiff: Bool?
}

struct SequenceMoveStep: Decodable {
    var x: Double
    var y: Double
    var dwellMS: Int?
    var space: CoordinateSpace?
    var meta: String?
    var noDiff: Bool?
}

struct SequenceTypeStep: Decodable {
    var text: String
    var delayMS: Int?
    var mode: TextInputMode?
    var element: String?
    var elementId: String?
    var role: String?
    var app: String?
    var via: InputDeliveryMethod?
    var strict: Bool?
    var noDiff: Bool?
}

struct SequenceKeyStep: Decodable {
    var chord: String
    var noDiff: Bool?
}

struct SequenceSleepStep: Decodable {
    var ms: Int
}

struct SequenceSleepResult: Codable, Sendable {
    var ms: Int
}
