import CoreGraphics
import Foundation
import Carbon.HIToolbox

struct ParsedKeyChord {
    let raw: String
    let keyToken: String
    let keyCode: CGKeyCode
    let modifiers: [ModifierKey]

    var flags: CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { partialResult, modifier in
            partialResult.formUnion(modifier.flag)
        }
    }

    var normalized: String {
        if modifiers.isEmpty {
            return keyToken
        }
        let modifiersText = modifiers.map(\.canonicalName).joined(separator: "+")
        return "\(modifiersText)+\(keyToken)"
    }
}

enum ModifierKey: String, CaseIterable {
    case command
    case shift
    case option
    case control

    var canonicalName: String {
        switch self {
        case .command:
            return "cmd"
        case .shift:
            return "shift"
        case .option:
            return "option"
        case .control:
            return "ctrl"
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .command:
            return .maskCommand
        case .shift:
            return .maskShift
        case .option:
            return .maskAlternate
        case .control:
            return .maskControl
        }
    }

    var keyCode: CGKeyCode {
        switch self {
        case .command:
            return CGKeyCode(kVK_Command)
        case .shift:
            return CGKeyCode(kVK_Shift)
        case .option:
            return CGKeyCode(kVK_Option)
        case .control:
            return CGKeyCode(kVK_Control)
        }
    }

    static func parse(_ token: String) -> ModifierKey? {
        switch token {
        case "cmd", "command", "meta":
            return .command
        case "shift":
            return .shift
        case "opt", "option", "alt":
            return .option
        case "ctrl", "control":
            return .control
        default:
            return nil
        }
    }
}

enum KeyCodes {
    private static let keyMap: [String: CGKeyCode] = {
        var map: [String: CGKeyCode] = [
            "a": CGKeyCode(kVK_ANSI_A),
            "b": CGKeyCode(kVK_ANSI_B),
            "c": CGKeyCode(kVK_ANSI_C),
            "d": CGKeyCode(kVK_ANSI_D),
            "e": CGKeyCode(kVK_ANSI_E),
            "f": CGKeyCode(kVK_ANSI_F),
            "g": CGKeyCode(kVK_ANSI_G),
            "h": CGKeyCode(kVK_ANSI_H),
            "i": CGKeyCode(kVK_ANSI_I),
            "j": CGKeyCode(kVK_ANSI_J),
            "k": CGKeyCode(kVK_ANSI_K),
            "l": CGKeyCode(kVK_ANSI_L),
            "m": CGKeyCode(kVK_ANSI_M),
            "n": CGKeyCode(kVK_ANSI_N),
            "o": CGKeyCode(kVK_ANSI_O),
            "p": CGKeyCode(kVK_ANSI_P),
            "q": CGKeyCode(kVK_ANSI_Q),
            "r": CGKeyCode(kVK_ANSI_R),
            "s": CGKeyCode(kVK_ANSI_S),
            "t": CGKeyCode(kVK_ANSI_T),
            "u": CGKeyCode(kVK_ANSI_U),
            "v": CGKeyCode(kVK_ANSI_V),
            "w": CGKeyCode(kVK_ANSI_W),
            "x": CGKeyCode(kVK_ANSI_X),
            "y": CGKeyCode(kVK_ANSI_Y),
            "z": CGKeyCode(kVK_ANSI_Z),
            "0": CGKeyCode(kVK_ANSI_0),
            "1": CGKeyCode(kVK_ANSI_1),
            "2": CGKeyCode(kVK_ANSI_2),
            "3": CGKeyCode(kVK_ANSI_3),
            "4": CGKeyCode(kVK_ANSI_4),
            "5": CGKeyCode(kVK_ANSI_5),
            "6": CGKeyCode(kVK_ANSI_6),
            "7": CGKeyCode(kVK_ANSI_7),
            "8": CGKeyCode(kVK_ANSI_8),
            "9": CGKeyCode(kVK_ANSI_9),
            "-": CGKeyCode(kVK_ANSI_Minus),
            "=": CGKeyCode(kVK_ANSI_Equal),
            "[": CGKeyCode(kVK_ANSI_LeftBracket),
            "]": CGKeyCode(kVK_ANSI_RightBracket),
            "\\": CGKeyCode(kVK_ANSI_Backslash),
            ";": CGKeyCode(kVK_ANSI_Semicolon),
            "'": CGKeyCode(kVK_ANSI_Quote),
            ",": CGKeyCode(kVK_ANSI_Comma),
            ".": CGKeyCode(kVK_ANSI_Period),
            "/": CGKeyCode(kVK_ANSI_Slash),
            "`": CGKeyCode(kVK_ANSI_Grave),
            "enter": CGKeyCode(kVK_Return),
            "return": CGKeyCode(kVK_Return),
            "tab": CGKeyCode(kVK_Tab),
            "escape": CGKeyCode(kVK_Escape),
            "esc": CGKeyCode(kVK_Escape),
            "delete": CGKeyCode(kVK_Delete),
            "forwarddelete": CGKeyCode(kVK_ForwardDelete),
            "space": CGKeyCode(kVK_Space),
            "left": CGKeyCode(kVK_LeftArrow),
            "right": CGKeyCode(kVK_RightArrow),
            "up": CGKeyCode(kVK_UpArrow),
            "down": CGKeyCode(kVK_DownArrow)
        ]

        map["leftarrow"] = CGKeyCode(kVK_LeftArrow)
        map["rightarrow"] = CGKeyCode(kVK_RightArrow)
        map["uparrow"] = CGKeyCode(kVK_UpArrow)
        map["downarrow"] = CGKeyCode(kVK_DownArrow)

        return map
    }()

    static func parseChord(_ rawChord: String) throws -> ParsedKeyChord {
        let tokens = rawChord
            .split(separator: "+", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        guard !tokens.isEmpty else {
            throw ScreenCommanderError.invalidArguments("Chord cannot be empty.")
        }

        var modifiers: [ModifierKey] = []
        var keyToken: String?
        var keyCode: CGKeyCode?

        for token in tokens {
            guard !token.isEmpty else {
                throw ScreenCommanderError.invalidArguments("Chord contains an empty token. Use format like cmd+shift+4.")
            }

            if let modifier = ModifierKey.parse(token) {
                if !modifiers.contains(modifier) {
                    modifiers.append(modifier)
                }
                continue
            }

            guard keyToken == nil else {
                throw ScreenCommanderError.invalidArguments("Chord must contain exactly one non-modifier key token.")
            }

            guard let resolvedCode = keyMap[token] else {
                throw ScreenCommanderError.invalidArguments("Unsupported key token '\(token)'.")
            }

            keyToken = token
            keyCode = resolvedCode
        }

        guard let keyToken, let keyCode else {
            throw ScreenCommanderError.invalidArguments("Chord must include a non-modifier key, for example cmd+shift+4 or enter.")
        }

        let orderedModifiers = ordered(modifiers)

        return ParsedKeyChord(
            raw: rawChord,
            keyToken: keyToken,
            keyCode: keyCode,
            modifiers: orderedModifiers
        )
    }

    private static func ordered(_ modifiers: [ModifierKey]) -> [ModifierKey] {
        let preferredOrder: [ModifierKey] = [.command, .shift, .option, .control]
        return preferredOrder.filter { modifiers.contains($0) }
    }
}
