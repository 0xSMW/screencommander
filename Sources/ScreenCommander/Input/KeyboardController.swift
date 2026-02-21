import AppKit
import CoreGraphics
import Foundation
import Carbon.HIToolbox

protocol KeyboardControlling {
    func type(text: String, delayMilliseconds: Int?) throws
    func typeByPasting(text: String) throws
    func press(chord: ParsedKeyChord) throws
    func pressSystemKey(_ key: SystemKey) throws
    func run(sequence: KeySequence) throws
}

final class KeyboardController: KeyboardControlling {
    private let enterKeyDownHoldMicroseconds: useconds_t = 20_000
    private let systemDownState = Int(0xA)
    private let systemUpState = Int(0xB)
    private let systemAuxControlSubtype = Int16(0x08)

    func type(text: String, delayMilliseconds: Int?) throws {
        let source = try makeEventSource()

        let delay = max(0, delayMilliseconds ?? 0)

        for character in text {
            try postUnicodeCharacter(String(character), source: source)
            if delay > 0 {
                usleep(useconds_t(delay * 1_000))
            }
        }
    }

    func typeByPasting(text: String) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard pasteboard.setString(text, forType: .string) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not set clipboard text for paste input.")
        }

        let pasteChord = try KeyCodes.parseChord("cmd+v")
        try press(chord: pasteChord)
    }

    func press(chord: ParsedKeyChord) throws {
        let source = try makeEventSource()

        if case .system(let systemKey, _) = chord.key {
            if !chord.modifiers.isEmpty {
                throw ScreenCommanderError.invalidArguments("Modifiers are not supported with system keys.")
            }

            try pressSystemKey(systemKey)
            return
        }

        try runModifiersForStep(flags: chord.flags, source: source, pressed: true)

        try postKeyboardEvent(
            keyCode: chord.key.keyboardCode,
            keyDown: true,
            flags: chord.flags,
            source: source
        )

        if chord.key.keyboardCode == CGKeyCode(kVK_Return) {
            usleep(enterKeyDownHoldMicroseconds)
        }

        try postKeyboardEvent(
            keyCode: chord.key.keyboardCode,
            keyDown: false,
            flags: chord.flags,
            source: source
        )

        try runModifiersForStep(flags: chord.flags, source: source, pressed: false)
    }

    func pressSystemKey(_ key: SystemKey) throws {
        try postSystemKeyEvent(systemCode: key.nxKeyCode, keyDown: true)
        usleep(enterKeyDownHoldMicroseconds)
        try postSystemKeyEvent(systemCode: key.nxKeyCode, keyDown: false)
    }

    func run(sequence: KeySequence) throws {
        let source = try makeEventSource()

        for step in sequence.steps {
            switch step {
            case .keyDown(let key, let flags):
                try handleStepKeyDown(key: key, flags: flags, source: source)
            case .keyUp(let key, let flags):
                try handleStepKeyUp(key: key, flags: flags, source: source)
            case .press(let key, let flags):
                switch key {
                case .keyboard:
                    try runModifiersForStep(flags: flags, source: source, pressed: true)
                    try postResolvedKey(key: key, keyDown: true, flags: flags, source: source)
                    try postResolvedKey(key: key, keyDown: false, flags: flags, source: source)
                    try runModifiersForStep(flags: flags, source: source, pressed: false)
                case .system(let systemKey, _):
                    if !flags.isEmpty {
                        throw ScreenCommanderError.invalidArguments("Modifiers are not supported with system key steps.")
                    }
                    try pressSystemKey(systemKey)
                }
            case .sleep(let milliseconds):
                if milliseconds > 0 {
                    usleep(useconds_t(milliseconds * 1_000))
                }
            }
        }
    }

    private func handleStepKeyDown(key: ResolvedKey, flags: CGEventFlags, source: CGEventSource) throws {
        switch key {
        case .keyboard:
            try runModifiersForStep(flags: flags, source: source, pressed: true)
            try postResolvedKey(key: key, keyDown: true, flags: flags, source: source)
        case .system(let systemKey, _):
            if !flags.isEmpty {
                throw ScreenCommanderError.invalidArguments("Modifiers are not supported with system key steps.")
            }
            try postSystemKeyEvent(systemCode: systemKey.nxKeyCode, keyDown: true)
        }
    }

    private func handleStepKeyUp(key: ResolvedKey, flags: CGEventFlags, source: CGEventSource) throws {
        switch key {
        case .keyboard:
            try postResolvedKey(key: key, keyDown: false, flags: flags, source: source)
            try runModifiersForStep(flags: flags, source: source, pressed: false)
        case .system(let systemKey, _):
            if !flags.isEmpty {
                throw ScreenCommanderError.invalidArguments("Modifiers are not supported with system key steps.")
            }
            try postSystemKeyEvent(systemCode: systemKey.nxKeyCode, keyDown: false)
        }
    }

    private func postResolvedKey(key: ResolvedKey, keyDown: Bool, flags: CGEventFlags, source: CGEventSource) throws {
        guard let keyCode = key.keyboardCode else {
            throw ScreenCommanderError.inputSynthesisFailed("Unable to post unsupported key type.")
        }

        try postKeyboardEvent(
            keyCode: keyCode,
            keyDown: keyDown,
            flags: flags,
            source: source
        )
    }

    private func runModifiersForStep(flags: CGEventFlags, source: CGEventSource, pressed: Bool) throws {
        let modifiers = modifierKeys(from: flags)
        if pressed {
            for modifier in modifiers where !modifier.isFnOnlyFlag {
                try postKeyCode(modifier.keyCode, keyDown: true, flags: flags, source: source)
            }
        } else {
            for modifier in modifiers.reversed() where !modifier.isFnOnlyFlag {
                try postKeyCode(modifier.keyCode, keyDown: false, flags: flags, source: source)
            }
        }
    }

    private func modifierKeys(from flags: CGEventFlags) -> [ModifierKey] {
        ModifierKey.allCases.filter { flags.contains($0.flag) }
    }

    private func postKeyboardEvent(
        keyCode: CGKeyCode?,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource
    ) throws {
        guard let keyCode else {
            throw ScreenCommanderError.inputSynthesisFailed("Unable to post key event without keycode.")
        }

        try postKeyCode(keyCode, keyDown: keyDown, flags: flags, source: source)
    }

    private func postKeyCode(_ keyCode: CGKeyCode?, keyDown: Bool, flags: CGEventFlags, source: CGEventSource) throws {
        guard let keyCode else {
            throw ScreenCommanderError.inputSynthesisFailed("Unable to post key event without keycode.")
        }

        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create key event for keycode \(keyCode).")
        }

        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    private func postSystemKeyEvent(systemCode: Int64, keyDown: Bool) throws {
        let state = keyDown ? systemDownState : systemUpState
        let data1 = Int((systemCode << 16) | (Int64(state) << 8))

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: systemAuxControlSubtype,
            data1: data1,
            data2: 0
        ) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not construct system-defined event for system key.")
        }

        guard let cgEvent = event.cgEvent else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not convert system-defined event for system key.")
        }

        cgEvent.post(tap: .cghidEventTap)
    }

    private func postUnicodeCharacter(_ character: String, source: CGEventSource) throws {
        let utf16 = Array(character.utf16)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create Unicode keyboard events.")
        }

        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func makeEventSource() throws -> CGEventSource {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create keyboard event source.")
        }
        return source
    }
}

private extension ModifierKey {
    var isFnOnlyFlag: Bool {
        self == .fn
    }
}
