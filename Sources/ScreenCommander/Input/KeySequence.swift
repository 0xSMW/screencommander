import CoreGraphics
import Foundation

enum KeyStep: Sendable, Equatable {
    case keyDown(ResolvedKey, flags: CGEventFlags)
    case keyUp(ResolvedKey, flags: CGEventFlags)
    case press(ResolvedKey, flags: CGEventFlags)
    case sleep(milliseconds: Int)

    var normalized: String {
        switch self {
        case .keyDown(let key, let flags):
            return normalized(prefix: "down", key: key, flags: flags)
        case .keyUp(let key, let flags):
            return normalized(prefix: "up", key: key, flags: flags)
        case .press(let key, let flags):
            return normalized(prefix: "press", key: key, flags: flags)
        case .sleep(let milliseconds):
            return "sleep:\(milliseconds)"
        }
    }

    private func normalized(prefix: String, key: ResolvedKey, flags: CGEventFlags) -> String {
        let modifiers = ModifierKey.allCases
            .filter { flags.contains($0.flag) }
            .map { $0.canonicalName }

        if modifiers.isEmpty {
            return "\(prefix):\(key.normalizedToken)"
        }
        return "\(prefix):\(modifiers.joined(separator: "+"))+\(key.normalizedToken)"
    }
}

struct KeySequence: Sendable, Equatable {
    var steps: [KeyStep]
}
