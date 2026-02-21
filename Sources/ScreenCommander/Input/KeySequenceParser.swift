import Foundation

struct KeySequenceParser {
    static func parse(_ rawSteps: [String]) throws -> KeySequence {
        guard !rawSteps.isEmpty else {
            throw ScreenCommanderError.invalidArguments("Key sequence must contain at least one step.")
        }

        let steps = try rawSteps.map { try parseStep($0) }
        return KeySequence(steps: steps)
    }

    private static func parseStep(_ raw: String) throws -> KeyStep {
        let stepText = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stepText.isEmpty else {
            throw ScreenCommanderError.invalidArguments("Empty sequence step is not allowed.")
        }

        let parts = stepText.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            throw ScreenCommanderError.invalidArguments("Invalid step format '\(stepText)'. Expected <action>:<token>.")
        }

        let action = parts[0].lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            throw ScreenCommanderError.invalidArguments("Step '\(action)' requires a target token.")
        }

        switch action {
        case "down":
            let key = try KeyCodes.parseHoldTarget(payload)
            return .keyDown(key, flags: .init())
        case "up":
            let key = try KeyCodes.parseHoldTarget(payload)
            return .keyUp(key, flags: .init())
        case "press":
            let chord = try KeyCodes.parseChord(payload)
            return .press(chord.key, flags: chord.flags)
        case "sleep":
            guard let ms = Int(payload), ms >= 0 else {
                throw ScreenCommanderError.invalidArguments("sleep duration must be a non-negative integer: '\(payload)'.")
            }
            return .sleep(milliseconds: ms)
        default:
            throw ScreenCommanderError.invalidArguments("Unknown step action '\(action)'. Expected down, up, press, or sleep.")
        }
    }
}
