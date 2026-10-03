import Foundation

struct KeySequenceParser {
    static func parse(_ rawSteps: [String]) throws -> KeySequence {
        guard !rawSteps.isEmpty else {
            throw ScreenCommanderError.invalidArguments("Key sequence must contain at least one step.")
        }

        let steps = try rawSteps.map { try parseStep($0) }
        let shortcuts = rawSteps.compactMap { raw -> String? in
            let parts = raw.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() != "sleep" else { return nil }
            return KeyCodes.systemShortcutAlias(String(parts[1]))
        }
        return KeySequence(steps: steps, systemShortcuts: shortcuts)
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
            try InputLimits.check(ms, in: InputLimits.keySleepMs, "A sleep step's milliseconds")
            return .sleep(milliseconds: ms)
        default:
            throw ScreenCommanderError.invalidArguments("Unknown step action '\(action)'. Expected down, up, press, or sleep.")
        }
    }
}
