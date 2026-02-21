import AppKit
import CoreGraphics
import Foundation
import Carbon.HIToolbox

protocol KeyboardControlling {
    func type(text: String, delayMilliseconds: Int?) throws
    func typeByPasting(text: String) throws
    func press(chord: ParsedKeyChord) throws
}

final class KeyboardController: KeyboardControlling {
    private let enterKeyDownHoldMicroseconds: useconds_t = 20_000

    func type(text: String, delayMilliseconds: Int?) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create keyboard event source.")
        }

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
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create keyboard event source.")
        }

        var currentFlags = CGEventFlags()

        for modifier in chord.modifiers {
            currentFlags.formUnion(modifier.flag)
            try postKey(
                keyCode: modifier.keyCode,
                keyDown: true,
                flags: currentFlags,
                source: source
            )
        }

        try postKey(
            keyCode: chord.keyCode,
            keyDown: true,
            flags: currentFlags,
            source: source
        )
        if chord.keyCode == CGKeyCode(kVK_Return) {
            usleep(enterKeyDownHoldMicroseconds)
        }
        try postKey(
            keyCode: chord.keyCode,
            keyDown: false,
            flags: currentFlags,
            source: source
        )

        for modifier in chord.modifiers.reversed() {
            currentFlags.remove(modifier.flag)
            try postKey(
                keyCode: modifier.keyCode,
                keyDown: false,
                flags: currentFlags,
                source: source
            )
        }
    }

    private func postUnicodeCharacter(_ character: String, source: CGEventSource) throws {
        let utf16: [UniChar] = Array(character.utf16)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create Unicode keyboard events.")
        }

        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func postKey(
        keyCode: CGKeyCode,
        keyDown: Bool,
        flags: CGEventFlags,
        source: CGEventSource
    ) throws {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
            throw ScreenCommanderError.inputSynthesisFailed("Could not create key event for keycode \(keyCode).")
        }

        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
