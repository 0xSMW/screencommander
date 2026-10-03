import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct ParsedKeyChord {
    let raw: String
    let key: ResolvedKey
    let modifiers: [ModifierKey]
    /// Set when the chord came from an alias for a system-wide shortcut
    /// (`spotlight`, `raycast`, `missioncontrol`). Those only mean something when
    /// posted globally. A raw chord such as `cmd+space` leaves this nil.
    var systemShortcut: String? = nil

    var flags: CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { partialResult, modifier in
            partialResult.formUnion(modifier.flag)
        }
    }

    var normalized: String {
        let keyToken = key.normalizedToken
        if modifiers.isEmpty {
            return keyToken
        }

        let modifiersText = modifiers.map(\.canonicalName).joined(separator: "+")
        return "\(modifiersText)+\(keyToken)"
    }
}

enum ResolvedKey: Equatable, Sendable {
    case keyboard(keyCode: CGKeyCode, token: String)
    case system(SystemKey, token: String)

    var normalizedToken: String {
        switch self {
        case .keyboard(_, let token):
            return token
        case .system(_, let token):
            return token
        }
    }

    var keyboardCode: CGKeyCode? {
        switch self {
        case .keyboard(let keyCode, _):
            return keyCode
        case .system:
            return nil
        }
    }
}

enum ModifierKey: String, CaseIterable {
    case command
    case shift
    case option
    case control
    case fn

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
        case .fn:
            return "fn"
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
        case .fn:
            return .maskSecondaryFn
        }
    }

    var keyCode: CGKeyCode? {
        switch self {
        case .command:
            return CGKeyCode(kVK_Command)
        case .shift:
            return CGKeyCode(kVK_Shift)
        case .option:
            return CGKeyCode(kVK_Option)
        case .control:
            return CGKeyCode(kVK_Control)
        case .fn:
            return nil
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
        case "fn":
            return .fn
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
            "space": CGKeyCode(kVK_Space),
            "tab": CGKeyCode(kVK_Tab),
            "enter": CGKeyCode(kVK_Return),
            "return": CGKeyCode(kVK_Return),
            "esc": CGKeyCode(kVK_Escape),
            "escape": CGKeyCode(kVK_Escape),
            "delete": CGKeyCode(kVK_Delete),
            "forwarddelete": CGKeyCode(kVK_ForwardDelete),
            "left": CGKeyCode(kVK_LeftArrow),
            "right": CGKeyCode(kVK_RightArrow),
            "up": CGKeyCode(kVK_UpArrow),
            "down": CGKeyCode(kVK_DownArrow),
            "leftarrow": CGKeyCode(kVK_LeftArrow),
            "rightarrow": CGKeyCode(kVK_RightArrow),
            "uparrow": CGKeyCode(kVK_UpArrow),
            "downarrow": CGKeyCode(kVK_DownArrow),
            "f1": CGKeyCode(kVK_F1),
            "f2": CGKeyCode(kVK_F2),
            "f3": CGKeyCode(kVK_F3),
            "f4": CGKeyCode(kVK_F4),
            "f5": CGKeyCode(kVK_F5),
            "f6": CGKeyCode(kVK_F6),
            "f7": CGKeyCode(kVK_F7),
            "f8": CGKeyCode(kVK_F8),
            "f9": CGKeyCode(kVK_F9),
            "f10": CGKeyCode(kVK_F10),
            "f11": CGKeyCode(kVK_F11),
            "f12": CGKeyCode(kVK_F12),
            "f13": CGKeyCode(kVK_F13),
            "f14": CGKeyCode(kVK_F14),
            "f15": CGKeyCode(kVK_F15),
            "f16": CGKeyCode(kVK_F16),
            "f17": CGKeyCode(kVK_F17),
            "f18": CGKeyCode(kVK_F18),
            "f19": CGKeyCode(kVK_F19),
            "f20": CGKeyCode(kVK_F20),
            "home": CGKeyCode(kVK_Home),
            "end": CGKeyCode(kVK_End),
            "pageup": CGKeyCode(kVK_PageUp),
            "pgup": CGKeyCode(kVK_PageUp),
            "pagedown": CGKeyCode(kVK_PageDown),
            "pgdown": CGKeyCode(kVK_PageDown),
            "capslock": CGKeyCode(kVK_CapsLock),
            "help": CGKeyCode(kVK_Help),
            "keypad0": CGKeyCode(kVK_ANSI_Keypad0),
            "keypad1": CGKeyCode(kVK_ANSI_Keypad1),
            "keypad2": CGKeyCode(kVK_ANSI_Keypad2),
            "keypad3": CGKeyCode(kVK_ANSI_Keypad3),
            "keypad4": CGKeyCode(kVK_ANSI_Keypad4),
            "keypad5": CGKeyCode(kVK_ANSI_Keypad5),
            "keypad6": CGKeyCode(kVK_ANSI_Keypad6),
            "keypad7": CGKeyCode(kVK_ANSI_Keypad7),
            "keypad8": CGKeyCode(kVK_ANSI_Keypad8),
            "keypad9": CGKeyCode(kVK_ANSI_Keypad9),
            "keypad+": CGKeyCode(kVK_ANSI_KeypadPlus),
            "keypad-": CGKeyCode(kVK_ANSI_KeypadMinus),
            "keypad*": CGKeyCode(kVK_ANSI_KeypadMultiply),
            "keypad/": CGKeyCode(kVK_ANSI_KeypadDivide),
            "keypad.": CGKeyCode(kVK_ANSI_KeypadDecimal),
            "keypadenter": CGKeyCode(kVK_ANSI_KeypadEnter)
        ]

        return map
    }()

    static func parseResolvedKey(_ raw: String) throws -> ResolvedKey {
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !token.isEmpty else {
            throw ScreenCommanderError.invalidArguments("Key token cannot be empty.")
        }

        if let modifier = ModifierKey.parse(token), let keyCode = modifier.keyCode {
            return .keyboard(keyCode: keyCode, token: modifier.canonicalName)
        }

        if let resolved = resolveNamedKeyboardToken(token) {
            return resolved
        }

        throw ScreenCommanderError.invalidArguments("Unsupported key token '\(token)'.")
    }

    static func parseChord(_ rawChord: String) throws -> ParsedKeyChord {
        let normalized = rawChord
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let alias = parseNamedChord(normalized, raw: rawChord) {
            return alias
        }

        if normalized.contains(" ") && !normalized.contains("+") {
            let spaceTokens = normalized
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { String($0) }
            return try parseTokenChord(tokens: spaceTokens, raw: rawChord)
        }

        let tokens = normalized
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }

        return try parseTokenChord(tokens: tokens, raw: rawChord)
    }

    private static func parseTokenChord(tokens: [String], raw: String) throws -> ParsedKeyChord {
        var tokens = tokens

        if tokens.last == "" && tokens.count >= 2 && tokens[tokens.count - 2] == "keypad" {
            tokens.removeLast()
            tokens[tokens.count - 1] = "keypad+"
        }

        guard !tokens.isEmpty else {
            throw ScreenCommanderError.invalidArguments("Chord cannot be empty.")
        }

        var modifiers: [ModifierKey] = []
        var key: ResolvedKey?

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

            guard key == nil else {
                throw ScreenCommanderError.invalidArguments("Chord must contain exactly one non-modifier key token.")
            }

            if let resolved = resolveNamedKeyboardToken(token) {
                if case .system = resolved, !modifiers.isEmpty {
                    throw ScreenCommanderError.invalidArguments("Modifiers are not supported with system keys such as '\(token)'.")
                }
                key = resolved
                continue
            }

            throw ScreenCommanderError.invalidArguments("Unsupported key token '\(token)'.")
        }

        guard let resolvedKey = key else {
            throw ScreenCommanderError.invalidArguments("Chord must include a non-modifier key, for example cmd+shift+4 or enter.")
        }

        return ParsedKeyChord(
            raw: raw,
            key: resolvedKey,
            modifiers: ordered(modifiers)
        )
    }

    static func parseHoldTarget(_ raw: String) throws -> ResolvedKey {
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !token.isEmpty else {
            throw ScreenCommanderError.invalidArguments("Sequence key token cannot be empty.")
        }

        if let modifier = ModifierKey.parse(token) {
            guard let keyCode = modifier.keyCode else {
                throw ScreenCommanderError.invalidArguments("Modifier '\(token)' cannot be used in a hold/release step.")
            }
            return .keyboard(keyCode: keyCode, token: modifier.canonicalName)
        }

        if let named = resolveNamedKeyboardToken(token) {
            return named
        }

        throw ScreenCommanderError.invalidArguments("Unsupported key token '\(token)'.")
    }

    private static func ordered(_ modifiers: [ModifierKey]) -> [ModifierKey] {
        let preferredOrder: [ModifierKey] = [.command, .shift, .option, .control, .fn]
        return preferredOrder.filter { modifiers.contains($0) }
    }

    private static func parseNamedChord(_ token: String, raw: String) -> ParsedKeyChord? {
        if let macro = resolveNamedMacroChord(token) {
            return ParsedKeyChord(raw: raw, key: macro.key, modifiers: macro.modifiers,
                                  systemShortcut: systemShortcutAlias(token))
        }

        return nil
    }

    /// The canonical name when `token` is an alias for a system-wide shortcut.
    static func systemShortcutAlias(_ token: String) -> String? {
        switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "spotlight": return "spotlight"
        case "raycast": return "raycast"
        case "missioncontrol", "mission-control", "mission_control": return "missioncontrol"
        default: return nil
        }
    }

    /// Chords macOS itself takes before any app sees them: the app switcher,
    /// Spotlight, Force Quit, Lock Screen, Log Out, and the screenshot shortcuts.
    /// Sent to an app in the background they arrive as ordinary keys and do
    /// nothing, so without `--foreground` they are refused. Kept to chords no app
    /// handles itself.
    static let systemWideChords = [
        "cmd+tab", "cmd+shift+tab",
        "cmd+space", "cmd+option+space",
        "cmd+option+esc",
        "cmd+ctrl+q", "cmd+shift+q",
        "cmd+shift+3", "cmd+shift+4", "cmd+shift+5",
        "cmd+shift+ctrl+3", "cmd+shift+ctrl+4",
    ]

    private static let systemWideChordKeys: [CGKeyCode: [(flags: CGEventFlags, name: String)]] = {
        var table: [CGKeyCode: [(flags: CGEventFlags, name: String)]] = [:]
        for raw in systemWideChords {
            guard let chord = try? parseChord(raw), case .keyboard(let keyCode, _) = chord.key else {
                continue
            }
            table[keyCode, default: []].append((chord.flags, chord.normalized))
        }
        return table
    }()

    static let chordModifierMask: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    /// The normalized name of a system-wide chord, when this key and these
    /// modifiers are one. Fn is ignored.
    static func systemWideChord(keyCode: CGKeyCode, flags: CGEventFlags) -> String? {
        let modifiers = flags.intersection(chordModifierMask)
        return systemWideChordKeys[keyCode]?.first { $0.flags == modifiers }?.name
    }

    static func systemWideChord(_ chord: ParsedKeyChord) -> String? {
        guard case .keyboard(let keyCode, _) = chord.key else {
            return nil
        }
        return systemWideChord(keyCode: keyCode, flags: chord.flags)
    }

    /// The first system-wide chord a key sequence presses, counting modifiers held
    /// down by earlier `down:` steps.
    static func systemWideChord(in sequence: KeySequence) -> String? {
        var held = CGEventFlags()
        for step in sequence.steps {
            switch step {
            case .keyDown(.keyboard(let keyCode, _), let flags):
                if let modifier = KeyboardController.modifierFlag(forKeyCode: keyCode) {
                    held.insert(modifier)
                } else if let name = systemWideChord(keyCode: keyCode, flags: held.union(flags)) {
                    return name
                }
            case .keyUp(.keyboard(let keyCode, _), _):
                if let modifier = KeyboardController.modifierFlag(forKeyCode: keyCode) {
                    held.remove(modifier)
                }
            case .press(.keyboard(let keyCode, _), let flags):
                if let name = systemWideChord(keyCode: keyCode, flags: held.union(flags)) {
                    return name
                }
            default:
                break
            }
        }
        return nil
    }

    /// The `background_delivery_unavailable` reason for a system-wide chord.
    static func systemWideChordRefusal(_ name: String) -> String {
        "'\(name)' is a system-wide shortcut that macOS handles before any app sees it. Sent to an app in the "
            + "background it would arrive as ordinary keys and do nothing, so it needs --foreground."
    }

    /// The `background_delivery_unavailable` reason for a system-wide shortcut alias.
    static func systemShortcutRefusal(_ alias: String) -> String {
        "'\(alias)' is a system-wide shortcut and needs --foreground. Sent in the background it would only reach the target app, where it does nothing useful."
    }

    private static func resolveNamedMacroChord(_ token: String) -> (key: ResolvedKey, modifiers: [ModifierKey])? {
        switch token {
        case "spotlight", "raycast":
            return (
                key: .keyboard(keyCode: CGKeyCode(kVK_Space), token: "space"),
                modifiers: [.command]
            )
        case "missioncontrol", "mission-control", "mission_control":
            return (
                key: .keyboard(keyCode: CGKeyCode(kVK_F3), token: token),
                modifiers: []
            )
        default:
            return nil
        }
    }

    private static func resolveNamedKeyboardToken(_ token: String) -> ResolvedKey? {
        if let keyCode = keyMap[token] {
            return .keyboard(keyCode: keyCode, token: token)
        }

        if let system = SystemKey.resolve(token) {
            return .system(system, token: system.rawValue)
        }

        switch token {
        case "missioncontrol", "mission-control", "mission_control":
            return .keyboard(keyCode: CGKeyCode(kVK_F3), token: token)
        default:
            return nil
        }
    }
}
