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

    @Flag(name: .long, help: "Emit machine-readable JSON output.")
    var json: Bool = false

    mutating func run() throws {
        do {
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

                let stepResult = SequenceStepResult(
                    index: index + 1,
                    action: actionResult.action,
                    click: actionResult.click,
                    type: actionResult.type,
                    key: actionResult.key,
                    preshot: preshotResult,
                    postshot: postshotResult
                )
                outputs.append(stepResult)

                if !json {
                    print("Step \(stepResult.index): \(stepResult.action) ok")
                }
            }

            let result = SequenceRunResult(file: fileURL.path, steps: outputs)
            if json {
                try CommandRuntime.emitJSON(command: "sequence", result: result)
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
            let result = try CommandRuntime.engine.click(
                ClickRequest(
                    x: click.x,
                    y: click.y,
                    coordinateSpace: click.space ?? .pixels,
                    metadataPath: click.meta,
                    button: click.button ?? .left,
                    doubleClick: click.double ?? false,
                    primeClick: click.prime ?? false,
                    humanLike: !(click.raw ?? false)
                )
            )
            return StepActionResult(action: "click", click: result, type: nil, key: nil)
        case .type(let type):
            let result = try CommandRuntime.engine.type(
                TypeRequest(
                    text: type.text,
                    delayMilliseconds: type.delayMS,
                    inputMode: type.mode ?? .paste
                )
            )
            return StepActionResult(action: "type", click: nil, type: result, key: nil)
        case .key(let key):
            let result = try CommandRuntime.engine.key(KeyRequest(chord: key.chord))
            return StepActionResult(action: "key", click: nil, type: nil, key: result)
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
    var click: ClickResult?
    var type: TypeResult?
    var key: KeyResult?
}

struct SequenceRunResult: Codable, Sendable {
    var file: String
    var steps: [SequenceStepResult]
}

struct SequenceStepResult: Codable, Sendable {
    var index: Int
    var action: String
    var click: ClickResult?
    var type: TypeResult?
    var key: KeyResult?
    var preshot: ActionScreenshotResult?
    var postshot: ActionScreenshotResult?
}

struct SequenceFile: Decodable {
    var steps: [SequenceStep]
}

enum SequenceStep: Decodable {
    case click(SequenceClickStep)
    case type(SequenceTypeStep)
    case key(SequenceKeyStep)

    private enum CodingKeys: String, CodingKey {
        case click
        case type
        case key
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.click) {
            self = .click(try container.decode(SequenceClickStep.self, forKey: .click))
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

        throw ScreenCommanderError.invalidArguments(
            "Each sequence step must contain exactly one key: click, type, or key."
        )
    }
}

struct SequenceClickStep: Decodable {
    var x: Double
    var y: Double
    var space: CoordinateSpace?
    var meta: String?
    var button: MouseButtonChoice?
    var double: Bool?
    var prime: Bool?
    var raw: Bool?
}

struct SequenceTypeStep: Decodable {
    var text: String
    var delayMS: Int?
    var mode: TextInputMode?
}

struct SequenceKeyStep: Decodable {
    var chord: String
}
